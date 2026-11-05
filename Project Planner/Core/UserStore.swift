//
//  UserStore.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import Foundation
import SwiftUI
import Combine
import UIKit
import FirebaseAuth
import FirebaseFirestore

@MainActor
class UserStore: ObservableObject {
    @Published var currentUser: AppUser? {
        // RULEBOOK 1.10.0 §17: the job and booking read plans follow the signed-in profile.
        didSet { refreshJobAccessContext() }
    }
    /// When set, tab visibility and `can*` helpers use a simulated role. Identity and Firestore still use `currentUser`.
    @Published var roleTestingPreset: RoleTestingPreset?
    @Published var organizationUsers: [AppUser] = [] {
        didSet {
            restampSameEmailAliasesIfNeeded()
            // Rules that run without a store (`timesheetSelfSigned` in `TimesheetApprovalPolicy`) read this roster.
            RulebookRosterSnapshot.update(organizationUsers)
            refreshJobAccessContext()
            schedulePrivatePayOverlay()
        }
    }
    /// Bumped by every roster change, so an overlay that finishes after a newer roster arrived is dropped.
    private var privatePayOverlayGeneration = 0
    /// True while the overlay's own result is being published (it must not schedule another read).
    private var publishingPrivatePayOverlay = false
    /// RULEBOOK 1.31.0 §11: every `users` document of the open organisation, unfolded (one row per document, not per
    /// email), from the last roster load plus live changes. `organizationUserDocumentsOrganizationId` names its company.
    private(set) var organizationUserDocuments: [AppUser] = []
    private var organizationUserDocumentsOrganizationId: String?
    /// Folded same-email `users` document id → the id the roster kept, from the last roster load.
    /// Bookings saved under the folded id (often the person's sign-in uid) must count for the kept person.
    private(set) var organizationUserIdAliases: [String: String] = [:]
    /// Document ids of `organizations/{orgId}/userEmails/{email}` from the last successful roster read.
    /// Nil when that read has not completed or failed. People lists pass this into `listedRosterUsers`.
    @Published var organizationUserEmailClaims: Set<String>?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// RULEBOOK 1.13.0 §14 `selfEmailChangeSentMessage`: shown after a person asked to change their own sign-in email.
    @Published var selfEmailChangeNotice: String?
    
    private(set) var firebaseBackend: FirebaseBackend?
    /// Company activity notices written after Manage Users changes (RULEBOOK 1.31.0 `job_manager_removed`,
    /// `operative_deleted`). Set by `NotificationService.setUserStore`.
    weak var notificationService: NotificationService?
    private var smartCache: SmartCacheService?
    @Published var isOffline: Bool = false
    /// Throttle `lastSeenAt` writes (foreground heartbeats).
    private var lastSeenAtWriteTime: Date?
    /// Single-flight + short cooldown to prevent duplicate org user roster fetches.
    private var organizationUsersLoadInProgress = false
    /// The organisation whose roster load last finished (read or failed). Warnings wait for it
    /// (`WarningInputsReadiness`).
    private(set) var organizationUsersFinishedLoadOrganizationId: String?
    private var organizationUsersLoadGeneration = 0
    private var organizationUsersLoadOrganizationId: String?
    private var lastOrganizationUsersLoadAt: Date?
    private var currentUserListener: ListenerRegistration?
    private var currentUserListenerTarget: String?
    /// Counts `users/{uid}` snapshots; only the newest one's device-session result is applied (RULEBOOK §12:
    /// an older copy finishing its async step late must not roll back the photo or any other field).
    private var currentUserSnapshotGeneration = 0
    /// Live roster: `users where organizationId == org` (RULEBOOK §1, §11). Keyed to one organisation;
    /// results that arrive after an organisation switch are ignored.
    private var organizationUsersListener: ListenerRegistration?
    private var organizationUsersListenerOrganizationId: String?
    /// The organisation whose roster listener failed; the one-off load is the fallback there.
    private var organizationUsersListenerFailedOrganizationId: String?
    /// Stops a roster reload that started before a name save from putting the old name back.
    private var identityRevision: IdentityRevision?

    private struct IdentityRevision {
        var userIds: Set<String>
        var previousFirst: String
        var previousSurname: String
        var firstName: String
        var surname: String
        var email: String
        var mobile: String?
        var savedAt: Date
    }

    init() {
        // RULEBOOK 1.8.0 `CanonicalBusinessEngine.parseUserDocument` `annualLeaveDefaultsPending`: a user read before the organisation's
        // `annualLeaveDefaults` were loaded carries the rulebook default figures. Read them again once the
        // organisation document arrives (or its defaults change on another device).
        NotificationCenter.default.addObserver(
            forName: .organizationAnnualLeaveDefaultsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let changed = (note.userInfo?["changed"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.rereadUsersAfterLeaveDefaultsArrive(defaultsChanged: changed)
            }
        }
        NotificationCenter.default.addObserver(forName: .securitySwitchesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.securitySwitchesChanged() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// RULEBOOK 1.26.0 §8: while `privatePay` is on for the open organisation, every roster row's pay is read from the
    /// pay profiles this viewer may see (`CanonicalBusinessEngine.payProfileReadPlan` + `overlayPayProfile`), so
    /// timesheets, invoices, the weekly report and people lists keep showing pay after the strip. While it is off this
    /// does nothing: the users documents are shown as stored.
    private func schedulePrivatePayOverlay() {
        guard !publishingPrivatePayOverlay else { return }
        privatePayOverlayGeneration &+= 1
        guard SecuritySwitchContext.privatePay, let firebaseBackend, !organizationUsers.isEmpty else { return }
        let generation = privatePayOverlayGeneration
        let roster = organizationUsers
        Task { @MainActor [weak self] in
            let overlaid = await firebaseBackend.overlayRosterPayIfPrivate(roster)
            guard let self, generation == self.privatePayOverlayGeneration, overlaid != roster else { return }
            self.publishingPrivatePayOverlay = true
            self.organizationUsers = overlaid
            self.publishingPrivatePayOverlay = false
        }
    }

    /// A switch changed: on → lay the pay profiles over; off → read the roster again, so no overlaid value stays.
    private func securitySwitchesChanged() {
        if SecuritySwitchContext.privatePay {
            schedulePrivatePayOverlay()
        } else {
            Task { await loadOrganizationUsers(forceRefresh: true) }
        }
    }

    private func rereadUsersAfterLeaveDefaultsArrive(defaultsChanged: Bool) {
        guard firebaseBackend?.currentOrganization != nil else { return }
        if defaultsChanged || currentUser?.annualLeaveDefaultsPending == true {
            Task { await self.loadCurrentUser() }
        }
        if defaultsChanged || organizationUsers.contains(where: { $0.annualLeaveDefaultsPending }) {
            Task { await self.loadOrganizationUsers(forceRefresh: true) }
        }
    }
    
    /// Last-used organisation is `users/{uid}.organizationId`. `isActive == false` means that organisation deactivated them.
    var isDeactivatedForLastUsedOrganization: Bool {
        currentUser?.isActive == false
    }

    var lastUsedOrganizationId: String {
        let fromUser = currentUser?.organizationId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromUser.isEmpty { return fromUser }
        return firebaseBackend?.currentOrganization?.firestoreDocumentId ?? ""
    }

    func setFirebaseBackend(_ firebaseBackend: FirebaseBackend) {
        guard LaunchStartupPolicy.shouldRewireStore(isSameInstance: self.firebaseBackend === firebaseBackend) else { return }
        self.firebaseBackend = firebaseBackend
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
    }

    /// Writes `users/{uid}.lastSeenAt` (merge). Call from app foreground; throttled to ~2 minutes.
    func recordCurrentUserLastSeenIfDue() async {
        guard let firebaseBackend = firebaseBackend else { return }
        guard let uid = firebaseBackend.currentUser?.uid, !uid.isEmpty else { return }
        let now = Date()
        if let t = lastSeenAtWriteTime, now.timeIntervalSince(t) < 120 { return }
        lastSeenAtWriteTime = now
        do {
            try await firebaseBackend.updateUserLastSeenAt(userId: uid)
            if var cu = currentUser, cu.id == uid {
                cu.lastSeenAt = now
                currentUser = cu
            }
            if let idx = organizationUsers.firstIndex(where: { $0.id == uid }) {
                organizationUsers[idx].lastSeenAt = now
            }
        } catch {
            print("🔥🔥🔥 DEBUG: lastSeenAt heartbeat failed: \(error.localizedDescription)")
        }
    }

    /// Ensures an `operatives` roster row exists for this app user (matched by email) so qualifications can attach.
    func ensureOperativeProfileForAppUser(_ user: AppUser, operativeStore: OperativeStore) async -> Operative? {
        let emailNorm = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emailNorm.isEmpty else { return nil }
        if let existing = operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == emailNorm
        }) {
            return existing
        }
        let first = user.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (String(user.email.split(separator: "@").first ?? "User"))
            : user.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = user.surname.trimmingCharacters(in: .whitespacesAndNewlines)
        let op = Operative(
            firstName: first,
            lastName: last,
            email: user.email.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: user.mobileNumber,
            startDate: OrganizationRulebookContext.calendar.startOfDay(for: Date()),
            // Pay fields of `operatives/{id}` are written only by someone who may change this person's pay (§8).
            dayRate: canChangePay(of: user) ? user.dayRate : nil,
            tradeTypePreset: user.tradeTypePreset,
            tradeTypeCustom: user.tradeTypeCustom
        )
        await operativeStore.addOperative(op)
        return operativeStore.allOperatives.first(where: { $0.id == op.id }) ?? op
    }
    
    /// Effective user for UI and permission helpers (respects role testing).
    var displayUser: AppUser? {
        guard let base = currentUser else { return nil }
        guard let preset = roleTestingPreset else { return base }
        return Self.applyRoleTesting(preset, to: base)
    }

    /// Firebase Auth session exists but the org `AppUser` isn’t in memory yet. Home shouldn’t hide admin/manager tiles during this window.
    var isHomeProfileLoading: Bool {
        Auth.auth().currentUser != nil && currentUser == nil
    }
    
    /// Whether the signed-in account may open role testing (not available in real operative-only login).
    var canConfigureRoleTesting: Bool {
        guard let u = currentUser else { return false }
        if u.permissions.operativeMode { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.permissions.manager
    }
    
    private static func applyRoleTesting(_ preset: RoleTestingPreset, to user: AppUser) -> AppUser {
        var u = user
        switch preset {
        case .superAdmin:
            u.isSuperAdmin = true
            u.permissions = UserPermissions(
                adminAccess: true,
                manager: true,
                operatives: true,
                skills: false,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                siteAudit: true
            )
            u.role = .admin
        case .admin:
            u.isSuperAdmin = false
            u.permissions = UserPermissions(
                adminAccess: true,
                manager: true,
                operatives: true,
                skills: false,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                siteAudit: true
            )
            u.role = .admin
        case .manager:
            u.isSuperAdmin = false
            u.permissions = UserPermissions(
                adminAccess: false,
                manager: true,
                operatives: true,
                skills: false,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                siteAudit: true
            )
            u.role = .manager
        case .operative:
            u.isSuperAdmin = false
            u.permissions = UserPermissions(
                adminAccess: false,
                manager: false,
                operatives: false,
                skills: false,
                qualifications: false,
                materials: false,
                projects: true,
                smallWorks: true,
                operativeMode: true,
                siteAudit: true
            )
            u.role = .operative
        }
        return u
    }
    
    // MARK: - User Management
    
    func loadCurrentUser() async {
        guard let firebaseBackend = firebaseBackend else {
            print("🔥🔥🔥 DEBUG: loadCurrentUser skipped — FirebaseBackend not wired yet")
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            if let firebaseUser = Auth.auth().currentUser {
                // Load user data from Firestore
                var userData = try await firebaseBackend.getUserData(userId: firebaseUser.uid)

                // Org load runs in parallel from the auth listener; first profile fetch can win the race and see no org.
                if userData == nil, firebaseBackend.currentOrganization == nil {
                    print("🔥🔥🔥 DEBUG: Profile/org race — loading organization before user document")
                    await firebaseBackend.loadUserOrganizationWithRecovery(userId: firebaseUser.uid)
                    userData = try await firebaseBackend.getUserData(userId: firebaseUser.uid)
                }
                
                // If user doesn't exist or isn't a super admin, check if they created the organization
                if userData == nil, let organization = firebaseBackend.currentOrganization {
                    // A cache miss is not proof the account is gone. Writing a new profile over `users/{uid}`
                    // used to replace the real document. Only create when the server confirms it is missing.
                    let probe = await firebaseBackend.probeOrganizationUser(
                        userId: firebaseUser.uid,
                        organizationId: organization.firestoreDocumentId
                    )
                    switch probe {
                    case .present(let existing):
                        userData = existing
                    case .unconfirmed, .permissionDenied:
                        print("🔥🔥🔥 DEBUG: Not creating a user document — the server did not confirm users/\(firebaseUser.uid) is missing")
                    case .confirmedMissing:
                        let superAdminPermissions = UserPermissions(
                            adminAccess: true,
                            operatives: true,
                            skills: false,
                            qualifications: true,
                            materials: true,
                            projects: true,
                            smallWorks: true
                        )
                        userData = AppUser(
                            id: firebaseUser.uid,
                            email: firebaseUser.email ?? "",
                            organizationId: organization.firestoreDocumentId,
                            role: .admin,
                            createdAt: Date(),
                            firstName: "",
                            surname: "",
                            isActive: true,
                            passwordSet: true,
                            permissions: superAdminPermissions,
                            isSuperAdmin: true, // Organization creator = super admin
                            policyAccepted: false,
                            policyAcceptedAt: nil
                        )
                        try await firebaseBackend.saveUser(userData!)
                    }
                }

                if let loaded = userData {
                    // Paint with the profile already read. The phone-session overlay must not hold Home blank.
                    self.currentUser = loaded
                    userData = await firebaseBackend.applyDeviceSessionIfNeeded(to: loaded)
                }
                self.currentUser = userData
                startCurrentUserListener(userId: firebaseUser.uid)

                if userData?.isActive == false {
                    isLoading = false
                    return
                }

                // Load org roster in the background so a slow / stuck org query cannot block the main shell.
                Task { await self.loadOrganizationUsers() }
            }
        } catch {
            errorMessage = "Failed to load user data: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error loading current user: \(error)")
        }

        if currentUser == nil, let firebaseUser = Auth.auth().currentUser,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
           !organizationId.isEmpty {
            currentUser = provisionalSessionUser(
                firebaseUser: firebaseUser,
                organizationId: organizationId
            )
            print("🔥🔥🔥 DEBUG: Using provisional session profile so the main shell can render")
        }
        
        isLoading = false
    }

    /// Leaves the launch splash if the profile read has not returned. Uses the organisation already stored on this phone.
    func unblockLaunchProfileIfNeeded() {
        guard currentUser == nil, let firebaseUser = Auth.auth().currentUser else { return }
        let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId
            ?? firebaseBackend?.cachedOrganizationDocumentId()
            ?? ""
        currentUser = provisionalSessionUser(firebaseUser: firebaseUser, organizationId: organizationId)
        print("🔥🔥🔥 DEBUG: Launch profile opened locally org=\(organizationId.isEmpty ? "none yet" : organizationId)")
    }

    /// Minimal profile when Firestore is slow or unreachable — keeps `isHomeProfileLoading` false enough to show UI.
    private func provisionalSessionUser(firebaseUser: FirebaseAuth.User, organizationId: String) -> AppUser {
        let email = firebaseUser.email ?? ""
        let namePart = email.components(separatedBy: "@").first ?? ""
        var placeholder = AppUser(
            id: firebaseUser.uid,
            email: email,
            organizationId: organizationId,
            role: .manager,
            firstName: namePart.capitalized,
            surname: "",
            passwordSet: true,
            permissions: UserPermissions(
                adminAccess: true,
                manager: true,
                operatives: true,
                skills: false,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                siteAudit: true,
                wholesalersOrderHistory: true
            ),
            policyAccepted: true
        )
        // Not read from `users/{uid}`: the legal gate waits for the real document (`AppUser.showsLegalPackGate`).
        placeholder.isProvisional = true
        return placeholder
    }
    
    /// Puts the last roster saved on this phone on screen before a network load.
    /// An organisation switch must not sit on an empty list, and it must not keep the previous organisation's people.
    func showCachedRoster(for organizationId: String) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        let cached = RosterRetention.users(for: orgId)
        if organizationUsersListenerOrganizationId != orgId {
            // The previous organisation's live roster must not keep writing into this one.
            stopOrganizationUsersListener()
        }
        organizationUsers = cached
        organizationUserEmailClaims = nil
        organizationUsersLoadOrganizationId = orgId
        let managers = cached.filter(\.appearsOnManagersList).count
        let operatives = cached.filter(\.appearsOnOperativesList).count
        print("🔥🔥🔥 DEBUG: ROSTER_RESTORED org=\(orgId) count=\(cached.count) managers=\(managers) operatives=\(operatives)")
    }

    /// One-off roster load (members, email claims and staff links included), then the live listener on the
    /// organisation's users query keeps it current. `forceRefresh` skips the short repeat-load cooldown.
    func loadOrganizationUsers(forceRefresh: Bool = false) async {
        guard let firebaseBackend = firebaseBackend,
              let currentUser = currentUser else {
            print("🔥🔥🔥 DEBUG: Cannot load users - missing firebaseBackend or currentUser")
            return
        }
        // The open organisation is `FirebaseBackend.currentOrganization` (AGENTS rule 2). `currentUser.organizationId`
        // is only a fallback: before the phone-session overlay lands it is `users/{uid}.organizationId`, the company
        // the person last opened, and loading that roster showed another company's people here.
        let requestedOrganizationId = Self.rosterOrganizationId(
            openOrganizationId: firebaseBackend.currentOrganization?.firestoreDocumentId,
            profileOrganizationId: currentUser.organizationId
        )
        guard !requestedOrganizationId.isEmpty else {
            print("🔥🔥🔥 DEBUG: ROSTER_LOAD skipped — no organisation id, leaving the current list in place")
            return
        }
        let sameOrgInFlight = organizationUsersLoadInProgress && organizationUsersLoadOrganizationId == requestedOrganizationId
        if sameOrgInFlight {
            return
        }
        let now = Date()
        // A one-person roster, or a roster with nobody on Managers or Operatives, is the failure mode.
        // Do not treat that as a fresh success and ignore the next load for 3 seconds.
        let cachedCount = RosterRetention.users(for: requestedOrganizationId).count
        let listedStaff = organizationUsers.filter { $0.appearsOnManagersList || $0.appearsOnOperativesList }.count
        let rosterLooksComplete = organizationUsers.count > 1
            && listedStaff > 0
            && cachedCount <= organizationUsers.count
        if !forceRefresh,
           rosterLooksComplete,
           organizationUsersLoadOrganizationId == requestedOrganizationId,
           let last = lastOrganizationUsersLoadAt,
           now.timeIntervalSince(last) < 3 {
            return
        }
        organizationUsersLoadGeneration += 1
        let generation = organizationUsersLoadGeneration
        organizationUsersLoadOrganizationId = requestedOrganizationId
        organizationUsersLoadInProgress = true
        defer {
            if organizationUsersLoadGeneration == generation {
                organizationUsersLoadInProgress = false
                lastOrganizationUsersLoadAt = Date()
                organizationUsersFinishedLoadOrganizationId = requestedOrganizationId
            }
        }

        if organizationUsers.isEmpty {
            let cached = RosterRetention.users(for: requestedOrganizationId)
            if !cached.isEmpty {
                organizationUsers = cached
                print("🔥🔥🔥 DEBUG: ROSTER_RESTORED before fetch count=\(cached.count)")
            }
        }
        
        print("🔥🔥🔥 DEBUG: loadOrganizationUsers called for organizationId: \(requestedOrganizationId)")
        
        // The signed-in account and the creator are never deleted in-app (`canDeleteUser`): lift any burial an older
        // build left after one denied read, or they stay off this phone's roster for good.
        let signedInUserId = Auth.auth().currentUser?.uid ?? currentUser.id
        RosterRetention.untombstone(
            [signedInUserId, firebaseBackend.currentOrganization?.creatorUserId ?? ""],
            organizationId: requestedOrganizationId
        )

        do {
            let roster = try await firebaseBackend.getOrganizationUsers(
                organizationId: requestedOrganizationId,
                signedInUserId: signedInUserId
            )
            // Rows the rulebook could not read (no role, no permissions) never replace rows it did read.
            let users = Self.rosterKeepingReadRows(roster.users, onScreen: organizationUsers)
            guard generation == organizationUsersLoadGeneration else {
                print("🔥🔥🔥 DEBUG: Ignoring organisation user roster for \(requestedOrganizationId) — a newer organisation load replaced it")
                return
            }
            let stillSameOrg = normalizedOrganizationId(self.currentUser?.organizationId ?? "") == requestedOrganizationId
                || normalizedOrganizationId(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") == requestedOrganizationId
            guard stillSameOrg else {
                print("🔥🔥🔥 DEBUG: Ignoring organisation user roster for \(requestedOrganizationId) — the signed-in organisation changed")
                return
            }
            print("🔥🔥🔥 DEBUG: Loaded \(users.count) users from Firebase")
            for user in users {
                print("🔥🔥🔥 DEBUG: - \(user.email) (\(user.firstName) \(user.surname)) - Active: \(user.isActive), PasswordSet: \(user.passwordSet)")
            }

            // `users/{uid}` is the only source of pay and line manager (RULEBOOK §1, §8). The
            // `operativeProfiles` mirror and on-device copies are never laid over it.
            let anchored = roster.anchoredUserIds
                .union([signedInUserId, firebaseBackend.currentOrganization?.creatorUserId ?? ""].filter { !$0.isEmpty })
            let healed = await healRosterKeepingKnownPeople(
                incoming: users,
                organizationId: requestedOrganizationId,
                anchoredIds: anchored
            )
            // Healing probes absent people for up to 8 seconds. A save made meanwhile (a role change) ends this
            // load: its server copy is older than what the save wrote, so it is never published.
            guard generation == organizationUsersLoadGeneration else {
                print("🔥🔥🔥 DEBUG: Ignoring organisation user roster for \(requestedOrganizationId) — a save or a newer load replaced it while healing")
                return
            }
            guard let listed = CanonicalBusinessEngine.listedRosterUsers(healed, claimedEmails: roster.claimedEmails) else {
                print("🔥🔥🔥 DEBUG: ROSTER_LIST script did not return a list — keeping the roster already on screen")
                ReaderDiagnostics.shared.record(
                    collection: "users",
                    rowCount: healed.count,
                    parsedCount: 0,
                    keptCount: organizationUsers.count,
                    source: "roster load (listedRosterUsers did not answer)"
                )
                return
            }
            // People documents arrived but none could be read or listed: keep the roster on screen (and the saved
            // copy), never publish and save an empty one.
            if LiveSnapshotMerge.refusesUnreadSnapshot(
                collection: "users",
                rowCount: roster.users.count,
                parsedCount: listed.filter { !$0.parsedWithoutRulebook }.count,
                existingCount: organizationUsers.count,
                fromCache: false
            ) {
                return
            }
            organizationUserEmailClaims = roster.claimedEmails
            organizationUserIdAliases = roster.userIdAliases
            organizationUserDocuments = roster.documents
            organizationUserDocumentsOrganizationId = requestedOrganizationId
            publishRoster(listed, organizationId: requestedOrganizationId)
            startOrganizationUsersListener(organizationId: requestedOrganizationId)
        } catch {
            errorMessage = "Failed to load organization users: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error loading organization users: \(error)")
            if organizationUsers.isEmpty {
                let cached = RosterRetention.users(for: requestedOrganizationId)
                if !cached.isEmpty {
                    organizationUsers = cached
                    print("🔥🔥🔥 DEBUG: ROSTER_KEPT cached count=\(cached.count) after fetch error")
                }
            } else {
                print("🔥🔥🔥 DEBUG: ROSTER_KEPT on-screen count=\(organizationUsers.count) after fetch error")
            }
        }
    }

    /// The fetched roster with every row `parseUserDocument` could not read replaced by the row already on screen
    /// for that id (when there is one). Nothing is decided about the person here.
    static func rosterKeepingReadRows(_ fetched: [AppUser], onScreen: [AppUser]) -> [AppUser] {
        guard fetched.contains(where: \.parsedWithoutRulebook) else { return fetched }
        var known: [String: AppUser] = [:]
        for user in onScreen where !user.parsedWithoutRulebook && known[user.id] == nil { known[user.id] = user }
        let kept = fetched.map { user in user.parsedWithoutRulebook ? (known[user.id] ?? user) : user }
        NSLog(
            "ROSTER_UNREAD_ROWS unread=%d of %d — kept %d rows already on screen",
            fetched.filter(\.parsedWithoutRulebook).count,
            fetched.count,
            zip(fetched, kept).filter { $0.0.parsedWithoutRulebook && !$0.1.parsedWithoutRulebook }.count
        )
        return kept
    }

    /// The organisation whose roster to load: the open one, else the profile's. Not a business rule — which
    /// company is open is `chooseSessionOrganization`, already applied to `currentOrganization`.
    static func rosterOrganizationId(openOrganizationId: String?, profileOrganizationId: String) -> String {
        let open = normalizedOrganizationId(openOrganizationId ?? "")
        if !open.isEmpty { return open }
        return normalizedOrganizationId(profileOrganizationId)
    }

    /// One live-listener snapshot laid over the roster on screen, before the `rosterPeople` fold.
    /// Changed rows replace or join by id; a row the snapshot does not mention — including one that left the
    /// `organizationId` query (`removedIds`) — stays. Someone found through the members map, a membership, the
    /// creator or a staff link has a `users` document naming another company, so this query never returns them;
    /// only the full load decides who leaves (RULEBOOK §1).
    static func liveRosterMerge(
        onScreen: [AppUser],
        changed: [AppUser],
        isTombstoned: (String) -> Bool
    ) -> [AppUser] {
        var byId: [String: AppUser] = [:]
        var order: [String] = []
        for user in onScreen where byId[user.id] == nil {
            byId[user.id] = user
            order.append(user.id)
        }
        for incoming in changed where !isTombstoned(incoming.id) {
            var user = incoming
            if user.parsedWithoutRulebook, let existing = byId[user.id], !existing.parsedWithoutRulebook {
                NSLog("ROSTER_ROW_KEPT id=%@ — parseUserDocument did not answer for the live copy", user.id)
                continue
            }
            if let existing = byId[user.id] {
                user.sameEmailUserIds = existing.sameEmailUserIds
            } else {
                order.append(user.id)
            }
            byId[user.id] = user
        }
        return order.compactMap { byId[$0] }
    }

    /// Sorts and publishes a `listedRosterUsers` result and saves it on this phone.
    private func publishRoster(_ listed: [AppUser], organizationId: String) {
        let sortedUsers = listed.sorted { user1, user2 in
            if user1.isSuperAdmin != user2.isSuperAdmin {
                return user1.isSuperAdmin
            }
            return user1.email < user2.email
        }
        let published = sortedUsers.filter(\.isStoredUserDocument)
        organizationUsers = published
        // Empty is stored only when this load ended with nobody. People the server could not
        // confirm as gone stay in `published`, so a short fetch cannot wipe the saved roster.
        // Save the list with its same-email ids put back, so a cold start still matches bookings.
        RosterRetention.save(
            organizationUsers,
            organizationId: organizationId,
            allowEmpty: published.isEmpty
        )
        let admins = published.filter(\.appearsOnAdminsList).count
        let managers = published.filter(\.appearsOnManagersList).count
        let operatives = published.filter(\.appearsOnOperativesList).count
        print("🔥🔥🔥 DEBUG: ROSTER_PUBLISHED count=\(published.count) admins=\(admins) managers=\(managers) operatives=\(operatives)")
    }

    private func stopOrganizationUsersListener() {
        organizationUsersListener?.remove()
        organizationUsersListener = nil
        organizationUsersListenerOrganizationId = nil
    }

    /// Attaches the live roster listener for `organizationId` (replacing one for another organisation).
    /// If it cannot start or fails, the one-off load stays the source for that organisation.
    private func startOrganizationUsersListener(organizationId: String) {
        guard let firebaseBackend else { return }
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        if organizationUsersListener != nil, organizationUsersListenerOrganizationId == orgId { return }
        if organizationUsersListenerFailedOrganizationId == orgId { return }
        stopOrganizationUsersListener()
        organizationUsersListenerOrganizationId = orgId
        organizationUsersListener = firebaseBackend.observeOrganizationUsers(
            organizationId: orgId,
            onChange: { [weak self] changed, removedIds in
                self?.applyLiveRosterChange(changed: changed, removedIds: removedIds, organizationId: orgId)
            },
            onError: { [weak self] error in
                guard let self, self.organizationUsersListenerOrganizationId == orgId else { return }
                print("🔥🔥🔥 DEBUG: ROSTER_LISTENER failed org=\(orgId): \(error.localizedDescription) — using one-off loads")
                self.stopOrganizationUsersListener()
                self.organizationUsersListenerFailedOrganizationId = orgId
            }
        )
        if organizationUsersListener == nil {
            organizationUsersListenerOrganizationId = nil
            organizationUsersListenerFailedOrganizationId = orgId
        }
    }

    /// A snapshot from the live roster query, fed through the same pipeline as a load
    /// (`rosterPeople` fold, then `listedRosterUsers`). Ignored after an organisation switch.
    private func applyLiveRosterChange(changed: [AppUser], removedIds: [String], organizationId: String) {
        guard organizationUsersListenerOrganizationId == organizationId else { return }
        let stillSameOrg = normalizedOrganizationId(currentUser?.organizationId ?? "") == organizationId
            || normalizedOrganizationId(firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "") == organizationId
        guard stillSameOrg, organizationUsersLoadOrganizationId == organizationId else { return }
        if !removedIds.isEmpty {
            // Leaving the query is not proof someone left the company (they may have opened another
            // organisation last). The full load confirms who is still a member.
            Task { await self.loadOrganizationUsers(forceRefresh: true) }
        }
        guard !changed.isEmpty else { return }
        if organizationUserDocumentsOrganizationId == organizationId {
            organizationUserDocuments = Self.liveRosterMerge(
                onScreen: organizationUserDocuments,
                changed: changed,
                isTombstoned: { RosterRetention.isTombstoned($0, organizationId: organizationId) }
            )
        }
        let merged = Self.liveRosterMerge(
            onScreen: organizationUsers,
            changed: changed,
            isTombstoned: { RosterRetention.isTombstoned($0, organizationId: organizationId) }
        )
        let folded = collapseRosterByEmail(merged)
        guard let listed = CanonicalBusinessEngine.listedRosterUsers(folded, claimedEmails: organizationUserEmailClaims) else {
            print("🔥🔥🔥 DEBUG: ROSTER_LISTENER script did not return a list — keeping the roster on screen")
            return
        }
        if LiveSnapshotMerge.refusesUnreadSnapshot(
            collection: "users (live)",
            rowCount: folded.count,
            parsedCount: listed.count,
            existingCount: organizationUsers.count,
            fromCache: false
        ) {
            return
        }
        publishRoster(listed, organizationId: organizationId)
    }

    #if DEBUG
    /// Unit tests: the alias map a roster load would set.
    func applyRosterAliasesForTesting(_ aliases: [String: String]) {
        organizationUserIdAliases = aliases
        restampSameEmailAliasesIfNeeded()
    }
    #endif

    /// Puts every folded same-email id back on the person it was folded into. Several paths replace
    /// people in `organizationUsers` (cache restore, healing, profile edits); none may lose these ids,
    /// or bookings under them stop counting for that person on Daily Overview, warnings, the weekly
    /// report, and timesheets (`bookingIdsForAccount` / `resolveBookingPerson` read them as `aliasIds`).
    private func restampSameEmailAliasesIfNeeded() {
        guard !organizationUserIdAliases.isEmpty else { return }
        var foldedByKept: [String: Set<String>] = [:]
        for (folded, kept) in organizationUserIdAliases {
            foldedByKept[kept, default: []].insert(folded)
        }
        var changed = false
        var users = organizationUsers
        for index in users.indices {
            guard let folded = foldedByKept[users[index].id] else { continue }
            let merged = Set(users[index].sameEmailUserIds).union(folded).subtracting([users[index].id])
            if merged != Set(users[index].sameEmailUserIds) {
                users[index].sameEmailUserIds = merged.sorted()
                changed = true
            }
        }
        if changed { organizationUsers = users }
    }

    /// A short Firestore query must not delete managers or operatives who were already on the list.
    /// Someone leaves when their user document is confirmed gone, an admin deletes them, or that
    /// document's read is permission-denied. A timeout is not a reason to drop them.
    /// `anchoredIds` (members map, creator, signed-in account) leave only when their document is confirmed gone.
    private func healRosterKeepingKnownPeople(
        incoming: [AppUser],
        organizationId: String,
        anchoredIds: Set<String> = []
    ) async -> [AppUser] {
        guard let firebaseBackend else { return incoming }
        var byId: [String: AppUser] = [:]
        for user in RosterRetention.users(for: organizationId) where user.isStoredUserDocument && !RosterRetention.isTombstoned(user.id, organizationId: organizationId) {
            byId[user.id] = user
        }
        let inMemoryMatchesOrg = !organizationUsers.isEmpty
            && organizationUsersLoadOrganizationId == normalizedOrganizationId(organizationId)
        if inMemoryMatchesOrg {
            for user in organizationUsers where user.isStoredUserDocument && !RosterRetention.isTombstoned(user.id, organizationId: organizationId) {
                byId[user.id] = user
            }
        }
        let incomingIds = Set(incoming.map(\.id))
        for user in incoming where user.isStoredUserDocument && !RosterRetention.isTombstoned(user.id, organizationId: organizationId) {
            var stored = user
            if let rev = identityRevision,
               rev.userIds.contains(user.id),
               Date().timeIntervalSince(rev.savedAt) < 30,
               stored.firstName == rev.previousFirst,
               stored.surname == rev.previousSurname {
                stored.firstName = rev.firstName
                stored.surname = rev.surname
                stored.email = rev.email
                stored.mobileNumber = rev.mobile
            }
            byId[user.id] = stored
        }
        let missingIds = byId.keys.filter { id in
            !incomingIds.contains(id) && !id.hasPrefix("directory:")
        }
        let started = Date()
        for id in missingIds {
            if Date().timeIntervalSince(started) > 8 {
                print("🔥🔥🔥 DEBUG: ROSTER_KEPT remaining people — stopped confirming absences after 8s")
                break
            }
            let probe = await firebaseBackend.probeOrganizationUser(userId: id, organizationId: organizationId)
            let read: LaunchStartupPolicy.RosterUserDocumentRead
            switch probe {
            case .present:
                read = .present
            case .confirmedMissing:
                read = .confirmedMissing
            case .permissionDenied:
                read = .permissionDenied
            case .unconfirmed:
                read = .unconfirmed
            }
            switch LaunchStartupPolicy.rosterAbsenceDecision(read, anchored: anchoredIds.contains(id)) {
            case .keep:
                if case .present(let user) = probe {
                    byId[id] = user
                } else {
                    print("🔥🔥🔥 DEBUG: ROSTER_KEPT \(byId[id]?.email ?? id) — this fetch missed them and their document was not confirmed gone")
                }
            case .drop:
                byId.removeValue(forKey: id)
                if read == .permissionDenied {
                    // Off this list only. A denied read is never a tombstone: a burial outlived the read and kept the
                    // person (the super admin included) off this phone's roster on every later load, under any account.
                    print("🔥🔥🔥 DEBUG: ROSTER_DROPPED \(id) — user document read was denied")
                } else {
                    print("🔥🔥🔥 DEBUG: ROSTER_CONFIRMED_GONE \(id)")
                }
            }
        }
        return collapseRosterByEmail(Array(byId.values))
    }

    /// Two `users` documents can share an email. The Managers list must show that person once.
    /// Same rule as the roster load: `rosterPeople` through `FirebaseBackend.foldRosterBySameEmail`.
    private func collapseRosterByEmail(_ users: [AppUser]) -> [AppUser] {
        let folded = FirebaseBackend.foldRosterBySameEmail(users)
        for (alias, kept) in folded.aliases where organizationUserIdAliases[alias] != kept {
            organizationUserIdAliases[alias] = kept
        }
        return folded.users
    }
    
    /// The roster row for `userId` under any of the person's ids: the row with that id (ignoring case), else the row
    /// the `rosterPeople` fold kept for it (`sameEmailUserIds`, `formerUserIds`, `userIdAliases`). Two `users`
    /// documents on one email are one row, and which document the fold keeps can change when a save writes both (a
    /// user type change writes every same-email document): a lookup by the exact id an editor opened then missed the
    /// person ("not in the loaded user list") although the change had landed. Nothing about the person is decided
    /// here; the fold is the rulebook's.
    static func rosterIndex(for userId: String, in users: [AppUser], aliases: [String: String]) -> Int? {
        let wanted = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if let exact = users.firstIndex(where: { $0.id == wanted }) { return exact }
        if let index = users.firstIndex(where: { same($0.id, wanted) }) { return index }
        if let index = users.firstIndex(where: { user in
            user.sameEmailUserIds.contains { same($0, wanted) } || user.formerUserIds.contains { same($0, wanted) }
        }) {
            return index
        }
        if let kept = aliases.first(where: { same($0.key, wanted) })?.value,
           let index = users.firstIndex(where: { same($0.id, kept) }) {
            return index
        }
        return nil
    }

    /// `rosterIndex(for:in:aliases:)` over the roster on screen.
    func rosterIndex(for userId: String) -> Int? {
        Self.rosterIndex(for: userId, in: organizationUsers, aliases: organizationUserIdAliases)
    }

    /// The roster row for `userId` under any of the person's ids (`rosterIndex(for:)`).
    func rosterRow(for userId: String) -> AppUser? {
        rosterIndex(for: userId).map { organizationUsers[$0] }
    }

    /// RULEBOOK 1.31.0 §11 (platform guardrail 1): every users document of the open organisation, unfolded. Falls
    /// back to the folded roster (with each person's same-email ids as rows of their own) until a full load has read
    /// the documents for this organisation.
    var unfoldedOrganizationUsers: [AppUser] {
        let openOrg = normalizedOrganizationId(firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "")
        if !organizationUserDocuments.isEmpty, organizationUserDocumentsOrganizationId == openOrg {
            var rows = organizationUserDocuments
            // A person on screen the document read did not return (anchored, healed) stays in.
            let known = Set(rows.map { $0.id.lowercased() })
            rows += organizationUsers.filter { !known.contains($0.id.lowercased()) }
            return rows
        }
        return organizationUsers
    }

    /// `RulebookPeople.roster` over the unfolded documents, with `organizationId` as each document stores it.
    var unfoldedRosterRows: [[String: Any]] {
        unfoldedOrganizationUsers.map { user in
            var row = RulebookPeople.person(user)
            row["organizationId"] = user.storedOrganizationId ?? user.organizationId
            row["firstName"] = user.firstName
            row["surname"] = user.surname
            return row
        }
    }

    /// Call when the user signs out so deleted/other-org users don't persist in the UI.
    func clearOnSignOut() {
        stopOrganizationUsersListener()
        organizationUsersListenerFailedOrganizationId = nil
        currentUserListener?.remove()
        currentUserListener = nil
        currentUserListenerTarget = nil
        currentUserSnapshotGeneration += 1
        organizationUsers = []
        organizationUserDocuments = []
        organizationUserDocumentsOrganizationId = nil
        organizationUsersFinishedLoadOrganizationId = nil
        organizationUserEmailClaims = nil
        currentUser = nil
        roleTestingPreset = nil
        errorMessage = nil
    }

    private func startCurrentUserListener(userId: String) {
        guard let firebaseBackend else { return }
        let target = "user:\(userId)"
        guard LaunchStartupPolicy.shouldAttachListener(
            activeTarget: currentUserListenerTarget,
            requestedTarget: target
        ) else { return }
        currentUserListener?.remove()
        currentUserListenerTarget = target
        currentUserListener = firebaseBackend.observeCurrentUserDocument(userId: userId) { [weak self] user in
            guard let self, let user else { return }
            // A copy the rulebook could not read has no role or permissions: keep the profile already read.
            if user.parsedWithoutRulebook, let existing = self.currentUser, existing.id == user.id, !existing.parsedWithoutRulebook {
                NSLog("CURRENT_USER_KEPT id=%@ — parseUserDocument did not answer for the live copy", user.id)
                return
            }
            self.currentUserSnapshotGeneration += 1
            let generation = self.currentUserSnapshotGeneration
            Task { @MainActor in
                let resolved = await self.firebaseBackend?.applyDeviceSessionIfNeeded(to: user) ?? user
                // A newer snapshot arrived while this one was resolved: it decides the profile.
                guard generation == self.currentUserSnapshotGeneration else { return }
                self.currentUser = resolved
            }
        }
    }
    
    // MARK: - Permission Checks
    
    func hasPermission(_ permission: (AppUser) -> Bool) -> Bool {
        // Firestore profile not loaded yet but Auth session exists — keep gates open so admin/manager shells
        // (Manage Users, holiday, etc.) don’t flash “access denied” or empty permission state during startup.
        guard let user = displayUser else {
            return Auth.auth().currentUser != nil
        }
        return permission(user)
    }
    
    // MARK: - Admin, then operative, then manager
    
    // Admin wins over operativeMode. A super admin or admin is not placed on Operatives.
    func hasAdminAccess() -> Bool {
        guard let currentUser = displayUser else { return false }
        return currentUser.isRosterAdmin
    }

    /// Holiday stays available when a person has no paid allowance. `annualLeaveEnabled` is the allowance, not this switch.
    func isAnnualLeaveFeatureEnabled() -> Bool {
        true
    }

    /// Shared cross-platform nav label from `organizations/{orgId}.settings.uiLabels.navigationLabels`.
    /// Returns `fallback` when the key is not configured.
    func navigationLabel(_ key: String, fallback: String) -> String {
        guard let org = firebaseBackend?.currentOrganization else {
            return Self.normalizedScheduleNavigationLabel(key: key, value: fallback)
        }
        let value = org.settings.uiLabels.navigationLabel(for: key, fallback: fallback)
        return Self.normalizedScheduleNavigationLabel(key: key, value: value)
    }

    /// Legacy orgs may still store "Schedule" for the shared dashboard key.
    private static func normalizedScheduleNavigationLabel(key: String, value: String) -> String {
        guard key == "dashboard_schedule" else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "schedule" || lower == "my schedule" {
            return "My Schedule"
        }
        if !lower.contains("my") && lower.contains("schedule") {
            return "My Schedule"
        }
        return value
    }
    
    // Simplified permission checks using user.permissions. Operatives get restricted access.
    func canManageUsers() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess() || hasPermission { $0.permissions.adminAccess }
    }
    
    func canViewOperatives() -> Bool {
        if isOperativeMode() { return false }
        guard let u = displayUser else { return false }
        // Super admin keeps the Operatives page. Everyone else follows `canManageOperatives` (RULEBOOK §11: above
        // operative level with the Operatives toggle in effect; admins have it on and locked).
        if u.isSuperAdmin { return true }
        return CanonicalBusinessEngine.canManageOperatives(u.permissionSubject)
    }
    
    /// Organisation material catalogue (batch upload, CRUD). Admins and managers only — not operatives with project materials access.
    func canManageMaterialCatalogue() -> Bool {
        if isOperativeMode() { return false }
        guard let u = displayUser else { return false }
        return hasAdminAccess() || u.permissions.manager
    }

    /// Wholesalers page. Off hides the page. Super admin is unchanged.
    func canAccessWholesalers() -> Bool {
        if isOperativeMode() { return false }
        guard let u = displayUser else { return false }
        if u.isSuperAdmin { return true }
        let isStaff = u.permissions.manager || u.permissions.adminAccess || u.role == .admin || u.role == .manager
        return isStaff && u.effectivePermissions.wholesalersOrderHistory
    }

    /// Quote and order history follows the same Wholesalers toggle as the page.
    func canViewWholesalerOrderHistory() -> Bool {
        canAccessWholesalers()
    }

    /// Skills catalogue management has been removed from the product.
    func canManageSkills() -> Bool {
        false
    }

    /// Organisation qualification templates (add / rename / delete).
    /// Super admin always can. Admins and managers follow the Qualifications toggle.
    ///
    /// **Permission scope (important):** toggling `permissions.qualifications` only
    /// changes who may open the Organisation Qualifications editor. It must never
    /// delete or rewrite:
    /// - `organizations/{orgId}/qualifications` (org catalogue — shared org data)
    /// - any staff member's assigned qualifications / expiry / certificates on
    ///   their operative profile (including the manager's own My Qualifications)
    /// Templates someone created while they had manage access remain org property.
    func canManageOrganisationQualifications() -> Bool {
        QualificationsAccessPolicy.canManageOrganisationCatalogue(
            user: displayUser,
            isOperativeMode: isOperativeMode(),
            hasAdminAccess: hasAdminAccess()
        )
    }

    /// Opens the Qualifications hub (org templates and/or My Qualifications).
    /// Admins and managers always get at least My Qualifications; operatives use `my_qualifications`.
    /// Losing manage-org access still leaves this true for managers so My Qualifications remains available.
    func canAccessQualificationsHub() -> Bool {
        QualificationsAccessPolicy.canOpenQualificationsHub(
            user: displayUser,
            isOperativeMode: isOperativeMode(),
            hasAdminAccess: hasAdminAccess()
        )
    }
    
    func canManageQualifications() -> Bool {
        canManageOrganisationQualifications()
    }
    
    func canViewProjects() -> Bool {
        return true
    }

    func organizationAnnualLeaveDefaults() -> OrganizationAnnualLeaveDefaults {
        firebaseBackend?.currentOrganization?.settings.annualLeaveDefaults ?? .default
    }

    func canViewMaterials() -> Bool {
        if isOperativeMode() {
            return displayUser?.effectivePermissions.materials == true
        }
        return true
    }

    func canAccessInvoicing() -> Bool {
        canAccessTimesheetsSurface()
    }

    /// Self-employed users can submit their own timesheets. PAYE users keep access until the open pay run is paid
    /// when that period still includes self-employed days (e.g. after switching from self-employed to PAYE).
    func canAccessMyTimesheets() -> Bool {
        guard let user = displayUser else { return false }
        let settings = firebaseBackend?.currentOrganization?.settings.invoicing ?? .default
        return TimesheetPayrollPolicy.canAccessMyTimesheets(user: user, settings: settings)
    }

    /// Operative timesheets visibility:
    /// - Admin/super-admin accounts (`seesEveryUserTimesheet`) always have User Timesheets, even while the
    ///   roster is loading or the company has no active operative. The roster must not turn an admin's hub
    ///   into the operative one.
    /// - Managers: `userTimesheetSubjects` once the packed script has it (anyone active they line-manage,
    ///   under any of their ids). Before that, the previous check stays: an active operative-mode report.
    /// - While the profile or this organisation's roster is still loading, a manager keeps the screen.
    func canAccessOperativeTimesheets() -> Bool {
        guard let user = displayUser else { return false }
        let role = Self.staffAccountRole(for: user)
        guard CanonicalBusinessEngine.canReviewUserTimesheets(role) == true else {
            return false
        }
        if CanonicalBusinessEngine.seesEveryUserTimesheet(role) == true {
            return true
        }
        if isUserTimesheetRosterLoading {
            return true
        }
        // `userTimesheetSubjects`; closed when the script did not answer (no Swift copy of the rule, AGENTS.md Rule 0).
        guard let ids = UserTimesheetAccessRulebook.subjectUserIds(viewer: user, members: organizationUsers) else {
            return false
        }
        return !ids.isEmpty
    }

    /// The profile, or this organisation's roster, has not arrived yet. Screens wait instead of deciding on an empty list.
    var isUserTimesheetRosterLoading: Bool {
        if isHomeProfileLoading { return true }
        return organizationUsers.isEmpty && organizationUsersLoadInProgress
    }

    /// People on User Timesheets for the signed-in viewer (role testing applies), sorted by name.
    /// `userTimesheetSubjects` decides once the packed script has it; before that, the screen's previous filter.
    func userTimesheetSubjectUsers() -> [AppUser] {
        guard let viewer = displayUser else { return [] }
        // `userTimesheetSubjects`; empty when the script did not answer (no Swift copy of the rule, AGENTS.md Rule 0).
        guard let ids = UserTimesheetAccessRulebook.subjectUserIds(viewer: viewer, members: organizationUsers) else {
            return []
        }
        let wanted = Set(ids)
        let users = organizationUsers.filter { wanted.contains($0.id) }
        // RULEBOOK 1.30.2 `userTimesheetSubjects`: never the viewer (their own sheet is My Timesheets).
        let viewerIds = Set(RulebookPeople.ownerIds(for: viewer, users: organizationUsers).map { $0.lowercased() })
        return users
            .filter { !viewerIds.contains($0.id.lowercased()) }
            .sorted(by: { $0.fullName < $1.fullName })
    }

    /// RULEBOOK 1.31.0 §8 `exportedTimesheetHistorySubjects` (Exported list and its count): the people
    /// `userTimesheetSubjects` lists, the viewer's own sheets and inactive people in scope, sorted by name. Empty when
    /// the script did not answer (never a wider Swift list).
    func exportedTimesheetHistoryUsers(viewer: AppUser) -> [AppUser] {
        guard let ids = UserTimesheetAccessRulebook.exportedHistoryUserIds(viewer: viewer, members: organizationUsers) else {
            return []
        }
        var seen = Set<String>()
        var users: [AppUser] = []
        for id in ids {
            let match = organizationUsers.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
                ?? (viewer.id.caseInsensitiveCompare(id) == .orderedSame ? viewer : nil)
            guard let user = match, seen.insert(user.id.lowercased()).inserted else { continue }
            users.append(user)
        }
        return users.sorted { $0.fullName < $1.fullName }
    }

    func canAccessTimesheetsSurface() -> Bool {
        canAccessMyTimesheets() || canAccessOperativeTimesheets() || shouldShowTimesheetsDisabledMessage()
    }

    /// User has a timesheet-eligible role but is PAYE with no remaining self-employed days in the open pay run.
    func shouldShowTimesheetsDisabledMessage() -> Bool {
        guard let user = displayUser else { return false }
        guard user.employmentType(on: Date()) != .selfEmployed else { return false }
        guard !canAccessMyTimesheets() else { return false }
        return isTimesheetEligibleRole(user)
    }

    func isTimesheetEligibleRole(_ user: AppUser) -> Bool {
        user.permissions.operativeMode
            || user.permissions.manager
            || user.permissions.adminAccess
            || user.role == .manager
            || user.role == .admin
    }

    // MARK: - Sensitive profile (UTR and VAT number)

    #if DEBUG
    /// `-uiTesting` stand-in for users/{uid}/private/taxIds. TEST data only; never touches Firestore.
    var uiTestSensitiveProfiles: [String: CanonicalBusinessEngine.CanonicalSensitiveProfile] = [:]
    #endif

    /// `canViewSensitiveProfile` for the signed-in viewer (role testing applies).
    func canViewSensitiveProfile(of subjectUserId: String) -> Bool {
        guard let viewer = displayUser else { return false }
        return CanonicalBusinessEngine.canViewSensitiveProfile(
            viewerRole: Self.staffAccountRole(for: viewer),
            viewerUserId: viewer.id,
            subjectUserId: subjectUserId
        )
    }

    /// Resolved UTR and VAT number, or nil without any read when the viewer may not see them.
    func loadSensitiveProfile(for user: AppUser) async -> CanonicalBusinessEngine.CanonicalSensitiveProfile? {
        guard canViewSensitiveProfile(of: user.id) else { return nil }
        #if DEBUG
        if UITestingMode.shouldSkipNetworkBootstrap {
            return uiTestSensitiveProfiles[user.id]
                ?? CanonicalBusinessEngine.resolveSensitiveProfile(privateDoc: nil, legacyUser: nil)
        }
        #endif
        guard let firebaseBackend else { return nil }
        do {
            return try await firebaseBackend.loadSensitiveProfile(userId: user.id, legacyUser: user.legacySensitiveFields)
        } catch {
            errorMessage = "Could not load UTR and VAT number: \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves UTR and VAT number to users/{uid}/private/taxIds. Blank clears.
    func updateUserBillingProfile(userId: String, vatNumber: String?, utrNumber: String?) async -> Bool {
        guard canViewSensitiveProfile(of: userId) else { return false }
        #if DEBUG
        if UITestingMode.shouldSkipNetworkBootstrap {
            guard let write = CanonicalBusinessEngine.sensitiveProfileWriteFields(
                utrNumber: utrNumber,
                vatNumber: vatNumber,
                updatedByUserId: displayUser?.id ?? ""
            ), write.ok, let fields = write.fields else { return false }
            uiTestSensitiveProfiles[userId] = CanonicalBusinessEngine.resolveSensitiveProfile(
                privateDoc: ["utrNumber": fields.utrNumber, "vatNumber": fields.vatNumber],
                legacyUser: nil
            )
            return true
        }
        #endif
        guard let firebaseBackend = firebaseBackend else { return false }
        if smartCache?.isOnline == false {
            return queueOwnBillingProfile(userId: userId, vatNumber: vatNumber, utrNumber: utrNumber, firebaseBackend: firebaseBackend)
        }
        do {
            try await firebaseBackend.saveSensitiveProfile(userId: userId, utrNumber: utrNumber, vatNumber: vatNumber)
            if let index = rosterIndex(for: userId) {
                organizationUsers[index].vatNumber = nil
                organizationUsers[index].utrNumber = nil
            }
            if currentUser?.id == userId {
                currentUser?.vatNumber = nil
                currentUser?.utrNumber = nil
            }
            return true
        } catch {
            errorMessage = "Could not save billing details: \(error.localizedDescription)"
            return false
        }
    }

    /// Outbox entity id of the signed-in person's queued billing details ("Pending sync").
    static func billingOutboxEntityId(userId: String) -> String { "taxIds_\(userId)" }

    /// RULEBOOK §2: the person's own profile fields are allowed offline. Billing details are queued as the whole
    /// `users/{uid}/private/taxIds` document (`sensitiveProfileDocPath`, `sensitiveProfileWriteFields`) with no write
    /// metadata, since its rules allow only its own keys. Someone else's details stay online only.
    private func queueOwnBillingProfile(
        userId: String,
        vatNumber: String?,
        utrNumber: String?,
        firebaseBackend: FirebaseBackend
    ) -> Bool {
        guard let signedIn = firebaseBackend.currentUser?.uid, signedIn == userId else {
            errorMessage = OfflinePolicy.onlineOnlyMessage
            return false
        }
        guard let path = CanonicalBusinessEngine.sensitiveProfileDocPath(userId: userId),
              let write = CanonicalBusinessEngine.sensitiveProfileWriteFields(
                utrNumber: utrNumber,
                vatNumber: vatNumber,
                updatedByUserId: signedIn
              ), write.ok, let fields = write.fields else {
            let limit = CanonicalBusinessEngine.sensitiveValueMax ?? 20
            errorMessage = "UTR and VAT number can be up to \(limit) characters each."
            return false
        }
        // RULEBOOK 1.9.0 §12: the queued document is `taxIdsDocumentFields` (its only fields) plus `updatedAt`.
        let document = CanonicalBusinessEngine.taxIdsDocumentFields(
            utrNumber: utrNumber,
            vatNumber: vatNumber,
            updatedByUserId: signedIn
        )
        var queued: [String: OfflineFieldValue] = [
            "utrNumber": .string(document?["utrNumber"] as? String ?? fields.utrNumber),
            "vatNumber": .string(document?["vatNumber"] as? String ?? fields.vatNumber),
            "updatedByUserId": .string(document?["updatedByUserId"] as? String ?? fields.updatedByUserId),
        ]
        queued["updatedAt"] = .serverTimestamp
        OfflineOutboxStore.shared.enqueueOwnProfileFields(
            userId: signedIn,
            fields: queued,
            organizationId: firebaseBackend.resolvedOrganizationIdForOfflineWrites() ?? "",
            documentPath: path,
            replacesDocument: true,
            stampsWriteMetadata: false,
            entityId: Self.billingOutboxEntityId(userId: signedIn)
        )
        return true
    }

    func updateUserTimesheetsEnabled(userId: String, enabled: Bool) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let index = rosterIndex(for: userId) else { return false }

        var updated = organizationUsers[index]
        updated.timesheetsEnabled = enabled

        do {
            try await firebaseBackend.patchOwnUserTimesheetsEnabled(userId: userId, enabled: enabled)
            organizationUsers[index] = updated
            if let cu = currentUser, cu.id == userId {
                // A roster row (possibly this phone's saved roster) never replaces the acceptance read from users/{uid}.
                currentUser = updated.carryingLegalAcceptance(from: cu)
            }
            return true
        } catch {
            errorMessage = "Could not save timesheets setting: \(error.localizedDescription)"
            return false
        }
    }
    
    func canEditProjects() -> Bool {
        canManageWorkCatalogue(.projects) || canManageWorkCatalogue(.smallWorks)
    }
    
    func canViewSiteAudit() -> Bool {
        guard let currentUser = displayUser else { return false }
        if currentUser.permissions.operativeMode {
            return currentUser.effectivePermissions.siteAudit
        }
        return true
    }
    
    func canEditOperatives() -> Bool {
        return canViewOperatives()
    }
    
    /// Managers roster tab / shortcuts (not Manage Users). Admin-level only; non-admin managers use Operatives or Manage Users as allowed.
    func canViewManagers() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess()
    }
    
    /// Editing the dedicated Managers roster (same gate as `canViewManagers()`).
    func canEditManagers() -> Bool {
        canViewManagers()
    }
    
    func canViewSkills() -> Bool {
        false
    }
    
    func canEditSkills() -> Bool {
        false
    }
    
    func canViewQualifications() -> Bool {
        if isOperativeMode() { return true }
        return canAccessQualificationsHub()
    }
    
    func canEditQualifications() -> Bool {
        if isOperativeMode() { return true }
        return canAccessQualificationsHub()
    }
    
    func canBookWork() -> Bool {
        if isOperativeMode() { return false }
        return true
    }
    
    /// Directory / menu / home tile for adding and editing sub contractor records.
    /// Booking live subcontractors onto a job is separate and stays available to managers.
    func canManageSubcontractors() -> Bool {
        if isOperativeMode() { return false }
        if isHomeProfileLoading { return true }
        guard let currentUser = displayUser else { return false }
        if currentUser.isSuperAdmin || currentUser.permissions.adminAccess || currentUser.role == .admin {
            return true
        }
        return currentUser.permissions.manager && currentUser.effectivePermissions.subContractors
    }

    /// Add projects or small works (`canCreateJob`, RULEBOOK 1.10.0 §16 round 2): admins and super admins outside
    /// operative mode always; a manager only with that kind's toggle; operatives never. The same answer as
    /// `canEditWorkCatalogue` and `canChangeJobManagers`. Editing one job is `canEditJob`.
    func canManageWorkCatalogue(_ catalogue: WorkAccess.JobCatalogue) -> Bool {
        switch catalogue {
        case .projects: return canCreateJob(kind: .projects)
        case .smallWorks: return canCreateJob(kind: .smallWorks)
        case .all: return canCreateJob(kind: .projects) && canCreateJob(kind: .smallWorks)
        }
    }

    func canViewWeeklyReports() -> Bool {
        if isOperativeMode() { return false }
        if isHomeProfileLoading { return true }
        guard let u = displayUser else { return false }
        return u.effectivePermissions.weeklyReports
    }

    func canViewDailyOverview() -> Bool {
        if isOperativeMode() { return false }
        if isHomeProfileLoading { return true }
        guard let u = displayUser else { return false }
        return u.effectivePermissions.dailyOverview
    }

    /// Flags for `canViewStaffWarnings`, `isStaffAccount`, and `seesEveryJob`. Operative mode is passed through; the script decides it wins.
    static func staffAccountRole(for user: AppUser) -> CanonicalBusinessEngine.CanonicalStaffAccountRole {
        CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: user.isSuperAdmin,
            isAdmin: user.permissions.adminAccess || user.role == .admin,
            isManager: user.permissions.manager || user.role == .manager,
            isOperativeMode: user.permissions.operativeMode || user.role == .operative
        )
    }

    /// Audience for `visibleNotificationPreferenceKeys`. Hide/show stays in the script.
    /// Operatives-on is `canViewOperatives` (super admin stays true). Clients is staff.
    /// Materials is catalogue management: an operative Materials toggle is list access, not this flag.
    func notificationPreferenceAudience() -> CanonicalBusinessEngine.CanonicalNotificationPreferenceAudience? {
        guard let user = displayUser else { return nil }
        return CanonicalBusinessEngine.CanonicalNotificationPreferenceAudience(
            role: Self.staffAccountRole(for: user),
            catalogue: CanonicalBusinessEngine.CanonicalWorkCatalogueToggles(
                projects: user.effectivePermissions.projects,
                smallWorks: user.effectivePermissions.smallWorks
            ),
            canManagePeople: canViewOperatives(),
            canManageClients: !isOperativeMode(),
            canManageMaterials: canManageMaterialCatalogue()
        )
    }

    /// Staff warning rows are the organisation canonical list. The script decides who sees them.
    func canViewStaffWarnings() -> Bool {
        guard let u = displayUser else { return isHomeProfileLoading }
        return CanonicalBusinessEngine.canViewStaffWarnings(Self.staffAccountRole(for: u))
    }

    /// Every admin and every manager sees variations on every job. Operatives do not.
    func canSeeVariations() -> Bool {
        guard let u = displayUser else { return false }
        return CanonicalBusinessEngine.canSeeVariations(Self.staffAccountRole(for: u))
    }

    /// Tracker numbering is admin and super admin only. Managers can see variations without this.
    func canManageVariationTracker() -> Bool {
        guard let u = displayUser else { return false }
        return CanonicalBusinessEngine.canManageVariationTracker(Self.staffAccountRole(for: u))
    }
    
    /// Super admins, admins, and managers may set whether a site audit is visible to operative-mode users.
    func canManageSiteAuditOperativeVisibility() -> Bool {
        guard let u = displayUser else { return false }
        if isOperativeMode() { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.permissions.manager
    }
    
    /// Manager account with operative management only (no admin / super admin).
    /// These users can open Manage Operatives, view profiles, edit operative details,
    /// and add a new operative. They cannot add managers or admins.
    func isActingManagerOperativeManagementOnly() -> Bool {
        guard let u = displayUser else { return false }
        // A manager-level account (`permissionLevelOf`) that `canManageOperatives`.
        guard u.permissionLevel == .manager else { return false }
        return CanonicalBusinessEngine.canManageOperatives(u.permissionSubject)
    }

    /// Admins and managers with operative management can open the team annual leave directory.
    func canAccessOperativeAnnualLeaveDirectory() -> Bool {
        if isOperativeMode() { return false }
        if hasAdminAccess() { return true }
        guard let u = displayUser else { return false }
        return CanonicalBusinessEngine.canManageOperatives(u.permissionSubject)
    }
    
    /// Whether the signed-in user may change permissions for `target` in **Manage / edit user**.
    func canEditTargetUserPermissions(_ target: AppUser) -> Bool {
        guard let acting = currentUser else { return false }
        if target.isSuperAdmin || isOrganizationCreator(userId: target.id) {
            // RULEBOOK 1.31.0 (hand-off): the Super Admin edits their own profile — the rules allow it; only their own
            // self-manage toggles are fixed (`lockedPermissionFields`). Nobody else edits the Super Admin.
            return isSamePerson(acting, target)
        }
        if acting.permissions.operativeMode { return false }
        if hasAdminAccess() { return true }
        if isActingManagerOperativeManagementOnly() {
            return target.permissions.operativeMode || target.role == .operative
        }
        return false
    }
    
    /// The signed-in person and `target` are one person (their id or a folded same-email id).
    private func isSamePerson(_ acting: AppUser, _ target: AppUser) -> Bool {
        let ids = Set(([acting.id] + acting.sameEmailUserIds).map { $0.lowercased() })
        return ids.contains(target.id.lowercased())
    }

    func canViewReports() -> Bool {
        if isOperativeMode() { return false }
        return true
    }
    
    /// RULEBOOK 1.10.0 §11: `userDeleteRefusal(actor, target, { roster, creatorUserId })` — only an admin or super
    /// admin outside operative mode deletes; never themselves, the super admin or the company owner; an admin who is
    /// not super admin deletes only people who are not admins. Nil when the delete may go ahead.
    func userDeleteRefusalMessage(targetUser: AppUser, actingUser: AppUser) -> String? {
        let roster = RulebookPeople.roster(organizationUsers)
        let options: [String: Any] = [
            "roster": roster,
            "creatorUserId": firebaseBackend?.currentOrganization?.creatorUserId ?? NSNull(),
            // RULEBOOK 1.31.0 (owner decision 7): a manager with the Operatives permission deletes operatives only.
            "actorManagesOperatives": actorManagesOperativesOnly,
        ]
        guard let raw = CanonicalBusinessEngine.callJSON(
            "userDeleteRefusal",
            arguments: [Self.userDeletePerson(actingUser), Self.userDeletePerson(targetUser), options]
        ) else {
            return "Couldn't check who may delete this person: the rules did not load. Try again."
        }
        guard let code = raw as? String else { return nil }
        let messages = CanonicalBusinessEngine.constant("USER_DELETE_REFUSAL_MESSAGES", as: [String: String].self) ?? [:]
        return messages[code] ?? "You do not have permission to delete this user."
    }

    /// The `userDeleteWrites` input, as web `lib/stores/userStore.ts` `deleteUser` builds it. RULEBOOK 1.31.0:
    /// `listedInMembers` is whether `organizations/{orgId}.members` has an entry under the person's id (true when the
    /// map is not loaded) — the plan removes `members.{uid}` only then. An operatives manager's account step runs one
    /// write at a time and the rules let them remove exactly one listed `operative` entry
    /// (`orgRootRemovesOneOperativeMember`), so removing a missing entry stopped the delete halfway.
    static func userDeleteInput(
        organizationId: String,
        user: AppUser,
        actorUserId: String,
        roster: [[String: Any]],
        bookings: [[String: Any]],
        managerSiteBookings: [[String: Any]],
        operativeRows: [[String: Any]],
        managerRows: [[String: Any]],
        invitations: [[String: Any]],
        actorManagesOperatives: Bool,
        members: [String: String]?,
        now: Date = Date()
    ) -> [String: Any] {
        [
            "orgId": organizationId,
            "user": userDeletePerson(user),
            "actorUserId": actorUserId,
            "platform": "ios",
            "roster": roster,
            "bookings": bookings,
            "managerSiteBookings": managerSiteBookings,
            "operativeRows": operativeRows,
            "managerRows": managerRows,
            "invitations": invitations,
            "listedInMembers": members.map { $0[user.id] != nil } ?? true,
            "actorManagesOperatives": actorManagesOperatives,
            "nowIso": CanonicalBusinessEngine.isoString(from: now),
            "tz": OrganizationRulebookContext.timeZoneIdentifier,
        ]
    }

    /// `UserDeletePerson { id, email, role, formerUserIds, sameEmailUserIds }`.
    static func userDeletePerson(_ user: AppUser) -> [String: Any] {
        let role = staffAccountRole(for: user)
        return [
            "id": user.id,
            "email": user.email,
            "role": [
                "isSuperAdmin": role.isSuperAdmin,
                "isAdmin": role.isAdmin,
                "isManager": role.isManager,
                "isOperativeMode": role.isOperativeMode,
            ],
            "formerUserIds": user.formerUserIds,
            "sameEmailUserIds": user.sameEmailUserIds,
        ]
    }

    /// `canDeleteUser`: `userDeleteRefusal` is null.
    private func canDeleteUser(targetUser: AppUser, actingUser: AppUser) -> Bool {
        userDeleteRefusalMessage(targetUser: targetUser, actingUser: actingUser) == nil
    }

    /// UI-facing wrapper for delete permission checks.
    func canDeleteUser(_ user: AppUser) -> Bool {
        guard let actingUser = currentUser else { return false }
        return canDeleteUser(targetUser: user, actingUser: actingUser)
    }

    func isOrganizationCreator(userId: String) -> Bool {
        guard let creatorUserId = firebaseBackend?.currentOrganization?.creatorUserId else { return false }
        return creatorUserId == userId
    }

    /// The organisation creator, or anyone still flagged super admin. Their toggles stay locked.
    func isProtectedSuperAdmin(_ user: AppUser) -> Bool {
        user.isSuperAdmin || isOrganizationCreator(userId: user.id)
    }
    
    /// Summary of what the current user can and cannot see (for debugging / Settings).
    func currentUserAccessSummary() -> String {
        guard let u = displayUser else { return "Not signed in." }
        let previewNote = roleTestingPreset.map { "(Preview: \($0.title)) " } ?? ""
        if u.permissions.operativeMode {
            return """
            \(previewNote)Role: Operative (limited view)
            Can see: Home, Projects (assigned only), Small Works (assigned only), My Schedule (view only), Settings
            Cannot see: Managers, Operatives list, Manage Users, Add User, Qualifications admin, Wholesalers, Help tab, Create project/small works, Book work, Reports, Daily/Weekly overview
            """
        }
        var lines: [String] = [previewNote + "Role: " + (u.isSuperAdmin ? "Super Admin" : (u.permissions.adminAccess ? "Admin" : (u.permissions.manager ? "Manager" : "User")))]
        if hasAdminAccess() {
            lines.append("Can: Manage users, managers list, manage operatives, qualifications, projects/small works, book work, reports")
        } else if canViewOperatives() {
            lines.append("Can: Manage operatives (roster), projects/small works (as permitted), book work")
        } else {
            lines.append("Can: View projects, small works (as permitted)")
        }
        return lines.joined(separator: "\n")
    }
    
    func isOperativeMode() -> Bool {
        // Super admins and users with admin access should never be in operative mode
        if hasAdminAccess() {
            return false
        }
        
        // Operative mode is for actual operatives who log in with their operative email
        // Check if the current user has operativeMode permission
        guard let currentUser = displayUser else {
            return false
        }
        
        // Operative mode flag or explicit role (Firestore may be missing the flag on some legacy docs).
        return currentUser.permissions.operativeMode || currentUser.role == .operative
    }
    
             // MARK: - User Invitation
             
    /// For operative invitations, pass the line manager's Firebase Auth UID (`users` document id).
    func inviteUser(firstName: String, surname: String, email: String, mobileNumber: String?, permissions: UserPermissions, employmentType: EmploymentType = .paye, assignedManagerUserId: String? = nil, assignedManagerUserIds: [String]? = nil, hasNoLineManager: Bool = false, invitedOperativeDayRate: Double? = nil, invitedManagerDayRate: Double? = nil, invitedTradeTypePreset: String? = nil, invitedTradeTypeCustom: String? = nil, annualLeaveDaysPerYear: Double? = nil, annualLeaveYearStartMonth: Int? = nil, annualLeaveYearEndMonth: Int? = nil, annualLeaveCarriesOver: Bool? = nil, annualLeaveEnabled: Bool? = nil, annualLeaveYearAllowance: Double? = nil, annualLeaveYearAllowanceKey: String? = nil, timesheetsEnabled: Bool? = nil, vatNumber: String? = nil, utrNumber: String? = nil) async -> Bool {
        print("🔥🔥🔥 DEBUG: inviteUser called with firstName: \(firstName), surname: \(surname), email: \(email)")
        
        errorMessage = nil

        let managerIds = (assignedManagerUserIds ?? assignedManagerUserId.map { [$0] } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var draftUser = AppUser(
            id: "invite-validation",
            email: email,
            organizationId: firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "",
            role: .manager,
            permissions: permissions,
            hasNoLineManager: hasNoLineManager
        )
        draftUser.setLineManagerUserIds(managerIds)
        if let annualLeaveEnabled { draftUser.annualLeaveEnabled = annualLeaveEnabled }
        // RULEBOOK §8, §11: `lineManagerRequiredError` refuses an invite that cannot self-book and has no line manager.
        if let lineManagerError = AnnualLeaveApproval.lineManagerRequiredError(for: draftUser, users: organizationUsers) {
            errorMessage = lineManagerError
            return false
        }
        
        guard let firebaseBackend = firebaseBackend else {
            print("🔥🔥🔥 DEBUG: No firebaseBackend available")
            errorMessage = "Unable to connect to server. Please check your internet connection and try again."
            return false
        }
        
        guard firebaseBackend.isAuthenticated else {
            print("🔥🔥🔥 DEBUG: User not authenticated")
            errorMessage = "You must be signed in to create users. Please sign in and try again."
            return false
        }
        
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: No organization ID available")
            errorMessage = "Organization not loaded. Please wait a moment and try again."
            return false
        }
        
        guard let invitedBy = firebaseBackend.currentUser?.uid else {
            print("🔥🔥🔥 DEBUG: No current user ID available")
            errorMessage = "Unable to identify current user. Please sign in again."
            return false
        }
        
        // CRITICAL: Before creating a user, ensure the current user has admin permissions
        // Check the ACTUAL Firebase document (not just in-memory object) and fix if needed
        guard let currentUserId = firebaseBackend.currentUser?.uid else {
            print("🔥🔥🔥 DEBUG: ⚠️ No current user ID available")
            errorMessage = "Unable to identify current user. Please sign in again."
            return false
        }
        
        // Whether the inviter is an admin, from their stored document; nil when it could not be read (the rules decide).
        var inviterIsAdmin: Bool?
        // Load the actual user document from Firebase to check permissions
        if let firebaseUserData = try? await firebaseBackend.getUserData(userId: currentUserId) {
            print("🔥🔥🔥 DEBUG: Current user (inviter) Firebase document data:")
            print("🔥🔥🔥 DEBUG: - isSuperAdmin: \(firebaseUserData.isSuperAdmin)")
            print("🔥🔥🔥 DEBUG: - adminAccess: \(firebaseUserData.permissions.adminAccess)")
            print("🔥🔥🔥 DEBUG: - role: \(firebaseUserData.role.rawValue)")
            
            // Check if user has admin permissions in Firebase
            let hasAdmin = firebaseUserData.isSuperAdmin || firebaseUserData.permissions.adminAccess || firebaseUserData.role == .admin
            inviterIsAdmin = hasAdmin
            let canInviteOperativesAsManager =
                !hasAdmin &&
                !firebaseUserData.permissions.operativeMode &&
                firebaseUserData.permissions.manager &&
                firebaseUserData.permissions.operatives

            if !hasAdmin && !canInviteOperativesAsManager {
                print("🔥🔥🔥 DEBUG: ⚠️ Current user does NOT have admin permissions in Firebase!")
                errorMessage = "You do not have admin permissions. Please contact an administrator."
                return false
            }

            // Managers with Operative Management can ONLY invite operatives
            if canInviteOperativesAsManager {
                guard permissions.operativeMode else {
                    errorMessage = "Managers can only add operatives."
                    return false
                }
            }

            if hasAdmin {
                print("🔥🔥🔥 DEBUG: ✅ Current user HAS admin permissions in Firebase")
                print("🔥🔥🔥 DEBUG: - isSuperAdmin: \(firebaseUserData.isSuperAdmin)")
                print("🔥🔥🔥 DEBUG: - adminAccess: \(firebaseUserData.permissions.adminAccess)")
                print("🔥🔥🔥 DEBUG: - role: \(firebaseUserData.role.rawValue)")
            } else {
                print("🔥🔥🔥 DEBUG: ✅ Current user can invite operatives as manager")
            }
        } else {
            print("🔥🔥🔥 DEBUG: ⚠️ Current user document does not exist in Firebase!")
            errorMessage = "Your user document does not exist. Please sign out and sign back in."
            return false
        }
        
        // Double-check: admins must still be admins; managers inviting operatives skip this admin-only gate.
        print("🔥🔥🔥 DEBUG: Final verification - checking user document one more time...")
        if let finalCheck = try? await firebaseBackend.getUserData(userId: currentUserId) {
            let hasAdmin = finalCheck.isSuperAdmin || finalCheck.permissions.adminAccess || finalCheck.role == .admin
            let managerInvitingOperative =
                !hasAdmin &&
                !finalCheck.permissions.operativeMode &&
                finalCheck.permissions.manager &&
                finalCheck.permissions.operatives &&
                permissions.operativeMode
            print("🔥🔥🔥 DEBUG: Final check - hasAdmin: \(hasAdmin), managerInvitingOperative: \(managerInvitingOperative)")
            if !hasAdmin && !managerInvitingOperative {
                print("🔥🔥🔥 DEBUG: ⚠️ WARNING: User still doesn't have admin permissions after fix attempt!")
                errorMessage = "Your user document does not have admin permissions. Please ensure isSuperAdmin=true, adminAccess=true, or role='admin' in Firebase Console. User ID: \(currentUserId)"
                return false
            }
        }
        
        print("🔥🔥🔥 DEBUG: Calling createUserInvitation with organizationId: \(organizationId), invitedBy: \(invitedBy)")
        print("🔥🔥🔥 DEBUG: Current user ID for rules check: \(currentUserId)")
        
        do {
            try await firebaseBackend.createUserInvitation(
                email: email,
                organizationId: organizationId,
                invitedBy: invitedBy,
                firstName: firstName,
                surname: surname,
                mobileNumber: mobileNumber,
                permissions: permissions,
                employmentType: employmentType,
                assignedManagerUserId: managerIds.first ?? assignedManagerUserId,
                assignedManagerUserIds: managerIds,
                hasNoLineManager: hasNoLineManager,
                invitedOperativeDayRate: invitedOperativeDayRate,
                invitedManagerDayRate: invitedManagerDayRate,
                invitedTradeTypePreset: invitedTradeTypePreset,
                invitedTradeTypeCustom: invitedTradeTypeCustom,
                annualLeaveDaysPerYear: annualLeaveDaysPerYear,
                annualLeaveYearStartMonth: annualLeaveYearStartMonth,
                annualLeaveYearEndMonth: annualLeaveYearEndMonth,
                annualLeaveCarriesOver: annualLeaveCarriesOver,
                annualLeaveEnabled: annualLeaveEnabled,
                annualLeaveYearAllowance: annualLeaveYearAllowance,
                annualLeaveYearAllowanceKey: annualLeaveYearAllowanceKey,
                timesheetsEnabled: timesheetsEnabled,
                // Only an admin may set another person's tax fields (`canViewSensitiveProfile`).
                vatNumber: canViewSensitiveProfile(of: "") ? vatNumber : nil,
                utrNumber: canViewSensitiveProfile(of: "") ? utrNumber : nil,
                inviterIsAdmin: inviterIsAdmin
            )
            print("🔥🔥🔥 DEBUG: createUserInvitation succeeded")
            
            // Reload organization users to show the newly added user
            await loadOrganizationUsers()
            print("🔥🔥🔥 DEBUG: Organization users reloaded")
            
            return true
        } catch let refusal as InvitationNotOperativeOnlyError {
            // RULEBOOK 1.12.0 §11 `invitationIsOperativeOnly`: refused before anything was written.
            errorMessage = refusal.errorDescription
            return false
        } catch {
            print("🔥🔥🔥 DEBUG: Error inviting user: \(error)")
            print("🔥🔥🔥 DEBUG: Error type: \(type(of: error))")
            if let nsError = error as NSError? {
                print("🔥🔥🔥 DEBUG: Error domain: \(nsError.domain), code: \(nsError.code)")
                print("🔥🔥🔥 DEBUG: Error userInfo: \(nsError.userInfo)")
            }
            
            // Provide more specific error messages with diagnostic info
            if let nsError = error as NSError? {
                if nsError.domain == "FIRFirestoreErrorDomain" {
                    switch nsError.code {
                    case 7: // Permission denied
                        // Get current user info for better error message
                        if let currentUserId = firebaseBackend.currentUser?.uid,
                           let currentUserData = try? await firebaseBackend.getUserData(userId: currentUserId) {
                            let hasSuperAdmin = currentUserData.isSuperAdmin
                            let hasAdminAccess = currentUserData.permissions.adminAccess
                            let hasAdminRole = currentUserData.role == .admin
                            
                            var diagnosticInfo = "\n\nYour current permissions:\n"
                            diagnosticInfo += "• isSuperAdmin: \(hasSuperAdmin ? "✅ true" : "❌ false")\n"
                            diagnosticInfo += "• adminAccess: \(hasAdminAccess ? "✅ true" : "❌ false")\n"
                            diagnosticInfo += "• role: \(currentUserData.role.rawValue) \(hasAdminRole ? "✅" : "❌")\n\n"
                            
                            if !hasSuperAdmin && !hasAdminAccess && !hasAdminRole {
                                diagnosticInfo += "⚠️ You don't have admin permissions.\n\n"
                                diagnosticInfo += "To fix this:\n"
                                diagnosticInfo += "1. Go to Firebase Console → Firestore Database → users collection\n"
                                diagnosticInfo += "2. Find your user document (ID: \(currentUserId))\n"
                                diagnosticInfo += "3. Set these fields:\n"
                                diagnosticInfo += "   - isSuperAdmin: true (boolean, not string)\n"
                                diagnosticInfo += "   - adminAccess: true (boolean, not string)\n"
                                diagnosticInfo += "   - role: \"admin\" (string)\n\n"
                                diagnosticInfo += "OR contact an administrator to grant you permissions."
                            } else {
                                diagnosticInfo += "You have admin permissions, but Firestore rules are still blocking the create operation.\n\n"
                                diagnosticInfo += "This could mean:\n"
                                diagnosticInfo += "1. Rules are not deployed correctly\n"
                                diagnosticInfo += "2. Rules are cached (wait 2-3 minutes after deploying)\n"
                                diagnosticInfo += "3. The isAdminOrSuperAdmin() function is failing during CREATE operations\n\n"
                                diagnosticInfo += "Check Firebase Console → Firestore → Rules to verify the 'allow create' rule is deployed."
                            }
                            
                            errorMessage = "Permission denied when creating user.\(diagnosticInfo)"
                        } else {
                            errorMessage = "Permission denied. Your user document may not exist or you may not have admin permissions. Please check Firebase Console."
                        }
                    case 14: // Unavailable
                        errorMessage = "Service temporarily unavailable. Please check your internet connection and try again."
                    default:
                        errorMessage = "Failed to create user: \(error.localizedDescription)"
                    }
                } else {
                    errorMessage = "Failed to create user: \(error.localizedDescription)"
                }
            } else {
                errorMessage = "Failed to create user. Please check your internet connection and try again."
            }
            
            return false
        }
    }

    // MARK: - Ownership transfer (Super Admin reassignment)

    /// Transfers organization ownership (Super Admin) to another administrator.
    /// Updates `organizations/{orgId}.creatorUserId` and the super-admin flags only.
    func transferSuperAdmin(to newOwnerUserId: String) async -> Bool {
        guard let firebaseBackend else { return false }
        guard let currentUser else { return false }
        guard currentUser.isSuperAdmin else {
            errorMessage = "Only the Super Admin can transfer ownership."
            return false
        }
        guard !currentUser.permissions.operativeMode else {
            errorMessage = "Operatives cannot transfer ownership."
            return false
        }
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "Organization not loaded."
            return false
        }
        let newId = newOwnerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        if newId.isEmpty || newId == currentUser.id {
            errorMessage = "You are already the Super Admin."
            return false
        }
        guard let newOwner = organizationUsers.first(where: { $0.id == newId }), newOwner.isStoredUserDocument else {
            errorMessage = "User not found."
            return false
        }
        guard !newOwner.permissions.operativeMode else {
            errorMessage = "Cannot make an operative the Super Admin."
            return false
        }
        guard newOwner.permissions.adminAccess || newOwner.role == .admin else {
            errorMessage = "Only an Admin can be made Super Admin."
            return false
        }
        guard newOwner.isActive, newOwner.passwordSet else {
            errorMessage = "Choose an active administrator who has finished setting up their account."
            return false
        }

        // RULEBOOK 1.31.0 §11 `superAdminTransferWrites`: one batch — the organisation's creator and members entry, the
        // new Super Admin (both self-manage toggles on), and every outgoing Super Admin (kept self-approved when they
        // have no line manager; owner decision 4 Nov). Before 1.31.0 these were separate writes.
        guard let writes = CanonicalBusinessEngine.superAdminTransferWrites(
            organizationId: organizationId,
            fromUserId: currentUser.id,
            toUserId: newId,
            previousCreatorUserId: firebaseBackend.currentOrganization?.creatorUserId,
            roster: unfoldedRosterRows
        ) else {
            errorMessage = "Couldn't work out the change: the rules did not load. Nothing was changed."
            return false
        }

        do {
            let db = Firestore.firestore()
            let batch = db.batch()
            let actor = Auth.auth().currentUser?.uid
            for write in writes {
                let ref = db.document(write.path)
                var fields: [String: Any] = [:]
                for (key, value) in write.fields { fields[key] = value }
                switch write.kind {
                case "membership":
                    // Admins may not read another person's membership: a merge-set of the nested flags (created when
                    // missing), as web `transferSuperAdmin`.
                    var flat: [String: Any] = ["organizationId": organizationId, "updatedAt": FieldValue.serverTimestamp()]
                    var nested: [String: Any] = [:]
                    for (key, value) in fields {
                        if key.hasPrefix("permissions.") { nested[String(key.dropFirst("permissions.".count))] = value } else { flat[key] = value }
                    }
                    flat["permissions"] = nested
                    batch.setData(flat, forDocument: ref, merge: true)
                case "userProfile":
                    batch.updateData(WriteMetadata.stamped(fields, userId: actor), forDocument: ref)
                default:
                    fields["updatedAt"] = FieldValue.serverTimestamp()
                    batch.updateData(fields, forDocument: ref)
                }
            }
            try await batch.commit()
            if organizationIdsMatch(firebaseBackend.currentOrganization?.firestoreDocumentId, organizationId) {
                firebaseBackend.currentOrganization?.creatorUserId = newId
            }
            await loadCurrentUser()
            await loadOrganizationUsers()
            return true
        } catch {
            errorMessage = "Failed to transfer ownership: \(error.localizedDescription)"
            return false
        }
    }
             
             func acceptInvitation(invitationToken: String, password: String) async -> Bool {
                 // This is a placeholder implementation
                 // In a real app, this would validate the invitation token and create the user account
                 print("🔥🔥🔥 DEBUG: Accepting invitation with token: \(invitationToken)")
                 
                 // Simulate success for now
                 return true
             }
             
             // MARK: - User Management
             
             func deleteUser(_ user: AppUser, bookingStore: BookingStore?, operativeStore: OperativeStore?) async {
                 guard let firebaseBackend = firebaseBackend else {
                     print("🔥🔥🔥 DEBUG: ❌ Cannot delete user - Firebase backend is nil")
                     return
                 }
                 
                 let userName = user.fullName
                 let userId = user.id
                 let userEmail = user.email.lowercased()
                 print("🔥🔥🔥 DEBUG: ========== DELETE USER START ==========")
                 print("🔥🔥🔥 DEBUG: Deleting user: \(userName) (ID: \(userId), Email: \(userEmail))")
                 
                 // Check if current user has permission
                 guard let currentUser = currentUser else {
                     print("🔥🔥🔥 DEBUG: ❌ Cannot delete user - current user is nil")
                     return
                 }
                 
                // RULEBOOK 1.10.0 §11: `canDeleteUser` / `userDeleteRefusal` first — nothing is written when refused.
                if let refusal = userDeleteRefusalMessage(targetUser: user, actingUser: currentUser) {
                    print("🔥🔥🔥 DEBUG: ❌ Delete blocked by userDeleteRefusal: \(refusal)")
                    errorMessage = refusal
                    return
                }
                // RULEBOOK 1.31.0 §11 `lineManagerChangeBlock`: a line manager is not deleted while anyone reports to them.
                if let blocked = lineManagerChangeBlockMessage(for: user, change: .delete) {
                    errorMessage = blocked
                    return
                }
                guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                    errorMessage = "Organization not loaded."
                    return
                }
                let rosterBeforeDelete = unfoldedRosterRows
                let targetRole = Self.staffAccountRole(for: user)
                let deletedOperative = targetRole.isOperativeMode && !targetRole.isAdmin && !targetRole.isSuperAdmin
                guard let actorUid = Auth.auth().currentUser?.uid else {
                    errorMessage = "Sign in again to delete this person."
                    return
                }
                // Historic bookings keep the stored `bookedBy` name (AGENTS rule 4); deleting the booker never
                // rewrites them.
                do {
                    let db = Firestore.firestore()
                    let ids = RulebookPeople.ownerIds(for: user, users: organizationUsers)
                    let emailNormalized = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let emailRaw = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Labour and manager site bookings under any of the person's ids, read from the server as web
                    // `deleteUser` does: their ids and their Operatives-list rows on the same email, in stored, upper
                    // and lower case. The in-memory store may not hold them (an operatives manager under enforced reads
                    // loads only their jobs' bookings), which would leave future bookings orphaned.
                    let catalogueIds = (operativeStore?.operatives ?? [])
                        .filter { !emailNormalized.isEmpty && $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == emailNormalized }
                        .map(\.documentId)
                    var lookup: [String] = []
                    for id in ids + catalogueIds {
                        for variant in [id, id.uppercased(), id.lowercased()] where !variant.isEmpty && !lookup.contains(variant) {
                            lookup.append(variant)
                        }
                    }
                    var labourRows: [[String: Any]] = []
                    for chunk in stride(from: 0, to: lookup.count, by: 30).map({ Array(lookup[$0..<min($0 + 30, lookup.count)]) }) where !chunk.isEmpty {
                        let snap = try await db.collection("organizations").document(organizationId)
                            .collection("bookings").whereField("operativeId", in: chunk).getDocuments(source: .server)
                        for doc in snap.documents {
                            let date = (doc.data()["date"] as? Timestamp)?.dateValue() ?? .distantPast
                            labourRows.append(["id": doc.documentID, "operativeId": doc.data()["operativeId"] as? String ?? "", "dateMs": date.timeIntervalSince1970 * 1000])
                        }
                    }
                    var managerRows: [[String: Any]] = []
                    for chunk in stride(from: 0, to: ids.count, by: 30).map({ Array(ids[$0..<min($0 + 30, ids.count)]) }) where !chunk.isEmpty {
                        let snap = try await db.collection("organizations").document(organizationId)
                            .collection("managerSiteBookings").whereField("userId", in: chunk).getDocuments(source: .server)
                        for doc in snap.documents {
                            let date = (doc.data()["date"] as? Timestamp)?.dateValue() ?? .distantPast
                            managerRows.append(["id": doc.documentID, "userId": doc.data()["userId"] as? String ?? "", "dateMs": date.timeIntervalSince1970 * 1000])
                        }
                    }
                    var invitationRows: [[String: Any]] = []
                    for variant in Array(Set([emailNormalized, emailRaw].filter { !$0.isEmpty })) {
                        let invSnap = try await db.collection("invitations")
                            .whereField("organizationId", isEqualTo: organizationId)
                            .whereField("email", isEqualTo: variant)
                            .getDocuments(source: .server)
                        invitationRows += invSnap.documents.map { ["id": $0.documentID, "email": ($0.data()["email"] as? String) ?? variant] }
                    }
                    let membersMap = firebaseBackend.organizationMembersSnapshot.flatMap {
                        organizationIdsMatch($0.organizationId, organizationId) ? $0.members : nil
                    }
                    let input = Self.userDeleteInput(
                        organizationId: organizationId,
                        user: user,
                        actorUserId: actorUid,
                        roster: RulebookPeople.roster(organizationUsers),
                        bookings: labourRows,
                        managerSiteBookings: managerRows,
                        operativeRows: (operativeStore?.operatives ?? []).map { ["id": $0.documentId, "email": $0.email] as [String: Any] },
                        managerRows: (operativeStore?.managers ?? []).map { ["id": $0.firestoreDocumentId, "email": $0.email] as [String: Any] },
                        invitations: invitationRows,
                        actorManagesOperatives: actorManagesOperativesOnly,
                        members: membersMap
                    )
                    guard let steps = CanonicalBusinessEngine.callJSON("userDeleteWrites", arguments: [input]) as? [[String: Any]],
                          !steps.isEmpty else {
                        errorMessage = "Couldn't delete this person: the rules did not load. Try again."
                        return
                    }
                    // `userDeleteWrites`: one batch per step, in order; the account batch first, so a refusal there
                    // leaves everything as it was. Later steps stop at the first refusal.
                    for (index, step) in steps.enumerated() {
                        let batch = db.batch()
                        for write in step["writes"] as? [[String: Any]] ?? [] {
                            guard let path = write["path"] as? String, !path.isEmpty else { continue }
                            let ref = db.document(path)
                            switch write["op"] as? String {
                            case "delete":
                                batch.deleteDocument(ref)
                            case "update":
                                var fields: [AnyHashable: Any] = [:]
                                for field in write["deleteFields"] as? [String] ?? [] { fields[field] = FieldValue.delete() }
                                if !fields.isEmpty { batch.updateData(fields, forDocument: ref) }
                            case "set":
                                var fields = write["fields"] as? [String: Any] ?? [:]
                                for field in write["serverTimestampFields"] as? [String] ?? [] { fields[field] = FieldValue.serverTimestamp() }
                                batch.setData(fields, forDocument: ref)
                            default:
                                continue
                            }
                        }
                        do {
                            try await batch.commit()
                            print("🔥🔥🔥 DEBUG: ✅ userDeleteWrites step \(index) (\(step["step"] as? String ?? "?")) done")
                        } catch {
                            // Any `account` step refused stops the delete (an operatives manager's account step is
                            // several single writes, RULEBOOK 1.31.0).
                            if index == 0 || (step["step"] as? String) == "account" { throw error }
                            print("🔥🔥🔥 DEBUG: ⚠️ userDeleteWrites step \(step["step"] as? String ?? "?") refused: \(error.localizedDescription)")
                            break
                        }
                    }
                } catch {
                    print("🔥🔥🔥 DEBUG: ❌ Failed to delete user \(userName) from Firebase: \(error.localizedDescription)")
                    errorMessage = "Failed to delete user: \(error.localizedDescription)"
                    return
                }
                
                // Remember the delete. A later short fetch must not put this person back, and must not be the way anyone else disappears.
                // A blank email is nobody's: it must not bury every other row without one.
                let sameEmail: (AppUser) -> Bool = { !userEmail.isEmpty && $0.email.lowercased() == userEmail }
                let neverBuried = Set([actorUid, firebaseBackend.currentOrganization?.creatorUserId ?? ""])
                let removedIds = (organizationUsers.filter(sameEmail).map(\.id) + [userId])
                    .filter { !neverBuried.contains($0) }
                RosterRetention.tombstone(removedIds, organizationId: organizationId)
                organizationUsers.removeAll { sameEmail($0) || $0.id == userId }
                RosterRetention.save(organizationUsers, organizationId: organizationId)
                print("🔥🔥🔥 DEBUG: ✅ User removed from local array")
                // RULEBOOK 1.31.0 §11, §13: a deleted manager is taken off their jobs (`job_manager_removed`); the admins
                // hear that an operative was deleted (`operative_deleted`). Best effort — the delete is done.
                await removeFromManagedJobs(user, change: .delete, roster: rosterBeforeDelete)
                if deletedOperative {
                    let name = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? userEmail : userName
                    await notificationService?.notifyOperativeDeleted(userId: userId, name: name.isEmpty ? "An operative" : name)
                }
                await loadOrganizationUsers()
                 print("🔥🔥🔥 DEBUG: ✅ Reloaded organization users after deletion")
                 print("🔥🔥🔥 DEBUG: ========== DELETE USER COMPLETE ==========")
             }
             
    /// Saves display name, profile email, and phone; reconciles org `userEmails`; syncs linked operative / manager roster by **previous** email.
    /// When the signed-in user changes their own email, requests Firebase Auth **verify-before-update** so sign-in can move to the new address after they confirm.
    func updateUserIdentityProfile(
        userId: String,
        firstName: String,
        surname: String,
        email: String,
        mobileNumber: String?,
        operativeStore: OperativeStore?
    ) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let index = rosterIndex(for: userId) else { return false }
        // The company owner's name is changed by the owner only (RULEBOOK 1.31.0: the Super Admin edits their own profile).
        if isOrganizationCreator(userId: userId) && Auth.auth().currentUser?.uid != userId {
            errorMessage = "Could not save this name."
            return false
        }

        var updated = organizationUsers[index]
        let oldEmailNorm = updated.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSurname = surname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedMobile = mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mobileOut: String? = (trimmedMobile?.isEmpty == false) ? trimmedMobile : nil

        guard !trimmedEmail.isEmpty else {
            errorMessage = "Email cannot be empty."
            return false
        }

        // RULEBOOK 1.12.0 §16: on their own users document a person changes `email` only to their signed-in Auth
        // email. So a self change asks Firebase Auth first (`sendEmailVerification(beforeUpdatingEmail:)`) and every
        // document keeps the current email; it moves to the new address only after Auth has changed
        // (`syncSignedInEmailToProfileIfNeeded` on the next sign-in). A refused request writes nothing.
        let requestedEmailChange = oldEmailNorm != trimmedEmail
        let isSelf = Auth.auth().currentUser?.uid == userId
        var pendingSelfEmail: String?
        if requestedEmailChange && isSelf {
            // RULEBOOK 1.13.0 §14 `selfEmailChangeAction`: only a well-formed new address asks Auth to verify it.
            if CanonicalBusinessEngine.selfEmailChangeAction(storedEmail: oldEmailNorm, nextEmail: trimmedEmail) == .invalid {
                errorMessage = "Please enter a valid email address."
                return false
            }
            do {
                try await firebaseBackend.sendVerifyBeforeUpdateEmail(to: trimmedEmail)
                pendingSelfEmail = trimmedEmail
            } catch {
                errorMessage = "Could not change your sign-in email: \(error.localizedDescription)"
                print("🔥🔥🔥 DEBUG: verifyBeforeUpdateEmail failed: \(error)")
                return false
            }
        }
        let savedEmail = pendingSelfEmail == nil ? trimmedEmail : oldEmailNorm

        updated.firstName = trimmedFirst
        updated.surname = trimmedSurname
        updated.email = savedEmail
        updated.mobileNumber = mobileOut

        let emailChanged = oldEmailNorm != savedEmail
        let orgId = updated.organizationId
        let previousFirst = organizationUsers[index].firstName
        let previousSurname = organizationUsers[index].surname
        var idsToPatch = Set(organizationUsers.filter { person in
            let email = person.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return email == oldEmailNorm || email == savedEmail
        }.map(\.id))
        idsToPatch.insert(userId)

        do {
            for id in idsToPatch {
                do {
                    // Only the changed identity fields of each document (`userProfileWriteFields` against the row
                    // this device loaded for that id).
                    try await firebaseBackend.patchUserIdentity(
                        userId: id,
                        firstName: trimmedFirst,
                        surname: trimmedSurname,
                        email: savedEmail,
                        mobileNumber: mobileOut,
                        previous: organizationUsers.first(where: { $0.id == id })
                    )
                } catch {
                    print("🔥🔥🔥 DEBUG: identity patch skipped for \(id): \(error.localizedDescription)")
                }
            }
            if emailChanged {
                try await firebaseBackend.reconcileUserEmailIndex(
                    organizationId: orgId,
                    userId: userId,
                    oldEmailNormalized: oldEmailNorm,
                    newEmail: savedEmail
                )
            }

            if let opStore = operativeStore {
                if let oi = opStore.operatives.firstIndex(where: {
                    $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == oldEmailNorm
                }) {
                    var op = opStore.operatives[oi]
                    op.firstName = trimmedFirst
                    op.lastName = trimmedSurname
                    op.email = savedEmail
                    op.phone = mobileOut
                    op.updatedAt = Date()
                    await opStore.updateOperative(op)
                }
                let managerIndexes = opStore.managers.indices.filter {
                    opStore.managers[$0].email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == oldEmailNorm
                }
                for mi in managerIndexes {
                    opStore.managers[mi].email = savedEmail
                    opStore.managers[mi].firstName = trimmedFirst
                    opStore.managers[mi].lastName = trimmedSurname
                    opStore.managers[mi].mobileNumber = mobileOut ?? ""
                    opStore.managers[mi].updatedAt = Date()
                }
                do {
                    try await firebaseBackend.updateManagerIdentityInPlace(
                        organizationId: orgId,
                        previousEmail: oldEmailNorm,
                        firstName: trimmedFirst,
                        lastName: trimmedSurname,
                        email: savedEmail,
                        mobileNumber: mobileOut ?? ""
                    )
                } catch {
                    print("🔥🔥🔥 DEBUG: manager identity update skipped: \(error.localizedDescription)")
                }
            }

            var people = organizationUsers
            for offset in people.indices where idsToPatch.contains(people[offset].id) {
                people[offset].firstName = trimmedFirst
                people[offset].surname = trimmedSurname
                people[offset].email = savedEmail
                people[offset].mobileNumber = mobileOut
            }
            if people.indices.contains(index) {
                people[index] = updated
            }
            organizationUsers = collapseRosterByEmail(people)
            identityRevision = IdentityRevision(
                userIds: idsToPatch,
                previousFirst: previousFirst,
                previousSurname: previousSurname,
                firstName: trimmedFirst,
                surname: trimmedSurname,
                email: savedEmail,
                mobile: mobileOut,
                savedAt: Date()
            )
            if let orgForRoster = firebaseBackend.currentOrganization?.firestoreDocumentId ?? Optional(updated.organizationId) {
                RosterRetention.save(organizationUsers, organizationId: orgForRoster)
            }
            if var cu = currentUser, cu.id == userId {
                cu.firstName = trimmedFirst
                cu.surname = trimmedSurname
                cu.email = savedEmail
                cu.mobileNumber = mobileOut
                currentUser = cu
            }

            if let pendingSelfEmail {
                // Not an error: Firebase Auth emailed the confirmation link; the profile email moves after it.
                selfEmailChangeNotice = CanonicalBusinessEngine.selfEmailChangeSentMessage(pendingSelfEmail)
            }

            return true
        } catch {
            errorMessage = "Could not save profile: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: updateUserIdentityProfile error: \(error)")
            return false
        }
    }

             func updateUserPermissions(
                 userId: String,
                 permissions: UserPermissions,
                 holidayStore: HolidayStore? = nil,
                 linkedOperativeUUID: UUID? = nil,
                 role: UserRole? = nil
             ) async -> Bool {
                 guard let firebaseBackend = firebaseBackend else { return false }
                 // A message from an earlier save must not be shown as the reason this one failed.
                 errorMessage = nil

                 do {
                     if let index = rosterIndex(for: userId) {
                         var updatedUser = organizationUsers[index]
                         let previousPermissions = updatedUser.permissions

                         if updatedUser.isSuperAdmin || isOrganizationCreator(userId: updatedUser.id) {
                             print("🔥🔥🔥 DEBUG: Cannot update permissions for the Super Admin")
                             errorMessage = "The Super Admin's account type cannot be changed here."
                             return false
                         }

                        // Skills catalogue is retired — never persist the flag as enabled.
                        var sanitized = permissions
                        sanitized.skills = false
                        let isSelfSave = Auth.auth().currentUser?.uid == userId
                        if isSelfSave {
                            sanitized.adminAccess = previousPermissions.adminAccess
                        }
                        // `sanitized.qualifications` is UI access only for the org catalogue.
                        // This method must not load/save organisations/.../qualifications or
                        // rewrite operative.qualifications when that flag changes.
                        updatedUser.permissions = sanitized
                        // Role follows Change user type. A toggle save must not invent a different role.
                        // A self save must not send role or admin privilege fields.
                        let previousRole = updatedUser.role
                        if let role, !isSelfSave {
                            updatedUser.role = role
                        }
                        let staffMaterialsAlwaysOn = updatedUser.isSuperAdmin
                            || sanitized.adminAccess
                            || updatedUser.role == .admin
                            || ((sanitized.manager || updatedUser.role == .manager) && !sanitized.operativeMode)
                        if staffMaterialsAlwaysOn {
                            updatedUser.permissions.materials = true
                            updatedUser.permissions.siteAudit = true
                        }

                        try await firebaseBackend.patchChangedUserPermissions(
                            userId: userId,
                            previous: previousPermissions,
                            updated: updatedUser.permissions,
                            previousRole: previousRole,
                            nextRole: isSelfSave ? nil : role
                        )
                         // A roster load that read the server before this write landed must not publish its
                         // older copy over the saved one (the person went back to their old role on screen).
                         invalidateInFlightRosterLoads()

                         let changesAccountType = !isSelfSave && (
                             (role != nil && role != previousRole)
                                 || updatedUser.permissions.adminAccess != previousPermissions.adminAccess
                                 || updatedUser.permissions.manager != previousPermissions.manager
                                 || updatedUser.permissions.operativeMode != previousPermissions.operativeMode
                         )
                         if changesAccountType {
                             // Read the saved document back from the server: the screen shows what was stored,
                             // never the value it asked for.
                             let orgId = normalizedOrganizationId(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "")
                             switch await firebaseBackend.probeOrganizationUser(userId: userId, organizationId: orgId) {
                             case .present(let stored):
                                 var confirmed = stored
                                 confirmed.sameEmailUserIds = updatedUser.sameEmailUserIds
                                 if !UserTypeChangeReadBack.landed(
                                     expectedRole: isSelfSave ? nil : role,
                                     expected: updatedUser.permissions,
                                     stored: stored
                                 ) {
                                     if let current = rosterIndex(for: userId) {
                                         if organizationUsers[current].id == confirmed.id {
                                             organizationUsers[current] = confirmed
                                         } else {
                                             organizationUsers[current].role = confirmed.role
                                             organizationUsers[current].permissions = confirmed.permissions
                                         }
                                     }
                                     errorMessage = UserTypeChangeReadBack.notSavedMessage(stored: stored)
                                     NSLog("ROLE_CHANGE_NOT_STORED id=%@ role=%@ adminAccess=%@", userId, stored.role.rawValue, stored.permissions.adminAccess ? "true" : "false")
                                     return false
                                 }
                                 updatedUser = confirmed
                             case .confirmedMissing:
                                 errorMessage = "This person's profile no longer exists, so their account type was not changed."
                                 return false
                             case .permissionDenied, .unconfirmed:
                                 // The server accepted the write; only the read-back could not be made.
                                 NSLog("ROLE_CHANGE_READBACK_UNCONFIRMED id=%@", userId)
                             }
                             if let role, !isSelfSave {
                                 await patchSameEmailDocuments(
                                     of: updatedUser,
                                     permissions: updatedUser.permissions,
                                     role: role,
                                     organizationId: orgId
                                 )
                             }
                         }

                         // The roster may have been republished while the write was in flight: find the row again.
                         guard let savedIndex = rosterIndex(for: userId) else {
                             return true
                         }
                         // `rosterIndex` finds the person under any of their ids, so the row may be the other same-email
                         // document the fold kept. Replacing it with this document's copy would drop the kept id (and
                         // every booking stored under it would name nobody): only the saved type moves onto that row,
                         // as `changeAccountType` does.
                         if organizationUsers[savedIndex].id == updatedUser.id {
                             organizationUsers[savedIndex] = updatedUser
                         } else {
                             organizationUsers[savedIndex].role = updatedUser.role
                             organizationUsers[savedIndex].permissions = updatedUser.permissions
                         }
                         let saved = organizationUsers[savedIndex]
                         // The copy saved on this phone follows the stored role too: an organisation switch or a cold
                         // start paints this cache first, and a load that missed the person then kept the old role.
                         if let orgId = organizationUsersLoadOrganizationId {
                             RosterRetention.save(organizationUsers, organizationId: orgId)
                         }

                         // Never delete leave (owner decision 4 Nov): the change only affects future leave.

                         return true
                     }
                     errorMessage = "This person is not in the loaded user list. Pull to refresh and try again."
                     return false
                 } catch {
                     print("🔥🔥🔥 DEBUG: Error updating user permissions: \(error)")
                     errorMessage = UserTypeChangeReadBack.writeRefusedMessage(error)
                     return false
                 }
             }

    /// RULEBOOK 1.11.0 / 1.12.2 §11: "Change user type" through `accountTypeChangeWrites` — every document that decides
    /// the type: `users/{uid}`, the same-email `users` documents of this organisation, `members.{uid}` and
    /// `users/{uid}/orgMemberships/{orgId}`, written as **one atomic batch** (`commitAccountTypeChangeWrites`, web
    /// `userStore.changeAccountType`). A profile of another company keeps its own document; only the members entry and
    /// the membership change (`note`). Refused for a Super Admin who would stop being an admin.
    /// `screenPermissions` are the toggles the sheet set; the plan applies `effectivePermissions` for the new level.
    ///
    /// The person is found under any of their ids (`rosterIndex(for:)`): the batch writes every same-email document, so
    /// the `rosterPeople` fold may keep the other document afterwards. After the commit the profile is read back from the
    /// server; a read-back that cannot be made is not an error (the batch was accepted).
    func changeAccountType(
        userId: String,
        kind: RulebookPermissionLevel,
        screenPermissions: UserPermissions,
        sheetToggles: [String: Bool]? = nil,
        holidayStore: HolidayStore? = nil,
        linkedOperativeUUID: UUID? = nil
    ) async -> (ok: Bool, note: String?) {
        errorMessage = nil
        guard let firebaseBackend, let personIndex = rosterIndex(for: userId) else {
            errorMessage = "This person is not in the loaded user list. Pull to refresh and try again."
            return (false, nil)
        }
        let person = organizationUsers[personIndex]
        if (person.isSuperAdmin || isOrganizationCreator(userId: person.id)) && kind != .admin {
            errorMessage = CanonicalBusinessEngine.constant("ACCOUNT_TYPE_SUPER_ADMIN_MESSAGE", as: String.self)
                ?? "The Super Admin's account type cannot be changed here."
            return (false, nil)
        }
        // RULEBOOK 1.31.0 §11 `lineManagerChangeBlock`: a line manager is not made an operative while anyone reports
        // to them; the refusal lists the reports.
        if let blocked = lineManagerChangeBlockMessage(for: person, change: .level(kind)) {
            errorMessage = blocked
            return (false, nil)
        }
        // The roster as it was before the change, for `jobManagerRemovalWrites` after it.
        let rosterBeforeChange = unfoldedRosterRows
        let orgId = normalizedOrganizationId(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "")
        // The person as the plan reads them (web passes the stored document): every stored toggle, top level and nested,
        // so `accountTypeWritePermissions` keeps the saved toggles the new level cannot change.
        var personRow = RulebookPeople.person(person)
        for (key, value) in person.accountTypeSubject { personRow[key] = value }
        personRow["role"] = person.role.rawValue
        personRow["organizationId"] = person.organizationId
        // `members.{uid}` and the membership go on the id the organisation's members map knows for this person (the
        // fold may show a same-email document with another id); the shown document is written as a same-email one.
        let membersMap = firebaseBackend.organizationMembersSnapshot.flatMap {
            organizationIdsMatch($0.organizationId, orgId) ? $0.members : nil
        }
        let planId = Self.membersKeyId(for: person, members: membersMap)
        personRow["id"] = planId
        // The roster the plan scans for same-email documents of this organisation: RULEBOOK 1.31.0 the UNFOLDED users
        // documents (`unfoldedOrganizationUsers`), never the email fold; a document still missing is read here (its
        // own `organizationId` decides whether it is written).
        var roster: [[String: Any]] = unfoldedOrganizationUsers.map {
            ["id": $0.id, "email": $0.email, "organizationId": $0.storedOrganizationId ?? $0.organizationId]
        }
        for aliasId in ([person.id] + person.sameEmailUserIds) where aliasId.caseInsensitiveCompare(planId) != .orderedSame
            && !roster.contains(where: { ($0["id"] as? String)?.caseInsensitiveCompare(aliasId) == .orderedSame }) {
            guard case .present(let alias) = await firebaseBackend.probeOrganizationUser(userId: aliasId, organizationId: orgId),
                  !alias.isSuperAdmin else { continue }
            roster.append(["id": alias.id, "email": alias.email, "organizationId": alias.organizationId])
        }
        guard let plan = CanonicalBusinessEngine.accountTypeChangeWrites(
            person: personRow,
            kind: kind,
            organizationId: orgId,
            roster: roster,
            // Only the toggles the sheet shows for the new level (web `changeAccountType` passes the sheet's values).
            // The whole map carried in-effect values for toggles the sheet does not show, so admin → manager wrote
            // `wholesalersOrderHistory: true` (an admin has it in effect) over a stored false.
            permissions: sheetToggles,
            members: membersMap
        ) else {
            errorMessage = "Could not work out the change. Nothing was changed."
            return (false, nil)
        }
        switch plan {
        case .refused(_, let message):
            errorMessage = message
            return (false, nil)
        case .ok(let role, let effective, let writes, let note):
            do {
                try await firebaseBackend.commitAccountTypeChangeWrites(
                    writes,
                    organizationId: orgId,
                    actorUserId: Auth.auth().currentUser?.uid
                )
            } catch {
                NSLog("ACCOUNT_TYPE_BATCH_REFUSED id=%@ %@", person.id, error.localizedDescription)
                errorMessage = UserTypeChangeReadBack.writeRefusedMessage(error)
                return (false, nil)
            }
            // A roster load that read the server before this batch landed must not publish its older copy over it.
            invalidateInFlightRosterLoads()

            let nextRole: UserRole = role == .admin ? .admin : role == .manager ? .manager : .operative
            let writesOwnProfile = writes.contains { write in
                if case .userProfile(let path, _) = write { return path.caseInsensitiveCompare("users/\(planId)") == .orderedSame }
                return false
            }
            var saved = person
            if writesOwnProfile {
                saved.role = nextRole
                saved.permissions = screenPermissions.applying(effective)
                // Read the saved document back from the server: the screen shows what was stored. The batch was
                // accepted, so a read-back that cannot be made (or a copy not yet caught up) is not an error.
                if case .present(let stored) = await firebaseBackend.probeOrganizationUser(userId: planId, organizationId: orgId) {
                    if UserTypeChangeReadBack.landed(expectedRole: nextRole, expected: saved.permissions, stored: stored) {
                        var confirmed = stored
                        confirmed.sameEmailUserIds = person.sameEmailUserIds
                        confirmed.formerUserIds = person.formerUserIds
                        saved = confirmed
                    } else {
                        NSLog("ROLE_CHANGE_READBACK_BEHIND id=%@ role=%@", person.id, stored.role.rawValue)
                    }
                }
                // The roster may have been republished (and re-folded) while the batch was in flight.
                if let index = rosterIndex(for: person.id) {
                    if organizationUsers[index].id == saved.id {
                        organizationUsers[index] = saved
                    } else {
                        organizationUsers[index].role = saved.role
                        organizationUsers[index].permissions = saved.permissions
                    }
                    if let rosterOrgId = organizationUsersLoadOrganizationId {
                        RosterRetention.save(organizationUsers, organizationId: rosterOrgId)
                    }
                }
            }

            // RULEBOOK 1.31.0 §11: made an operative → off every job they manage, admins told (`job_manager_removed`).
            // Admin ↔ manager keeps every job (`changeRemovesJobManager` is false).
            await removeFromManagedJobs(person, change: .level(kind), roster: rosterBeforeChange)
            // Never delete leave (owner decision 4 Nov): a type change only affects future leave.
            return (true, note)
        }
    }

    /// The id of `person` that the organisation's `members` map is keyed by: the row's own id when the map has it (or
    /// the map is not loaded), else the first of the person's same-email ids that it has. Only picks which of the
    /// person's own document ids the `accountTypeChangeWrites` plan is built for.
    static func membersKeyId(for person: AppUser, members: [String: String]?) -> String {
        guard let members, !members.isEmpty else { return person.id }
        func isKey(_ candidate: String) -> Bool {
            members.keys.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(candidate) == .orderedSame }
        }
        if isKey(person.id) { return person.id }
        return person.sameEmailUserIds.first(where: isKey) ?? person.id
    }

    /// Ends every roster load already in flight: its result is ignored when it lands. The next load starts afresh.
    private func invalidateInFlightRosterLoads() {
        organizationUsersLoadGeneration += 1
        organizationUsersLoadInProgress = false
        lastOrganizationUsersLoadAt = nil
    }

    /// The person's other `users` documents with the same email in this organisation (`rosterPeople`
    /// `sameEmailUserIds`) get the same account type, so the document their own sign-in reads
    /// (`users/{auth uid}`) is not left on the old one. A document whose `organizationId` is another company is
    /// never written. A failure here is logged; the row the editor saved stays saved.
    private func patchSameEmailDocuments(
        of person: AppUser,
        permissions: UserPermissions,
        role: UserRole,
        organizationId: String
    ) async {
        guard let firebaseBackend, !organizationId.isEmpty else { return }
        for aliasId in person.sameEmailUserIds where aliasId.caseInsensitiveCompare(person.id) != .orderedSame {
            guard case .present(let alias) = await firebaseBackend.probeOrganizationUser(
                userId: aliasId,
                organizationId: organizationId
            ) else { continue }
            guard organizationIdsMatch(alias.organizationId, organizationId), !alias.isSuperAdmin else { continue }
            do {
                try await firebaseBackend.patchChangedUserPermissions(
                    userId: aliasId,
                    previous: alias.permissions,
                    updated: permissions,
                    previousRole: alias.role,
                    nextRole: role
                )
            } catch {
                NSLog("ROLE_CHANGE_ALIAS_SKIPPED id=%@ error=%@", aliasId, error.localizedDescription)
            }
        }
    }

    /// Persists annual leave entitlement on `users/{userId}` as a field-limited patch. The write does not include organizationId.
    func updateUserAnnualLeaveEntitlement(
        userId: String,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        yearAllowance: Double? = nil,
        yearAllowanceKey: String? = nil,
        writeYearAllowance: Bool = false
    ) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let index = rosterIndex(for: userId) else { return false }
        var updated = organizationUsers[index]
        if updated.isSuperAdmin || isOrganizationCreator(userId: updated.id) {
            return false
        }
        let clampedDays = AnnualLeavePolicy.clampDaysPerYear(daysPerYear)
        let sm = AnnualLeavePolicy.clampMonth(startMonth)
        let em = AnnualLeavePolicy.clampMonth(endMonth)

        updated.annualLeaveDaysPerYear = clampedDays
        updated.annualLeaveYearStartMonth = sm
        updated.annualLeaveYearEndMonth = em
        updated.annualLeaveCarriesOver = carriesOver
        if writeYearAllowance {
            updated.annualLeaveYearAllowance = yearAllowance
            updated.annualLeaveYearAllowanceKey = yearAllowanceKey
        }

        do {
            let canPatchLeave = hasAdminAccess()
                || (isActingManagerOperativeManagementOnly()
                    && (updated.permissions.operativeMode || updated.role == .operative))
            guard canPatchLeave else { return false }
            try await firebaseBackend.updateAnnualLeaveEntitlement(
                userId: userId,
                daysPerYear: clampedDays,
                startMonth: sm,
                endMonth: em,
                carriesOver: carriesOver,
                yearAllowance: yearAllowance,
                yearAllowanceKey: yearAllowanceKey,
                writeYearAllowance: writeYearAllowance
            )
            organizationUsers[index] = updated
            if var cu = currentUser, cu.id == userId {
                cu.annualLeaveDaysPerYear = clampedDays
                cu.annualLeaveYearStartMonth = sm
                cu.annualLeaveYearEndMonth = em
                cu.annualLeaveCarriesOver = carriesOver
                if writeYearAllowance {
                    cu.annualLeaveYearAllowance = yearAllowance
                    cu.annualLeaveYearAllowanceKey = yearAllowanceKey
                }
                currentUser = cu
            }
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: updateUserAnnualLeaveEntitlement error: \(error)")
            errorMessage = "Could not save annual leave settings: \(error.localizedDescription)"
            return false
        }
    }

    /// Persists `annualLeaveEnabled` on `users/{userId}` as a field-limited patch. The write does not include organizationId.
    /// RULEBOOK 1.13.0 §4.4: an admin sets or clears `users/{uid}.employmentStartDate` (`YYYY-MM-DD`); the leave year
    /// joined is pro rata from it (`annualLeaveBalance` `employmentStartDayKey`).
    func updateUserEmploymentStartDate(userId: String, dayKey: String?) async -> Bool {
        guard let firebaseBackend, hasAdminAccess() else { return false }
        do {
            try await firebaseBackend.updateEmploymentStartDate(userId: userId, dayKey: dayKey)
            if let index = rosterIndex(for: userId) {
                organizationUsers[index].employmentStartDate = dayKey
            }
            if var me = currentUser, me.id == userId {
                me.employmentStartDate = dayKey
                currentUser = me
            }
            return true
        } catch {
            errorMessage = "Could not save the start date: \(error.localizedDescription)"
            return false
        }
    }

    func updateUserAnnualLeaveEnabled(userId: String, enabled: Bool) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let index = rosterIndex(for: userId) else { return false }
        if isOrganizationCreator(userId: userId) { return false }
        var updated = organizationUsers[index]
        if updated.isSuperAdmin || isOrganizationCreator(userId: updated.id) {
            return false
        }

        updated.annualLeaveEnabled = enabled

        do {
            let canPatchLeave = hasAdminAccess()
                || (isActingManagerOperativeManagementOnly()
                    && (updated.permissions.operativeMode || updated.role == .operative))
            guard canPatchLeave else { return false }
            try await firebaseBackend.updateAnnualLeaveEnabled(userId: userId, enabled: enabled)
            organizationUsers[index] = updated
            if var cu = currentUser, cu.id == userId {
                cu.annualLeaveEnabled = enabled
                currentUser = cu
            }
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: updateUserAnnualLeaveEnabled error: \(error)")
            errorMessage = "Could not save annual leave access: \(error.localizedDescription)"
            return false
        }
    }

    func updateUserEmploymentType(userId: String, employmentType: EmploymentType, effectiveAt: Date? = nil) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let storedRow = rosterRow(for: userId) else { return false }
        if isOrganizationCreator(userId: userId) { return false }
        // RULEBOOK 1.26.1 §8 `CanonicalBusinessEngine.payEditorStartingValues`: the previous employment type is the
        // pay editor's record (the pay profile while `privatePay` is on; the users document as stored while it is off).
        var updated = await payEditorRecord(for: storedRow)
        guard let index = rosterIndex(for: userId) else { return false }
        if updated.isSuperAdmin || isOrganizationCreator(userId: updated.id) {
            return false
        }
        // RULEBOOK §8: employment type is pay, so it follows `canChangePersonPay`.
        guard canChangePay(of: updated) else {
            errorMessage = Self.payChangeRefusedMessage
            return false
        }
        guard let change = CanonicalBusinessEngine.applyEmploymentTypeChange(
            previousType: updated.employmentType.rawValue,
            nextType: employmentType.rawValue,
            previousTransitionFrom: updated.employmentTypeTransitionFrom?.rawValue,
            previousEffectiveAt: updated.employmentTypeEffectiveAt,
            effectiveAt: effectiveAt
        ) else {
            errorMessage = "Could not save employment type."
            return false
        }
        updated.employmentType = EmploymentType.fromCanonical(change.employmentType)
        updated.employmentTypeTransitionFrom = change.employmentTypeTransitionFrom.map { EmploymentType.fromCanonical($0) }
        updated.employmentTypeEffectiveAt = change.employmentTypeEffectiveAt
        updated.timesheetsEnabled = updated.employmentType(on: Date()) == .selfEmployed

        do {
            if hasAdminAccess() {
                let previousTimesheets = organizationUsers[index].timesheetsEnabled
                try await firebaseBackend.updateUserEmploymentType(
                    userId: userId,
                    employmentType: updated.employmentType,
                    transitionFrom: updated.employmentTypeTransitionFrom,
                    effectiveAt: updated.employmentTypeEffectiveAt,
                    timesheetsEnabled: updated.timesheetsEnabled == previousTimesheets ? nil : updated.timesheetsEnabled
                )
            } else if isActingManagerOperativeManagementOnly(),
                      updated.permissions.operativeMode || updated.role == .operative {
                try await firebaseBackend.updateUserEmploymentType(
                    userId: userId,
                    employmentType: employmentType,
                    transitionFrom: updated.employmentTypeTransitionFrom,
                    effectiveAt: updated.employmentTypeEffectiveAt
                )
            } else {
                return false
            }
            organizationUsers[index] = updated
            if var cu = currentUser, cu.id == userId {
                cu.employmentType = updated.employmentType
                cu.employmentTypeTransitionFrom = updated.employmentTypeTransitionFrom
                cu.employmentTypeEffectiveAt = updated.employmentTypeEffectiveAt
                cu.timesheetsEnabled = updated.timesheetsEnabled
                currentUser = cu
            }
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: updateUserEmploymentType error: \(error)")
            errorMessage = "Could not save employment type: \(error.localizedDescription)"
            return false
        }
    }

             /// Updates the line manager and the rate on the user account (RULEBOOK §8, §11).
             /// Only someone who may change this person's pay (`canChangePersonPay`) can change either; anyone else
             /// gets a clear error and nothing is written. The rate keeps the person's stored `payBasis`: the single
             /// rate field edits that basis's amount, and the save writes `payBasis` plus that one amount.
             func updateOperativeProfileFields(
                for user: AppUser,
                assignedManagerUserId: String?,
                assignedManagerUserIds: [String]? = nil,
                hasNoLineManager: Bool? = nil,
                dayRate: Double?,
                operativeStore: OperativeStore?,
                dayRateEffectiveAt: Date? = nil,
                updateDayRate: Bool = true
             ) async -> Bool {
                guard let firebaseBackend = firebaseBackend else { return false }
                guard organizationUsers.contains(where: { $0.id == user.id }) else { return false }
                // RULEBOOK 1.26.1 §8 `CanonicalBusinessEngine.payEditorStartingValues`: the save baseline (the "rate
                // changed?" test and the rate-history previous row) is the editor's record, never a stale users rate.
                let original = await payEditorRecord(for: organizationUsers.first(where: { $0.id == user.id }) ?? user)
                guard let index = organizationUsers.firstIndex(where: { $0.id == user.id }) else { return false }
                var updatedUser = original
                guard updatedUser.permissions.operativeMode || updatedUser.role == .operative || updatedUser.permissions.manager || updatedUser.role == .manager || updatedUser.permissions.adminAccess || updatedUser.role == .admin else { return false }
                if let hasNoLineManager {
                    updatedUser.setNoLineManager(hasNoLineManager)
                }
                let managerIds = (assignedManagerUserIds ?? assignedManagerUserId.map { [$0] } ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !updatedUser.hasNoLineManager {
                    if managerIds.contains(updatedUser.id) {
                        errorMessage = "A user cannot be their own line manager."
                        return false
                    }
                    updatedUser.setLineManagerUserIds(managerIds)
                }
                let previousPay = Self.storedPay(of: original)
                let dayRateChanged = updateDayRate && previousPay.amount != dayRate
                let lineManagerChanged = Set(updatedUser.lineManagerUserIds) != Set(original.lineManagerUserIds)
                    || updatedUser.hasNoLineManager != original.hasNoLineManager
                guard dayRateChanged || lineManagerChanged else { return true }
                guard canChangePay(of: original) else {
                    errorMessage = Self.payChangeRefusedMessage
                    return false
                }
                if dayRateChanged {
                    Self.applyStoredPay(to: &updatedUser, basis: previousPay.basis, amount: dayRate)
                }

                var historyRows: [CanonicalBusinessEngine.CanonicalPayRateHistoryWrite] = []
                if dayRateChanged, let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                    let emailNorm = updatedUser.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let linkedOperativeId = operativeStore?.operatives.first(where: {
                        $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == emailNorm
                    })?.id
                    let change = await payRateChangeRows(
                        organizationId: orgId,
                        user: updatedUser,
                        operativeId: linkedOperativeId,
                        previous: previousPay,
                        nextAmount: dayRate,
                        nextBasis: previousPay.basis,
                        effectiveAt: dayRateEffectiveAt ?? Date()
                    )
                    if let refusal = change.refusal {
                        errorMessage = refusal
                        return false
                    }
                    historyRows = change.rows
                }
                do {
                    // RULEBOOK 1.10.0 §8: the profile and its `payRateChangeWrites` rows in one batch.
                    try await firebaseBackend.updateOperativeProfileMetadata(
                        userId: updatedUser.id,
                        assignedManagerUserId: updatedUser.assignedManagerUserId,
                        assignedManagerUserIds: updatedUser.lineManagerUserIds,
                        hasNoLineManager: hasNoLineManager ?? updatedUser.hasNoLineManager,
                        dayRate: dayRate,
                        updateDayRate: dayRateChanged,
                        payBasis: previousPay.basis,
                        historyRows: historyRows
                    )
                    // Mirror (web writes the same one). Never read over users/{uid}; best effort.
                    let mirrored = Self.storedPay(of: updatedUser)
                    try? await firebaseBackend.saveOperativeProfileMetadataFallback(
                        organizationId: updatedUser.organizationId,
                        userId: updatedUser.id,
                        assignedManagerUserId: updatedUser.assignedManagerUserId,
                        dayRate: mirrored.amount,
                        payBasis: mirrored.basis
                    )
                    organizationUsers[index] = updatedUser
                    if let operativeStore {
                        await syncActiveOperativesWithUserAccounts(operativeStore: operativeStore)
                    }
                    await loadOrganizationUsers(forceRefresh: true)
                    return true
                } catch {
                    // No fallback write and no on-device copy: the server refused, so nothing changed.
                    errorMessage = Self.isPermissionDenied(error)
                        ? Self.payChangeRefusedMessage
                        : "Failed to update operative profile fields: \(error.localizedDescription)"
                    print("🔥🔥🔥 DEBUG: Error updating operative profile fields: \(error)")
                    return false
                }
             }

    // MARK: - Pay (RULEBOOK §8)

    static let payChangeRefusedMessage = "You don't have permission to change this person's pay or line manager. Nothing was saved."

    /// `canChangePersonPay` for the signed-in account, from its real document (as the security rules see it,
    /// not role testing). `subject` nil is an operative catalogue row with no account.
    func canChangePay(of subject: AppUser?) -> Bool {
        canChangePay(subjectUserId: subject?.id, subjectIsOperative: subject?.isPaySubjectOperative ?? true)
    }

    /// `canChangePersonPay` for a person Add User is about to create (no id yet; web passes `''`).
    func canChangePayOfNewPerson(isOperative: Bool) -> Bool {
        canChangePay(subjectUserId: "", subjectIsOperative: isOperative)
    }

    private func canChangePay(subjectUserId: String?, subjectIsOperative: Bool) -> Bool {
        guard let writer = currentUser else { return false }
        return CanonicalBusinessEngine.canChangePersonPay(
            writerUserId: Auth.auth().currentUser?.uid ?? writer.id,
            writerIsPlatformOwner: AppUser.isPlatformOwnerEmail(writer.email),
            writerIsAdmin: writer.isSuperAdmin || writer.permissions.adminAccess
                || (writer.role == .admin && !writer.permissions.operativeMode),
            writerIsManager: writer.permissions.manager || writer.role == .manager,
            writerHasOperativesAccess: writer.permissions.operatives,
            writerIsOperativeMode: writer.permissions.operativeMode,
            subjectUserId: subjectUserId,
            subjectIsOperative: subjectIsOperative
        )
    }

    /// The stored basis (`day` / `hourly`) and its amount, read with `readStoredRates`.
    static func storedPay(of user: AppUser) -> (basis: String, amount: Double?) {
        let stored = CanonicalBusinessEngine.readStoredRates(
            payBasis: user.payBasis,
            dayRate: user.dayRate,
            hourlyRate: user.hourlyRate
        )
        let basis = stored?.payBasis == "hourly" ? "hourly" : "day"
        let amount = basis == "hourly" ? stored?.hourlyRate : stored?.dayRate
        return (basis, amount)
    }

    /// The in-memory copy after a rate save: `payBasis` plus exactly one amount (`exclusiveRates`).
    static func applyStoredPay(to user: inout AppUser, basis: String, amount: Double?) {
        guard let amount else {
            user.payBasis = nil
            user.dayRate = nil
            user.hourlyRate = nil
            return
        }
        let pay = CanonicalBusinessEngine.exclusiveRates(
            payBasis: basis,
            dayRate: basis == "hourly" ? nil : amount,
            hourlyRate: basis == "hourly" ? amount : nil
        )
        user.payBasis = pay?.payBasis ?? basis
        user.dayRate = (pay?.payBasis ?? basis) == "hourly" ? nil : (pay?.dayRate ?? amount)
        user.hourlyRate = (pay?.payBasis ?? basis) == "hourly" ? (pay?.hourlyRate ?? amount) : nil
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7
    }

    /// RULEBOOK 1.10.0 §8 `payRateChangeWrites`: the `operativeDayRateHistory` rows a rate change writes in the
    /// profile's batch (a seed row only when the person's history loaded and is empty; a "rate cleared" row when a
    /// rate is cleared). A failed history load refuses the save (`refusal`), never counted as empty history.
    private func payRateChangeRows(
        organizationId: String,
        user: AppUser,
        operativeId: UUID?,
        previous: (basis: String, amount: Double?),
        nextAmount: Double?,
        nextBasis: String,
        effectiveAt: Date
    ) async -> (rows: [CanonicalBusinessEngine.CanonicalPayRateHistoryWrite], refusal: String?) {
        guard let firebaseBackend else { return ([], nil) }
        var historyIds: [String]?
        if let collection = try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: organizationId) {
            // The person's loaded rows (any of their ids, or their operative row).
            var ids = Set<String>()
            for personId in RulebookPeople.ownerIds(for: user, users: organizationUsers) {
                for entry in collection.mergedEntries(userId: personId, operativeId: nil) { ids.insert(entry.documentId ?? entry.id.uuidString) }
            }
            for entry in collection.mergedEntries(userId: nil, operativeId: operativeId) { ids.insert(entry.documentId ?? entry.id.uuidString) }
            historyIds = Array(ids).sorted()
        }
        guard let result = CanonicalBusinessEngine.payRateChangeWrites(
            userId: user.id,
            operativeId: operativeId.map { Booking.storedOperativeId(for: $0) },
            previous: (previous.amount, previous.basis == "hourly" ? "hourly" : "day"),
            next: (nextAmount, nextBasis == "hourly" ? "hourly" : "day"),
            historyRowIds: historyIds,
            effective: effectiveAt,
            seedEffective: user.createdAt
        ) else {
            return ([], "Couldn't save the rate: the pay rules did not load. Try again.")
        }
        return (result.rows, result.refusal)
    }
    
    /// Persists trade type on the user document and mirrors it to linked operative or manager roster rows (matched by email).
    /// Uploads a new profile image and writes `profilePhotoURL` on the user document.
    func updateUserProfilePhoto(for user: AppUser, image: UIImage) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "No organization loaded."
            return false
        }
        do {
            let url = try await firebaseBackend.uploadUserProfilePhoto(image, userId: user.id, organizationId: orgId)
            try await firebaseBackend.updateUserProfilePhotoURL(userId: user.id, url: url)
            let changedAt = Date()
            if let idx = organizationUsers.firstIndex(where: { $0.id == user.id }) {
                organizationUsers[idx].profilePhotoURL = url
                organizationUsers[idx].profilePhotoUpdatedAt = changedAt
            }
            if var cu = currentUser, cu.id == user.id {
                cu.profilePhotoURL = url
                cu.profilePhotoUpdatedAt = changedAt
                currentUser = cu
            }
            return true
        } catch {
            errorMessage = "Could not upload profile photo: \(error.localizedDescription)"
            return false
        }
    }
    
    func updateUserStaffTrade(for user: AppUser, tradeTypePreset: String?, tradeTypeCustom: String?, operativeStore: OperativeStore) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let index = organizationUsers.firstIndex(where: { $0.id == user.id }) else { return false }
        guard user.permissions.operativeMode
            || user.role == .operative
            || user.permissions.manager
            || user.role == .manager
            || user.permissions.adminAccess
            || user.role == .admin
            || user.isSuperAdmin else {
            return false
        }
        var updated = organizationUsers[index]
        updated.tradeTypePreset = tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tradeTypeCustom = tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.tradeTypePreset?.isEmpty == true { updated.tradeTypePreset = nil }
        if updated.tradeTypeCustom?.isEmpty == true { updated.tradeTypeCustom = nil }
        do {
            try await firebaseBackend.updateUserStaffTradeMetadata(
                userId: updated.id,
                tradeTypePreset: updated.tradeTypePreset,
                tradeTypeCustom: updated.tradeTypeCustom
            )
            organizationUsers[index] = updated
            await syncStaffTradeFromUserToRoster(user: updated, operativeStore: operativeStore)
            await loadOrganizationUsers()
            return true
        } catch {
            errorMessage = "Failed to update trade type: \(error.localizedDescription)"
            return false
        }
    }

    private func syncStaffTradeFromUserToRoster(user: AppUser, operativeStore: OperativeStore) async {
        let email = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        if user.permissions.operativeMode || user.role == .operative,
           let idx = operativeStore.operatives.firstIndex(where: {
               $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
           }) {
            var op = operativeStore.operatives[idx]
            guard op.tradeTypePreset != user.tradeTypePreset || op.tradeTypeCustom != user.tradeTypeCustom else { return }
            op.tradeTypePreset = user.tradeTypePreset
            op.tradeTypeCustom = user.tradeTypeCustom
            op.updatedAt = Date()
            await operativeStore.updateOperative(op)
            return
        }
        if user.permissions.manager || user.role == .manager,
           let idx = operativeStore.managers.firstIndex(where: {
               $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
           }) {
            var m = operativeStore.managers[idx]
            guard m.tradeTypePreset != user.tradeTypePreset || m.tradeTypeCustom != user.tradeTypeCustom else { return }
            m.tradeTypePreset = user.tradeTypePreset
            m.tradeTypeCustom = user.tradeTypeCustom
            m.updatedAt = Date()
            await operativeStore.updateManager(m)
        }
    }

    func updateManagerDayRate(
        for user: AppUser,
        dayRate: Double?,
        effectiveAt: Date? = nil,
        operativeStore: OperativeStore? = nil
    ) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard organizationUsers.contains(where: { $0.id == user.id }) else { return false }
        // RULEBOOK 1.26.1 §8 `CanonicalBusinessEngine.payEditorStartingValues`: the previous rate is the editor's record.
        let row = await payEditorRecord(for: organizationUsers.first(where: { $0.id == user.id }) ?? user)
        guard let index = organizationUsers.firstIndex(where: { $0.id == user.id }) else { return false }
        let isStaffDayRate = row.permissions.manager || row.role == .manager || row.permissions.adminAccess || row.role == .admin
        guard isStaffDayRate, !row.permissions.operativeMode else { return false }

        var updatedUser = row
        let previousPay = Self.storedPay(of: updatedUser)
        guard previousPay.amount != dayRate else { return true }
        // A manager's pay is changed by admins only, and nobody but an admin changes their own (§8).
        guard canChangePay(of: row) else {
            errorMessage = Self.payChangeRefusedMessage
            return false
        }
        Self.applyStoredPay(to: &updatedUser, basis: previousPay.basis, amount: dayRate)

        var historyRows: [CanonicalBusinessEngine.CanonicalPayRateHistoryWrite] = []
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            let change = await payRateChangeRows(
                organizationId: orgId,
                user: updatedUser,
                operativeId: nil,
                previous: previousPay,
                nextAmount: dayRate,
                nextBasis: previousPay.basis,
                effectiveAt: effectiveAt ?? Date()
            )
            if let refusal = change.refusal {
                errorMessage = refusal
                return false
            }
            historyRows = change.rows
        }
        do {
            // RULEBOOK 1.10.0 §8: the profile and its `payRateChangeWrites` rows in one batch.
            try await firebaseBackend.updateUserDayRateMetadata(
                userId: updatedUser.id,
                dayRate: dayRate,
                payBasis: previousPay.basis,
                historyRows: historyRows
            )
            // Mirror (web writes the same one). Never read over users/{uid}; best effort.
            try? await firebaseBackend.saveOperativeProfileMetadataFallback(
                organizationId: updatedUser.organizationId,
                userId: updatedUser.id,
                assignedManagerUserId: updatedUser.assignedManagerUserId,
                dayRate: dayRate,
                payBasis: previousPay.basis
            )
            organizationUsers[index] = updatedUser
            if let operativeStore {
                await syncOperativeDayRateFromStaffUser(updatedUser, operativeStore: operativeStore)
            }
            await loadOrganizationUsers(forceRefresh: true)
            return true
        } catch {
            errorMessage = Self.isPermissionDenied(error)
                ? Self.payChangeRefusedMessage
                : "Failed to update day rate: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error updating staff day rate: \(error)")
            return false
        }
    }

    private func syncOperativeDayRateFromStaffUser(_ user: AppUser, operativeStore: OperativeStore) async {
        guard canChangePay(of: user) else { return }
        let em = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !em.isEmpty,
              let idx = operativeStore.operatives.firstIndex(where: {
                  $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == em
              }) else { return }
        var op = operativeStore.operatives[idx]
        let targetDay = user.dayRate
        let targetHourly = user.hourlyRate
        guard op.dayRate != targetDay || op.hourlyRate != targetHourly else { return }
        op.dayRate = targetDay
        op.hourlyRate = targetHourly
        op.updatedAt = Date()
        await operativeStore.updateOperative(op)
    }
             
             // MARK: - User Active Status
             
             /// RULEBOOK 1.31.0 §11 `userActiveWrites`: `isActive` on every users document of the person in this
             /// organisation (their same-email copies included, read from the unfolded roster) and `accountActive` on their
             /// membership, in one batch. A line manager is not deactivated while anyone reports to them
             /// (`lineManagerChangeBlock`); a deactivated manager is taken off their jobs (`jobManagerRemovalWrites`).
             func updateUserActiveStatus(for user: AppUser, isActive: Bool) async -> Bool {
                 guard firebaseBackend != nil else {
                     errorMessage = "Unable to connect."
                     return false
                 }
                 guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else {
                     errorMessage = "Organization not loaded."
                     return false
                 }
                 if !isActive && isProtectedSuperAdmin(user) {
                     errorMessage = "The Super Admin cannot be deactivated."
                     return false
                 }
                 if !isActive, let blocked = lineManagerChangeBlockMessage(for: user, change: .deactivate) {
                     errorMessage = blocked
                     return false
                 }
                 let rosterBeforeChange = unfoldedRosterRows
                 let writes = CanonicalBusinessEngine.userActiveWrites(
                     organizationId: organizationId,
                     personId: user.id,
                     email: user.email,
                     isActive: isActive,
                     roster: unfoldedOrganizationUsers.map { row in
                         ["id": row.id, "email": row.email, "organizationId": row.storedOrganizationId ?? row.organizationId]
                     }
                 )
                 guard !writes.isEmpty else {
                     errorMessage = "Couldn't work out the change: the rules did not load. Nothing was changed."
                     return false
                 }
                 // Memberships are admin writes (web `setUserActive`): a manager with the Operatives permission writes the
                 // users documents only. A membership is updated only when it already exists (`writeOrgMembership`,
                 // never a bare `{ accountActive }` document: a session reads any membership as the person's level here).
                 let actorIsAdmin = currentUser.map { Self.staffAccountRole(for: $0) }.map { ($0.isAdmin || $0.isSuperAdmin) && !$0.isOperativeMode } ?? false
                 let db = Firestore.firestore()
                 let batch = db.batch()
                 let actor = Auth.auth().currentUser?.uid
                 var memberships: [(userId: String, fields: [String: Any])] = []
                 for write in writes {
                     var fields: [String: Any] = [:]
                     for (key, value) in write.fields { fields[key] = value }
                     if write.kind == "membership" {
                         let parts = write.path.split(separator: "/").map(String.init)
                         if actorIsAdmin, parts.count == 4 { memberships.append((parts[1], fields)) }
                         continue
                     }
                     batch.updateData(WriteMetadata.stamped(fields, userId: actor), forDocument: db.document(write.path))
                 }
                 do {
                     try await batch.commit()
                 } catch {
                     errorMessage = "Failed to update active status: \(error.localizedDescription)"
                     print("🔥🔥🔥 DEBUG: ❌ Error updating user active status: \(error)")
                     return false
                 }
                 for membership in memberships {
                     do {
                         _ = try await firebaseBackend?.writeOrgMembership(
                             userId: membership.userId,
                             organizationId: organizationId,
                             next: membership.fields,
                             writer: "admin"
                         )
                     } catch {
                         print("🔥🔥🔥 DEBUG: [OrgMembership] accountActive patch skipped: \(error.localizedDescription)")
                     }
                 }
                 let emailNormalized = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                 for i in organizationUsers.indices {
                     if organizationUsers[i].id == user.id
                         || (!emailNormalized.isEmpty && organizationUsers[i].email.lowercased() == emailNormalized) {
                         organizationUsers[i].isActive = isActive
                     }
                 }
                 errorMessage = nil
                 if !isActive {
                     await removeFromManagedJobs(user, change: .deactivate, roster: rosterBeforeChange)
                 }
                 await loadOrganizationUsers()
                 return true
             }
             
             // MARK: - Resend Invitation Email
             
             func resendInvitationEmail(email: String, firstName: String, surname: String, invitationId: String) async {
                 guard let firebaseBackend = firebaseBackend else { return }
                 
                 // Use FirebaseBackend's sendInvitationEmail method
                 await firebaseBackend.sendInvitationEmail(
                     email: email,
                     firstName: firstName,
                     surname: surname,
                     invitationId: invitationId
                 )
             }
             
             func sendSignUpEmailWithVerification(email: String, firstName: String, surname: String, invitationId: String) async -> Bool {
                 guard let firebaseBackend = firebaseBackend else { return false }
                 await firebaseBackend.sendInvitationEmail(
                     email: email,
                     firstName: firstName,
                     surname: surname,
                     invitationId: invitationId
                 )
                 return true
             }
             
             /// Sends a password reset email (new verification code) to the user. Use for active/verified users.
             func sendPasswordResetEmail(to email: String) async -> Bool {
                 guard let firebaseBackend = firebaseBackend else { return false }
                 do {
                     try await firebaseBackend.resetPassword(email: email)
                     return true
                 } catch {
                     print("🔥🔥🔥 DEBUG: Error sending password reset email: \(error)")
                     return false
                 }
             }
    
    /// Sends **Firebase Authentication's** password-reset email (standard OOB link). Use for pending users who already have
    /// an Auth account so invitation setup fails with "email already in use".
    func sendFirebaseAuthPasswordResetEmail(to email: String) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        do {
            try await firebaseBackend.resetUserPassword(email: email)
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: Firebase Auth password reset failed: \(error)")
            return false
        }
    }
    
    /// Keeps roster `Operative.isActive` in sync with active operative app-user accounts so scheduling pickers include them.
    func syncActiveOperativesWithUserAccounts(operativeStore: OperativeStore) async {
        if WarningsRefreshHelper.isHomeWarningsWarmInFlight {
            print("🔥🔥🔥 DEBUG: Skipping operative roster sync — Home warnings warm in flight")
            return
        }
        for user in organizationUsers where user.permissions.operativeMode && user.isActive {
            let em = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = operativeStore.operatives.firstIndex(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == em
            }) else { continue }
            var op = operativeStore.operatives[idx]
            var changed = false
            if !op.isActive {
                op.isActive = true
                changed = true
            }
            // Pay on `operatives/{id}` is mirrored only by someone who may change this person's pay
            // (`canChangePersonPay`). Everyone else sends only the changed non-pay fields.
            let mayMirrorPay = canChangePay(of: user)
            let stored = Self.storedPay(of: user)
            if !mayMirrorPay {
                // Leave the row's pay as it is.
            } else if stored.basis == "day", let dr = stored.amount {
                if op.dayRate != dr {
                    op.dayRate = dr
                    changed = true
                }
                if op.hourlyRate != nil {
                    op.hourlyRate = nil
                    changed = true
                }
            } else if stored.basis == "hourly", let hr = stored.amount {
                if op.hourlyRate != hr {
                    op.hourlyRate = hr
                    changed = true
                }
                if op.dayRate != nil {
                    op.dayRate = nil
                    changed = true
                }
            }
            // A blank account rate leaves the row's rate alone: `payRateOnDay` falls back to the operative
            // row when users/{uid} has none (RULEBOOK §8), and a local copy never deletes a stored field.
            if op.tradeTypePreset != user.tradeTypePreset || op.tradeTypeCustom != user.tradeTypeCustom {
                op.tradeTypePreset = user.tradeTypePreset
                op.tradeTypeCustom = user.tradeTypeCustom
                changed = true
            }
            if changed {
                op.updatedAt = Date()
                await operativeStore.updateOperative(op)
                print("🔥🔥🔥 DEBUG: ✅ Synced operative roster for linked user \(em)")
                await Task.yield()
            }
        }
    }
}
