import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif
@preconcurrency import FirebaseFirestoreInternal
import Combine

// MARK: - Firestore field normalization

/// Resolves `organizationId` whether stored as String, DocumentReference, or legacy path strings.
func organizationIdFromFirestore(_ value: Any?) -> String? {
    if let ref = value as? DocumentReference {
        let id = ref.documentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
    if let s = value as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.contains("/") {
            return String(t.split(separator: "/").last ?? Substring(t))
        }
        return t
    }
    return nil
}

func organizationIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !left.isEmpty,
          !right.isEmpty else {
        return false
    }
    return left == right
}

/// Firestore often delivers booleans as `Bool`, as `NSNumber` (0/1), or as `"true"` / `"1"`.
/// `as? Bool` only accepts a real boolean, so a number or string becomes "missing" and the roster hides that person.
nonisolated func firestoreBool(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let int = value as? Int { return int != 0 }
    if let int = value as? Int64 { return int != 0 }
    if let double = value as? Double { return double != 0 }
    if let string = value as? String {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
    return nil
}

/// Firestore dates arrive as Timestamps, ISO strings, `yyyy-MM-dd`, epoch numbers, or `{seconds:}` maps.
nonisolated func firestoreDate(_ value: Any?) -> Date? {
    if let timestamp = value as? Timestamp { return timestamp.dateValue() }
    if let date = value as? Date { return date }
    if let map = value as? [String: Any] {
        let seconds = (map["seconds"] as? NSNumber)?.doubleValue
            ?? (map["_seconds"] as? NSNumber)?.doubleValue
            ?? (map["seconds"] as? Double)
            ?? (map["_seconds"] as? Double)
        if let seconds {
            return Date(timeIntervalSince1970: seconds)
        }
    }
    if let number = value as? NSNumber {
        return firestoreDate(fromEpoch: number.doubleValue)
    }
    if let number = value as? Double {
        return firestoreDate(fromEpoch: number)
    }
    if let number = value as? Int {
        return firestoreDate(fromEpoch: Double(number))
    }
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let parsed = ISO8601DateFormatter().date(from: trimmed) { return parsed }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: trimmed) { return parsed }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "dd-MM-yyyy"] {
            day.dateFormat = format
            if let parsed = day.date(from: trimmed) { return parsed }
        }
    }
    return nil
}

private nonisolated func firestoreDate(fromEpoch value: Double) -> Date? {
    guard value > 0 else { return nil }
    let seconds = value > 10_000_000_000 ? value / 1000 : value
    return Date(timeIntervalSince1970: seconds)
}

/// Result of reading one `users/{id}` document from the server while deciding whether they may leave the roster.
enum OrganizationUserProbe {
    case present(AppUser)
    case confirmedMissing
    /// The rules refused this document. That is not proof it still exists.
    case permissionDenied
    case unconfirmed
}

/// Shared by `FirebaseBackend` and its membership extension (separate file).
func normalizedOrganizationId(_ organizationId: String) -> String {
    organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isOfflineNetworkError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed,
             NSURLErrorCallIsActive:
            return true
        default:
            break
        }
    }
    if nsError.domain == "FIRFirestoreErrorDomain" {
        // 4 deadline exceeded, 8 resource exhausted, 13 internal, 14 unavailable
        if [4, 8, 13, 14].contains(nsError.code) { return true }
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        if isOfflineNetworkError(underlying) { return true }
    }
    let message = nsError.localizedDescription.lowercased()
    if message.contains("offline") { return true }
    if message.contains("network") { return true }
    if message.contains("unavailable") { return true }
    if message.contains("local cache") { return true }
    if message.contains("failed to get document from server") { return true }
    if message.contains("failed to get documents from server") { return true }
    if message.contains("the internet connection appears to be offline") { return true }
    return false
}

// MARK: - Firebase Backend Manager

@MainActor
class FirebaseBackend: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: FirebaseAuth.User?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentOrganization: Organization? {
        didSet {
            OrganizationDocumentAbbreviation.update(from: currentOrganization)
            OrganizationRulebookContext.update(from: currentOrganization)
            // Users parsed before the organisation's leave defaults were known (`annualLeaveDefaultsPending` from
            // `CanonicalBusinessEngine.parseUserDocument`) are read again once they arrive or change.
            if let next = currentOrganization {
                let sameOrganization = oldValue != nil
                    && organizationIdsMatch(oldValue?.firestoreDocumentId, next.firestoreDocumentId)
                let defaultsChanged = sameOrganization
                    && oldValue?.settings.annualLeaveDefaults != next.settings.annualLeaveDefaults
                if !sameOrganization || defaultsChanged {
                    NotificationCenter.default.post(
                        name: .organizationAnnualLeaveDefaultsDidChange,
                        object: nil,
                        userInfo: ["changed": defaultsChanged]
                    )
                }
            }
        }
    }
    @Published var userRole: UserRole = .basic
    /// Set after the root shell has kicked off the first org-wide store load (prevents duplicate parallel reloads on launch).
    @Published var hasBootstrappedOrgDataLoad = false
    /// True while `PlannerStoreWiring.bootstrapOrgDataIfNeeded` is in flight (including waiting for org).
    /// Prevents a second caller from starting another full bootstrap after the wait loop yields.
    var isBootstrappingOrgDataLoad = false
    /// While `Date() < launchQuietUntil`, skip heavy post-launch work (warnings, reminder storms).
    /// Set when home-critical bootstrap finishes so Holidays publishing cannot immediately freeze Home.
    var launchQuietUntil: Date?
    /// True while the user is moving from one organisation to another. Root shows the login splash.
    @Published var isSwitchingOrganization = false
    /// Bumped when Settings or the deactivated gate asks to switch. Root performs the switch.
    @Published var organizationSwitchToken: UUID?
    var organizationSwitchTargetId: String?
    @Published var organizationSwitchErrorMessage: String?
    /// While set, store loads must not restore the previous organisation from memory or disk.
    var suppressStaleOrganizationCache = false
    
    /// Lazy so `FirebaseBackend` can be constructed before `application(_:didFinishLaunchingWithOptions:)` calls `FirebaseApp.configure()`.
    /// `internal` so `FirebaseBackend+OrganizationMembership` (separate file) can use the same clients.
    lazy var auth: Auth = Auth.auth()
    lazy var db: Firestore = Firestore.firestore()
    #if canImport(FirebaseStorage)
    lazy var storage: Storage = Storage.storage()
    #endif
    private var authHandle: AuthStateDidChangeListenerHandle?
    /// Single-flight attach: `await` yields MainActor, so a second caller must wait instead of starting a parallel `perform` (duplicate listeners / races).
    private var authAttachInProgress = false
    
    // Local storage keys. The company this phone reopens is `cached_organizationId`
    // (`IOS_SESSION_ORGANIZATION_STORAGE_KEY`). The owner uid is only so a different
    // account can clear that one slot; it is not a second organisation id.
    private let organizationIdKey = "cached_organizationId"
    private let organizationNameKey = "cached_organizationName"
    private let organizationOwnerUserIdKey = "cached_organizationOwnerUserId"
    /// Company `chooseSessionOrganization` has opened for this process. Booking snapshots for this id are applied.
    var sessionOrganizationId: String = ""
    /// False when the script's `persistOrganizationId` is null, so a user-document company is not written into `cached_organizationId`.
    var persistRememberedOrganizationId = true
    /// Last switcher rows. A finished members query still keeps these, plus the remembered company and the user-document company.
    var listedOrganizationMemberships: [OrgMembershipSummary] = []

    struct OperativeProfileMetadata {
        let userId: String
        let assignedManagerUserId: String?
        let dayRate: Double?
        /// `day` / `hourly` from `parseOperativeProfileDocument` (an hourly mirror stays hourly).
        var payBasis: String? = nil
        var hourlyRate: Double? = nil
        var assignedManagerUserIds: [String] = []
    }
    
    /// Breaks recover → loadUserOrganization → org read fails → recover again loops (see firestore org self-read rules).
    private var suppressOrganizationReadPermissionRecovery = false
    /// Prevents parallel org load/recovery storms from multiple stores/views.
    private var organizationLoadInProgress = false
    /// Recover is kicked from org load, stores, and the root shell. Never allow those to stack a full scan.
    var isRecoveringOrganizationLink = false
    /// De-duplicates `organizationDidLoad` broadcasts for the same org within a short window.
    private var lastOrganizationDidLoadBroadcastOrgId: String?
    private var lastOrganizationDidLoadBroadcastAt: Date?
    private var organizationDocumentListener: ListenerRegistration?
    private var organizationDocumentListenerTarget: String?
    private var bookingsLiveListener: ListenerRegistration?
    private var bookingsLiveListenerTarget: String?
    /// Counts from the last booking read: how many documents the shared parser kept or refused.
    @Published private(set) var lastBookingDecodeReport: BookingDecodeReport?
    private var managerScheduleLiveListener: ListenerRegistration?
    private var managerScheduleLiveListenerTarget: String?
    /// Every other organisation-scoped live listener (`OrgLiveListeners.swift`). Emptied with the schedule
    /// listeners on an organisation switch and on sign-out.
    let liveListeners = OrgListenerRegistry()
    /// Lower bound of the launch booking and manager-site listeners. Nil with `scheduleHistoryIsFull` means every date.
    var scheduleHistoryStart: Date?
    private var scheduleHistoryIsFull = false
    /// Inbox ids already accepted for an only-if-missing write. A token refresh must not write the same row twice.
    private var acceptedMissingNotificationIds = Set<String>()
    /// Push tokens a send has already reported as dead. The full token is never logged.
    private var failedPushTokens = Set<String>()
    /// The FCM token this device last wrote to the signed-in account, so sign-out can remove it (RULEBOOK §13).
    private var registeredPushToken: String?
    /// `userEmails` documents confirmed missing. A second launch lookup does not retry them.
    private var userEmailClaimMisses = Set<String>()
    /// True when `organizations/{orgId}.settings.myScheduleOptions` exists in Firestore.
    /// Writable from membership helpers in `FirebaseBackend+OrganizationMembership`.
    var organizationHasFirestoreMyScheduleOptions = false

    /// Ensures org id is non-empty and org document is readable before subcollection reads.
    func ensureReadableOrganization(_ organizationId: String) async throws -> String {
        let trimmedOrgId = normalizedOrganizationId(organizationId)
        guard !trimmedOrgId.isEmpty else {
            print("🔥🔥🔥 DEBUG: ❌ Refusing Firebase read with empty organizationId")
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is empty. Please Force Reload in Settings."]
            )
        }
        do {
            _ = try await getDocumentWithServerTimeoutAndCacheFallback(
                db.collection("organizations").document(trimmedOrgId)
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                // Some deployments deny org root read while allowing subcollection access.
                // Do not block projects/smallWorks/clients/operatives reads in that case.
                print("🔥🔥🔥 DEBUG: ⚠️ Org root read denied for \(trimmedOrgId), continuing with subcollection reads")
                return trimmedOrgId
            }
            if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: ⚠️ Org root offline/cache miss for \(trimmedOrgId), continuing with subcollection reads")
                return trimmedOrgId
            }
            throw error
        }
        return trimmedOrgId
    }

    private func isFirestorePermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7
    }

    @MainActor
    func broadcastOrganizationDidLoadIfNeeded(force: Bool = false) {
        guard let orgId = currentOrganization?.firestoreDocumentId else { return }
        let now = Date()
        if !force,
           lastOrganizationDidLoadBroadcastOrgId == orgId,
           let lastAt = lastOrganizationDidLoadBroadcastAt,
           now.timeIntervalSince(lastAt) < 1.5 {
            return
        }
        lastOrganizationDidLoadBroadcastOrgId = orgId
        lastOrganizationDidLoadBroadcastAt = now
        startOrganizationDocumentListener(organizationId: orgId)
        NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
    }

    /// Starts an organisation switch on the root shell so the login splash can cover the app
    /// and the work is not cancelled when Settings is removed from the screen.
    func queueOrganizationSwitch(to organizationId: String) {
        let trimmed = normalizedOrganizationId(organizationId)
        guard !trimmed.isEmpty else { return }
        guard !isSwitchingOrganization else { return }
        organizationSwitchErrorMessage = nil
        organizationSwitchTargetId = trimmed
        isSwitchingOrganization = true
        organizationSwitchToken = UUID()
    }

    private func stopOrganizationDocumentListener() {
        organizationDocumentListener?.remove()
        organizationDocumentListener = nil
        organizationDocumentListenerTarget = nil
        stopScheduleLiveListeners()
    }

    func stopScheduleLiveListeners() {
        bookingsLiveListener?.remove()
        bookingsLiveListener = nil
        bookingsLiveListenerTarget = nil
        managerScheduleLiveListener?.remove()
        managerScheduleLiveListener = nil
        managerScheduleLiveListenerTarget = nil
        liveListeners.removeAll()
    }

    private func startOrganizationDocumentListener(organizationId: String) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        let target = "org:\(orgId)"
        guard LaunchStartupPolicy.shouldAttachListener(
            activeTarget: organizationDocumentListenerTarget,
            requestedTarget: target
        ) else { return }
        stopOrganizationDocumentListener()
        organizationDocumentListenerTarget = target
        organizationDocumentListener = db.collection("organizations").document(orgId)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("🔥🔥🔥 DEBUG: organization listener error: \(error.localizedDescription)")
                    return
                }
                guard let self, let snapshot, snapshot.exists, let data = snapshot.data() else { return }
                Task { @MainActor in
                    // A snapshot for a company the user has since left is ignored.
                    guard organizationIdsMatch(self.currentOrganization?.firestoreDocumentId, orgId) else { return }
                    self.applyOrganizationDocumentSettings(from: data, organizationId: orgId)
                    self.applyOrganizationDocumentBilling(from: data, organizationId: orgId)
                }
            }
    }

    /// Every snapshot of `organizations/{orgId}` re-parses ALL settings (working hours incl. prior and
    /// scheduled, warning detection, invoicing, currency, bank holiday region, company details, annual
    /// leave defaults, schedule options, material cut-off) with the same reader as the first load, so a
    /// web save shows on iOS without a reload. The server always wins over the in-memory copy.
    @MainActor
    private func applyOrganizationDocumentSettings(from data: [String: Any], organizationId: String) {
        guard var org = currentOrganization,
              organizationIdsMatch(org.firestoreDocumentId, organizationId) else { return }
        let parsed = buildOrganizationFromDocument(orgId: org.firestoreDocumentId, data: data)
        let previous = org
        org.name = parsed.name
        org.settings = parsed.settings
        org.officeAddressLine1 = parsed.officeAddressLine1
        org.officeAddressLine2 = parsed.officeAddressLine2
        org.officeCity = parsed.officeCity
        org.officeCounty = parsed.officeCounty
        org.officePostcode = parsed.officePostcode
        org.countryCode = parsed.countryCode
        org.defaultLatitude = parsed.defaultLatitude
        org.defaultLongitude = parsed.defaultLongitude
        org.companyLogoURL = parsed.companyLogoURL
        org.documentAbbreviation = parsed.documentAbbreviation
        if let creator = parsed.creatorUserId, !creator.isEmpty {
            org.creatorUserId = creator
        }
        org.payrollTimePolicyPrior = parsed.payrollTimePolicyPrior
        org.payrollTimePolicyEffectiveFrom = parsed.payrollTimePolicyEffectiveFrom
        org.payrollTimePolicyScheduled = parsed.payrollTimePolicyScheduled
        guard org != previous else { return }
        currentOrganization = org
        storeOrganizationLocally(org)
        if previous.settings.myScheduleOptions != org.settings.myScheduleOptions {
            NotificationCenter.default.post(name: .organizationMyScheduleOptionsDidChange, object: nil)
        }
        if previous.settings.materialCutOff != org.settings.materialCutOff {
            NotificationCenter.default.post(name: .organizationMaterialCutOffDidChange, object: nil)
        }
    }

    /// Re-reads nested `billing` when the organisation document changes. Does not write billing back.
    @MainActor
    func applyOrganizationDocumentBilling(from data: [String: Any], organizationId: String) {
        guard var org = currentOrganization else { return }
        guard organizationIdsMatch(org.firestoreDocumentId, organizationId) else { return }
        let next = OrganizationBillingMap.storedJSON(from: data)
        guard org.billingJSON != next || !org.billingResolved else { return }
        org.billingJSON = next
        org.billingResolved = true
        currentOrganization = org
        cacheBillingJSON(org)
    }

    @MainActor
    private func setCurrentOrganizationFromRecovery(orgId: String, orgData: [String: Any], fallbackRole: String = "member") async {
        if OrganizationTrialPolicy.isAccessBlocked(orgData) {
            errorMessage = OrganizationTrialPolicy.blockedMessage(from: orgData)
            currentOrganization = nil
            return
        }
        let orgSettings = Self.organizationSettingsFromOrgDocument(orgData)
        organizationHasFirestoreMyScheduleOptions = Self.organizationHasMyScheduleOptionsInDocument(orgData)
        let organization = organizationKeepingKnownName(Organization.make(
            fromFirestoreId: orgId,
            data: orgData,
            settings: orgSettings,
            fallbackName: "Recovered Organization"
        ))
        let remembered = cachedOrganizationIdString()
        var probes = [orgId: "allowed"]
        if let remembered, !remembered.isEmpty, !organizationIdsMatch(remembered, orgId),
           let userId = currentUser?.uid {
            probes[remembered] = await probeSessionOrganizationAccess(userId: userId, organizationId: remembered)
        }
        guard let choice = CanonicalBusinessEngine.chooseSessionOrganization(
            explicitOrganizationId: nil,
            rememberedOrganizationId: remembered,
            documentOrganizationId: orgId,
            probes: probes
        ), !choice.organizationId.isEmpty else {
            return
        }
        if !organizationIdsMatch(choice.organizationId, orgId) {
            publishSessionOrganizationIfNeeded(choice.organizationId)
            return
        }
        persistRememberedOrganizationId = !(choice.persistOrganizationId ?? "").isEmpty
        sessionOrganizationId = normalizedOrganizationId(orgId)
        currentOrganization = organization
        userRole = UserRole(rawValue: fallbackRole) ?? .basic
        errorMessage = nil
        storeOrganizationLocally(organization)
        print("🔥🔥🔥 DEBUG: ✅ Recovery set currentOrganization directly: \(organization.name) (\(orgId))")
    }
    
    init() {
        print("🔥🔥🔥 DEBUG: FirebaseBackend init — deferring Auth/Firestore until default app exists")
        Task { @MainActor [self] in
            await self.attachAuthStateListenerWhenReady()
        }
    }

    /// Call immediately before any `Auth`/`Firestore` use if launch-time configure was skipped (e.g. bad plist path).
    private func ensureFirebaseAppConfigured() {
        PlannerAppCheckProviderFactory.installIfNeeded()
        guard FirebaseApp.app() == nil else { return }
        let names = ["GoogleService-Info", "GoogleService-Info 2"]
        for name in names {
            if let path = Bundle.main.path(forResource: name, ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: path) {
                FirebaseApp.configure(options: options)
                print("🔥🔥🔥 DEBUG: ensureFirebaseAppConfigured — using \(name).plist")
                print("🔥🔥🔥 DEBUG: ensureFirebaseAppConfigured — default app exists: \(FirebaseApp.app() != nil)")
                return
            }
        }
        FirebaseApp.configure()
        print("🔥🔥🔥 DEBUG: ensureFirebaseAppConfigured — default app exists: \(FirebaseApp.app() != nil)")
    }

    /// Binds Auth after `FirebaseApp.configure()` (SwiftUI may create this object before `application(_:didFinishLaunchingWithOptions:)` returns).
    private func attachAuthStateListenerWhenReady() async {
        if authHandle != nil { return }
        if authAttachInProgress {
            while authAttachInProgress {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            if authHandle != nil { return }
            // Fall through: first attempt failed to attach — try once more (no recursion).
        }
        authAttachInProgress = true
        defer { authAttachInProgress = false }
        await performAuthStateListenerAttach()
    }

    private func performAuthStateListenerAttach() async {
        guard authHandle == nil else { return }
        ensureFirebaseAppConfigured()
        var attempts = 0
        while FirebaseApp.app() == nil && attempts < 320 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            attempts += 1
        }
        guard FirebaseApp.app() != nil else {
            print("🔥🔥🔥 DEBUG: ❌ Firebase default app still nil after wait — check GoogleService-Info.plist is in the built app (target membership).")
            return
        }

        #if DEBUG
        let keepUITestSession = UITestingMode.isEnabled && UITestingMode.autoLoginRole != nil
        #else
        let keepUITestSession = false
        #endif
        if !keepUITestSession {
            let sessionUser = auth.currentUser
            currentUser = sessionUser
            isAuthenticated = sessionUser != nil
        }

        authHandle = auth.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                if UITestingMode.isEnabled, UITestingMode.autoLoginRole != nil { return }
                #endif
                self.currentUser = user
                self.isAuthenticated = user != nil
                if let user = user {
                    print("🔥🔥🔥 Firebase user signed in: \(user.email ?? "N/A")")

                    if self.currentOrganization == nil {
                        Task { [weak self] in
                            await self?.loadUserOrganizationWithRecovery(userId: user.uid)
                        }
                    }
                    // Do not broadcast organizationDidLoad here when org is already set.
                    // Sign-in + org-load + bootstrap were each kicking full store loads (Simulator jetsam).

                    NotificationCenter.default.post(name: .userDidSignIn, object: user.email)
                } else {
                    print("Firebase user signed out.")
                    self.stopOrganizationDocumentListener()
                    self.organizationHasFirestoreMyScheduleOptions = false
                    self.currentOrganization = nil
                    self.sessionOrganizationId = ""
                    self.userRole = .basic
                    self.hasBootstrappedOrgDataLoad = false
                    self.isBootstrappingOrgDataLoad = false
                    self.launchQuietUntil = nil
                    // Same-user sign-out keeps cached_organizationId. A different uid clears it on the next sign-in.
                    if CanonicalBusinessEngine.rememberedOrganizationSurvivesSignOut() == false {
                        self.clearLocalOrganizationCache()
                    }
                    NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                }
            }
        }
    }

    /// Call before sign-in / sign-up if the launch-time listener attach failed or hasn’t run yet.
    private func ensureAuthStateListenerAttached() async {
        if authHandle != nil { return }
        await attachAuthStateListenerWhenReady()
    }

    /// Signed-in launch must already have a profile before the first frame.
    /// Putting Home in after the window appears leaves a blank white screen.
    func installLaunchSession(into userStore: UserStore) {
        syncPublishedAuthFromAuthSession()
        prepareRememberedOrganizationOwner(for: currentUser?.uid)
        let remembered = cachedOrganizationIdString()
        let provisional = CanonicalBusinessEngine.provisionalOrganizationId(
            explicitOrganizationId: nil,
            rememberedOrganizationId: remembered,
            documentOrganizationId: nil
        ) ?? ""
        if !provisional.isEmpty {
            sessionOrganizationId = provisional
        }
        if currentOrganization == nil {
            publishSessionOrganizationIfNeeded(provisional)
        }
        userStore.setFirebaseBackend(self)
        userStore.unblockLaunchProfileIfNeeded()
        print("🔥🔥🔥 DEBUG: Launch session before first frame auth=\(isAuthenticated) user=\(userStore.currentUser != nil)")
    }

    /// Pushes `Auth.auth().currentUser` into `@Published` immediately (no listener required). Use so UI gates don’t spin forever while attach runs.
    func syncPublishedAuthFromAuthSession() {
        ensureFirebaseAppConfigured()
        guard FirebaseApp.app() != nil else { return }
        #if DEBUG
        if UITestingMode.isEnabled, UITestingMode.autoLoginRole != nil { return }
        #endif
        let user = auth.currentUser
        currentUser = user
        isAuthenticated = user != nil
    }

    /// After launch, re-attach the auth listener if needed and align `isAuthenticated` with Firebase’s session (e.g. persisted login).
    func syncAuthStateFromSessionIfNeeded() async {
        ensureFirebaseAppConfigured()
        syncPublishedAuthFromAuthSession()
        await ensureAuthStateListenerAttached()
        guard FirebaseApp.app() != nil else { return }
        #if DEBUG
        if UITestingMode.isEnabled, UITestingMode.autoLoginRole != nil { return }
        #endif
        let user = auth.currentUser
        currentUser = user
        isAuthenticated = user != nil
    }

    deinit {
        if let handle = authHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
    
    // MARK: - Authentication Methods
    
    func signUp(email: String, password: String, organizationName: String) async throws {
        print("🔥🔥🔥 DEBUG: FirebaseBackend.signUp() called with email: \(email), organization: \(organizationName)")
        ensureFirebaseAppConfigured()
        isLoading = true
        errorMessage = nil
        guard FirebaseApp.app() != nil else {
            isLoading = false
            let msg = "Firebase did not start (missing or invalid GoogleService-Info.plist in the app). Add the plist from Firebase Console to the app target, then clean build."
            errorMessage = msg
            throw NSError(domain: "FirebaseBackend", code: 500, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        // RULEBOOK §14: `passwordPolicyError` (8 characters; the platform owner's developer account 10).
        switch CanonicalBusinessEngine.passwordPolicyError(password, email: email) {
        case .accepted:
            break
        case .rejected(let message):
            isLoading = false
            errorMessage = message
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        case .unavailable:
            isLoading = false
            let message = "Could not check the password. Please try again."
            errorMessage = message
            throw NSError(domain: "FirebaseBackend", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
        }

        do {
            // Create user account
            print("🔥🔥🔥 DEBUG: Creating Firebase user with email: \(email)")
            let result = try await auth.createUser(withEmail: email, password: password)
            print("🔥🔥🔥 DEBUG: Firebase user created successfully: \(result.user.uid)")
            
            // Create organization first; store creator so only they can ever be super admin
            let organizationId = UUID().uuidString
            guard let nameFields = CanonicalBusinessEngine.organizationNameToFirestore(organizationName),
                  let writtenName = nameFields["name"] as? String,
                  !writtenName.isEmpty else {
                throw NSError(
                    domain: "FirebaseBackend",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Organisation name is required"]
                )
            }
            var organizationData: [String: Any] = nameFields
            organizationData["members"] = [result.user.uid: "admin"]
            organizationData["creatorUserId"] = result.user.uid
            organizationData["countryCode"] = "GB"
            organizationData["settings"] = [:]
            organizationData["createdAt"] = Timestamp(date: Date())
            organizationData["updatedAt"] = Timestamp(date: Date())
            
            print("🔥🔥🔥 DEBUG: Creating organization with ID: \(organizationId)")
            try await db.collection("organizations").document(organizationId).setData(organizationData)
            
            // Create initial subcollections structure for the organization
            print("🔥🔥🔥 DEBUG: Creating initial subcollections structure")
            
            // No longer creating placeholder documents - subcollections will be created automatically when first document is added
            print("🔥🔥🔥 DEBUG: Organization structure ready - subcollections will be created when first documents are added")
            
            // Create user document with organization reference
            let userData: [String: Any] = [
                "email": email,
                "displayName": email,
                "organizationId": organizationId,
                "role": "admin",
                "firstName": "",
                "surname": "",
                "isActive": true,
                "passwordSet": true, // User signed up with password, so password is set
                "adminAccess": true, // Super admin gets full permissions
                "operatives": true,
                "skills": false,
                "qualifications": true,
                "isSuperAdmin": true, // Organization creator is super admin
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
            
            print("🔥🔥🔥 DEBUG: Creating user document for: \(result.user.uid)")
            #if DEBUG
            print("🔥🔥🔥 DEBUG: User document keys: \(userData.keys.sorted().joined(separator: ", "))")
            #endif
            try await db.collection("users").document(result.user.uid).setData(userData)
            
            // Verify user document was created
            let verifyUserDoc = try await db.collection("users").document(result.user.uid).getDocument()
            if verifyUserDoc.exists {
                print("🔥🔥🔥 DEBUG: ✅ User document created and verified successfully")
                if let verifyData = verifyUserDoc.data() {
                    print("🔥🔥🔥 DEBUG: Verified user document has organizationId: \(verifyData["organizationId"] as? String ?? "MISSING")")
                }
            } else {
                print("🔥🔥🔥 DEBUG: ❌ CRITICAL: User document creation failed - document does not exist after creation!")
                throw NSError(domain: "FirebaseBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create user document"])
            }
            
            // Create organization object (creator = this user)
            let organization = Organization(
                id: Manager.stableId(forFirestoreDocumentId: organizationId),
                firestoreDocumentId: organizationId,
                name: organizationName,
                settings: OrganizationSettings(),
                countryCode: "GB",
                creatorUserId: result.user.uid
            )
            
            // Store organization locally immediately. The company just created is an explicit choice.
            if let choice = CanonicalBusinessEngine.chooseSessionOrganization(
                explicitOrganizationId: organizationId,
                rememberedOrganizationId: nil,
                documentOrganizationId: organizationId,
                probes: [organizationId: "allowed"]
            ), !choice.organizationId.isEmpty {
                sessionOrganizationId = choice.organizationId
                persistRememberedOrganizationId = !(choice.persistOrganizationId ?? "").isEmpty
            } else {
                sessionOrganizationId = organizationId
                persistRememberedOrganizationId = true
            }
            storeOrganizationLocally(organization)
            
            // Set organization immediately on main thread
            await MainActor.run {
                self.currentOrganization = organization
                self.userRole = .admin
                self.errorMessage = nil // Clear any errors
                print("🔥🔥🔥 DEBUG: Sign-up completed for new organization")
                print("🔥🔥🔥 DEBUG: Organization set in memory: \(organization.name) (ID: \(organizationId))")
                
                // Post notification that organization was loaded
                NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
            }
            
            // Verify organization is still set after a brief delay (to catch any auth state listener issues)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await MainActor.run {
                if self.currentOrganization == nil {
                    print("🔥🔥🔥 DEBUG: ⚠️ Organization was cleared after signup - restoring it")
                    self.currentOrganization = organization
                    NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
                }
            }
            
            print("🔥🔥🔥 DEBUG: User sign-up completed successfully")
            currentUser = auth.currentUser
            isAuthenticated = currentUser != nil
            isLoading = false
            Task { await self.ensureAuthStateListenerAttached() }
            
        } catch {
            print("🔥🔥🔥 DEBUG: Error during sign-up: \(error.localizedDescription)")
            isLoading = false
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    /// User-friendly message when session/credential is expired; sign out so they can log in again with current password.
    private static let sessionExpiredMessage = "Your session has expired. Please sign in again with your current email and password."
    
    /// True only for **stale auth session / refresh token** issues — not wrong password at sign-in.
    /// `invalidCredential` (17004) and strings like "credential … expired" are often wrong password or bad email/password;
    /// treating those as "session expired" misleads users (e.g. hotmail sign-in showing session message).
    private func isSessionExpiredOrInvalidCredential(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "FIRAuthErrorDomain" else { return false }
        switch ns.code {
        case 17017: return true // invalidUserToken
        case 17021: return true // userTokenExpired (e.g. password changed elsewhere, refresh invalid)
        case 17014: return true // requiresRecentLogin (sensitive op needs fresh sign-in)
        default: return false
        }
    }
    
    func signIn(email: String, password: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            errorMessage = "Please enter your email address."
            throw NSError(domain: "AuthError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Please enter your email address."])
        }

        ensureFirebaseAppConfigured()
        isLoading = true
        errorMessage = nil
        // Never block sign-in on listener attach (can stall the MainActor); attach after session exists.
        guard FirebaseApp.app() != nil else {
            isLoading = false
            let msg = "Firebase did not start (missing or invalid GoogleService-Info.plist in the app). Add the plist from Firebase Console to the app target, then clean build."
            errorMessage = msg
            throw NSError(domain: "FirebaseBackend", code: 500, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        do {
            _ = try await auth.signIn(withEmail: trimmedEmail, password: password)
            try? await auth.currentUser?.reload()
            currentUser = auth.currentUser
            isAuthenticated = currentUser != nil
            if !isAuthenticated {
                let msg = "Sign-in returned without an active user. Try again, or check Keychain access in Settings if using a device profile."
                errorMessage = msg
                isLoading = false
                throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            isLoading = false
            Task { await self.ensureAuthStateListenerAttached() }
        } catch {
            isLoading = false
            let nsError = error as NSError
            errorMessage = SignInAuthError.presentedMessage(
                domain: nsError.domain,
                code: nsError.code,
                localizedDescription: error.localizedDescription
            )
            throw error
        }
    }
    
    func signOut() throws {
        try auth.signOut()
    }

    /// RULEBOOK §13: a forced sign-out (expired session, blocked trial) removes this device's push token from every
    /// `users` document it was written to before Firebase Auth signs out, exactly as `AppSignOut` does. The wait is
    /// bounded (`removeThisDevicePushTokenBeforeSignOut`); sign-out goes ahead either way.
    func forcedSignOutRemovingPushToken() async {
        await removeThisDevicePushTokenBeforeSignOut()
        try? auth.signOut()
    }
    
    /// Sends a new verification code (invitation token) so the user can set or reset their password on the Project Planner page.
    /// Creates a fresh invitation document and emails the user with "Verification code" wording.
    /// Sends Firebase Auth’s password-reset email (login screen). Works without Resend or Apple Mail.
    func sendPasswordResetEmailFromLogin(email: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "AuthError",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Please enter your email address."]
            )
        }
        try await auth.sendPasswordReset(withEmail: trimmed)
    }

    func resetPassword(email: String) async throws {
        // Find the user in the open company so we can create a new invitation (verification code) for them.
        // An email-only users query is refused. With no company, do not scan every user.
        let orgId = normalizedOrganizationId(
            currentOrganization?.firestoreDocumentId ?? cachedOrganizationIdString() ?? ""
        )
        guard !orgId.isEmpty else {
            print("🔥🔥🔥 DEBUG: resetPassword has no organisation — not listing users by email")
            try await auth.sendPasswordReset(withEmail: email)
            return
        }
        var usersSnapshot = try await db.collection("users")
            .whereField("email", isEqualTo: email)
            .whereField("organizationId", isEqualTo: orgId)
            .limit(to: 1)
            .getDocuments(source: .server)
        if usersSnapshot.documents.isEmpty, email != email.lowercased() {
            usersSnapshot = try await db.collection("users")
                .whereField("email", isEqualTo: email.lowercased())
                .whereField("organizationId", isEqualTo: orgId)
                .limit(to: 1)
                .getDocuments(source: .server)
        }
        guard let userDoc = usersSnapshot.documents.first else {
            // User not in our system – fall back to Firebase Auth password reset
            try await auth.sendPasswordReset(withEmail: email)
            return
        }
        let data = userDoc.data()
        guard let organizationId = data["organizationId"] as? String,
              let firstName = data["firstName"] as? String,
              let surname = data["surname"] as? String else {
            try await auth.sendPasswordReset(withEmail: email)
            return
        }
        let permissionsMap = data["permissions"] as? [String: Any] ?? [:]
        func permissionFlag(_ key: String, default defaultValue: Bool) -> Bool {
            firestoreBool(permissionsMap[key]) ?? firestoreBool(data[key]) ?? defaultValue
        }
        let permissions = UserPermissions(
            adminAccess: permissionFlag("adminAccess", default: false),
            manager: permissionFlag("manager", default: false),
            operatives: permissionFlag("operatives", default: false),
            skills: permissionFlag("skills", default: false),
            qualifications: permissionFlag("qualifications", default: false),
            materials: permissionFlag("materials", default: false),
            projects: permissionFlag("projects", default: true),
            smallWorks: permissionFlag("smallWorks", default: true),
            operativeMode: permissionFlag("operativeMode", default: false),
            annualLeaveSelfBook: permissionFlag("annualLeaveSelfBook", default: false),
            weeklyReports: permissionFlag("weeklyReports", default: false),
            dailyOverview: permissionFlag("dailyOverview", default: true),
            subContractors: permissionFlag("subContractors", default: false),
            siteAudit: permissionFlag("siteAudit", default: true),
            wholesalersOrderHistory: permissionFlag("wholesalersOrderHistory", default: true)
        )
        let invitedBy = currentUser?.uid ?? ""
        let invitationId = UUID().uuidString
        var invitationData: [String: Any] = [
            "email": email,
            "organizationId": organizationId,
            "invitedBy": invitedBy,
            "firstName": firstName,
            "surname": surname,
            "permissions": [
                "adminAccess": permissions.adminAccess,
                "manager": permissions.manager,
                "operatives": permissions.operatives,
                "skills": false,
                "qualifications": permissions.qualifications,
                "materials": permissions.materials,
                "projects": permissions.projects,
                "smallWorks": permissions.smallWorks,
                "operativeMode": permissions.operativeMode,
                "annualLeaveSelfBook": permissions.annualLeaveSelfBook,
                "weeklyReports": permissions.weeklyReports,
                "dailyOverview": permissions.dailyOverview,
                "subContractors": permissions.subContractors,
                "siteAudit": permissions.siteAudit,
                "wholesalersOrderHistory": permissions.wholesalersOrderHistory
            ],
            "createdAt": Timestamp(date: Date()),
            "isUsed": false
        ]
        if let mobileNumber = data["mobileNumber"] as? String, !mobileNumber.isEmpty {
            invitationData["mobileNumber"] = mobileNumber
        }
        try await db.collection("invitations").document(invitationId).setData(invitationData)
        let orgName = currentOrganization?.name
        await sendPasswordResetVerificationEmail(email: email, firstName: firstName, surname: surname, verificationCode: invitationId, fromName: orgName)
    }
    
    /// Sends the password reset email with a single link. No code – user clicks the link and sets new password on the website. From name = organisation name when set.
    private func sendPasswordResetVerificationEmail(email: String, firstName: String, surname: String, verificationCode: String, fromName: String? = nil) async {
        let resendService = ResendEmailService()
        _ = await resendService.sendPasswordResetLinkEmail(
            to: email,
            firstName: firstName,
            surname: surname,
            token: verificationCode,
            fromName: fromName
        )
    }
    
    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard let user = currentUser else {
            throw NSError(domain: "AuthError", code: 401, userInfo: [NSLocalizedDescriptionKey: "No user signed in"])
        }
        
        do {
            let credential = EmailAuthProvider.credential(withEmail: user.email!, password: currentPassword)
            try await user.reauthenticate(with: credential)
            try await user.updatePassword(to: newPassword)
        } catch {
            if isSessionExpiredOrInvalidCredential(error) {
                await forcedSignOutRemovingPushToken()
                errorMessage = FirebaseBackend.sessionExpiredMessage
            } else {
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }
    
    // MARK: - User Management
    
    func getCurrentUserData() async throws -> UserData? {
        guard let user = currentUser else { return nil }
        
        let doc = try await db.collection("users").document(user.uid).getDocument()
        guard doc.exists else { return nil }
        
        let data = doc.data()!
        return UserData(
            id: user.uid,
            email: data["email"] as? String ?? "",
            displayName: data["displayName"] as? String ?? "",
            organizationId: data["organizationId"] as? String ?? "",
            role: data["role"] as? String ?? "basic",
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }
    
    func updateUserData(_ userData: UserData) async throws {
        let data: [String: Any] = [
            "email": userData.email,
            "displayName": userData.displayName,
            "organizationId": userData.organizationId,
            "role": userData.role,
            "updatedAt": Timestamp(date: Date())
        ]
        
        try await db.collection("users").document(userData.id).updateData(data)
    }
    
    // MARK: - Organization Management
    
    // MARK: - Local Storage Helpers
    
    /// Clears cached org id/name so a new sign-in never reuses another account's organization path (avoids permission denied on projects).
    @MainActor
    func clearLocalOrganizationCache() {
        UserDefaults.standard.removeObject(forKey: rememberedOrganizationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: organizationNameKey)
        print("🔥🔥🔥 DEBUG: ✅ Cleared local organization cache (different account)")
    }

    private var rememberedOrganizationDefaultsKey: String {
        CanonicalBusinessEngine.iosSessionOrganizationStorageKey ?? organizationIdKey
    }
    
    /// Store organizationId locally for offline access
    @MainActor
    func storeOrganizationIdLocally(_ organizationId: String) {
        UserDefaults.standard.set(organizationId, forKey: rememberedOrganizationDefaultsKey)
        print("🔥🔥🔥 DEBUG: ✅ Stored organizationId locally: \(organizationId)")
    }
    
    /// Load organizationId from local storage
    @MainActor
    func resolvedOrganizationIdForOfflineWrites() -> String? {
        if let live = currentOrganization?.firestoreDocumentId,
           !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return live
        }
        return loadOrganizationIdLocally()
    }

    /// Load organizationId from local storage
    @MainActor
    private func loadOrganizationIdLocally() -> String? {
        return UserDefaults.standard.string(forKey: rememberedOrganizationDefaultsKey)
    }
    
    /// Last organisation stored on this phone. Launch can open with this if Firestore is slow.
    func cachedOrganizationDocumentId() -> String? {
        loadOrganizationFromLocalStorage()?.firestoreDocumentId
    }

    /// Organisation id saved on this phone, even when the cached name is missing.
    func cachedOrganizationIdString() -> String? {
        let raw = loadOrganizationIdLocally()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Cached display name for this id only. Another company's cached name is not reused.
    func cachedOrganizationName(matching organizationId: String) -> String? {
        guard organizationIdsMatch(cachedOrganizationIdString(), organizationId) else { return nil }
        let name = UserDefaults.standard.string(forKey: organizationNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Empty string is missing. A saved name on this company stays when the next read is blank.
    func organizationKeepingKnownName(_ organization: Organization) -> Organization {
        var copy = organization
        let kept = organizationIdsMatch(currentOrganization?.firestoreDocumentId, copy.firestoreDocumentId)
            ? currentOrganization?.name
            : nil
        if let name = CanonicalBusinessEngine.coalesceOrganizationName([
            copy.name,
            kept,
            cachedOrganizationName(matching: copy.firestoreDocumentId)
        ]) {
            copy.name = name
        }
        return copy
    }

    /// Company-details field. Empty stays empty so the fallback label is not saved as the name.
    func organizationNameForEditing(_ organization: Organization) -> String {
        let parsed = CanonicalBusinessEngine.parseOrganizationName(["name": organization.name]) ?? ""
        return CanonicalBusinessEngine.coalesceOrganizationName([
            parsed,
            organization.name,
            cachedOrganizationName(matching: organization.firestoreDocumentId)
        ]) ?? parsed
    }

    /// Clears `cached_organizationId` only when a different account is about to use this device.
    @MainActor
    func prepareRememberedOrganizationOwner(for userId: String?) {
        let next = userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !next.isEmpty else { return }
        let previous = UserDefaults.standard.string(forKey: organizationOwnerUserIdKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clear = CanonicalBusinessEngine.shouldClearRememberedOrganization(
            signedOutUserId: previous.isEmpty ? nil : previous,
            nextUserId: next
        ) == true
        if clear {
            clearLocalOrganizationCache()
            currentOrganization = nil
            sessionOrganizationId = ""
        }
        if previous != next {
            UserDefaults.standard.set(next, forKey: organizationOwnerUserIdKey)
        }
    }

    /// Opens the session company in memory without writing `cached_organizationId`.
    @MainActor
    func publishSessionOrganizationIfNeeded(_ organizationId: String) {
        let trimmed = normalizedOrganizationId(organizationId)
        guard !trimmed.isEmpty else { return }
        sessionOrganizationId = trimmed
        if organizationIdsMatch(currentOrganization?.firestoreDocumentId, trimmed) { return }
        if let currentId = currentOrganization?.firestoreDocumentId, !currentId.isEmpty {
            stopScheduleLiveListeners()
        }
        if let cached = loadOrganizationFromLocalStorage(),
           organizationIdsMatch(cached.firestoreDocumentId, trimmed) {
            currentOrganization = organizationKeepingKnownName(cached)
            return
        }
        let cachedBilling = cachedBillingJSON(matching: trimmed)
        currentOrganization = Organization(
            id: Manager.stableId(forFirestoreDocumentId: trimmed),
            firestoreDocumentId: trimmed,
            name: cachedOrganizationName(matching: trimmed) ?? "",
            billingJSON: cachedBilling,
            billingResolved: cachedBilling != nil
        )
    }

    /// Company last written on `users/{uid}.organizationId`. Web and iOS can sit in different companies, so this is not the phone's session.
    var sharedUserOrganizationId: String?
    /// Profile this phone is using when that company is not `sharedUserOrganizationId`.
    var deviceSessionProfile: AppUser?

    /// Load organization from local storage (for offline access)
    @MainActor
    private func loadOrganizationFromLocalStorage() -> Organization? {
        guard let organizationId = loadOrganizationIdLocally(),
              let organizationName = UserDefaults.standard.string(forKey: organizationNameKey) else {
            return nil
        }
        
        if let uuid = UUID(uuidString: organizationId) {
            var settings = OrganizationSettings()
            if let regionId = UserDefaults.standard.string(forKey: Self.bankHolidayRegionDefaultsKey(organizationId)),
               !regionId.isEmpty {
                settings.bankHolidayRegionId = regionId
            }
            if let currencyCode = UserDefaults.standard.string(forKey: Self.currencyCodeDefaultsKey(organizationId)),
               !currencyCode.isEmpty {
                settings.currencyCode = currencyCode
            }
            let cachedBilling = cachedBillingJSON(matching: organizationId)
            return Organization(
                id: uuid,
                firestoreDocumentId: organizationId,
                name: organizationName,
                settings: settings,
                billingJSON: cachedBilling,
                billingResolved: cachedBilling != nil
            )
        }
        return nil
    }

    private static func bankHolidayRegionDefaultsKey(_ organizationId: String) -> String {
        "org_bank_holiday_region_\(organizationId)"
    }

    private static func currencyCodeDefaultsKey(_ organizationId: String) -> String {
        "org_currency_code_\(organizationId)"
    }
    
    /// Store organization locally. A null `persistOrganizationId` must not copy `users/{uid}.organizationId` into the cache.
    @MainActor
    func storeOrganizationLocally(_ organization: Organization) {
        guard persistRememberedOrganizationId else {
            print("🔥🔥🔥 DEBUG: Leaving cached_organizationId unchanged")
            return
        }
        let previousId = loadOrganizationIdLocally()
        let previousName = UserDefaults.standard.string(forKey: organizationNameKey)
        let keptName = organizationIdsMatch(previousId, organization.firestoreDocumentId) ? previousName : nil
        let name = CanonicalBusinessEngine.coalesceOrganizationName([organization.name, keptName]) ?? organization.name
        storeOrganizationIdLocally(organization.firestoreDocumentId)
        if let uid = currentUser?.uid, !uid.isEmpty {
            UserDefaults.standard.set(uid, forKey: organizationOwnerUserIdKey)
        }
        if !name.isEmpty {
            UserDefaults.standard.set(name, forKey: organizationNameKey)
        } else if !organizationIdsMatch(previousId, organization.firestoreDocumentId) {
            UserDefaults.standard.removeObject(forKey: organizationNameKey)
        }
        if let regionId = organization.settings.bankHolidayRegionId, !regionId.isEmpty {
            UserDefaults.standard.set(regionId, forKey: Self.bankHolidayRegionDefaultsKey(organization.firestoreDocumentId))
        }
        if let currencyCode = organization.settings.currencyCode, !currencyCode.isEmpty {
            UserDefaults.standard.set(currencyCode, forKey: Self.currencyCodeDefaultsKey(organization.firestoreDocumentId))
        }
        cacheBillingJSON(organization)
        print("🔥🔥🔥 DEBUG: ✅ Stored organization locally: \(organization.name)")
    }

    /// Last nested billing map for this company. This does not write `cached_organizationId`.
    @MainActor
    private func cacheBillingJSON(_ organization: Organization) {
        guard organization.billingResolved else { return }
        let billingKey = Self.billingJSONDefaultsKey(organization.firestoreDocumentId)
        if let billingJSON = organization.billingJSON {
            UserDefaults.standard.set(billingJSON, forKey: billingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: billingKey)
        }
    }

    private static func billingJSONDefaultsKey(_ organizationId: String) -> String {
        "org_billing_json_\(organizationId)"
    }

    private func cachedBillingJSON(matching organizationId: String) -> String? {
        let trimmed = normalizedOrganizationId(organizationId)
        guard !trimmed.isEmpty else { return nil }
        let stored = UserDefaults.standard.string(forKey: Self.billingJSONDefaultsKey(trimmed))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }
    
    /// Builds `OrganizationSettings` from a Firestore `organizations/{id}` document, including `payrollTimePolicy`.
    static func organizationSettingsFromOrgDocument(_ data: [String: Any]) -> OrganizationSettings {
        var settings = OrganizationSettings()
        if let settingsDict = data["settings"] as? [String: Any],
           let uiLabelsDict = settingsDict["uiLabels"] as? [String: Any],
           let navLabels = uiLabelsDict["navigationLabels"] as? [String: Any] {
            let parsed = navLabels.reduce(into: [String: String]()) { out, pair in
                if let value = pair.value as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        out[pair.key] = trimmed
                    }
                }
            }
            if !parsed.isEmpty {
                var merged = OrganizationUILabels.defaultNavigationLabels
                for (k, v) in parsed { merged[k] = v }
                settings.uiLabels = OrganizationUILabels(navigationLabels: merged)
            }
        }
        if let policyDict = data["payrollTimePolicy"] as? [String: Any] {
            let policy = OrgPayrollTimePolicy.fromFirestore(policyDict)
            settings.payrollTimePolicy = policy
            settings.workingHours.startTime = policy.standardDayStart
            settings.workingHours.endTime = policy.standardDayEnd
            settings.workingHours.lunchBreak = policy.unpaidBreakMinutes
        }
        let nestedWarning = (data["settings"] as? [String: Any])?["warningDetection"] as? [String: Any]
        let warningRaw = Self.resolveWarningDetectionRaw(
            topLevel: data["warningDetection"] as? [String: Any],
            nested: nestedWarning
        )
        // Raw value to the script, so `clashLookaheadDaysFallback` keeps the missing/invalid notice (RULEBOOK §5).
        if let detection = OrgWarningDetectionSettings(firestoreRaw: warningRaw) {
            settings.warningDetection = detection
        }
        if let invoicingDict = data["invoicing"] as? [String: Any] {
            settings.invoicing = organizationInvoicingFromFirestore(invoicingDict)
        }
        if let annualLeaveDefaultsDict = data["annualLeaveDefaults"] as? [String: Any] {
            settings.annualLeaveDefaults = organizationAnnualLeaveDefaultsFromFirestore(annualLeaveDefaultsDict)
        }
        if let settingsDict = data["settings"] as? [String: Any],
           let raw = settingsDict["myScheduleOptions"] as? [String: Any] {
            settings.myScheduleOptions = MyScheduleOptions.fromFirestore(raw)
        }
        if let settingsDict = data["settings"] as? [String: Any],
           let raw = settingsDict["materialCutOff"] as? [String: Any],
           let cutOff = OrgMaterialCutOff.fromFirestore(raw) {
            settings.materialCutOff = cutOff
        }
        // Rulebook: `parseCompanyDetails` (top-level `bankHolidayRegionId`, then `settings.bankHolidayRegionId`)
        // and `resolveOrganizationCurrency` (also honours the legacy literal "settings.currencyCode" key
        // and falls back to `defaultCurrencyForCountry`). Both read the raw document.
        let rawDocument = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        if let details = CanonicalBusinessEngine.parseCompanyDetails(orgDocument: rawDocument),
           let regionId = (details["bankHolidayRegionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !regionId.isEmpty {
            settings.bankHolidayRegionId = regionId
        }
        if let currency = CanonicalBusinessEngine.resolveOrganizationCurrency(orgDocument: rawDocument),
           !currency.isEmpty {
            settings.currencyCode = currency
        }
        return settings
    }

    /// Reads current/prior/scheduled payroll policy fields with `payrollTimePolicyTimeline` (a due scheduled
    /// change counts from its day on). Day keys are in this document's zone, `organizationTimeZone(countryCode)`.
    static func applyPayrollPolicyFields(from data: [String: Any], to organization: inout Organization) {
        let rawDocument = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        let zone = CanonicalBusinessEngine.organizationTimeZoneIdentifier(countryCode: data["countryCode"] as? String)
        let todayKey = CanonicalBusinessEngine.organizationDayKey(Date(), timeZoneIdentifier: zone)
        guard let state = CanonicalBusinessEngine.payrollTimePolicyTimeline(
            orgDocument: rawDocument,
            todayKey: todayKey,
            timeZone: zone
        ) else {
            print("🔥🔥🔥 DEBUG: payrollTimePolicyTimeline did not answer — keeping the parsed current policy")
            return
        }
        organization.settings.payrollTimePolicy = state.current
        organization.settings.workingHours.startTime = state.current.standardDayStart
        organization.settings.workingHours.endTime = state.current.standardDayEnd
        organization.settings.workingHours.lunchBreak = state.current.unpaidBreakMinutes
        organization.payrollTimePolicyPrior = state.prior
        organization.payrollTimePolicyEffectiveFrom = state.effectiveFromDayKey.flatMap {
            CanonicalBusinessEngine.organizationDate(fromDayKey: $0, timeZoneIdentifier: zone)
        }
        if let policy = state.scheduledPolicy,
           let key = state.scheduledEffectiveFromDayKey,
           let day = CanonicalBusinessEngine.organizationDate(fromDayKey: key, timeZoneIdentifier: zone) {
            organization.payrollTimePolicyScheduled = OrgPayrollTimePolicyScheduledChange(policy: policy, effectiveFrom: day)
        } else {
            organization.payrollTimePolicyScheduled = nil
        }
    }

    static func organizationHasMyScheduleOptionsInDocument(_ data: [String: Any]) -> Bool {
        guard let settingsDict = data["settings"] as? [String: Any] else { return false }
        return settingsDict["myScheduleOptions"] != nil
    }

    private static func organizationAnnualLeaveDefaultsFromFirestore(_ data: [String: Any]) -> OrganizationAnnualLeaveDefaults {
        let daysPerYear = (data["daysPerYear"] as? NSNumber)?.doubleValue
            ?? (data["daysPerYear"] as? Double)
            ?? OrganizationAnnualLeaveDefaults.default.daysPerYear
        let startMonth = (data["startMonth"] as? NSNumber)?.intValue
            ?? (data["startMonth"] as? Int)
            ?? OrganizationAnnualLeaveDefaults.default.startMonth
        let endMonth = (data["endMonth"] as? NSNumber)?.intValue
            ?? (data["endMonth"] as? Int)
            ?? OrganizationAnnualLeaveDefaults.default.endMonth
        let carriesOver = data["carriesOver"] as? Bool ?? OrganizationAnnualLeaveDefaults.default.carriesOver
        return OrganizationAnnualLeaveDefaults(
            daysPerYear: daysPerYear,
            startMonth: startMonth,
            endMonth: endMonth,
            carriesOver: carriesOver
        )
    }

    /// Top-level `warningDetection` wins. Nested `settings.warningDetection` supplies excluded ids only when that key was left out.
    static func resolveWarningDetectionRaw(topLevel: [String: Any]?, nested: [String: Any]?) -> [String: Any]? {
        guard topLevel != nil || nested != nil else { return nil }
        guard var top = topLevel else { return nested.map(jsonReadyDictionary) }
        let excluded = top["excludedUserIdsFromUnbookedWarnings"]
        let keyMissing = excluded == nil || excluded is NSNull
        if keyMissing,
           let nestedIds = nested?["excludedUserIdsFromUnbookedWarnings"] as? [Any],
           !nestedIds.isEmpty {
            top["excludedUserIdsFromUnbookedWarnings"] = nested?["excludedUserIdsFromUnbookedWarnings"]
        }
        return jsonReadyDictionary(top)
    }

    private static func paymentRunDateRangesFromFirestore(_ data: [String: Any]) -> [PaymentRunDateRange] {
        let rows = (data["paymentRunDateRanges"] as? [Any]) ?? []
        let cleanRows: [[String: Any]] = rows.compactMap { entry in
            guard let row = entry as? [String: Any] else { return nil }
            var out: [String: Any] = [:]
            for key in ["startDay", "endDay", "startDate", "endDate"] {
                if let number = jsonReadyNumber(row[key]) {
                    out[key] = number
                }
            }
            return out
        }
        let parsed = CanonicalBusinessEngine.parsePaymentRunDateRanges(["paymentRunDateRanges": cleanRows]) ?? []
        let ranges = parsed.compactMap { range -> PaymentRunDateRange? in
            guard range.startDay >= 1, range.endDay >= 1 else { return nil }
            return PaymentRunDateRange(startDay: range.startDay, endDay: range.endDay)
        }
        if ranges.isEmpty {
            return OrganizationInvoicingSettings.default.paymentRunDateRanges
        }
        return ranges
    }

    private static func jsonReadyDictionary(_ data: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in data {
            if let ready = jsonReadyValue(value) {
                out[key] = ready
            }
        }
        return out
    }

    private static func jsonReadyValue(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let flag = value as? Bool { return flag }
        if let number = jsonReadyNumber(value) { return number }
        if let text = value as? String { return text }
        if let rows = value as? [Any] {
            return rows.compactMap(jsonReadyValue)
        }
        if let rows = value as? NSArray {
            return rows.compactMap { jsonReadyValue($0) }
        }
        if let map = value as? [String: Any] {
            return jsonReadyDictionary(map)
        }
        return nil
    }

    private static func jsonReadyNumber(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return number
        }
        return nil
    }

    static func warningDetectionFirestoreMap(_ settings: OrgWarningDetectionSettings) -> [String: Any] {
        let canonical = CanonicalBusinessEngine.CanonicalWarningDetection(
            detectClashes: settings.detectClashes,
            clashLookaheadMode: settings.clashLookaheadMode.rawValue,
            clashLookaheadDays: settings.clashLookaheadDays,
            includeWeekendsForUnbookedLabour: settings.includeWeekendsForUnbookedLabour,
            excludedUserIdsFromUnbookedWarnings: settings.excludedUserIdsFromUnbookedWarnings
        )
        return CanonicalBusinessEngine.warningDetectionToFirestore(canonical) ?? settings.asFirestoreDictionary()
    }

    static func invoicingFirestoreMap(_ settings: OrganizationInvoicingSettings) -> [String: Any] {
        if let map = CanonicalBusinessEngine.invoicingToFirestore(settings.canonicalInvoicingSettings()) {
            return map
        }
        return [
            "paymentRunMode": settings.paymentRunMode.rawValue,
            "paymentDateMode": settings.paymentDateMode.rawValue,
            "paymentRunDateRanges": settings.paymentRunDateRanges.map { range in
                [
                    "startDay": range.startDay,
                    "endDay": range.endDay,
                    "startDate": range.startDay,
                    "endDate": range.endDay,
                ]
            },
            "paymentDates": settings.paymentDates,
            "noteToUsers": settings.noteToUsers,
            "recurringPaymentRunSummary": settings.recurringPaymentRunSummary,
            "recurringRunStartDay": settings.recurringRunStartDay.rawValue,
            "recurringRunEndDay": settings.recurringRunEndDay.rawValue,
            "recurringPaymentDay": settings.recurringPaymentDay.rawValue,
        ]
    }

    private static func organizationInvoicingFromFirestore(_ data: [String: Any]) -> OrganizationInvoicingSettings {
        if let parsed = CanonicalBusinessEngine.parseInvoicing(jsonReadyDictionary(data)),
           var settings = invoicingSettings(from: parsed) {
            settings.timesheetSubmission = parsed.timesheetSubmission
            return settings
        }
        return invoicingSettingsFallback(data)
    }

    private static func invoicingSettings(from parsed: CanonicalBusinessEngine.CanonicalInvoicingSettings) -> OrganizationInvoicingSettings? {
        guard let paymentRunMode = PaymentRunConfigurationMode(rawValue: parsed.paymentRunMode),
              let paymentDateMode = PaymentDateConfigurationMode(rawValue: parsed.paymentDateMode) else {
            return nil
        }
        let ranges = parsed.paymentRunDateRanges.compactMap { range -> PaymentRunDateRange? in
            guard range.startDay >= 1, range.endDay >= 1 else { return nil }
            return PaymentRunDateRange(startDay: range.startDay, endDay: range.endDay)
        }
        let paymentDates = parsed.paymentDates.compactMap { Int($0) }.filter { (1...31).contains($0) }
        let start = RecurringPaymentDay(rawValue: parsed.recurringRunStartDay) ?? .monday
        let end = RecurringPaymentDay(rawValue: parsed.recurringRunEndDay) ?? .sunday
        let pay = RecurringPaymentDay(rawValue: parsed.recurringPaymentDay) ?? .friday
        var settings = OrganizationInvoicingSettings(
            paymentRunMode: paymentRunMode,
            paymentDateMode: paymentDateMode,
            paymentRunDateRanges: ranges.isEmpty ? OrganizationInvoicingSettings.default.paymentRunDateRanges : ranges,
            paymentDates: paymentDates,
            noteToUsers: parsed.noteToUsers,
            recurringPaymentRunSummary: "In arrears: \(start.title) to \(end.title) (of the previous week)",
            recurringRunStartDay: start,
            recurringRunEndDay: end,
            recurringPaymentDay: pay
        )
        settings.timesheetSubmission = parsed.timesheetSubmission
        settings.paymentRunHistory = parsed.paymentRunHistory
        return settings
    }

    private static func invoicingSettingsFallback(_ data: [String: Any]) -> OrganizationInvoicingSettings {
        let paymentRunMode = PaymentRunConfigurationMode(rawValue: (data["paymentRunMode"] as? String) ?? "")
            ?? .dateRanges
        let paymentDateMode = PaymentDateConfigurationMode(rawValue: (data["paymentDateMode"] as? String) ?? "")
            ?? .specificDates
        let recurringPaymentRunSummary = (data["recurringPaymentRunSummary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recurringRunStartDay = RecurringPaymentDay(rawValue: (data["recurringRunStartDay"] as? String) ?? "")
            ?? .monday
        let recurringRunEndDay = RecurringPaymentDay(rawValue: (data["recurringRunEndDay"] as? String) ?? "")
            ?? .sunday
        let recurringPaymentDay = RecurringPaymentDay(rawValue: (data["recurringPaymentDay"] as? String) ?? "")
            ?? .friday
        let noteToUsers = (data["noteToUsers"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let paymentDates = ((data["paymentDates"] as? [NSNumber])?.map(\.intValue))
            ?? (data["paymentDates"] as? [Int])
            ?? OrganizationInvoicingSettings.default.paymentDates

        let ranges = paymentRunDateRangesFromFirestore(data)

        var settings = OrganizationInvoicingSettings(
            paymentRunMode: paymentRunMode,
            paymentDateMode: paymentDateMode,
            paymentRunDateRanges: ranges,
            paymentDates: paymentDates,
            noteToUsers: noteToUsers,
            recurringPaymentRunSummary: recurringPaymentRunSummary?.isEmpty == false
                ? recurringPaymentRunSummary!
                : "In arrears: \(recurringRunStartDay.title) to \(recurringRunEndDay.title) (of the previous week)",
            recurringRunStartDay: recurringRunStartDay,
            recurringRunEndDay: recurringRunEndDay,
            recurringPaymentDay: recurringPaymentDay
        )
        settings.timesheetSubmission = OrganizationInvoicingSettings.timesheetSubmission(from: data)
        return settings
    }

    /// Ensures `settings.uiLabels.navigationLabels` has a full default key set. Existing labels are preserved.
    private func seedOrganizationUILabelsIfNeeded(
        organizationId: String,
        orgData: [String: Any]
    ) async {
        let settings = orgData["settings"] as? [String: Any] ?? [:]
        let uiLabels = settings["uiLabels"] as? [String: Any] ?? [:]
        let existingRaw = uiLabels["navigationLabels"] as? [String: Any] ?? [:]

        var merged = OrganizationUILabels.defaultNavigationLabels
        for (key, value) in existingRaw {
            guard let stringValue = value as? String else { continue }
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                merged[key] = trimmed
            }
        }

        let defaultsMissing = OrganizationUILabels.defaultNavigationLabels.keys.contains { key in
            let existing = (existingRaw[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return existing.isEmpty
        }

        guard defaultsMissing else { return }

        do {
            try await db.collection("organizations").document(organizationId).updateData([
                "settings.uiLabels.navigationLabels": merged,
                "updatedAt": Timestamp(date: Date())
            ])
            if var org = currentOrganization {
                org.settings.uiLabels = OrganizationUILabels(navigationLabels: merged)
                currentOrganization = org
            }
        } catch {
            // Non-blocking: label seeding should never interrupt auth/org loading.
            print("🔥🔥🔥 DEBUG: UI label seed skipped: \(error.localizedDescription)")
        }
    }

    // Async version for better control
    @MainActor
    func loadUserOrganization(userId: String) async {
        print("🔥🔥🔥 DEBUG: loadUserOrganization (async) called for userId: \(userId)")
        if organizationLoadInProgress {
            print("🔥🔥🔥 DEBUG: ⏳ Organization load already in progress, skipping duplicate request")
            return
        }
        organizationLoadInProgress = true
        defer { organizationLoadInProgress = false }
        
            // Optionally keep cached name for offline display only AFTER Firebase fails —
            // assigning currentOrganization here used to trigger ContentView bootstrap
            // before the server org was verified, stacking with auth/bootstrap loads.
            if let cachedOrganization = loadOrganizationFromLocalStorage() {
                print("🔥🔥🔥 DEBUG: ✅ Found organization in local storage: \(cachedOrganization.name) (will verify against users/\(userId) in Firebase)")
                _ = cachedOrganization
            }
            
            await loadUserOrganizationFromFirebase(userId: userId)
    }

    private nonisolated enum ServerReadTimeoutError: Error {
        case timedOut
    }

    func getDocumentWithServerTimeoutAndCacheFallback(
        _ ref: DocumentReference,
        timeoutSeconds: Double = 8.0
    ) async throws -> DocumentSnapshot {
        let path = ref.path
        do {
            return try await Self.readDocumentFromServer(ref, timeoutSeconds: timeoutSeconds)
        } catch {
            if error is ServerReadTimeoutError {
                print("🔥🔥🔥 DEBUG: ⏱️ Firestore server read timed out for \(path) - trying cache")
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: 🌐 Offline while reading \(path) from server - trying cache")
            } else {
                let nsError = error as NSError
                print("🔥🔥🔥 DEBUG: ⚠️ Server read failed for \(path) [\(nsError.domain):\(nsError.code)] - trying cache")
            }

            return try await ref.getDocument(source: .cache)
        }
    }

    /// Off the main actor. A server read that never returns must not freeze the splash or Home.
    private nonisolated static func readDocumentFromServer(
        _ ref: DocumentReference,
        timeoutSeconds: Double
    ) async throws -> DocumentSnapshot {
        try await withThrowingTaskGroup(of: DocumentSnapshot.self) { group in
            group.addTask {
                try await ref.getDocument(source: .server)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ServerReadTimeoutError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw ServerReadTimeoutError.timedOut
            }
            return value
        }
    }

    /// Off the main actor. Loading every project on the main actor left the Projects
    /// spinner up until the system killed the app.
    private nonisolated static func readCollectionFromServer(
        _ collection: Query,
        timeoutSeconds: Double
    ) async throws -> QuerySnapshot {
        try await withThrowingTaskGroup(of: QuerySnapshot.self) { group in
            group.addTask {
                try await collection.getDocuments(source: .server)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ServerReadTimeoutError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw ServerReadTimeoutError.timedOut
            }
            return value
        }
    }
    
    /// Load organization from Firebase
    @MainActor
    private func loadUserOrganizationFromFirebase(userId: String) async {
        print("🔥🔥🔥 DEBUG: ========== LOADING ORGANIZATION FROM FIREBASE ==========")
        print("🔥🔥🔥 DEBUG: User ID: \(userId)")
        print("🔥🔥🔥 DEBUG: Current user email: \(currentUser?.email ?? "N/A")")
        var failingReadStep = "starting organization bootstrap"
        var discoveredOrganizationId: String?
        var discoveredUserRoleRaw: String?
        
        do {
            failingReadStep = "reading users/\(userId)"
            print("🔥🔥🔥 DEBUG: Attempting to read user document: users/\(userId)")
            let userDoc = try await getDocumentWithServerTimeoutAndCacheFallback(
                db.collection("users").document(userId)
            )
            
            print("🔥🔥🔥 DEBUG: User document exists: \(userDoc.exists)")
            
            let userData: [String: Any]
            if userDoc.exists, let data = userDoc.data() {
                userData = data
            } else {
                print("🔥🔥🔥 DEBUG: ❌ User document missing or empty at users/\(userId) — keeping this device's company")
                errorMessage = userDoc.exists
                    ? "User data is empty. Please contact support."
                    : "User document not found. Attempting recovery..."
                userData = [:]
            }
            
            if let rawOrg = userData["organizationId"] {
                print("🔥🔥🔥 DEBUG: Raw organizationId field type: \(type(of: rawOrg)), value: \(rawOrg)")
            }
            
            let sharedOrg = organizationIdFromFirestore(userData["organizationId"])
            if let sharedOrg, !sharedOrg.isEmpty {
                sharedUserOrganizationId = normalizedOrganizationId(sharedOrg)
            }
            // Explicit switch, then this phone's cached_organizationId, then users/{uid}.organizationId.
            let choice = await applySessionOrganizationChoice(
                userId: userId,
                documentOrganizationId: sharedOrg,
                explicitOrganizationId: nil
            )
            guard let choice, !choice.organizationId.isEmpty else {
                print("🔥🔥🔥 DEBUG: Session chooser returned no company — not inventing one")
                print("🔥🔥🔥 DEBUG: User data keys: \(userData.keys.joined(separator: ", "))")
                if choice != nil {
                    currentOrganization = nil
                    sessionOrganizationId = ""
                }
                errorMessage = "Organization not linked. Attempting recovery..."
                await attemptToFixMissingOrganization(userId: userId, userData: userData)
                return
            }
            let organizationId = choice.organizationId
            discoveredOrganizationId = organizationId
            discoveredUserRoleRaw = userData["role"] as? String
            
            print("🔥🔥🔥 DEBUG: ✅ Session organisation: \(organizationId) (shared users.organizationId: \(sharedOrg ?? "nil"))")
            
            // Migrate a DocumentReference to a string only for the company already stored on the user document.
            // Do not overwrite a different company — that is another platform's session.
            if organizationIdsMatch(sharedOrg, organizationId), !(userData["organizationId"] is String) {
                do {
                    try await ensureUserDocumentLinked(organizationId: organizationId)
                } catch {
                    print("🔥🔥🔥 DEBUG: ⚠️ organizationId → string migration failed (non-fatal): \(error.localizedDescription)")
                }
            }
            
            failingReadStep = "reading organizations/\(organizationId)"
            print("🔥🔥🔥 DEBUG: Attempting to read organization document: organizations/\(organizationId)")
            let orgDoc = try await getDocumentWithServerTimeoutAndCacheFallback(
                db.collection("organizations").document(organizationId)
            )
            
            print("🔥🔥🔥 DEBUG: Organization document exists: \(orgDoc.exists)")
            
            guard orgDoc.exists, let data = orgDoc.data() else {
                print("🔥🔥🔥 DEBUG: Organization document unread for \(organizationId) — keeping the session company")
                errorMessage = orgDoc.exists
                    ? "Organization data is empty. Please contact support."
                    : "Organization not found. Please contact support."
                publishSessionOrganizationIfNeeded(organizationId)
                return
            }

            if await rejectTrialBlockedOrganizationIfNeeded(organizationId: organizationId, orgData: data) {
                print("🔥🔥🔥 DEBUG: ❌ Trial access blocked for organisation: \(organizationId)")
                return
            }
            
            let organizationName = data["name"] as? String ?? "Unknown Organization"
            let creatorUserId = data["creatorUserId"] as? String
            print("🔥🔥🔥 DEBUG: ✅ Organization name: \(organizationName), creatorUserId: \(creatorUserId ?? "nil")")
            
            let orgSettings = Self.organizationSettingsFromOrgDocument(data)
            organizationHasFirestoreMyScheduleOptions = Self.organizationHasMyScheduleOptionsInDocument(data)
            var organization = organizationKeepingKnownName(Organization.make(
                fromFirestoreId: organizationId,
                data: data,
                settings: orgSettings,
                fallbackName: "Unknown Organization"
            ))
            Self.applyPayrollPolicyFields(from: data, to: &organization)
            
            self.sessionOrganizationId = normalizedOrganizationId(organizationId)
            self.currentOrganization = organization
            self.userRole = UserRole(rawValue: userData["role"] as? String ?? UserRole.basic.rawValue) ?? .basic
            self.errorMessage = nil // Clear any previous errors
            await seedOrganizationUILabelsIfNeeded(organizationId: organizationId, orgData: data)
            
            // Store organization locally for offline access
            storeOrganizationLocally(organization)
            
            print("🔥🔥🔥 DEBUG: ✅✅✅ Organization loaded successfully - Name: \(organizationName), ID: \(organizationId)")
        } catch {
            if isSessionExpiredOrInvalidCredential(error) {
                await forcedSignOutRemovingPushToken()
                errorMessage = FirebaseBackend.sessionExpiredMessage
                print("🔥🔥🔥 DEBUG: Session/credential expired – signed out so user can sign in again")
                return
            }
            if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: 🌐 Network offline while loading organization")
                errorMessage = "Internet connection appears offline. Reconnect and tap Force Reload."
                return
            }
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                print("🔥🔥🔥 DEBUG: ❌ Firestore permission error - security rules need to be updated")
                print("🔥🔥🔥 DEBUG: Error: Missing or insufficient permissions")
                print("🔥🔥🔥 DEBUG: Error code: \(nsError.code), domain: \(nsError.domain)")
                print("🔥🔥🔥 DEBUG: Failing read step: \(failingReadStep)")
                print("🔥🔥🔥 DEBUG: Firebase projectID (must match rules deployment): \(FirebaseApp.app()?.options.projectID ?? "nil")")
                print("🔥🔥🔥 DEBUG: Please ensure Firestore security rules are published in Firebase Console")
                print("🔥🔥🔥 DEBUG: Rules should allow authenticated users to read their user document and organization")

                // If only the organization root read is denied, continue with a lightweight org context.
                if failingReadStep.hasPrefix("reading organizations/"),
                   let organizationId = discoveredOrganizationId {
                    let cachedName = loadOrganizationFromLocalStorage()?.name
                    let fallbackOrganization = Organization(
                        id: Manager.stableId(forFirestoreDocumentId: organizationId),
                        firestoreDocumentId: organizationId,
                        name: (cachedName?.isEmpty == false) ? cachedName! : "Recovered Organization",
                        settings: OrganizationSettings(),
                        officeAddressLine1: nil,
                        officeCity: nil,
                        officePostcode: nil,
                        countryCode: "GB",
                        defaultLatitude: nil,
                        defaultLongitude: nil,
                        creatorUserId: nil
                    )
                    self.sessionOrganizationId = normalizedOrganizationId(organizationId)
                    self.currentOrganization = fallbackOrganization
                    self.userRole = UserRole(rawValue: discoveredUserRoleRaw ?? UserRole.basic.rawValue) ?? .basic
                    self.errorMessage = nil
                    storeOrganizationLocally(fallbackOrganization)
                    print("🔥🔥🔥 DEBUG: ✅ Using fallback organization context despite org-root read denial: \(organizationId)")
                    NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
                    return
                }
                
                if let userEmail = currentUser?.email, !suppressOrganizationReadPermissionRecovery {
                    print("🔥🔥🔥 DEBUG: Attempting recovery after permission error (one attempt)...")
                    suppressOrganizationReadPermissionRecovery = true
                    defer { suppressOrganizationReadPermissionRecovery = false }
                    let recovered = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                    if recovered, currentOrganization != nil {
                        print("🔥🔥🔥 DEBUG: ✅ Recovery finished — organization loaded")
                        NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
                        return
                    }
                }
                
                errorMessage = "Permission error reading your organization. Deploy the latest Firestore rules from the app repo (fixes circular org read), then try again or use Force Reload in Settings."
            } else {
                print("🔥🔥🔥 DEBUG: ❌ Error loading organization: \(error.localizedDescription)")
                print("🔥🔥🔥 DEBUG: Full error: \(error)")
                errorMessage = "Failed to load organization: \(error.localizedDescription)"
            }
        }
    }
    
    // Helper function to attempt fixing missing organization
    @MainActor
    private func attemptToFixMissingOrganization(userId: String, userData: [String: Any]) async {
        let email = currentUser?.email ?? (userData["email"] as? String) ?? ""
        guard !email.isEmpty else { return }
        _ = await recoverMissingOrganizationLink(userId: userId, userEmail: email)
    }
    
    func getOrganizationData(organizationId: String) async throws -> OrganizationData? {
        let doc = try await db.collection("organizations").document(organizationId).getDocument()
        guard doc.exists else { return nil }
        
        let data = doc.data()!
        return OrganizationData(
            id: organizationId,
            name: CanonicalBusinessEngine.parseOrganizationName(Organization.nameParsePayload(from: data)) ?? "",
            members: data["members"] as? [String: String] ?? [:],
            settings: data["settings"] as? [String: Any] ?? [:],
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }
    
    func updateOrganizationData(_ orgData: OrganizationData) async throws {
        guard let nameFields = CanonicalBusinessEngine.organizationNameWriteFields(orgData.name, existingName: nil) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Could not save the organisation name."]
            )
        }
        var data: [String: Any] = nameFields
        data["members"] = orgData.members
        data["settings"] = orgData.settings
        data["updatedAt"] = Timestamp(date: Date())
        
        try await db.collection("organizations").document(orgData.id).updateData(data)
    }
    
    // MARK: - Project Management
    
    private static func parseJobType(from rawValue: Any?, defaultValue: JobType) -> JobType {
        if let stringValue = rawValue as? String {
            if let exact = JobType(rawValue: stringValue) {
                return exact
            }
            let normalized = stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            switch normalized {
            case "cat a", "cata", "cata project", "project", "projects", "regular", "main":
                return .catA
            case "cat b", "catb":
                return .catB
            case "small works", "smallworks", "small work":
                return .smallWorks
            case "maintenance":
                return .maintenance
            default:
                break
            }
        }
        return defaultValue
    }
    
    private static func parseManagerLegacy(from rawValue: Any?) -> ManagerLegacy {
        if let stringValue = rawValue as? String {
            if let exact = ManagerLegacy(rawValue: stringValue) {
                return exact
            }
            let normalized = stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch normalized {
            case "n/a", "na", "none", "other", "":
                return .na
            case "adam":
                return .adam
            case "billey":
                return .billey
            case "charley":
                return .charley
            case "farnie":
                return .farnie
            case "fin":
                return .fin
            case "greg":
                return .greg
            case "morgan":
                return .morgan
            case "ross":
                return .ross
            case "custom":
                return .custom
            default:
                break
            }
        }
        return .na
    }
    
    /// Repairs membership/link if a user can authenticate but org writes fail with permission denied.
    func repairCurrentUserOrganizationAccess(organizationId: String) async {
        guard currentUser != nil else { return }
        let orgIdStr = normalizedOrganizationId(organizationId)
        guard !orgIdStr.isEmpty else { return }
        // A signed-in user cannot write their own organizationId, and a normal member
        // cannot add themselves to organizations/{orgId}.members as admin.
        print("🔥🔥🔥 DEBUG: repairCurrentUserOrganizationAccess skipped Firestore writes for \(orgIdStr)")
    }

    func saveProject(_ project: Project, organizationId: String, mode: RecordSaveMode, previous: Project? = nil) async throws {
        print("🔥🔥🔥 DEBUG: [SAVE] Saving project \(project.siteName) at projects/\(project.documentId)")
        // CRITICAL: Ensure user document is linked before validation
        // This prevents "user is not linked to organization" errors
        do {
            try await ensureUserDocumentLinked(organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE] ⚠️ Could not ensure user document is linked: \(error.localizedDescription)")
            // Continue anyway - validation might still pass if user is in organization members
        }
        try await validateDataIntegrity(organizationId: organizationId)
        try await saveJobDocument(project, collection: "projects", organizationId: organizationId, mode: mode, previous: previous)
    }

    /// RULEBOOK 1.7.0 §1 "Partial writes only": a job save writes the fields `jobWriteFields` names (the manager
    /// ids, the address and the map pin each as a group; `id`, `createdAt` and `organizationId` on create only). A
    /// new job is created whole. Never a full `setData` over the stored job, which deleted fields this app does
    /// not hold. The path is the stored document id (`Project.documentId`).
    private func saveJobDocument(
        _ job: Project,
        collection: String,
        organizationId: String,
        mode: RecordSaveMode,
        previous: Project?
    ) async throws {
        let ref = db.collection("organizations").document(organizationId).collection(collection).document(job.documentId)
        do {
            // The copy the user edited is the baseline, so only the fields they changed are written.
            try await writeChangedRosterRow(
                ref,
                payload: Self.jobDocumentPayload(job, organizationId: organizationId),
                previousPayload: previous.map { Self.jobDocumentPayload($0, organizationId: organizationId) },
                writeFields: "jobWriteFields",
                mode: mode
            )
        } catch {
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: [SAVE JOB] ❌ \(collection)/\(job.documentId): \(nsError.domain) \(nsError.code) \(error.localizedDescription)")
            throw error
        }
    }

    /// The fields a job save would write, as native Firestore values. "No value" is `FieldValue.delete()`, which
    /// `jobWriteFields` turns into a removal only when the stored job has that field. Ids are the stored ids.
    static func jobDocumentPayload(_ job: Project, organizationId: String) -> [String: Any] {
        func orDelete(_ value: Any?) -> Any { value ?? FieldValue.delete() }
        let managerIds = job.allAssignedManagerIds.map { job.storedManagerId(for: $0) }
        let primaryManager = (job.managerId ?? job.allAssignedManagerIds.first).map { job.storedManagerId(for: $0) }
        return [
            "jobNumber": job.jobNumber,
            "siteName": job.siteName,
            "addressLine1": job.addressLine1,
            "addressLine2": job.addressLine2 ?? "",
            "townCity": job.townCity,
            "postcode": job.postcode,
            // Keep siteAddress for backward compatibility
            "siteAddress": job.siteAddress,
            "client": [
                "id": job.client.documentId,
                "name": job.client.name,
                "email": job.client.email ?? "",
                "phone": job.client.phone ?? ""
            ],
            "startDate": Timestamp(date: job.startDate),
            "endDate": Timestamp(date: job.endDate),
            "jobType": job.jobType.rawValue,
            "customJobType": orDelete(job.customJobType),
            "manager": job.manager.rawValue,
            "managerId": orDelete(primaryManager),
            "managerIds": managerIds.isEmpty ? FieldValue.delete() as Any : managerIds as Any,
            "isLive": job.isLive,
            "description": job.description ?? "",
            "hiddenManagerUserIds": Array(job.hiddenManagerUserIds).sorted(),
            "hiddenOperativeUserIds": Array(job.hiddenOperativeUserIds).sorted(),
            "usesMapPinForLocation": job.usesMapPinForLocation,
            "latitude": orDelete(job.latitude),
            "longitude": orDelete(job.longitude),
            "organizationId": organizationId,
            "createdAt": Timestamp(date: job.createdAt),
            "updatedAt": Timestamp(date: job.updatedAt)
        ]
    }

    /// RULEBOOK 1.7.0 §1 "Document readers": `projects/{id}` and `smallWorks/{id}` are read only through
    /// `parseJobDocument` (web uses the same reader). The job id is the document id in stored case and the client
    /// and manager ids are kept as stored (a non-UUID id is kept with a stable in-app UUID, never random or
    /// dropped). A job with no start date starts on its creation day; no end date ends on its start day. The
    /// placeholder document is skipped. Tests call this with raw documents.
    static func jobs(fromDocuments documents: [(id: String, data: [String: Any])], smallWorks: Bool) -> [Project] {
        documents.compactMap { doc -> Project? in
            guard let row = CanonicalBusinessEngine.parseJobDocument(documentId: doc.id, data: doc.data, smallWorks: smallWorks) else {
                return nil
            }
            return job(fromCanonical: row, smallWorks: smallWorks, storedManagerName: doc.data["manager"])
        }
    }

    /// One `parseJobDocument` row as a `Project`. `storedManagerName` is the legacy `manager` label (the reader
    /// drops "Custom"; the legacy picker still shows it).
    static func job(fromCanonical row: CanonicalDocumentRow, smallWorks: Bool, storedManagerName: Any? = nil) -> Project {
        // RULEBOOK 1.8.0: `client.id` is the stored id (`client.id`, else `clientId`), else `jobClientId` when the job
        // names a client — the same derived id on web; the next job save writes it.
        let clientRow = CanonicalDocumentRow(row.map("client"))
        let clientId = clientRow?.text("id") ?? ""
        let client = Client(
            id: WorkDocumentKeys.inAppId(for: clientId.isEmpty ? "job-client.\(row.id)" : clientId),
            name: clientRow?.optionalText("name") ?? "Unknown Client",
            email: clientRow?.optionalText("email"),
            phone: clientRow?.optionalText("phone"),
            firestoreDocumentId: clientId.isEmpty ? nil : clientId
        )
        let startDate = row.date("startMs") ?? Date()
        let endDate = row.date("endMs") ?? startDate
        let jobType = parseJobType(from: row.optionalText("jobType"), defaultValue: smallWorks ? .smallWorks : .catA)
        let manager = parseManagerLegacy(from: row.optionalText("managerName") ?? storedManagerName)
        let storedManagerIds = row.strings("managerIds")
        let storedPrimary = row.optionalText("managerId")
        let managerIds = storedManagerIds.map { WorkDocumentKeys.inAppId(for: $0) }
        let managerId = storedPrimary.map { WorkDocumentKeys.inAppId(for: $0) }
        let hiddenManagerUserIds = Set(row.strings("hiddenManagerUserIds"))
        let hiddenOperativeUserIds = Set(row.strings("hiddenOperativeUserIds"))
        let siteName = row.optionalText("siteName") ?? (smallWorks ? "Unnamed Small Works" : "Unnamed Project")
        let addressLine1 = row.text("addressLine1")
        let townCity = row.text("townCity")
        let postcode = row.text("postcode")
        let siteAddress = row.text("siteAddress")
        var job: Project
        if addressLine1.isEmpty && townCity.isEmpty && postcode.isEmpty && !siteAddress.isEmpty {
            // Legacy one-line address only.
            job = Project(
                id: WorkDocumentKeys.inAppId(for: row.id),
                jobNumber: row.text("jobNumber"),
                siteName: siteName,
                siteAddress: siteAddress,
                client: client,
                startDate: startDate,
                endDate: endDate,
                jobType: jobType,
                manager: manager,
                isLive: row.bool("isLive", default: true),
                description: row.optionalText("description"),
                notes: row.optionalText("notes"),
                hiddenManagerUserIds: hiddenManagerUserIds,
                hiddenOperativeUserIds: hiddenOperativeUserIds
            )
            job.managerId = managerId
            job.managerIds = managerIds
            job.customJobType = row.optionalText("customJobType")
        } else {
            job = Project(
                id: WorkDocumentKeys.inAppId(for: row.id),
                jobNumber: row.text("jobNumber"),
                siteName: siteName,
                addressLine1: addressLine1,
                addressLine2: row.optionalText("addressLine2"),
                townCity: townCity,
                postcode: postcode,
                client: client,
                startDate: startDate,
                endDate: endDate,
                jobType: jobType,
                customJobType: row.optionalText("customJobType"),
                manager: manager,
                managerId: managerId,
                managerIds: managerIds,
                isLive: row.bool("isLive", default: true),
                description: row.optionalText("description"),
                notes: row.optionalText("notes"),
                hiddenManagerUserIds: hiddenManagerUserIds,
                hiddenOperativeUserIds: hiddenOperativeUserIds
            )
        }
        job.usesMapPinForLocation = row.bool("usesMapPinForLocation")
        job.latitude = row.number("latitude")
        job.longitude = row.number("longitude")
        if let createdAt = row.date("createdAtMs") { job.createdAt = createdAt }
        if let updatedAt = row.date("updatedAtMs") { job.updatedAt = updatedAt }
        job.firestoreDocumentId = row.id
        job.storedManagerIds = storedManagerIds + (storedPrimary.map { primary in
            storedManagerIds.contains(primary) ? [] : [primary]
        } ?? [])
        return job
    }
    
    /// Server-first collection read. An empty Firestore persistence cache is NOT treated as
    /// "this organisation has zero documents" — that is what made TestFlight lists vanish.
    /// The server attempt is off the main actor and gives up after 8 seconds.
    private func getDocumentsPreferringServer(_ collection: CollectionReference) async throws -> QuerySnapshot {
        do {
            return try await Self.readCollectionFromServer(collection, timeoutSeconds: 8)
        } catch {
            let timedOut = error is ServerReadTimeoutError
            guard timedOut || isFirestorePermissionDenied(error) || isOfflineNetworkError(error) else { throw error }
            if timedOut {
                print("🔥🔥🔥 DEBUG: ⏱️ Firestore collection read timed out for \(collection.path) — trying cache")
            }
            let cached: QuerySnapshot
            do {
                cached = try await collection.getDocuments(source: .cache)
            } catch {
                throw error
            }
            if cached.documents.isEmpty {
                print("🔥🔥🔥 DEBUG: Empty Firestore cache after server failure — not treating as a successful empty list")
                throw error
            }
            return cached
        }
    }

    func loadProjects(organizationId: String) async throws -> [Project] {
        let orgId = try await ensureReadableOrganization(organizationId)
        let snapshot = try await getDocumentsPreferringServer(
            db.collection("organizations").document(orgId).collection("projects")
        )
        let jobs = Self.jobs(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) }, smallWorks: false)
        print("🔥🔥🔥 DEBUG: [LOAD] ✅ Loaded \(jobs.count) of \(snapshot.documents.count) projects documents")
        return jobs
    }
    
    func saveClient(_ client: Client, organizationId: String, mode: RecordSaveMode, previous: Client? = nil) async throws {
        print("🔥🔥🔥 DEBUG: saveClient called with organizationId: \(organizationId)")
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save a client."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [saveClient] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)
        
        try await validateDataIntegrity(organizationId: orgId)
        
        // RULEBOOK 1.6.0 §1, §11: a partial update of the fields `clientWriteFields` names (a new client is
        // created whole). `id`, `createdAt` and `organizationId` are written on create only.
        let data = Self.clientDocumentPayload(client, organizationId: orgId)
        
        print("🔥🔥🔥 DEBUG: Saving client to organizations/\(orgId)/clients/\(client.documentId)")
        
        let ref = db.collection("organizations").document(orgId).collection("clients").document(client.documentId)
        let previousData = previous.map { Self.clientDocumentPayload($0, organizationId: orgId) }
        try await writeChangedRosterRow(ref, payload: data, previousPayload: previousData, writeFields: "clientWriteFields", mode: mode)
        
        print("🔥🔥🔥 DEBUG: Client saved successfully to Firebase")
    }
    
    static func clientDocumentPayload(_ client: Client, organizationId: String) -> [String: Any] {
        [
            "id": client.documentId,
            "name": client.name,
            "contactPerson": client.contactPerson ?? "",
            "email": client.email ?? "",
            "phone": client.phone ?? "",
            "address": client.address ?? "",
            "organizationId": organizationId,
            "createdAt": Timestamp(date: client.createdAt)
        ]
    }

    func loadClients(organizationId: String) async throws -> [Client] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: loadClients called for organization: \(orgId)")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection("organizations").document(orgId).collection("clients").getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) || isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: [LOAD CLIENTS] Server clients read failed for \(orgId) - trying cache fallback")
                snapshot = try await db.collection("organizations").document(orgId).collection("clients").getDocuments(source: .cache)
            } else {
                throw error
            }
        }
        
        let clients = Self.clients(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) })
        
        print("🔥🔥🔥 DEBUG: Loaded \(clients.count) clients from Firebase")
        return clients
    }
    
    /// RULEBOOK 1.6.0 §1 "Document readers": `clients/{id}` are read only through the rulebook's
    /// `parseClientDocument`. The record id is the document id in stored case (a non-UUID id is kept; a stored
    /// `id` field never replaces it). Tests call this with raw documents.
    static func clients(fromDocuments documents: [(id: String, data: [String: Any])]) -> [Client] {
        documents.compactMap { doc -> Client? in
            guard let row = CanonicalBusinessEngine.parseClientDocument(documentId: doc.id, data: doc.data) else { return nil }
            var client = Client(
                id: WorkDocumentKeys.inAppId(for: row.id),
                name: row.text("name"),
                contactPerson: row.optionalText("contactPerson"),
                email: row.optionalText("email"),
                phone: row.optionalText("phone"),
                address: row.optionalText("address"),
                firestoreDocumentId: row.id
            )
            if let createdAt = row.date("createdAtMs") { client.createdAt = createdAt }
            if let updatedAt = row.date("updatedAtMs") { client.updatedAt = updatedAt }
            return client
        }
    }
    
    func deleteClient(_ client: Client, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteClient called for client: \(client.name), organization: \(organizationId)")
        try await db.collection("organizations").document(organizationId).collection("clients").document(client.documentId).delete()
        print("🔥🔥🔥 DEBUG: Client deleted successfully from Firebase")
    }
    
    func deleteProject(_ project: Project, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteProject called for: \(project.siteName), organization: \(organizationId)")
        await removeFutureBookingsOfDeletedJob(project, organizationId: organizationId)
        try await db.collection("organizations").document(organizationId).collection("projects").document(project.documentId).delete()
        print("🔥🔥🔥 DEBUG: Project deleted successfully from Firebase")
    }

    /// RULEBOOK 1.7.0 §2: deleting a job removes its bookings from today on (`bookingsToRemoveOnProjectDelete`),
    /// each with its tombstone (`deleteBookingWithTombstone`); past bookings stay for timesheets and reports. A
    /// booking the rules refuse to delete (labour booking deletes are admin only) is logged and left in place.
    private func removeFutureBookingsOfDeletedJob(_ job: Project, organizationId: String) async {
        do {
            let snapshot = try await db.collection("organizations").document(organizationId).collection("bookings")
                .whereField("projectId", isEqualTo: job.documentId)
                .getDocuments()
            let bookings = bookingsFromFirestoreDocuments(snapshot.documents)
            guard !bookings.isEmpty,
                  let ids = CanonicalBusinessEngine.bookingsToRemoveOnProjectDelete(
                    bookings.map { (id: $0.documentKey, projectId: $0.storedProjectId, date: $0.date) },
                    projectId: job.documentId,
                    now: Date()
                  ) else { return }
            for id in ids {
                do {
                    try await deleteBookingWithTombstone(collection: "bookings", bookingId: id, organizationId: organizationId)
                } catch {
                    print("🔥🔥🔥 DEBUG: [DELETE JOB] booking \(id) not removed: \(error.localizedDescription)")
                }
            }
        } catch {
            print("🔥🔥🔥 DEBUG: [DELETE JOB] could not read the job's bookings: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Small Works Management (Separate Collection)
    
    func saveSmallWorks(_ smallWork: Project, organizationId: String, mode: RecordSaveMode, previous: Project? = nil) async throws {
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Saving small works \(smallWork.siteName) at smallWorks/\(smallWork.documentId)")
        // CRITICAL: Ensure user document is linked before validation
        // This prevents "user is not linked to organization" errors
        do {
            try await ensureUserDocumentLinked(organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ⚠️ Could not ensure user document is linked: \(error.localizedDescription)")
            // Continue anyway - validation might still pass if user is in organization members
        }
        try await validateDataIntegrity(organizationId: organizationId)
        try await saveJobDocument(smallWork, collection: "smallWorks", organizationId: organizationId, mode: mode, previous: previous)
    }
    
    func loadSmallWorks(organizationId: String) async throws -> [Project] {
        let orgId = try await ensureReadableOrganization(organizationId)
        let snapshot = try await getDocumentsPreferringServer(
            db.collection("organizations").document(orgId).collection("smallWorks")
        )
        let jobs = Self.jobs(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) }, smallWorks: true)
        print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] ✅ Loaded \(jobs.count) of \(snapshot.documents.count) smallWorks documents")
        return jobs
    }
    
    func deleteSmallWorks(_ smallWork: Project, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteSmallWorks called for: \(smallWork.siteName), organization: \(organizationId)")
        await removeFutureBookingsOfDeletedJob(smallWork, organizationId: organizationId)
        try await db.collection("organizations").document(organizationId).collection("smallWorks").document(smallWork.documentId).delete()
        print("🔥🔥🔥 DEBUG: Small Works deleted successfully from Firebase")
    }
    
    // MARK: - Job Types Management
    
    func saveJobTypes(organizationId: String, jobTypes: Set<String>) async throws {
        print("🔥🔥🔥 DEBUG: saveJobTypes called for organization: \(organizationId)")
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save job types."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [saveJobTypes] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)
        if jobTypes.isEmpty {
            print("🔥🔥🔥 DEBUG: Refusing to overwrite job types with an empty list")
            return
        }
        // RULEBOOK 1.8.0 §1: `jobTypesWriteFields` (canonical names, de-duplicated, sorted; a field update of
        // `jobTypes` only; no write when the list is empty or unchanged). §16: admins and managers only.
        let ref = db.collection("organizations").document(orgId).collection("settings").document("jobTypes")
        let snapshot = try await ref.getDocument(source: .server)
        let stored = snapshot.exists ? CanonicalBusinessEngine.parseJobTypesDocument(snapshot.data()) : nil
        guard let answer = CanonicalBusinessEngine.jobTypesWriteFields(stored: stored, next: Array(jobTypes)) else {
            throw CanonicalWriteUnavailableError(function: "jobTypesWriteFields")
        }
        guard let names = answer else { return }
        let patch = WriteMetadata.stamped(["jobTypes": names], userId: currentUser?.uid)
        if snapshot.exists {
            try await ref.updateData(patch)
        } else {
            // First save for this organisation: the document does not exist yet.
            var create = patch
            create["organizationId"] = orgId
            try await ref.setData(create, merge: true)
        }
        print("🔥🔥🔥 DEBUG: Job types saved successfully to Firebase")
    }
    
    func loadJobTypes(organizationId: String) async throws -> Set<String> {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: loadJobTypes called for organization: \(orgId)")
        let docRef = db.collection("organizations").document(orgId).collection("settings").document("jobTypes")
        let doc: DocumentSnapshot
        do {
            doc = try await docRef.getDocument(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [JOB TYPES LOAD] Server denied settings/jobTypes read for \(orgId) - trying cache fallback")
                doc = try await docRef.getDocument(source: .cache)
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: [JOB TYPES LOAD] Offline while reading settings/jobTypes for \(orgId) - trying cache fallback")
                doc = try await docRef.getDocument(source: .cache)
            } else {
                throw error
            }
        }
        if doc.exists, let data = doc.data() {
            // RULEBOOK 1.8.0 §1: `parseJobTypesDocument` (strings, `{ name }` maps, comma lists; enum spellings read
            // as the canonical names).
            let parsed = Set(CanonicalBusinessEngine.parseJobTypesDocument(data) ?? [])
            if !parsed.isEmpty {
                print("🔥🔥🔥 DEBUG: Loaded \(parsed.count) job types from Firebase")
                return parsed
            }
        }
        print("🔥🔥🔥 DEBUG: No job types found in Firebase, returning empty set")
        return []
    }

    // MARK: - Project Task Management
    
    func loadProjectTasks(organizationId: String) async throws -> [ProjectTask] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: Loading tasks from Firebase for organization: \(orgId)")
        let tasksRef = db.collection("organizations").document(orgId).collection("tasks")
        let snapshot = try await getDocumentsPreferringServer(tasksRef)
        print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) task documents in Firebase")
        
        return snapshot.documents.compactMap { Self.projectTask(documentId: $0.documentID, data: $0.data()) }
    }

    /// RULEBOOK 1.8.0 §1: one task through `parseTaskDocument` (document id in stored case, never a random id; a task
    /// with no or a non-UUID job id, an unknown status or items without ids is kept; item ids are derived).
    static func projectTask(documentId: String, data: [String: Any]) -> ProjectTask? {
        guard let row = CanonicalBusinessEngine.parseTaskDocument(documentId: documentId, data: data) else { return nil }
        let projectKey = row.text("projectId")
        let createdAt = row.date("createdAtMs") ?? Date(timeIntervalSince1970: 0)
        var task = ProjectTask(
            id: JobKeys.inAppId(row.id),
            projectId: projectKey.isEmpty ? Manager.stableId(forFirestoreDocumentId: "") : JobKeys.inAppId(projectKey),
            title: row.text("title"),
            details: row.optionalText("details"),
            createdBy: row.text("createdBy"),
            assignedOperativeId: row.optionalText("assignedOperativeId").map { JobKeys.inAppId($0) },
            assignedManagerId: row.optionalText("assignedManagerId").map { JobKeys.inAppId($0) },
            assignedOperativeIds: row.strings("assignedOperativeIds").map { JobKeys.inAppId($0) },
            assignedManagerIds: row.strings("assignedManagerIds").map { JobKeys.inAppId($0) },
            dueDate: row.date("dueDateMs"),
            priority: ProjectTask.Priority(rawValue: row.text("priority")) ?? .normal,
            status: ProjectTask.Status(rawValue: row.text("status")) ?? .todo,
            createdAt: createdAt,
            updatedAt: row.date("updatedAtMs") ?? createdAt,
            attachedFileURL: row.optionalText("attachedFileURL"),
            attachedFileName: row.optionalText("attachedFileName"),
            attachedImageURLs: row.strings("attachedImageURLs"),
            attachedSiteAuditId: row.optionalText("attachedSiteAuditId").map { JobKeys.inAppId($0) },
            attachedSiteAuditTitle: row.optionalText("attachedSiteAuditTitle"),
            completedBy: row.optionalText("completedBy"),
            completedAt: row.date("completedAtMs"),
            completionImages: row.strings("completionImages"),
            completionFiles: row.strings("completionFiles"),
            completionNotes: row.optionalText("completionNotes"),
            items: row.rows("items").map { item in
                ProjectTaskItem(id: JobKeys.inAppId(item.id), title: item.text("title"), description: item.optionalText("description"))
            },
            completedItemIds: row.strings("completedItemIds").map { JobKeys.inAppId($0) }
        )
        task.projectKey = projectKey
        return task
    }

    /// The `taskFields` input for a task: ids as stored, instants as native Timestamps.
    static func projectTaskFields(_ task: ProjectTask, organizationId: String) -> [String: Any]? {
        let projectId: String
        if let key = task.projectKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           Manager.stableId(forFirestoreDocumentId: key) == task.projectId {
            projectId = key
        } else {
            projectId = JobKeys.storedJobId(for: task.projectId)
        }
        let stored: (UUID) -> String = { WorkDocumentKeys.storedId(for: $0) }
        let input: [String: Any] = [
            "id": stored(task.id),
            "projectId": projectId,
            "title": task.title,
            "details": task.details ?? NSNull(),
            "createdBy": task.createdBy,
            "status": task.status.rawValue,
            "priority": task.priority.rawValue,
            "assignedOperativeId": task.assignedOperativeId.map { stored($0) as Any } ?? NSNull(),
            "assignedManagerId": task.assignedManagerId.map { stored($0) as Any } ?? NSNull(),
            "assignedOperativeIds": task.assignedOperativeIds.map(stored),
            "assignedManagerIds": task.assignedManagerIds.map(stored),
            "dueDate": task.dueDate.map { Timestamp(date: $0) as Any } ?? NSNull(),
            "completedBy": task.completedBy ?? NSNull(),
            "completedAt": task.completedAt.map { Timestamp(date: $0) as Any } ?? NSNull(),
            "completionNotes": task.completionNotes ?? NSNull(),
            "completionImages": task.completionImages,
            "completionFiles": task.completionFiles,
            "attachedImageURLs": task.attachedImageURLs,
            "attachedFileURL": task.attachedFileURL ?? NSNull(),
            "attachedFileName": task.attachedFileName ?? NSNull(),
            "attachedSiteAuditId": task.attachedSiteAuditId.map { stored($0) as Any } ?? NSNull(),
            "attachedSiteAuditTitle": task.attachedSiteAuditTitle ?? NSNull(),
            "items": task.items.map { ["id": stored($0.id), "title": $0.title, "description": $0.description ?? ""] as [String: Any] },
            "completedItemIds": task.completedItemIds.map(stored),
            "createdAt": Timestamp(date: task.createdAt),
            "organizationId": organizationId,
        ]
        guard let fields = CanonicalBusinessEngine.taskFields(input) else { return nil }
        return ScriptFirestoreValue.native(fields) as? [String: Any]
    }
    
    /// RULEBOOK 1.8.0 §1: a task saved with `taskWriteFields` (never a whole-task `setData`): assignee id with list,
    /// completion by with at, and items with completed item ids are each written together; `createdAt`, `createdBy`
    /// and `organizationId` are never rewritten. The task lives at its stored document id.
    func saveProjectTask(_ task: ProjectTask, organizationId: String) async throws {
        guard let data = Self.projectTaskFields(task, organizationId: organizationId) else {
            throw CanonicalWriteUnavailableError(function: "taskFields")
        }
        let ref = db.collection("organizations").document(organizationId)
            .collection("tasks")
            .document(WorkDocumentKeys.storedId(for: task.id))
        try await writeOperationsDocument(ref, writeFields: "taskWriteFields") { _ in data }
    }
    
    func deleteProjectTask(taskId: UUID, organizationId: String) async throws {
        try await db.collection("organizations").document(organizationId).collection("tasks").document(WorkDocumentKeys.storedId(for: taskId)).delete()
    }
    
    // MARK: - Firebase Storage
    
    #if canImport(FirebaseStorage)
    func uploadTaskFile(_ fileURL: URL, taskId: UUID, organizationId: String, fileName: String) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let fileData = try Data(contentsOf: fileURL)
        let prepared = try StorageUploadPolicy.prepareFileData(
            fileData,
            originalFileName: fileName,
            declaredContentType: nil,
            family: .workFile,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow()
        )
        let filePath = "organizations/\(organizationId)/tasks/\(taskId.uuidString)/files/\(prepared.objectName)"
        return try await putStorageData(prepared.data, path: filePath, contentType: prepared.contentType)
    }

    func uploadHealthSafetyFile(
        _ localFileURL: URL,
        organizationId: String,
        projectId: UUID,
        category: String,
        fileName: String
    ) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }

        let safeCategory = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let fileData = try Data(contentsOf: localFileURL)
        let prepared = try StorageUploadPolicy.prepareFileData(
            fileData,
            originalFileName: fileName,
            declaredContentType: nil,
            family: .workFile,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow()
        )
        let path = "organizations/\(organizationId)/healthSafety/\(projectId.uuidString)/\(safeCategory)/\(prepared.objectName)"
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = prepared.contentType
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(prepared.data, metadata: metadata) { metadata, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }

        do {
            let downloadURL = try await storageRef.downloadURL()
            return downloadURL.absoluteString
        } catch {
            print("⚠️ [HealthSafety] Uploaded file but could not fetch download URL: \(error.localizedDescription)")
            return "gs://\(storageRef.bucket)/\(storageRef.fullPath)"
        }
    }
    
    func uploadTaskImage(_ image: UIImage, taskId: UUID, organizationId: String) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
        }
        let prepared = try StorageUploadPolicy.prepareImage(
            image,
            family: .taskImage,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow(),
            initialQuality: 0.8,
            encodeFailedMessage: "Failed to process image",
            oversizedMessage: "Image is too large. It must be 10 MB or smaller."
        )
        let imagePath = "organizations/\(organizationId)/tasks/\(taskId.uuidString)/images/\(prepared.objectName)"
        let storageRef = storage.reference().child(imagePath)
        let imageData = prepared.data
        
        // Upload image using async/await wrapper
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(imageData, metadata: metadata) { metadata, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        
        // Get download URL
        let downloadURL = try await storageRef.downloadURL()
        return downloadURL.absoluteString
    }

    /// Site audit photos (not task attachments). Keeps Storage paths aligned with Firestore `siteAudits` for clearer rules later.
    func uploadSiteAuditImage(_ image: UIImage, auditId: UUID, organizationId: String) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let uploadImage = SiteAuditMediaProcessor.preparedForUpload(image)
        let prepared = try StorageUploadPolicy.prepareImage(
            uploadImage,
            family: .siteAuditPhoto,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow(),
            initialQuality: 0.72,
            encodeFailedMessage: "Failed to process image",
            oversizedMessage: "Site audit photo is too large. It must be 10 MB or smaller."
        )
        let imagePath = "organizations/\(organizationId)/siteAudits/\(auditId.uuidString)/images/\(prepared.objectName)"
        let imageData = prepared.data
        let storageRef = storage.reference().child(imagePath)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(imageData, metadata: metadata) { metadata, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        do {
            let downloadURL = try await storageRef.downloadURL()
            return downloadURL.absoluteString
        } catch {
            // Do not block Site Audit submission/PDF generation if public URL generation is denied.
            // We keep a durable Storage URI that can be resolved later with authenticated SDK access.
            print("⚠️ [SiteAudit] Uploaded image but could not fetch download URL: \(error.localizedDescription)")
            return "gs://\(storageRef.bucket)/\(storageRef.fullPath)"
        }
    }

    /// Profile photo for a user (managed from Manage Users). Overwrites prior object at this path.
    func uploadUserProfilePhoto(_ image: UIImage, userId: String, organizationId: String) async throws -> String {
        guard currentUser?.uid != nil else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let prepared = try StorageUploadPolicy.prepareImage(
            image,
            family: .profilePhoto,
            uid: currentUser?.uid ?? userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow(),
            initialQuality: 0.82,
            encodeFailedMessage: "Failed to process image",
            oversizedMessage: "Profile photo is too large. It must be 2 MB or smaller."
        )
        let path = "organizations/\(organizationId)/userProfiles/\(userId)/\(StorageUploadPolicy.profileObjectName)"
        let imageData = prepared.data
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(imageData, metadata: metadata) { metadata, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        let downloadURL = try await storageRef.downloadURL()
        return downloadURL.absoluteString
    }

    func uploadOrganizationLogoFile(_ data: Data, fileName: String, organizationId: String) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let prepared = try StorageUploadPolicy.prepareFileData(
            data,
            originalFileName: fileName,
            declaredContentType: nil,
            family: .companyLogo,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow()
        )
        let path = "organizations/\(organizationId)/branding/company_logo/\(prepared.objectName)"
        return try await putStorageData(prepared.data, path: path, contentType: prepared.contentType)
    }

    func uploadOrganizationLogo(_ image: UIImage, organizationId: String) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let prepared = try StorageUploadPolicy.prepareImage(
            image,
            family: .companyLogo,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow(),
            initialQuality: 0.75,
            encodeFailedMessage: "Failed to process logo image",
            oversizedMessage: "Company logo is too large. It must be 5 MB or smaller."
        )
        let path = "organizations/\(organizationId)/branding/company_logo/\(prepared.objectName)"
        let imageData = prepared.data
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(imageData, metadata: metadata) { metadata, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        let downloadURL = try await storageRef.downloadURL()
        return downloadURL.absoluteString
    }
    
    func uploadQualificationDocument(
        data: Data,
        organizationId: String,
        operativeId: String,
        qualificationId: String,
        fileName: String,
        contentType: String
    ) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let prepared = try StorageUploadPolicy.prepareFileData(
            data,
            originalFileName: fileName,
            declaredContentType: contentType,
            family: .qualificationCertificate,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow()
        )
        guard let path = CanonicalBusinessEngine.qualificationCertificateStoragePath(
            organizationId: organizationId,
            operativeId: operativeId,
            qualificationId: qualificationId,
            fileName: prepared.objectName
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Could not save the certificate. Organisation or qualification is missing."])
        }
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = prepared.contentType
        
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(prepared.data, metadata: metadata) { metadata, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        
        let downloadURL = try await storageRef.downloadURL()
        return downloadURL.absoluteString
    }

    func uploadTimesheetExportPDF(_ data: Data, fileName: String, organizationId: String) async throws -> String {
        if let message = StorageUploadPolicy.timesheetRefusal(data: data, fileName: fileName) {
            let oversize = data.count > StorageUploadPolicy.standardMaxBytes
            throw StorageUploadPolicy.failure(message, oversize: oversize)
        }
        let sanitized = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let stamp = Int(Date().timeIntervalSince1970)
        guard let path = CanonicalBusinessEngine.timesheetExportStoragePath(
            organizationId: organizationId,
            fileName: sanitized,
            stampSeconds: stamp
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Could not store the timesheet export."])
        }
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "application/pdf"
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(data, metadata: metadata) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        return try await storageRef.downloadURL().absoluteString
    }

    func updateOrganizationCompanyLogoURL(_ logoURL: String?) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        var payload: [String: Any] = ["updatedAt": Timestamp(date: Date())]
        if let logoURL, !logoURL.isEmpty {
            payload["companyLogoURL"] = logoURL
        } else {
            payload["companyLogoURL"] = FieldValue.delete()
        }
        try await db.collection("organizations").document(orgId)
            .updateData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))
        guard var org = currentOrganization else { return }
        org.companyLogoURL = (logoURL?.isEmpty == false) ? logoURL : nil
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    private func putStorageData(_ data: Data, path: String, contentType: String) async throws -> String {
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(data, metadata: metadata) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        return try await storageRef.downloadURL().absoluteString
    }
    #else
    func uploadTaskFile(_ fileURL: URL, taskId: UUID, organizationId: String, fileName: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available. Please add FirebaseStorage to your project dependencies via Xcode: File > Add Package Dependencies > https://github.com/firebase/firebase-ios-sdk"])
    }

    func uploadHealthSafetyFile(
        _ localFileURL: URL,
        organizationId: String,
        projectId: UUID,
        category: String,
        fileName: String
    ) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }
    
    func uploadTaskImage(_ image: UIImage, taskId: UUID, organizationId: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available. Please add FirebaseStorage to your project dependencies via Xcode: File > Add Package Dependencies > https://github.com/firebase/firebase-ios-sdk"])
    }

    func uploadSiteAuditImage(_ image: UIImage, auditId: UUID, organizationId: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }

    func uploadUserProfilePhoto(_ image: UIImage, userId: String, organizationId: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }
    
    func uploadQualificationDocument(
        data: Data,
        organizationId: String,
        operativeId: String,
        qualificationId: String,
        fileName: String,
        contentType: String
    ) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }
    #endif
    
    // MARK: - Operative Management

    /// People document write (RULEBOOK 1.6.0 §1, §11): creates the document when the server says it is missing,
    /// otherwise updates only the fields the rulebook's partial-write helper (`writeFields`: `operativeRowWriteFields`,
    /// `managerRowWriteFields`, `clientWriteFields`, `subcontractorWriteFields`) names — against `previousPayload`
    /// when the caller has the copy it edited, else the server copy — with `WriteMetadata`. Never rewrites the
    /// whole document and never deletes a field the copy lacks.
    func writeChangedRosterRow(
        _ ref: DocumentReference,
        payload: [String: Any],
        previousPayload: [String: Any]?,
        writeFields: String = "operativeRowWriteFields",
        mode: RecordSaveMode? = nil
    ) async throws {
        let uid = auth.currentUser?.uid
        let snapshot = try await ref.getDocument(source: .server)
        let storedData = snapshot.exists ? snapshot.data() : nil
        // An edit (`mode: .update`) of a document that is gone was deleted on another device: refuse it and never
        // re-create it with setData. Only a genuine create (`.create`), or the legacy upsert (nil), creates.
        switch RecordWritePlan.action(mode: mode, documentExists: storedData != nil) {
        case .refuseDeletedElsewhere:
            throw RecordDeletedElsewhereError(collection: ref.parent.collectionID, documentId: ref.documentID)
        case .create:
            let createPayload = payload.filter { !($0.value is FieldValue) && !($0.value is NSNull) }
            try await ref.setData(WriteMetadata.stamped(createPayload, userId: uid))
            return
        case .update:
            break
        }
        guard let stored = storedData else { return }
        guard let write = CanonicalBusinessEngine.peopleDocumentWrite(writeFields, before: previousPayload ?? stored, next: payload) else {
            throw CanonicalWriteUnavailableError(function: writeFields)
        }
        var changes = write.firestoreFields(from: payload)
        changes.removeValue(forKey: "updatedAt")
        guard !changes.isEmpty else { return }
        try await ref.updateData(WriteMetadata.stamped(changes, userId: uid))
    }

    private static func operativeDocumentPayload(_ operative: Operative, organizationId: String) -> [String: Any] {
        var data: [String: Any] = [
            "firstName": operative.firstName,
            "lastName": operative.lastName,
            "name": operative.name, // Keep for backward compatibility
            "email": operative.email,
            "phone": operative.phone ?? "",
            "startDate": Timestamp(date: operative.startDate),
            "skills": Array(operative.skills),
            "qualifications": operative.qualifications.map { qualification in
                var qualificationData: [String: Any] = [
                    "id": qualification.id,
                    "name": qualification.name,
                    "hasEndDate": qualification.hasEndDate,
                    "createdAt": Timestamp(date: qualification.createdAt),
                    "updatedAt": Timestamp(date: qualification.updatedAt)
                ]
                if let endDate = qualification.endDate {
                    qualificationData["endDate"] = Timestamp(date: endDate)
                }
                return qualificationData
            },
            "isActive": operative.isActive,
            "currencySymbol": operative.currencySymbol ?? OrgMoney.symbol(),
            "notes": operative.notes ?? "",
            "tradeTypePreset": operative.tradeTypePreset ?? "",
            "tradeTypeCustom": operative.tradeTypeCustom ?? "",
            "qualificationExpiryDates": Dictionary(uniqueKeysWithValues: operative.qualificationExpiryDates.map { ($0.key, Timestamp(date: $0.value)) }),
            "qualificationCertificateURLs": Dictionary(uniqueKeysWithValues: operative.qualificationCertificateURLs.map { ($0.key, $0.value) }),
            "organizationId": organizationId,
            "createdAt": Timestamp(date: operative.createdAt)
        ]
        // RULEBOOK §8: `payBasis` plus exactly one amount (`exclusiveRates`); a missing rate is removed, never
        // written as 0 (0 is a real rate). An hourly row stays hourly.
        for (key, value) in exclusivePayFields(payBasis: operative.storedPayBasis, amount: operative.storedPayAmount) {
            data[key] = value
        }
        return data
    }

    /// Partial write of `operatives/{id}`: only the fields that changed (against `previous` when the caller
    /// has the copy it edited, else the server document), plus `WriteMetadata`. A new row is created whole.
    func saveOperative(_ operative: Operative, organizationId: String, mode: RecordSaveMode, previous: Operative? = nil) async throws {
        print("🔥🔥🔥 DEBUG: saveOperative called with organizationId: \(organizationId)")
        print("🔥🔥🔥 DEBUG: Operative details - Name: \(operative.name), document: \(operative.documentId)")
        let data = Self.operativeDocumentPayload(operative, organizationId: organizationId)
        let previousData = previous.map { Self.operativeDocumentPayload($0, organizationId: organizationId) }
        // The stored document id (stored case; a non-UUID id is kept), never the in-memory UUID.
        let ref = db.collection("organizations").document(organizationId).collection("operatives").document(operative.documentId)
        do {
            try await writeChangedRosterRow(ref, payload: data, previousPayload: previousData, writeFields: "operativeRowWriteFields", mode: mode)
            print("🔥🔥🔥 DEBUG: Operative saved successfully to Firebase")
        } catch {
            print("🔥🔥🔥 DEBUG: ERROR saving operative: \(error.localizedDescription)")
            throw error
        }
    }

    /// Merges qualification maps onto the operative document. Other fields stay.
    /// `operativeDocumentId` is the stored document id (`Operative.documentId`), never the in-memory UUID.
    func patchOperativeQualificationMaps(
        operativeDocumentId: String,
        organizationId: String,
        write: CanonicalBusinessEngine.CanonicalOperativeQualificationMaps
    ) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let qualifications: [[String: Any]] = write.qualifications.map { row in
            var fields: [String: Any] = [
                "id": row.id,
                "name": row.name,
                "hasEndDate": row.hasEndDate,
                "createdAt": Timestamp(date: CanonicalBusinessEngine.date(fromIso: row.createdAtIso) ?? Date()),
                "updatedAt": Timestamp(date: CanonicalBusinessEngine.date(fromIso: row.updatedAtIso) ?? Date()),
            ]
            if let endDateIso = row.endDateIso, let endDate = CanonicalBusinessEngine.date(fromIso: endDateIso) {
                fields["endDate"] = Timestamp(date: endDate)
            }
            return fields
        }
        let expiry = write.qualificationExpiryDates.reduce(into: [String: Timestamp]()) { dates, entry in
            if let date = CanonicalBusinessEngine.date(fromIso: entry.value) {
                dates[entry.key] = Timestamp(date: date)
            }
        }
        let payload: [String: Any] = [
            "qualifications": qualifications,
            "qualificationExpiryDates": expiry,
            "qualificationCertificateURLs": write.qualificationCertificateURLs,
            "updatedAt": Timestamp(date: Date()),
        ]
        try await db.collection("organizations").document(orgId).collection("operatives").document(operativeDocumentId).setData(payload, merge: true)
    }
    
    /// `documentId` is the stored operative document id (`Operative.documentId`, stored case), never the in-memory UUID.
    func deleteOperative(documentId: String, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteOperative called for operative: \(documentId), organization: \(organizationId)")
        
        // RULEBOOK 1.7.0 §2 (`bookingsToRemoveOnOperativeDelete`): only this person's bookings from today on are
        // removed, each with its tombstone; past bookings stay for timesheets and reports. (Every booking used to
        // be deleted, without tombstones.) A booking the rules refuse to delete is logged and left in place.
        let bookingsSnapshot = try await db.collection("organizations").document(organizationId).collection("bookings")
            .whereField("operativeId", isEqualTo: documentId)
            .getDocuments()
        let bookings = bookingsFromFirestoreDocuments(bookingsSnapshot.documents)
        let removeIds = CanonicalBusinessEngine.bookingsToRemoveOnOperativeDelete(
            bookings.map {
                CanonicalBusinessEngine.CanonicalRemovableBooking(
                    id: $0.documentKey,
                    operativeId: $0.storedOperativeId,
                    dateMs: $0.date.timeIntervalSince1970 * 1000
                )
            },
            operativeIds: [documentId],
            now: Date()
        ) ?? []
        print("🔥🔥🔥 DEBUG: \(removeIds.count) of \(bookings.count) bookings for operative are from today on")
        for bookingId in removeIds {
            do {
                try await deleteBookingWithTombstone(collection: "bookings", bookingId: bookingId, organizationId: organizationId)
            } catch {
                print("🔥🔥🔥 DEBUG: booking \(bookingId) not removed: \(error.localizedDescription)")
            }
        }
        
        // Delete the operative
        try await db.collection("organizations").document(organizationId).collection("operatives").document(documentId).delete()
        print("🔥🔥🔥 DEBUG: Operative deleted from Firebase")
    }
    
    func loadOperatives(organizationId: String) async throws -> [Operative] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Starting load for organization: \(orgId)")
        let operativesRef = db.collection("organizations").document(orgId).collection("operatives")
        let snapshot = try await getDocumentsPreferringServer(operativesRef)
        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Found \(snapshot.documents.count) operative documents")
        
        let loaded = Self.operatives(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) })
        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Keeping \(loaded.count) real operatives (placeholders skipped)")
        return loaded
    }

    /// RULEBOOK 1.6.0 §1 "Document readers": `operatives/{id}` rows are read only through the rulebook's
    /// `parseOperativeDocument` (web uses the same reader). The document id is kept in stored case (a non-UUID id
    /// is kept, never randomised), an hourly row stays hourly (`payBasis`), a nameless row with an email is kept,
    /// and legacy placeholder rows (`isPlaceholder`) are skipped. Tests call this with raw documents.
    static func operatives(fromDocuments documents: [(id: String, data: [String: Any])]) -> [Operative] {
        documents.compactMap { doc -> Operative? in
            guard let row = CanonicalBusinessEngine.parseOperativeDocument(documentId: doc.id, data: doc.data) else {
                return nil
            }
            if row.bool("isPlaceholder") { return nil }
            return operative(fromCanonical: row)
        }
    }

    /// One `parseOperativeDocument` row as an `Operative`. `id` is the stable in-app UUID for the stored id
    /// (`Booking.internalOperativeId`, so bookings, history and pickers that name this id agree); `documentId`
    /// is the stored id every write addresses.
    static func operative(fromCanonical row: CanonicalDocumentRow) -> Operative {
        let documentId = row.id
        let id = Booking.internalOperativeId(for: documentId)
        if documentId != id.uuidString {
            // A lower-case UUID (web) keeps its stored case when a booking or history row names this person.
            OperativeKeyRegistry.shared.remember(raw: documentId, as: id)
        }
        let epoch = Date(timeIntervalSince1970: 0)
        let qualifications: [Qualification] = row.rows("qualifications").compactMap { entry in
            guard !entry.id.isEmpty, !entry.text("name").isEmpty else { return nil }
            return Qualification(
                id: entry.id,
                name: entry.text("name"),
                hasEndDate: entry.bool("hasEndDate"),
                endDate: entry.date("endDateMs"),
                createdAt: entry.date("createdAtMs") ?? epoch,
                updatedAt: entry.date("updatedAtMs") ?? entry.date("createdAtMs") ?? epoch
            )
        }
        var expiry: [String: Date] = [:]
        for (key, value) in row.map("qualificationExpiryDates") {
            if let ms = (value as? NSNumber)?.doubleValue { expiry[key] = Date(timeIntervalSince1970: ms / 1000) }
        }
        var certificates: [String: String] = [:]
        for (key, value) in row.map("qualificationCertificateURLs") {
            if let url = value as? String { certificates[key] = url }
        }
        var operative = Operative(
            id: id,
            firstName: row.text("firstName"),
            lastName: row.text("lastName"),
            email: row.text("email"),
            phone: row.optionalText("phone"),
            startDate: row.date("startDateMs") ?? row.date("createdAtMs") ?? Date(),
            skills: Set(row.strings("skills")),
            qualifications: qualifications,
            qualificationExpiryDates: expiry,
            qualificationCertificateURLs: certificates,
            isActive: row.bool("isActive", default: true),
            hourlyRate: row.number("hourlyRate"),
            dayRate: row.number("dayRate"),
            currencySymbol: row.optionalText("currencySymbol"),
            notes: row.optionalText("notes"),
            tradeTypePreset: row.optionalText("tradeTypePreset"),
            tradeTypeCustom: row.optionalText("tradeTypeCustom"),
            createdAt: row.date("createdAtMs") ?? Date(),
            updatedAt: row.date("updatedAtMs") ?? Date()
        )
        operative.firestoreDocumentId = documentId
        operative.payBasis = row.optionalText("payBasis")
        operative.linkedUserId = row.optionalText("linkedUserId")
        return operative
    }
    
    // MARK: - Debug Functions
    
    func debugFirebaseData() async {
        print("🔥🔥🔥 DEBUG: === Firebase Debug Info ===")
        print("🔥🔥🔥 DEBUG: isAuthenticated: \(isAuthenticated)")
        print("🔥🔥🔥 DEBUG: currentUser: \(currentUser?.email ?? "nil")")
        print("🔥🔥🔥 DEBUG: currentOrganization: \(currentOrganization?.name ?? "nil")")
        print("🔥🔥🔥 DEBUG: organizationId: \(currentOrganization?.firestoreDocumentId ?? "nil")")
        
        if let organizationId = currentOrganization?.firestoreDocumentId {
            do {
                let projects = try await loadProjects(organizationId: organizationId)
                print("🔥🔥🔥 DEBUG: Projects in Firebase: \(projects.count)")
                for project in projects {
                    print("🔥🔥🔥 DEBUG: - \(project.siteName) (\(project.jobNumber))")
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Error loading projects: \(error.localizedDescription)")
            }
        }
        print("🔥🔥🔥 DEBUG: === End Debug Info ===")
    }
    
    func testProjectSave() async {
        print("🔥🔥🔥 DEBUG: === Testing Project Save ===")
        
        guard let organizationId = currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: No organization ID available")
            return
        }
        
        // Create a test project
        let testProject = Project(
            jobNumber: "TEST-001",
            siteName: "Test Site",
            siteAddress: "123 Test Street",
            client: Client(
                name: "Test Client",
                email: "test@example.com",
                phone: "123-456-7890"
            ),
            startDate: Date(),
            endDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date(),
            jobType: .catA,
            manager: .na,
            isLive: true,
            description: "Test project for debugging"
        )
        
        do {
            try await saveProject(testProject, organizationId: organizationId, mode: .create)
            print("🔥🔥🔥 DEBUG: Test project saved successfully!")
            
            // Try to load it back
            let projects = try await loadProjects(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: Projects after test save: \(projects.count)")
            if let foundProject = projects.first(where: { $0.jobNumber == "TEST-001" }) {
                print("🔥🔥🔥 DEBUG: Test project found: \(foundProject.siteName)")
            } else {
                print("🔥🔥🔥 DEBUG: Test project NOT found in loaded projects")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error saving test project: \(error.localizedDescription)")
        }
        
        print("🔥🔥🔥 DEBUG: === End Test Project Save ===")
    }
    
    func testDataPersistence() async {
        print("🔥🔥🔥 DEBUG: === Testing Data Persistence ===")
        
        guard let organizationId = currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: No organization ID available for testing")
            return
        }
        
        print("🔥🔥🔥 DEBUG: Testing with organization ID: \(organizationId)")
        
        // Test project save
        let testProject = Project(
            jobNumber: "PERSISTENCE-TEST",
            siteName: "Persistence Test Site",
            siteAddress: "456 Test Avenue",
            client: Client(
                name: "Persistence Test Client",
                email: "persistence@test.com",
                phone: "555-123-4567"
            ),
            startDate: Date(),
            endDate: Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date(),
            jobType: .catB,
            manager: .na,
            isLive: true,
            description: "Testing data persistence to Firebase"
        )
        
        do {
            // Save the test project
            try await saveProject(testProject, organizationId: organizationId, mode: .create)
            print("🔥🔥🔥 DEBUG: Test project saved to Firebase")
            
            // Wait a moment for Firebase to process
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Try to load it back
            let loadedProjects = try await loadProjects(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: Loaded \(loadedProjects.count) projects from Firebase")
            
            if let foundProject = loadedProjects.first(where: { $0.jobNumber == "PERSISTENCE-TEST" }) {
                print("🔥🔥🔥 DEBUG: ✅ SUCCESS: Test project found in Firebase!")
                print("🔥🔥🔥 DEBUG: Project details: \(foundProject.siteName) - \(foundProject.client.name)")
            } else {
                print("🔥🔥🔥 DEBUG: ❌ FAILED: Test project NOT found in Firebase")
                print("🔥🔥🔥 DEBUG: Available projects:")
                for project in loadedProjects {
                    print("🔥🔥🔥 DEBUG: - \(project.jobNumber): \(project.siteName)")
                }
            }
        } catch {
            print("🔥🔥🔥 DEBUG: ❌ ERROR during persistence test: \(error.localizedDescription)")
        }
        
        print("🔥🔥🔥 DEBUG: === End Data Persistence Test ===")
    }
    
    func debugOrganizations() async {
        print("🔥🔥🔥 DEBUG: === Listing Organisations for current user ===")
        guard let userId = currentUser?.uid else {
            print("🔥🔥🔥 DEBUG: No signed-in user")
            return
        }
        do {
            let memberships = try await loadOrganizationMembershipDocuments(userId: userId)
            print("🔥🔥🔥 DEBUG: Found \(memberships.count) organisations for this user")
            for item in memberships {
                print("🔥🔥🔥 DEBUG: Organization ID: \(item.id)")
                print("🔥🔥🔥 DEBUG: Organization Name: \(item.data["name"] ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Role: \(item.role)")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error fetching organizations: \(error.localizedDescription)")
        }
        print("🔥🔥🔥 DEBUG: === End Organizations List ===")
    }
    
    func debugUsers() async {
        print("🔥🔥🔥 DEBUG: === Listing Users in current organisation ===")
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: No current organisation")
            return
        }
        do {
            let snapshot = try await db.collection("users")
                .whereField("organizationId", isEqualTo: orgId)
                .limit(to: 100)
                .getDocuments()
            print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) users")
            for document in snapshot.documents {
                let data = document.data()
                print("🔥🔥🔥 DEBUG: User ID: \(document.documentID) email: \(data["email"] ?? "N/A")")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error fetching users: \(error.localizedDescription)")
        }
        print("🔥🔥🔥 DEBUG: === End Users List ===")
    }
    
        func debugProjects() async {
            print("🔥🔥🔥 DEBUG: === Listing All Projects ===")
            print("🔥🔥🔥 DEBUG: Function called successfully!")
            
            guard let organizationId = currentOrganization?.firestoreDocumentId else {
                print("🔥🔥🔥 DEBUG: No organization ID available")
                return
            }
            
            do {
                print("🔥🔥🔥 DEBUG: Attempting to fetch projects for organization: \(organizationId)")
                let snapshot = try await db.collection("organizations").document(organizationId).collection("projects").getDocuments(source: .server)
                print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) projects")
                
                for document in snapshot.documents {
                    let data = document.data()
                    print("🔥🔥🔥 DEBUG: Project ID: \(document.documentID)")
                    print("🔥🔥🔥 DEBUG: Site Name: \(data["siteName"] ?? "N/A")")
                    print("🔥🔥🔥 DEBUG: Job Number: \(data["jobNumber"] ?? "N/A")")
                    print("---")
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Error fetching projects: \(error.localizedDescription)")
            }
            
            print("🔥🔥🔥 DEBUG: === End Projects List ===")
        }
        
        // MARK: - Manager Operations
        
        private static func managerDocumentPayload(_ manager: Manager, organizationId: String) -> [String: Any] {
            [
                "firstName": manager.firstName,
                "lastName": manager.lastName,
                "email": manager.email,
                "mobileNumber": manager.mobileNumber,
                "department": manager.department ?? "",
                "isActive": manager.isActive,
                "notes": manager.notes ?? "",
                "tradeTypePreset": manager.tradeTypePreset ?? "",
                "tradeTypeCustom": manager.tradeTypeCustom ?? "",
                "organizationId": organizationId,
                "createdAt": Timestamp(date: manager.createdAt)
            ]
        }

        /// Partial write of `managers/{id}`: only changed fields plus `WriteMetadata` (a new row is created).
        /// It never replaces the document, so pay fields another platform stored on the row stay.
        func saveManager(_ manager: Manager, organizationId: String, mode: RecordSaveMode, previous: Manager? = nil) async throws {
            print("🔥🔥🔥 DEBUG: saveManager called with organizationId: \(organizationId)")
            let data = Self.managerDocumentPayload(manager, organizationId: organizationId)
            let previousData = previous.map { Self.managerDocumentPayload($0, organizationId: organizationId) }
            let documentId = manager.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines)
            let storageId = documentId.isEmpty ? manager.id.uuidString : documentId
            print("🔥🔥🔥 DEBUG: Saving manager to organizations/\(organizationId)/managers/\(storageId)")
            let ref = db.collection("organizations").document(organizationId).collection("managers").document(storageId)
            try await writeChangedRosterRow(ref, payload: data, previousPayload: previousData, writeFields: "managerRowWriteFields", mode: mode)
            print("🔥🔥🔥 DEBUG: Manager saved successfully to Firebase")
        }

        /// Updates manager index documents that already use this email. Does not create a document.
        func updateManagerIdentityInPlace(
            organizationId: String,
            previousEmail: String,
            firstName: String,
            lastName: String,
            email: String,
            mobileNumber: String
        ) async throws {
            let orgId = normalizedOrganizationId(organizationId)
            let previous = previousEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let next = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !orgId.isEmpty, !previous.isEmpty, !next.isEmpty else { return }
            let snapshot = try await getDocumentsPreferringServer(
                db.collection("organizations").document(orgId).collection("managers")
            )
            var updated = 0
            for doc in snapshot.documents {
                let stored = ((doc.data()["email"] as? String) ?? "")
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard stored == previous || stored == next else { continue }
                try await doc.reference.updateData([
                    "firstName": firstName,
                    "lastName": lastName,
                    "email": next,
                    "mobileNumber": mobileNumber,
                    "updatedAt": Timestamp(date: Date())
                ])
                updated += 1
            }
            print("🔥🔥🔥 DEBUG: Updated \(updated) existing manager document(s) for \(previous)")
        }
        
        func loadManagers(organizationId: String) async throws -> [Manager] {
            let orgId = try await ensureReadableOrganization(organizationId)
            print("🔥🔥🔥 DEBUG: [LOAD MANAGERS] Starting load for organization: \(orgId)")
            let snapshot = try await getDocumentsPreferringServer(
                db.collection("organizations").document(orgId).collection("managers")
            )
            print("🔥🔥🔥 DEBUG: [LOAD MANAGERS] Found \(snapshot.documents.count) manager documents")
            
            return Self.managers(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) })
    }

    /// RULEBOOK 1.6.0 §1 "Document readers": `managers/{id}` rows are read only through the rulebook's
    /// `parseManagerDocument`: stored-case document id, names from either key, mobile from `mobileNumber` /
    /// `mobile` / `phone`, pay basis with one amount; legacy placeholder rows (`isPlaceholder`) are skipped.
    static func managers(fromDocuments documents: [(id: String, data: [String: Any])]) -> [Manager] {
        documents.compactMap { doc -> Manager? in
            guard let row = CanonicalBusinessEngine.parseManagerDocument(documentId: doc.id, data: doc.data) else {
                print("🔥🔥🔥 DEBUG: Failed to parse manager data for document: \(doc.id)")
                return nil
            }
            if row.bool("isPlaceholder") { return nil }
            let documentId = row.id
            var manager = Manager(
                // RULEBOOK 1.7.0: remembered so a job save writes this manager's stored id back.
                id: WorkDocumentKeys.inAppId(for: documentId),
                firstName: row.text("firstName"),
                lastName: row.text("lastName"),
                email: row.text("email"),
                mobileNumber: row.text("mobile"),
                department: row.optionalText("department"),
                isActive: row.bool("isActive", default: true),
                notes: row.optionalText("notes"),
                tradeTypePreset: row.optionalText("tradeTypePreset"),
                tradeTypeCustom: row.optionalText("tradeTypeCustom"),
                createdAt: row.date("createdAtMs") ?? Date(),
                updatedAt: row.date("updatedAtMs") ?? Date(),
                firestoreDocumentId: documentId
            )
            manager.payBasis = row.optionalText("payBasis")
            manager.dayRate = row.number("dayRate")
            manager.hourlyRate = row.number("hourlyRate")
            manager.linkedUserId = row.optionalText("linkedUserId")
            return manager
        }
    }
    
    func deleteManager(_ manager: Manager, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteManager called for manager: \(manager.fullName), organization: \(organizationId)")
        let documentId = manager.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageId = documentId.isEmpty ? manager.id.uuidString : documentId
        try await db.collection("organizations").document(organizationId).collection("managers").document(storageId).delete()
        print("🔥🔥🔥 DEBUG: Manager deleted successfully from Firebase")
    }
    
    /// Template document fields. Always writes name, hasEndDate, createdAt, and updatedAt.
    /// Library extras are added when the template has them. A merge write does not delete assignments.
    static func qualificationTemplateFirestoreFields(_ qualification: Qualification, updatedAt: Date? = nil) -> [String: Any] {
        var fields: [String: Any] = [
            "name": qualification.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "hasEndDate": qualification.hasEndDate,
            "createdAt": Timestamp(date: qualification.createdAt),
            "updatedAt": Timestamp(date: updatedAt ?? qualification.updatedAt),
        ]
        if let endDate = qualification.endDate {
            fields["endDate"] = Timestamp(date: endDate)
        }
        if let code = optionalQualificationText(qualification.code) { fields["code"] = code }
        if let section = optionalQualificationText(qualification.section) { fields["section"] = section }
        if let subsection = optionalQualificationText(qualification.subsection) { fields["subsection"] = subsection }
        if let awardingBody = optionalQualificationText(qualification.awardingBody) { fields["awardingBody"] = awardingBody }
        if let level = qualification.level { fields["level"] = level }
        if let renewYears = qualification.renewYears { fields["renewYears"] = renewYears }
        if let renewalType = optionalQualificationText(qualification.renewalType) { fields["renewalType"] = renewalType }
        if let status = optionalQualificationText(qualification.status) { fields["status"] = status }
        if let notes = optionalQualificationText(qualification.notes) { fields["notes"] = notes }
        return fields
    }

    static func optionalQualificationText(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    static func optionalQualificationNumber(_ value: Any?) -> Double? {
        if value == nil || value is NSNull { return nil }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    static func optionalQualificationInt(_ value: Any?) -> Int? {
        if value == nil || value is NSNull { return nil }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// Writes starter library codes that are not already document ids.
    /// A guided-setup or custom row does not block the rest. Never deletes the collection.
    /// A failure must not undo organisation create.
    func seedStarterQualificationLibraryIfEmpty(organizationId: String) async {
        let items = StarterQualificationLibrary.qualifications()
        guard !items.isEmpty else {
            print("🔥🔥🔥 DEBUG: Starter qualification library is missing from the app bundle")
            return
        }
        let collection = db.collection("organizations").document(organizationId).collection("qualifications")
        do {
            let existing = try await collection.getDocuments()
            guard let missingCodes = CanonicalBusinessEngine.missingStarterQualificationCodes(
                existingDocumentIds: existing.documents.map(\.documentID),
                libraryCodes: items.map(\.id)
            ) else {
                print("🔥🔥🔥 DEBUG: Starter qualification seed skipped: the shared script did not return missing codes")
                return
            }
            let missingIds = Set(missingCodes)
            let missing = items.filter { missingIds.contains($0.id) }
            if missing.isEmpty { return }
            let batchSize = 400
            var index = 0
            while index < missing.count {
                let end = min(index + batchSize, missing.count)
                let batch = db.batch()
                for item in missing[index..<end] {
                    batch.setData(
                        Self.qualificationTemplateFirestoreFields(item),
                        forDocument: collection.document(item.id),
                        merge: true
                    )
                }
                try await batch.commit()
                index = end
            }
            try await db.collection("organizations").document(organizationId).updateData([
                "starterQualificationLibraryVersion": StarterQualificationLibrary.version,
                "updatedAt": Timestamp(date: Date()),
            ])
            print("🔥🔥🔥 DEBUG: Seeded \(missing.count) starter qualifications for \(organizationId)")
        } catch {
            print("🔥🔥🔥 DEBUG: Starter qualification seed skipped: \(error.localizedDescription)")
        }
    }

    func saveQualifications(organizationId: String, qualifications: [Qualification]) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let qualsRef = db.collection("organizations").document(orgId).collection("qualifications")
        let existingSnapshot: QuerySnapshot
        do {
            existingSnapshot = try await qualsRef.getDocuments(source: .server)
        } catch {
            existingSnapshot = try await qualsRef.getDocuments(source: .cache)
        }

        if qualifications.isEmpty && !existingSnapshot.documents.isEmpty {
            print("🔥🔥🔥 DEBUG: Refusing to overwrite qualifications with an empty list")
            return
        }

        let batch = db.batch()
        for qualification in qualifications {
            let docRef = qualsRef.document(qualification.id)
            batch.setData(Self.qualificationTemplateFirestoreFields(qualification), forDocument: docRef, merge: true)
        }
        try await batch.commit()
        print("🔥🔥🔥 DEBUG: Successfully saved \(qualifications.count) qualifications to Firebase")
    }

    func saveQualification(_ qualification: Qualification, organizationId: String) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let docRef = db.collection("organizations").document(orgId).collection("qualifications").document(qualification.id)
        var fields = Self.qualificationTemplateFirestoreFields(qualification)
        fields["updatedAt"] = Timestamp(date: Date())
        try await docRef.setData(fields, merge: true)
    }

    func deleteQualification(_ qualificationId: String, organizationId: String) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        try await db.collection("organizations").document(orgId).collection("qualifications").document(qualificationId).delete()
    }
    
    /// RULEBOOK 1.6.0 §1, §11: the skills catalogue is saved with the rulebook's `skillsCatalogueWrites` — a partial
    /// write of the name / trade that changed per skill, and a delete only for a skill missing from a list that came
    /// from a successful load (`loaded`) and is not empty. Never delete-all and rewrite.
    func saveSkills(organizationId: String, skills: [OrganizationSkill], loaded: Bool) async throws {
        let skillsRef = db.collection("organizations").document(organizationId).collection("skills")
        let existingSnapshot = try await skillsRef.getDocuments(source: .server)
        let stored: [(id: String, name: String, trade: String)] = existingSnapshot.documents.map { doc in
            guard let row = CanonicalBusinessEngine.parseSkillDocument(documentId: doc.documentID, data: doc.data()) else {
                return (id: doc.documentID, name: "", trade: "")
            }
            return (id: row.id, name: row.text("name"), trade: row.text("trade"))
        }
        let next = skills.map { (id: $0.id, name: $0.name, trade: $0.trade) }
        guard let plan = CanonicalBusinessEngine.skillsCatalogueWrites(stored: stored, next: next, loaded: loaded) else {
            throw CanonicalWriteUnavailableError(function: "skillsCatalogueWrites")
        }
        guard !plan.write.isEmpty || !plan.remove.isEmpty else { return }
        let storedIds = Set(existingSnapshot.documents.map(\.documentID))
        let uid = auth.currentUser?.uid
        let batch = db.batch()
        for id in plan.remove {
            batch.deleteDocument(skillsRef.document(id))
        }
        for write in plan.write {
            let docRef = skillsRef.document(write.id)
            if storedIds.contains(write.id) {
                batch.updateData(WriteMetadata.stamped(write.set, userId: uid), forDocument: docRef)
            } else {
                var created = write.set
                created["createdAt"] = Timestamp(date: Date())
                batch.setData(WriteMetadata.stamped(created, userId: uid), forDocument: docRef)
            }
        }
        try await batch.commit()
        print("🔥🔥🔥 DEBUG: Saved organisation skills: \(plan.write.count) written, \(plan.remove.count) removed")
    }
    
    func loadQualifications(organizationId: String) async throws -> [Qualification] {
        let orgId = try await ensureReadableOrganization(organizationId)
        await seedStarterQualificationLibraryIfEmpty(organizationId: orgId)
        let snapshot = try await getDocumentsPreferringServer(
            db.collection("organizations").document(orgId).collection("qualifications")
        )
        
        var qualifications: [Qualification] = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                print("🔥🔥🔥 DEBUG: Failed to parse qualification data for document: \(doc.documentID)")
                continue
            }
            
            let hasEndDate = data["hasEndDate"] as? Bool ?? false
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt
            let endDate = (data["endDate"] as? Timestamp)?.dateValue()

            let qualification = Qualification(
                id: doc.documentID,
                name: name,
                hasEndDate: hasEndDate,
                endDate: endDate,
                createdAt: createdAt,
                updatedAt: updatedAt,
                code: Self.optionalQualificationText(data["code"]),
                section: Self.optionalQualificationText(data["section"]),
                subsection: Self.optionalQualificationText(data["subsection"]),
                awardingBody: Self.optionalQualificationText(data["awardingBody"]),
                level: Self.optionalQualificationInt(data["level"]),
                renewYears: Self.optionalQualificationNumber(data["renewYears"]),
                renewalType: Self.optionalQualificationText(data["renewalType"]),
                status: Self.optionalQualificationText(data["status"]),
                notes: Self.optionalQualificationText(data["notes"])
            )
            
            qualifications.append(qualification)
        }
        
        return qualifications.sorted { $0.name < $1.name }
    }
    
    func loadSkills(organizationId: String) async throws -> [OrganizationSkill] {
        let orgId = try await ensureReadableOrganization(organizationId)
        let snapshot = try await db.collection("organizations").document(orgId).collection("skills").getDocuments(source: .server)
        
        // RULEBOOK 1.6.0 §1 "Document readers": `parseSkillDocument` (a missing trade stays '').
        var skills: [OrganizationSkill] = snapshot.documents.compactMap { doc in
            guard let row = CanonicalBusinessEngine.parseSkillDocument(documentId: doc.documentID, data: doc.data()) else { return nil }
            let createdAt = row.date("createdAtMs") ?? Date()
            return OrganizationSkill(
                id: row.id,
                name: row.text("name"),
                trade: row.text("trade"),
                createdAt: createdAt,
                updatedAt: row.date("updatedAtMs") ?? createdAt
            )
        }
        skills.sort {
            if $0.trade.localizedCaseInsensitiveCompare($1.trade) != .orderedSame {
                return $0.trade.localizedCaseInsensitiveCompare($1.trade) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        print("🔥🔥🔥 DEBUG: Loaded \(skills.count) organisation skills from Firebase")
        return skills
    }
    
    func deleteOperative(operativeId: UUID) async {
        guard let organizationId = currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: No organization ID available for deleting operative")
            return
        }
        
        do {
            try await db.collection("organizations").document(organizationId).collection("operatives").document(Booking.storedOperativeId(for: operativeId)).delete()
            print("🔥🔥🔥 DEBUG: Successfully deleted operative \(operativeId) from Firebase")
        } catch {
            print("🔥🔥🔥 DEBUG: Error deleting operative from Firebase: \(error)")
        }
    }
    
    // MARK: - User Management Methods
    
    func getUserData(userId: String) async throws -> AppUser? {
        let doc = try await getDocumentWithServerTimeoutAndCacheFallback(
            db.collection("users").document(userId)
        )
        
        if !doc.exists {
            // Invited users often have users/{randomUUID} until first sign-in; merge onto Auth UID.
            if let auth = Auth.auth().currentUser, auth.uid == userId, let authEmail = auth.email, !authEmail.isEmpty {
                try await mergePlaceholderUserDocOntoAuthUidIfNeeded(authUid: userId, email: authEmail)
                let retry = try await getDocumentWithServerTimeoutAndCacheFallback(
                    db.collection("users").document(userId)
                )
                guard retry.exists, let data = retry.data() else { return nil }
                return Self.parseAppUserDocument(userId: userId, data: data)
            }
            return nil
        }
        
        guard let data = doc.data() else {
            return nil
        }
        
        return Self.parseAppUserDocument(userId: userId, data: data)
    }

    func observeCurrentUserDocument(
        userId: String,
        onChange: @escaping @MainActor (AppUser?) -> Void
    ) -> ListenerRegistration {
        db.collection("users").document(userId).addSnapshotListener { snapshot, error in
            if let error {
                print("🔥🔥🔥 DEBUG: current user listen error: \(error.localizedDescription)")
                return
            }
            guard let snapshot, snapshot.exists, let data = snapshot.data() else {
                Task { @MainActor in onChange(nil) }
                return
            }
            let parsed = Self.parseAppUserDocument(userId: userId, data: data)
            Task { @MainActor in onChange(parsed) }
        }
    }
    
    /// Copies profile fields from an older `users/*` row in the known company onto `users/{authUid}`.
    /// Does not list every user, and does not copy organisation or privilege fields onto the signed-in document.
    /// Invited user signing in before the invitation's set-password step created users/{authUid}.
    private func mergePlaceholderUserDocOntoAuthUidIfNeeded(authUid: String, email rawEmail: String) async throws {
        let orgId = normalizedOrganizationId(
            currentOrganization?.firestoreDocumentId ?? cachedOrganizationIdString() ?? ""
        )
        guard !orgId.isEmpty else {
            print("🔥🔥🔥 DEBUG: Skipping placeholder merge — no company to scope the email lookup")
            return
        }
        let variants = Array(Set([
            rawEmail,
            rawEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }))
        
        for variant in variants {
            var documents: [DocumentSnapshot] = []
            if let mappedId = await userIdFromUserEmailsDocument(organizationId: orgId, email: variant),
               mappedId != authUid {
                let mapped = try await db.collection("users").document(mappedId).getDocument(source: .server)
                if mapped.exists {
                    documents.append(mapped)
                }
            }
            let scoped = try await db.collection("users")
                .whereField("email", isEqualTo: variant)
                .whereField("organizationId", isEqualTo: orgId)
                .limit(to: 8)
                .getDocuments(source: .server)
            documents.append(contentsOf: scoped.documents)

            var seen = Set<String>()
            for placeholder in documents where placeholder.documentID != authUid && seen.insert(placeholder.documentID).inserted {
                guard let data = placeholder.data(), firestoreBool(data["passwordSet"]) != true else { continue }
                // users/{authUid} is created by the invitation's set-password step (web
                // `completeInviteSetup`), which records the 16-or-over confirmation, moves the tax ids,
                // and writes `formerUserIds`. The app never asks for that confirmation, and the rules
                // (Path 1) refuse a self-create without it, so the app does not create the profile here.
                NSLog("INVITE_SETUP_INCOMPLETE placeholder=%@ authUid=%@ — users/{authUid} is created by the invitation link", placeholder.documentID, authUid)
                throw NSError(
                    domain: "FirebaseBackend",
                    code: 412,
                    userInfo: [NSLocalizedDescriptionKey: "Finish setting up your account from the invitation email (set your password and confirm you are 16 or over), then sign in here."]
                )
            }
        }
    }
    
    /// RULEBOOK 1.6.0 §1 "Document readers", §8: `users/{uid}` is read only through the rulebook's
    /// `parseUserDocument` (web reads it with the same function). Names and legacy keys, role token, permission
    /// defaults, operative mode (a stray flag on an admin is ignored on lists; `operativeModeStored` keeps the
    /// stored flag for the approval rules), line managers (`hasNoLineManager` clears them), pay basis, employment
    /// transition, missing leave fields (the organisation `annualLeaveDefaults`) and missing `timesheetsEnabled`
    /// (`defaultTimesheetsEnabled`) all come from the script. Only the stored `name` / `displayName` strings and the
    /// legacy tax ids (moved to `users/{uid}/private/taxIds`) are read here as stored.
    static func parseAppUserDocument(
        userId: String,
        data: [String: Any],
        annualLeaveDefaults: OrganizationAnnualLeaveDefaults? = OrganizationRulebookContext.annualLeaveDefaults
    ) -> AppUser {
        func storedText(_ key: String) -> String? {
            let text = (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        guard let row = CanonicalBusinessEngine.parseUserDocument(
            documentId: userId,
            data: data,
            annualLeaveDefaults: annualLeaveDefaults
        ) else {
            // The script did not answer. No Swift copy of the reader: identity only, no privileges, until it does.
            NSLog("USER_PARSE_FAILED id=%@ — parseUserDocument did not answer", userId)
            var fallback = AppUser(
                id: userId,
                email: storedText("email") ?? "",
                organizationId: organizationIdFromFirestore(data["organizationId"]) ?? "",
                role: .viewer,
                firstName: storedText("firstName") ?? "",
                surname: storedText("surname") ?? storedText("lastName") ?? "",
                isActive: firestoreUserIsActive(from: data),
                passwordSet: true
            )
            fallback.documentName = data["name"] as? String ?? ""
            fallback.documentDisplayName = data["displayName"] as? String ?? ""
            return fallback
        }
        let flags = row.map("permissions")
        func permission(_ key: String) -> Bool { (flags[key] as? Bool) ?? false }
        let permissions = UserPermissions(
            adminAccess: permission("adminAccess"),
            manager: permission("manager"),
            operatives: permission("operatives"),
            skills: permission("skills"),
            qualifications: permission("qualifications"),
            materials: permission("materials"),
            projects: permission("projects"),
            smallWorks: permission("smallWorks"),
            operativeMode: row.bool("operativeMode"),
            annualLeaveSelfBook: permission("annualLeaveSelfBook"),
            weeklyReports: permission("weeklyReports"),
            dailyOverview: permission("dailyOverview"),
            subContractors: permission("subContractors"),
            siteAudit: permission("siteAudit"),
            wholesalersOrderHistory: permission("wholesalersOrderHistory")
        )
        let managerIds = row.strings("assignedManagerUserIds")
        var parsed = AppUser(
            id: userId,
            email: row.text("email"),
            organizationId: organizationIdFromFirestore(row.optionalText("organizationId")) ?? "",
            role: UserRole(rawValue: row.text("role")) ?? .viewer,
            createdAt: row.date("createdAtMs") ?? Date(),
            firstName: row.text("firstName"),
            surname: row.text("surname"),
            mobileNumber: row.optionalText("mobileNumber"),
            isActive: row.bool("isActive", default: true),
            passwordSet: row.bool("passwordSet", default: true),
            permissions: permissions,
            isSuperAdmin: row.bool("isSuperAdmin"),
            policyAccepted: row.bool("policyAccepted"),
            policyAcceptedAt: row.date("policyAcceptedAtMs"),
            legalPackVersion: row.optionalText("legalPackVersion"),
            assignedManagerUserId: managerIds.first ?? row.optionalText("assignedManagerUserId"),
            assignedManagerUserIds: managerIds,
            hasNoLineManager: row.bool("hasNoLineManager"),
            dayRate: row.number("dayRate"),
            hourlyRate: row.number("hourlyRate"),
            tradeTypePreset: row.optionalText("tradeTypePreset"),
            tradeTypeCustom: row.optionalText("tradeTypeCustom"),
            profilePhotoURL: row.optionalText("profilePhotoURL"),
            lastSeenAt: row.date("lastSeenAtMs"),
            employmentType: EmploymentType.fromCanonical(row.optionalText("employmentType")),
            employmentTypeTransitionFrom: row.optionalText("employmentTypeTransitionFrom").map { EmploymentType.fromCanonical($0) },
            employmentTypeEffectiveAt: row.date("employmentTypeEffectiveAtMs"),
            annualLeaveEnabled: row.bool("annualLeaveEnabled", default: true),
            annualLeaveDaysPerYear: row.number("annualLeaveDaysPerYear") ?? AnnualLeavePolicy.defaultDaysPerYear,
            annualLeaveYearStartMonth: row.number("annualLeaveYearStartMonth").map { Int($0) } ?? AnnualLeavePolicy.defaultStartMonth,
            annualLeaveYearEndMonth: row.number("annualLeaveYearEndMonth").map { Int($0) } ?? AnnualLeavePolicy.defaultEndMonth,
            annualLeaveCarriesOver: row.bool("annualLeaveCarriesOver"),
            annualLeaveYearAllowance: row.number("annualLeaveYearAllowance"),
            annualLeaveYearAllowanceKey: row.optionalText("annualLeaveYearAllowanceKey"),
            timesheetsEnabled: row.bool("timesheetsEnabled"),
            vatNumber: storedText("vatNumber"),
            utrNumber: storedText("utrNumber")
        )
        parsed.documentName = data["name"] as? String ?? ""
        parsed.documentDisplayName = data["displayName"] as? String ?? ""
        parsed.formerUserIds = row.strings("formerUserIds")
        parsed.documentUpdatedAt = row.date("updatedAtMs")
        parsed.status = row.optionalText("status")
        parsed.payBasis = row.optionalText("payBasis")
        parsed.profilePhotoUpdatedAt = row.date("profilePhotoUpdatedAtMs")
        parsed.operativeModeStored = row.bool("operativeModeStored")
        parsed.annualLeaveDefaultsPending = row.bool("annualLeaveDefaultsPending")
        return parsed
    }

    /// Server read of one user document.
    /// `confirmedMissing` is only a successful server snapshot that does not exist.
    /// Permission-denied is not proof the document is still there — the roster drops that row.
    /// A timeout or an offline failure is `unconfirmed`, and that row stays.
    func probeOrganizationUser(userId: String, organizationId: String) async -> OrganizationUserProbe {
        // `organizationId` is the roster being shown. It is not used to delete someone whose
        // user document points at another company: that field is the company they last opened.
        // A denied read does not clear `organizationId` on a document this phone can still read.
        _ = organizationId
        let trimmedId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return .unconfirmed }
        do {
            let doc = try await Self.readDocumentFromServer(
                db.collection("users").document(trimmedId),
                timeoutSeconds: 4
            )
            guard doc.exists, let data = doc.data() else { return .confirmedMissing }
            return .present(Self.parseAppUserDocument(userId: trimmedId, data: data))
        } catch {
            let nsError = error as NSError
            if LaunchStartupPolicy.isPermissionDenied(
                domain: nsError.domain,
                code: nsError.code,
                description: nsError.localizedDescription
            ) {
                return .permissionDenied
            }
            return .unconfirmed
        }
    }

    /// Writes only `isSuperAdmin`. A full `saveUser` from a roster refresh rewrote role flags and could hide that person.
    func clearMistakenSuperAdminFlag(userId: String) async throws {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await db.collection("users").document(trimmed).updateData([
            "isSuperAdmin": false,
            "updatedAt": Timestamp(date: Date())
        ])
    }

    /// Equality on `users.organizationId` misses documents stored as a reference, a path, or a different UUID casing.
    /// Those still belong to the org. This does not scan the whole `users` collection.
    private func userDocuments(whereOrganizationIdEquals value: Any, required: Bool) async throws -> [QueryDocumentSnapshot] {
        let query = db.collection("users").whereField("organizationId", isEqualTo: value)
        do {
            return try await query.getDocuments(source: .server).documents
        } catch {
            let denied = isFirestorePermissionDenied(error)
            if !LaunchStartupPolicy.shouldRetryOrganizationUserQuery(permissionDenied: denied) {
                if required { throw error }
                return []
            }
            if required {
                return try await query.getDocuments().documents
            }
            return (try? await query.getDocuments().documents) ?? []
        }
    }

    private struct OrgMemberIndex {
        /// Keys of `organizations/{orgId}.members`. Only these may receive an `organizationId` patch.
        var memberIds = Set<String>()
        /// Member keys plus `userEmails.userId`.
        var indexedUserIds = Set<String>()
        /// `userEmails/{email}` document id → `userId`.
        var userIdByEmail: [String: String] = [:]
        /// False only when both the server read and the cache read of `userEmails` failed.
        var emailClaimsLoaded = false
    }

    private func loadOrgMemberIndex(organizationId: String) async -> OrgMemberIndex {
        var index = OrgMemberIndex()
        let orgRef = db.collection("organizations").document(organizationId)
        let orgSnap: DocumentSnapshot?
        do {
            orgSnap = try await orgRef.getDocument(source: .server)
        } catch {
            orgSnap = try? await orgRef.getDocument(source: .cache)
        }
        if let members = orgSnap?.data()?["members"] as? [String: Any] {
            for (userId, _) in members {
                let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                index.memberIds.insert(trimmed)
                index.indexedUserIds.insert(trimmed)
            }
        }
        let emailQuery = orgRef.collection("userEmails")
        let emailSnap: QuerySnapshot?
        if let server = try? await emailQuery.getDocuments(source: .server) {
            emailSnap = server
        } else {
            emailSnap = try? await emailQuery.getDocuments()
        }
        if let emailSnap {
            index.emailClaimsLoaded = true
            for doc in emailSnap.documents {
                guard let userId = Self.firestoreLinkedUserId(doc.data()["userId"]) else { continue }
                index.indexedUserIds.insert(userId)
                let emailKey = doc.documentID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !emailKey.isEmpty {
                    index.userIdByEmail[emailKey] = userId
                }
            }
        }
        return index
    }

    /// `userId`, `userID`, `uid`, `linkedUserId`, or a `users/{id}` reference / path.
    private static func firestoreLinkedUserId(_ value: Any?) -> String? {
        if let ref = value as? DocumentReference {
            let id = ref.documentID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if t.contains("/") {
                let last = String(t.split(separator: "/").last ?? Substring(t))
                return last.isEmpty ? nil : last
            }
            return t
        }
        return nil
    }

    private struct StaffDirectoryLink {
        /// `userId` / `uid` / `linkedUserId` on the catalogue row. Not the catalogue document id.
        var candidateIds: [String]
        var documentId: String
        var email: String
        var rawEmail: String
        var fromManagers: Bool
    }

    /// Operative and manager documents are indexes. They are not user rows.
    private func loadStaffDirectoryLinks(organizationId: String) async -> [StaffDirectoryLink] {
        var links: [StaffDirectoryLink] = []
        for name in ["operatives", "managers"] {
            let fromManagers = name == "managers"
            let ref = db.collection("organizations").document(organizationId).collection(name)
            let snap: QuerySnapshot?
            if let server = try? await ref.getDocuments(source: .server) {
                snap = server
            } else {
                snap = try? await ref.getDocuments()
            }
            guard let snap else { continue }
            for doc in snap.documents {
                let data = doc.data()
                var ids: [String] = []
                for key in ["userId", "userID", "uid", "linkedUserId"] {
                    if let linked = Self.firestoreLinkedUserId(data[key]), !ids.contains(linked) {
                        ids.append(linked)
                    }
                }
                let docId = doc.documentID.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawEmail = ((data["email"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let email = rawEmail.lowercased()
                links.append(StaffDirectoryLink(
                    candidateIds: ids,
                    documentId: docId,
                    email: email,
                    rawEmail: rawEmail,
                    fromManagers: fromManagers
                ))
            }
        }
        return links
    }

    private enum LinkedUserLookup {
        case missing
        case usable([String: Any])
    }

    /// `missing` is a snapshot that is not there, or a permission-denied read.
    /// Denial does not fall through to a cached copy and re-insert the row.
    /// A user document whose organizationId is another company is still usable when the read succeeds:
    /// that field is the company they last opened, and this organisation can also list them.
    private func lookupLinkedUser(userId: String, organizationId: String) async -> LinkedUserLookup {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }
        _ = organizationId
        let ref = db.collection("users").document(trimmed)
        do {
            let server = try await ref.getDocument(source: .server)
            guard server.exists, let data = server.data() else { return .missing }
            return .usable(data)
        } catch {
            let nsError = error as NSError
            if LaunchStartupPolicy.isPermissionDenied(
                domain: nsError.domain,
                code: nsError.code,
                description: nsError.localizedDescription
            ) || LaunchStartupPolicy.isNotFound(domain: nsError.domain, code: nsError.code) {
                return .missing
            }
            if let cache = try? await ref.getDocument(source: .cache), cache.exists, let data = cache.data() {
                return .usable(data)
            }
            return .missing
        }
    }

    private func userIdFromUserEmailsDocument(organizationId: String, email: String) async -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = "\(normalizedOrganizationId(organizationId))|\(trimmed.lowercased())"
        if userEmailClaimMisses.contains(key) { return nil }
        let ref = db.collection("organizations").document(organizationId).collection("userEmails").document(trimmed)
        let outcome: LaunchStartupPolicy.UserEmailsPointRead
        do {
            let server = try await ref.getDocument(source: .server)
            outcome = LaunchStartupPolicy.classifyUserEmailsPointRead(
                exists: server.exists,
                userId: Self.firestoreLinkedUserId(server.data()?["userId"]),
                errorDomain: nil,
                errorCode: nil
            )
        } catch {
            let nsError = error as NSError
            outcome = LaunchStartupPolicy.classifyUserEmailsPointRead(
                exists: nil,
                userId: nil,
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
        }
        switch outcome {
        case .linked(let userId):
            return userId
        case .notFound:
            userEmailClaimMisses.insert(key)
            print("🔥🔥🔥 DEBUG: userEmails document missing — not a startup error")
            return nil
        case .failed:
            // A failed claims read stays failed. It does not hide live pending invites.
            return nil
        }
    }

    /// Email match inside one company. An empty organisation id does not list every user.
    private func userDocuments(whereEmailEquals email: String, organizationId: String) async -> [QueryDocumentSnapshot] {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let orgId = normalizedOrganizationId(organizationId)
        guard !trimmed.isEmpty, !orgId.isEmpty else { return [] }
        let query = db.collection("users")
            .whereField("email", isEqualTo: trimmed)
            .whereField("organizationId", isEqualTo: orgId)
            .limit(to: 5)
        if let docs = try? await query.getDocuments(source: .server).documents {
            return docs
        }
        return (try? await query.getDocuments().documents) ?? []
    }

    /// A managers-collection link may place this account on Managers only when the user document has no role flags.
    private static func qualifiesForManagersRecordPlacement(_ user: AppUser) -> Bool {
        if user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin { return false }
        if user.permissions.operativeMode || user.permissions.manager { return false }
        return true
    }

    /// Live `users where organizationId == orgId`, the query `getOrganizationUsers` starts from (RULEBOOK §1:
    /// the Manage Users roster is live). `onChange` gets the parsed added / modified documents and the ids that
    /// left the query. Nil when the organisation id is blank.
    func observeOrganizationUsers(
        organizationId: String,
        onChange: @escaping @MainActor (_ changed: [AppUser], _ removedIds: [String]) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) -> ListenerRegistration? {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return nil }
        return db.collection("users")
            .whereField("organizationId", isEqualTo: orgId)
            .addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error) }
                    return
                }
                guard let snapshot else { return }
                var changed: [AppUser] = []
                var removed: [String] = []
                for change in snapshot.documentChanges {
                    switch change.type {
                    case .added, .modified:
                        var user = Self.parseAppUserDocument(
                            userId: change.document.documentID,
                            data: change.document.data()
                        )
                        if user.organizationId.isEmpty { user.organizationId = orgId }
                        changed.append(user)
                    case .removed:
                        removed.append(change.document.documentID)
                    @unknown default:
                        break
                    }
                }
                guard !changed.isEmpty || !removed.isEmpty else { return }
                Task { @MainActor in onChange(changed, removed) }
            }
    }

    func getOrganizationUsers(organizationId: String) async throws -> OrganizationUserRoster {
        let orgId = normalizedOrganizationId(organizationId)
        print("🔥🔥🔥 DEBUG: getOrganizationUsers called with organizationId: \(orgId)")
        guard !orgId.isEmpty else { return OrganizationUserRoster(users: [], claimedEmails: nil) }

        struct CollectedUserDocument {
            var data: [String: Any]
            /// True when an organisation-id query already selected this document.
            /// The parser must not then drop it because `organizationId` was stored in a shape it cannot read.
            var matchedOrganizationQuery: Bool
        }

        var documentsById: [String: CollectedUserDocument] = [:]
        func absorb(_ documents: [QueryDocumentSnapshot], matchedOrganizationQuery: Bool) {
            for doc in documents {
                if var existing = documentsById[doc.documentID] {
                    if matchedOrganizationQuery { existing.matchedOrganizationQuery = true }
                    documentsById[doc.documentID] = existing
                } else {
                    documentsById[doc.documentID] = CollectedUserDocument(
                        data: doc.data(),
                        matchedOrganizationQuery: matchedOrganizationQuery
                    )
                }
            }
        }

        absorb(try await userDocuments(whereOrganizationIdEquals: orgId, required: true), matchedOrganizationQuery: true)
        // The exact organisation id succeeded. Lowercase, `organizations/{id}`, and a document
        // reference are different rules queries and are not issued.

        let memberIndex = await loadOrgMemberIndex(organizationId: orgId)
        let staffLinks = await loadStaffDirectoryLinks(organizationId: orgId)
        var explicitLinkUserIds = Set<String>()
        var directoryDocumentIds = Set<String>()
        for link in staffLinks {
            explicitLinkUserIds.formUnion(link.candidateIds)
            if !link.documentId.isEmpty {
                directoryDocumentIds.insert(link.documentId)
            }
        }
        let pointIds = LaunchStartupPolicy.pointReadUserIds(
            alreadyLoaded: Set(documentsById.keys),
            memberUserIds: memberIndex.memberIds,
            claimUserIds: Set(memberIndex.userIdByEmail.values),
            explicitLinkUserIds: explicitLinkUserIds,
            directoryDocumentIds: directoryDocumentIds
        )
        var fetched = 0
        for userId in pointIds {
            fetched += 1
            if fetched % 20 == 0 {
                await Task.yield()
            }
            switch await lookupLinkedUser(userId: userId, organizationId: orgId) {
            case .usable(let data):
                documentsById[userId] = CollectedUserDocument(data: data, matchedOrganizationQuery: false)
            case .missing:
                break
            }
        }

        var managersRecordUserIds = Set<String>()
        var staffResolvedUserIds = Set<String>()
        for link in staffLinks {
            if let matchedId = link.candidateIds.first(where: { documentsById[$0] != nil }) {
                staffResolvedUserIds.insert(matchedId)
                if link.fromManagers { managersRecordUserIds.insert(matchedId) }
                continue
            }
            guard !link.email.isEmpty else { continue }
            var resolvedIds: [String] = []
            var emailIndexUserId = memberIndex.userIdByEmail[link.email]
            if emailIndexUserId == nil {
                emailIndexUserId = await userIdFromUserEmailsDocument(organizationId: orgId, email: link.email)
            }
            if let mappedId = emailIndexUserId {
                if documentsById[mappedId] == nil {
                    switch await lookupLinkedUser(userId: mappedId, organizationId: orgId) {
                    case .usable(let data):
                        documentsById[mappedId] = CollectedUserDocument(data: data, matchedOrganizationQuery: false)
                    case .missing:
                        break
                    }
                }
                if documentsById[mappedId] != nil {
                    resolvedIds.append(mappedId)
                }
            }
            if resolvedIds.isEmpty {
                var emailDocs = await userDocuments(whereEmailEquals: link.email, organizationId: orgId)
                if !link.rawEmail.isEmpty, link.rawEmail != link.email {
                    emailDocs.append(contentsOf: await userDocuments(whereEmailEquals: link.rawEmail, organizationId: orgId))
                }
                absorb(emailDocs, matchedOrganizationQuery: false)
                resolvedIds = Array(Set(emailDocs.map(\.documentID).filter { documentsById[$0] != nil }))
            }
            staffResolvedUserIds.formUnion(resolvedIds)
            if link.fromManagers {
                managersRecordUserIds.formUnion(resolvedIds)
            }
        }

        print("🔥🔥🔥 DEBUG: Found \(documentsById.count) user documents for organisation \(orgId)")

        var users: [AppUser] = []

        for (userId, collected) in documentsById {
            let data = collected.data
            let email = data["email"] as? String ?? ""
            let storedOrganizationId = organizationIdFromFirestore(data["organizationId"])
            let docOrganizationId = storedOrganizationId ?? ""
            let queryAlreadyMatched = collected.matchedOrganizationQuery
            let fieldMissing = storedOrganizationId == nil && !queryAlreadyMatched
            let belongsByField = organizationIdsMatch(docOrganizationId, orgId)
            // members, userEmails, operatives, and managers are this company's list.
            // organizationId on the user document is only the company they last opened.
            let linkedToThisOrganisation = memberIndex.indexedUserIds.contains(userId) || staffResolvedUserIds.contains(userId)

            print("🔥🔥🔥 DEBUG: Processing user - DocumentID: \(userId), Email: \(email), DocOrgId: \(docOrganizationId), RequestedOrgId: \(orgId)")

            guard belongsByField || fieldMissing || queryAlreadyMatched || linkedToThisOrganisation else {
                print("🔥🔥🔥 DEBUG: Skipping user \(email) - not linked to this organisation")
                continue
            }

            var user = Self.parseAppUserDocument(userId: userId, data: data)
            if fieldMissing {
                user.organizationId = orgId
            }
            if managersRecordUserIds.contains(userId), Self.qualifiesForManagersRecordPlacement(user) {
                user.placedByManagersRecord = true
            }

            users.append(user)
            print("🔥🔥🔥 DEBUG: Added user to list: \(user.email) (\(user.firstName) \(user.surname)) role=\(user.role.rawValue) admin=\(user.appearsOnAdminsList) manager=\(user.appearsOnManagersList) operative=\(user.appearsOnOperativesList) passwordSet=\(user.passwordSet) active=\(user.isActive)")
        }

        // Same email, two documents: one person. `rosterPeople` decides which document is kept
        // (admin, signed in, newer, active, rank, lower id) and lists the folded ids, as web does.
        let (uniqueUsers, userIdAliases) = Self.foldRosterBySameEmail(users)

        print("🔥🔥🔥 DEBUG: Returning \(uniqueUsers.count) unique users")
        let claimedEmails: Set<String>? = memberIndex.emailClaimsLoaded ? Set(memberIndex.userIdByEmail.keys) : nil
        return OrganizationUserRoster(users: uniqueUsers, claimedEmails: claimedEmails, userIdAliases: userIdAliases)
    }

    /// `rosterPeople` over the parsed documents. Swift only carries the other document's manager-list
    /// placement and readable trade onto the kept one. Falls back to `collapsedRosterUser` when the
    /// script did not answer, so the roster is never empty for that reason.
    static func foldRosterBySameEmail(_ users: [AppUser]) -> (users: [AppUser], aliases: [String: String]) {
        let documents: [[String: Any]] = users.map { user in
            [
                "id": user.id,
                "email": user.email,
                "passwordSet": user.passwordSet,
                "isActive": user.isActive,
                "firstName": user.firstName,
                "surname": user.surname,
                "admin": user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin,
                "listed": user.appearsOnAdminsList || user.appearsOnManagersList || user.appearsOnOperativesList,
                "updatedAtMs": user.documentUpdatedAt.map { ($0.timeIntervalSince1970 * 1000).rounded() } ?? NSNull(),
                "formerUserIds": user.formerUserIds,
                "sameEmailUserIds": user.sameEmailUserIds
            ]
        }
        guard let result = CanonicalBusinessEngine.rosterPeople(documents) else {
            var byKey: [String: AppUser] = [:]
            var order: [String] = []
            for user in users {
                let emailKey = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let key = emailKey.isEmpty ? "id:\(user.id)" : emailKey
                if let existing = byKey[key] {
                    byKey[key] = collapsedRosterUser(existing, user)
                } else {
                    byKey[key] = user
                    order.append(key)
                }
            }
            let kept = order.compactMap { byKey[$0] }
            var aliases: [String: String] = [:]
            for person in kept {
                for folded in person.sameEmailUserIds { aliases[folded] = person.id }
            }
            return (kept, aliases)
        }
        var byId: [String: AppUser] = [:]
        for user in users where byId[user.id] == nil { byId[user.id] = user }
        var kept: [AppUser] = []
        for row in result.people {
            guard let id = row["id"] as? String, var person = byId[id] else { continue }
            person.sameEmailUserIds = row["sameEmailUserIds"] as? [String] ?? person.sameEmailUserIds
            person.formerUserIds = row["formerUserIds"] as? [String] ?? person.formerUserIds
            for folded in person.sameEmailUserIds {
                guard let other = byId[folded] else { continue }
                if !person.placedByManagersRecord && other.placedByManagersRecord {
                    person.placedByManagersRecord = true
                }
                if StaffEmailIdentity.reportTrade(for: person) == "General",
                   StaffEmailIdentity.reportTrade(for: other) != "General" {
                    person.tradeTypePreset = other.tradeTypePreset
                    person.tradeTypeCustom = other.tradeTypeCustom
                }
            }
            kept.append(person)
        }
        return (kept, result.userIdAliases)
    }

    /// One email stays one roster row. The signed-in account stays the id. A readable
    /// trade on the other document is kept, so the weekly report does not fall back to General.
    static func collapsedRosterUser(_ existing: AppUser, _ incoming: AppUser) -> AppUser {
        let incomingWins = rosterDocumentRank(incoming) > rosterDocumentRank(existing)
        var chosen = incomingWins ? incoming : existing
        let other = incomingWins ? existing : incoming
        if chosen.placedByManagersRecord == false && other.placedByManagersRecord {
            chosen.placedByManagersRecord = true
        }
        var aliases = Set(chosen.sameEmailUserIds)
        aliases.formUnion(other.sameEmailUserIds)
        aliases.insert(other.id)
        aliases.remove(chosen.id)
        chosen.sameEmailUserIds = aliases.sorted()
        chosen.formerUserIds = Array(Set(chosen.formerUserIds).union(other.formerUserIds)).sorted()
        let chosenTrade = StaffEmailIdentity.reportTrade(for: chosen)
        let otherTrade = StaffEmailIdentity.reportTrade(for: other)
        if chosenTrade == "General", otherTrade != "General" {
            chosen.tradeTypePreset = other.tradeTypePreset
            chosen.tradeTypeCustom = other.tradeTypeCustom
        }
        return chosen
    }

    /// Higher wins when two documents share an email. A classified, named, signed-in account beats a stub.
    private static func rosterDocumentRank(_ user: AppUser) -> Int {
        var rank = 0
        if user.passwordSet { rank += 4 }
        if user.appearsOnManagersList || user.appearsOnOperativesList || user.appearsOnAdminsList { rank += 2 }
        if !user.firstName.isEmpty || !user.surname.isEmpty { rank += 1 }
        if user.isActive { rank += 1 }
        return rank
    }
    
    // MARK: - Simplified User Management (Placeholder)
    
    
    func createOrganization(
        id: String,
        name: String,
        adminUserId: String,
        officeAddressLine1: String? = nil,
        officeCity: String? = nil,
        officePostcode: String? = nil,
        countryCode: String,
        defaultLatitude: Double? = nil,
        defaultLongitude: Double? = nil
    ) async throws {
        guard let nameFields = CanonicalBusinessEngine.organizationNameToFirestore(name),
              let writtenName = nameFields["name"] as? String,
              !writtenName.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Organisation name is required"]
            )
        }
        var payload: [String: Any] = nameFields
        payload["id"] = id
        payload["adminUserId"] = adminUserId
        payload["creatorUserId"] = adminUserId
        payload["countryCode"] = countryCode.uppercased()
        payload["createdAt"] = Timestamp(date: Date())
        payload["updatedAt"] = Timestamp(date: Date())
        if let officeAddressLine1, !officeAddressLine1.isEmpty {
            payload["officeAddressLine1"] = officeAddressLine1
        }
        if let officeCity, !officeCity.isEmpty {
            payload["officeCity"] = officeCity
        }
        if let officePostcode, !officePostcode.isEmpty {
            payload["officePostcode"] = officePostcode
        }
        if let defaultLatitude {
            payload["defaultLatitude"] = defaultLatitude
        }
        if let defaultLongitude {
            payload["defaultLongitude"] = defaultLongitude
        }
        payload["payrollTimePolicy"] = OrgPayrollTimePolicy.default.asFirestoreDictionary()
        payload["invoicing"] = Self.invoicingFirestoreMap(OrganizationInvoicingSettings.default)
        payload["annualLeaveDefaults"] = [
            "daysPerYear": OrganizationAnnualLeaveDefaults.default.daysPerYear,
            "startMonth": OrganizationAnnualLeaveDefaults.default.startMonth,
            "endMonth": OrganizationAnnualLeaveDefaults.default.endMonth,
            "carriesOver": OrganizationAnnualLeaveDefaults.default.carriesOver,
        ]
        payload["warningDetection"] = Self.warningDetectionFirestoreMap(OrgWarningDetectionSettings.default)
        try await db.collection("organizations").document(id).setData(payload, merge: true)
        let organizationId = id
        Task { await self.seedStarterQualificationLibraryIfEmpty(organizationId: organizationId) }
    }

    /// Admin: update company-wide warning detection settings (`organizations/{orgId}.warningDetection`).
    func updateOrganizationWarningDetectionSettings(_ settings: OrgWarningDetectionSettings) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        // Top-level map only. Nested settings.warningDetection is not the live document.
        var payload: [String: Any] = [:]
        for (key, value) in Self.warningDetectionFirestoreMap(settings) {
            payload["warningDetection.\(key)"] = value
        }
        let orgRef = db.collection("organizations").document(orgId)
        try await orgRef.updateData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))
        guard var org = currentOrganization else { return }
        org.settings.warningDetection = settings
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// The server always wins (§4): the detection settings read from the document replace the in-memory
    /// copy, even when they equal the factory defaults. `current` is kept only for the call signature.
    static func detectionForWarningScan(
        current: OrgWarningDetectionSettings,
        loaded: OrgWarningDetectionSettings
    ) -> OrgWarningDetectionSettings {
        _ = current
        return loaded
    }

    /// Re-reads the organisation document. Payment runs and warning detection always come from this live read.
    @discardableResult
    func refreshWarningDetectionFromServer() async -> Bool {
        guard let orgId = currentOrganization?.firestoreDocumentId else { return false }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await db.collection("organizations").document(orgId).getDocument(source: .server)
        } catch {
            print("🔥🔥🔥 DEBUG: warningDetection server read failed: \(error.localizedDescription)")
            return false
        }
        guard let data = snapshot.data(), var org = currentOrganization,
              organizationIdsMatch(org.firestoreDocumentId, orgId) else { return false }
        let loaded = Self.organizationSettingsFromOrgDocument(data)
        org.settings.invoicing = loaded.invoicing
        org.settings.warningDetection = Self.detectionForWarningScan(
            current: org.settings.warningDetection,
            loaded: loaded.warningDetection
        )
        currentOrganization = org
        storeOrganizationLocally(org)
        print("🔥🔥🔥 DEBUG: warning scan org refreshed mode=\(org.settings.warningDetection.clashLookaheadMode.rawValue) runs=\(org.settings.invoicing.paymentRunDateRanges.map { "\($0.startDay)-\($0.endDay)" }.joined(separator: ","))")
        return true
    }

    /// Date-aware payroll policy for bookings / timesheets on `day`.
    func payrollPolicy(for day: Date) -> OrgPayrollTimePolicy {
        PayrollTimePolicyCatalog.policy(for: day, organization: currentOrganization)
    }

    /// Server copy of the organisation document for a working-hours write. Online only: the write
    /// functions must see the stored prior / scheduled fields, not the in-memory copy.
    private func organizationDocumentForPayrollWrite(_ orgId: String) async throws -> [String: Any] {
        let snapshot = try await db.collection("organizations").document(orgId).getDocument(source: .server)
        guard let data = snapshot.data() else {
            throw NSError(domain: "FirebaseBackend", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organisation not found."])
        }
        return data
    }

    /// Writes `fields` (+ `WriteMetadata`) as a partial update and re-reads the payroll state locally
    /// through `payrollTimePolicyTimeline`, from the server document with `fields` applied.
    private func writeOrganizationPayrollFields(_ fields: [String: Any], orgId: String, serverData: [String: Any]) async throws {
        try await db.collection("organizations").document(orgId)
            .updateData(WriteMetadata.stamped(fields, userId: auth.currentUser?.uid))
        guard var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, orgId) else { return }
        var merged = serverData
        for (key, value) in fields { merged[key] = value }
        Self.applyPayrollPolicyFields(from: merged, to: &org)
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Organisation-zone today for the document being written.
    private static func payrollTodayKey(for data: [String: Any]) -> (todayKey: String, zone: String) {
        let zone = CanonicalBusinessEngine.organizationTimeZoneIdentifier(countryCode: data["countryCode"] as? String)
        return (CanonicalBusinessEngine.organizationDayKey(Date(), timeZoneIdentifier: zone), zone)
    }

    /// Admin: apply working-hours changes from today (`payrollTimePolicyApplyNowWriteFields`). The prior
    /// policy is the one in force yesterday; a future scheduled change is kept, a due one is consumed.
    func applyOrganizationPayrollTimePolicyImmediately(_ policy: OrgPayrollTimePolicy) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        if let message = CanonicalBusinessEngine.validatePayrollTimePolicy(policy) {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let serverData = try await organizationDocumentForPayrollWrite(orgId)
        let today = Self.payrollTodayKey(for: serverData)
        guard let fields = CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: Self.firestoreJSON(serverData) as? [String: Any] ?? [:],
            policy: policy,
            todayKey: today.todayKey,
            timeZone: today.zone
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Could not save these working hours."])
        }
        try await writeOrganizationPayrollFields(fields, orgId: orgId, serverData: serverData)
    }

    /// Admin: queue a future working-hours change (`payrollTimePolicyScheduleWriteFields`; replaces any
    /// pending change, promotes a due one first). `effectiveFrom` comes from a date picker, so its day is
    /// read in the picker's (device) calendar and sent as that `YYYY-MM-DD` organisation day.
    func scheduleOrganizationPayrollTimePolicyChange(_ policy: OrgPayrollTimePolicy, effectiveFrom: Date) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        if let message = CanonicalBusinessEngine.validatePayrollTimePolicy(policy) {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let picked = Calendar.current.dateComponents([.year, .month, .day], from: effectiveFrom)
        let effectiveKey = String(format: "%04d-%02d-%02d", picked.year ?? 0, picked.month ?? 0, picked.day ?? 0)
        let serverData = try await organizationDocumentForPayrollWrite(orgId)
        let today = Self.payrollTodayKey(for: serverData)
        if let message = CanonicalBusinessEngine.payrollTimePolicyScheduleDateError(
            effectiveFrom: effectiveKey,
            todayKey: today.todayKey
        ) {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let fields = CanonicalBusinessEngine.payrollTimePolicyScheduleWriteFields(
            orgDocument: Self.firestoreJSON(serverData) as? [String: Any] ?? [:],
            policy: policy,
            effectiveFrom: effectiveKey,
            todayKey: today.todayKey,
            timeZone: today.zone
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Could not schedule these working hours."])
        }
        try await writeOrganizationPayrollFields(fields, orgId: orgId, serverData: serverData)
    }

    /// Admin: cancel the pending working-hours change (`payrollTimePolicyCancelScheduleWriteFields`).
    /// A change that is already due is promoted first, never lost.
    func cancelScheduledOrganizationPayrollTimePolicyChange() async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        let serverData = try await organizationDocumentForPayrollWrite(orgId)
        let today = Self.payrollTodayKey(for: serverData)
        guard let fields = CanonicalBusinessEngine.payrollTimePolicyCancelScheduleWriteFields(
            orgDocument: Self.firestoreJSON(serverData) as? [String: Any] ?? [:],
            todayKey: today.todayKey,
            timeZone: today.zone
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Could not cancel the scheduled change."])
        }
        try await writeOrganizationPayrollFields(fields, orgId: orgId, serverData: serverData)
    }

    /// Admin: update organisation-wide payroll / working time defaults (`organizations/{orgId}.payrollTimePolicy`).
    /// Prefer `applyOrganizationPayrollTimePolicyImmediately` or `scheduleOrganizationPayrollTimePolicyChange`.
    func updateOrganizationPayrollTimePolicy(_ policy: OrgPayrollTimePolicy) async throws {
        try await applyOrganizationPayrollTimePolicyImmediately(policy)
    }

    /// Admin: update organisation invoicing settings (`organizations/{orgId}.invoicing`).
    func updateOrganizationInvoicingSettings(_ settings: OrganizationInvoicingSettings) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        // Payment-run history is built from the server document, not the in-memory copy (§4).
        let orgRef = db.collection("organizations").document(orgId)
        let snap = try await orgRef.getDocument(source: .server)
        let serverInvoicing = snap.data()?["invoicing"] as? [String: Any]
        let previous = serverInvoicing.map { Self.organizationInvoicingFromFirestore($0) }
            ?? OrganizationInvoicingSettings.default
        var settingsToSave = settings
        if let recordedAtDayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(Date()),
           let history = CanonicalBusinessEngine.paymentRunHistoryAfterChange(
            previous: previous.paymentRunWindow(),
            next: settings.paymentRunWindow(),
            existingHistory: previous.paymentRunHistory,
            recordedAtDayKey: recordedAtDayKey
           ) {
            settingsToSave.paymentRunHistory = history
        } else {
            settingsToSave.paymentRunHistory = previous.paymentRunHistory
        }
        let canonical = settingsToSave.canonicalInvoicingSettings()
        if let message = CanonicalBusinessEngine.validateInvoicingSettings(canonical) {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard let written = CanonicalBusinessEngine.invoicingToFirestore(canonical) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not save these payment run settings."]
            )
        }
        // Partial update of the keys `invoicingToFirestore` writes; other `invoicing` keys stay as stored.
        var patch: [String: Any] = [:]
        if serverInvoicing == nil {
            patch["invoicing"] = written
        } else {
            for (key, value) in written {
                patch["invoicing.\(key)"] = value
            }
        }
        try await orgRef.updateData(WriteMetadata.stamped(patch, userId: auth.currentUser?.uid))
        guard var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, orgId) else { return }
        org.settings.invoicing = settingsToSave
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Admin: update organisation annual-leave defaults used only for newly invited manager/operative users.
    func updateOrganizationAnnualLeaveDefaults(_ defaults: OrganizationAnnualLeaveDefaults) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        let payload: [String: Any] = [
            "daysPerYear": defaults.daysPerYear,
            "startMonth": defaults.startMonth,
            "endMonth": defaults.endMonth,
            "carriesOver": defaults.carriesOver,
        ]
        try await db.collection("organizations").document(orgId).updateData(
            WriteMetadata.stamped(["annualLeaveDefaults": payload], userId: auth.currentUser?.uid)
        )
        guard var org = currentOrganization else { return }
        org.settings.annualLeaveDefaults = defaults
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Admin: bank holiday region for annual leave calendars.
    func updateOrganizationBankHolidayRegion(_ regionId: String) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        let trimmed = regionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Select an annual leave / bank holiday region."]
            )
        }
        // Dotted `settings.bankHolidayRegionId` is a path only in updateData (never setData(merge:)).
        try await db.collection("organizations").document(orgId).updateData(
            WriteMetadata.stamped(
                ["bankHolidayRegionId": trimmed, "settings.bankHolidayRegionId": trimmed],
                userId: auth.currentUser?.uid
            )
        )
        guard var org = currentOrganization else { return }
        org.settings.bankHolidayRegionId = trimmed
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Admin: save annual-leave defaults and bank-holiday region in one write so settings dismiss immediately.
    func updateOrganizationAnnualLeaveSettings(
        defaults: OrganizationAnnualLeaveDefaults,
        bankHolidayRegionId: String
    ) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        let trimmed = bankHolidayRegionId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Rulebook 1.4.0 §4.4: a country with no listed region (`bankHolidayRegionsForCountry` empty) has nothing
        // to choose, so the leave defaults still save and the stored region is left alone.
        let payload: [String: Any] = [
            "daysPerYear": defaults.daysPerYear,
            "startMonth": defaults.startMonth,
            "endMonth": defaults.endMonth,
            "carriesOver": defaults.carriesOver,
        ]
        var fields: [String: Any] = ["annualLeaveDefaults": payload]
        if !trimmed.isEmpty {
            // Dotted `settings.bankHolidayRegionId` is a path only in updateData (never setData(merge:)).
            fields["bankHolidayRegionId"] = trimmed
            fields["settings.bankHolidayRegionId"] = trimmed
        }
        try await db.collection("organizations").document(orgId).updateData(
            WriteMetadata.stamped(fields, userId: auth.currentUser?.uid)
        )
        guard var org = currentOrganization else { return }
        org.settings.annualLeaveDefaults = defaults
        if !trimmed.isEmpty {
            org.settings.bankHolidayRegionId = trimmed
        }
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Admin: organisation currency for rates, reports, and invoicing.
    func updateOrganizationCurrencyCode(_ code: String) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        // `organizationCurrencyWriteFields`: currencyCode, currency and the dotted `settings.currencyCode`
        // path, as a partial update (a dotted key in setData(merge:) would be a literal field name).
        guard let fields = CanonicalBusinessEngine.organizationCurrencyWriteFields(code),
              let saved = fields["currencyCode"] as? String else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Select a supported currency."]
            )
        }
        try await db.collection("organizations").document(orgId).updateData(
            WriteMetadata.stamped(fields, userId: auth.currentUser?.uid)
        )
        guard var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, orgId) else { return }
        org.settings.currencyCode = saved
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Company-wide material cut-off. Dotted `settings.materialCutOff` leaves the other settings keys in place.
    func updateOrganizationMaterialCutOff(_ cutOff: OrgMaterialCutOff) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        guard let payload = cutOff.asFirestoreDictionary() else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not save the material cut-off."]
            )
        }
        try await db.collection("organizations").document(orgId).updateData(
            WriteMetadata.stamped(["settings.materialCutOff": payload], userId: auth.currentUser?.uid)
        )
        guard var org = currentOrganization else { return }
        org.settings.materialCutOff = cutOff
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
        NotificationCenter.default.post(name: .organizationMaterialCutOffDidChange, object: nil)
    }

    /// Admin: org-wide My Schedule booking options (`organizations/{orgId}.settings.myScheduleOptions`).
    func updateOrganizationMyScheduleOptions(_ options: MyScheduleOptions) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        // `scheduleOptionsWriteFields`: exactly the list given (trimmed, case-insensitive de-dupe), never
        // merged with the stored list, so a deleted item stays deleted.
        let written = CanonicalBusinessEngine.scheduleOptionsWriteFields(options) ?? options.asFirestoreDictionary()
        try await db.collection("organizations").document(orgId).updateData(
            WriteMetadata.stamped(["settings.myScheduleOptions": written], userId: auth.currentUser?.uid)
        )
        guard var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, orgId) else { return }
        org.settings.myScheduleOptions = MyScheduleOptions.fromFirestore(written)
        org.updatedAt = Date()
        organizationHasFirestoreMyScheduleOptions = true
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Loads per-user notification preferences from `users/{userId}.notificationPreferences`.
    func loadUserNotificationPreferences(userId: String) async throws -> NotificationSettings? {
        let doc = try await db.collection("users").document(userId).getDocument(source: .server)
        guard doc.exists, let data = doc.data(),
              let raw = data["notificationPreferences"] as? [String: Any] else {
            return nil
        }
        return notificationSettingsFromFirestore(raw)
    }

    /// Dotted updates for toggles. The cut-off clock stays on the organisation map.
    func saveUserNotificationPreferences(_ settings: NotificationSettings, userId: String) async throws {
        try await saveUserNotificationPreferenceKeys(settings.preferenceValues ?? [:], userId: userId)
    }

    /// Dotted `notificationPreferences.{key}` writes for the keys passed in. Does not replace the map.
    func saveUserNotificationPreferenceKeys(_ keys: [String: Bool], userId: String) async throws {
        var data: [String: Any] = [
            "updatedAt": Timestamp(date: Date()),
        ]
        if !keys.isEmpty, let patch = CanonicalBusinessEngine.userNotificationPreferenceFieldPatch(keys) {
            for (key, value) in patch {
                data[key] = value
            }
        }
        try await db.collection("users").document(userId).updateData(data)
    }

    private func notificationSettingsFromFirestore(_ data: [String: Any]) -> NotificationSettings {
        var settings = NotificationSettings(
            bookingConflicts: data["bookingConflicts"] as? Bool ?? true,
            projectDeadlines: data["projectDeadlines"] as? Bool ?? true,
            operativeAvailability: data["operativeAvailability"] as? Bool ?? false,
            dailyReports: data["dailyReports"] as? Bool ?? false,
            materialOrderCutOff: data["materialOrderCutOff"] as? Bool ?? true,
            materialCutOffHour: (data["materialCutOffHour"] as? NSNumber)?.intValue ?? (data["materialCutOffHour"] as? Int) ?? 16,
            materialCutOffMinute: (data["materialCutOffMinute"] as? NSNumber)?.intValue ?? (data["materialCutOffMinute"] as? Int) ?? 0,
            materialCutOffOnSaturday: data["materialCutOffOnSaturday"] as? Bool ?? false,
            materialCutOffOnSunday: data["materialCutOffOnSunday"] as? Bool ?? false,
            annualLeaveRequests: data["annualLeaveRequests"] as? Bool ?? true,
            annualLeaveDecisions: data["annualLeaveDecisions"] as? Bool ?? true,
            projectCreated: data["projectCreated"] as? Bool ?? true,
            smallWorksCreated: data["smallWorksCreated"] as? Bool ?? true,
            materialAdded: data["materialAdded"] as? Bool ?? true,
            bookingCreated: data["bookingCreated"] as? Bool ?? true,
            operativeCreated: data["operativeCreated"] as? Bool ?? true,
            managerCreated: data["managerCreated"] as? Bool ?? true,
            clientCreated: data["clientCreated"] as? Bool ?? true,
            warningRemoved: data["warningRemoved"] as? Bool ?? true,
            taskAssigned: data["taskAssigned"] as? Bool ?? true,
            toolboxTalkIssued: data["toolboxTalkIssued"] as? Bool ?? true,
            timesheetSignoff: data["timesheetSignoff"] as? Bool ?? true,
            qualificationExpiry: data["qualificationExpiry"] as? Bool ?? true,
            lineManagerPeerUpdate: data["lineManagerPeerUpdate"] as? Bool ?? true
        )
        if let parsed = CanonicalBusinessEngine.parseUserNotificationPreferences(data) {
            settings.applyCanonicalPreferences(parsed)
        }
        return settings
    }

    /// Super admin: update organisation display name, office location, country, and optional cached map center.
    func updateOrganizationCompanyDetails(
        name: String,
        hasOfficeAddress: Bool,
        officeAddressLine1: String?,
        officeAddressLine2: String? = nil,
        officeCity: String?,
        officeCounty: String? = nil,
        officePostcode: String?,
        countryCode: String,
        defaultLatitude: Double?,
        defaultLongitude: Double?,
        documentAbbreviation: String?,
        bankHolidayRegionId: String? = nil
    ) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        // Rulebook: `companyDetailsValidationError` then `companyDetailsWriteFields` → `{ set, remove }`.
        // A blank name is never written (`organizationNameWriteFields` inside it); blank optional fields and
        // the legacy nested `officeAddress` map are removed with `FieldValue.delete()`.
        // Rulebook 1.4.0 §4.1: `previous` is the saved country and region, so a country change needs a region from
        // the new country (`companyDetailsRegionPrompt`) and country + region go in this one partial update.
        let input = CanonicalBusinessEngine.companyDetailsInput(
            name: name,
            hasOfficeAddress: hasOfficeAddress,
            officeAddressLine1: officeAddressLine1,
            officeAddressLine2: officeAddressLine2,
            officeCity: officeCity,
            officeCounty: officeCounty,
            officePostcode: officePostcode,
            countryCode: countryCode,
            documentAbbreviation: documentAbbreviation,
            defaultLatitude: defaultLatitude,
            defaultLongitude: defaultLongitude,
            bankHolidayRegionId: bankHolidayRegionId,
            previousCountryCode: currentOrganization?.countryCode,
            previousBankHolidayRegionId: currentOrganization?.settings.bankHolidayRegionId
        )
        if let message = CanonicalBusinessEngine.companyDetailsValidationError(input) {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let write = CanonicalBusinessEngine.companyDetailsWriteFields(input) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Could not save the company details."]
            )
        }
        var payload: [String: Any] = write.set
        for path in write.remove where payload[path] == nil {
            payload[path] = FieldValue.delete()
        }
        try await db.collection("organizations").document(orgId)
            .updateData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))

        guard var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, orgId) else { return }
        func written(_ key: String) -> String? {
            let value = (write.set[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        if let writtenName = written("name") {
            org.name = writtenName
        }
        if let country = written("countryCode") {
            org.countryCode = country
        }
        if let region = written("bankHolidayRegionId") {
            org.settings.bankHolidayRegionId = region
        } else if write.remove.contains("bankHolidayRegionId") {
            org.settings.bankHolidayRegionId = nil
        }
        org.documentAbbreviation = OrganizationDocumentAbbreviation.normalized(written("documentAbbreviation"))
        org.officeAddressLine1 = written("officeAddressLine1")
        org.officeAddressLine2 = written("officeAddressLine2")
        org.officeCity = written("officeCity")
        org.officeCounty = written("officeCounty")
        org.officePostcode = written("officePostcode")
        if let lat = (write.set["defaultLatitude"] as? NSNumber)?.doubleValue,
           let lon = (write.set["defaultLongitude"] as? NSNumber)?.doubleValue {
            org.defaultLatitude = lat
            org.defaultLongitude = lon
        }
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }
    
    /// Every `users/{uid}` field a profile save manages, as it is stored. `saveUser` diffs two of these
    /// (the copy the caller edited and the edited copy) so only changed fields are written (RULEBOOK §1).
    static func userDocumentPayload(_ user: AppUser) -> [String: Any] {
        // Operative mode does not demote an admin. Tab order is admin, then operativeMode, then manager.
        let keepAdmin = user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin
        let operativeOnly = user.permissions.operativeMode && !keepAdmin
        // RULEBOOK 1.6.0 §8: `parseUserDocument` ignores a stray `operativeMode` flag on an admin for lists, but the
        // stored flag is what the approval and security rules read. A save writes the stored flag back unchanged
        // unless the editor turned operative mode on.
        let operativeModeToSave = user.permissions.operativeMode || (keepAdmin && user.operativeModeStored)
        let isSuperAdminToSave = operativeOnly ? false : user.isSuperAdmin
        let roleToSave: UserRole = operativeOnly ? .operative : user.role
        var userData: [String: Any] = [
            "email": user.email,
            "organizationId": user.organizationId,
            "role": roleToSave.rawValue,
            "createdAt": Timestamp(date: user.createdAt),
            "firstName": user.firstName,
            "surname": user.surname,
            "isActive": user.isActive,
            "passwordSet": user.passwordSet,
            "adminAccess": operativeOnly ? false : user.permissions.adminAccess,
            "manager": operativeOnly ? false : user.permissions.manager,
            "operatives": operativeOnly ? false : user.permissions.operatives,
            "skills": false,
            "qualifications": operativeOnly ? false : user.permissions.qualifications,
            "materials": operativeOnly ? user.permissions.materials : true,
            "projects": user.permissions.projects,
            "smallWorks": user.permissions.smallWorks,
            "operativeMode": operativeModeToSave,
            "annualLeaveSelfBook": user.permissions.annualLeaveSelfBook,
            "weeklyReports": user.permissions.weeklyReports,
            "dailyOverview": user.permissions.dailyOverview,
            "subContractors": user.permissions.subContractors,
            "siteAudit": operativeOnly ? user.permissions.siteAudit : true,
            "wholesalersOrderHistory": user.permissions.wholesalersOrderHistory,
            "permissions": [
                "adminAccess": operativeOnly ? false : user.permissions.adminAccess,
                "manager": operativeOnly ? false : user.permissions.manager,
                "operatives": operativeOnly ? false : user.permissions.operatives,
                "skills": false,
                "qualifications": operativeOnly ? false : user.permissions.qualifications,
                "materials": operativeOnly ? user.permissions.materials : true,
                "projects": user.permissions.projects,
                "smallWorks": user.permissions.smallWorks,
                "operativeMode": operativeModeToSave,
                "siteAudit": operativeOnly ? user.permissions.siteAudit : true,
                "subContractors": user.permissions.subContractors,
                "wholesalersOrderHistory": user.permissions.wholesalersOrderHistory,
                "annualLeaveSelfBook": user.permissions.annualLeaveSelfBook,
                "weeklyReports": user.permissions.weeklyReports,
                "dailyOverview": user.permissions.dailyOverview,
            ] as [String: Bool],
            "isSuperAdmin": isSuperAdminToSave,
            "policyAccepted": user.policyAccepted,
            "employmentType": user.employmentType.rawValue
        ]

        if let transitionFrom = user.employmentTypeTransitionFrom {
            userData["employmentTypeTransitionFrom"] = transitionFrom.rawValue
        } else {
            userData["employmentTypeTransitionFrom"] = FieldValue.delete()
        }
        if let effectiveAt = user.employmentTypeEffectiveAt {
            userData["employmentTypeEffectiveAt"] = Timestamp(date: effectiveAt)
        } else {
            userData["employmentTypeEffectiveAt"] = FieldValue.delete()
        }
        
        let trimmedMobile = user.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedMobile.isEmpty {
            userData["mobileNumber"] = trimmedMobile
        } else {
            userData["mobileNumber"] = FieldValue.delete()
        }
        
        if let policyAcceptedAt = user.policyAcceptedAt {
            userData["policyAcceptedAt"] = Timestamp(date: policyAcceptedAt)
        } else {
            userData["policyAcceptedAt"] = FieldValue.delete()
        }
        if let legalPackVersion = user.legalPackVersion, !legalPackVersion.isEmpty {
            userData["legalPackVersion"] = legalPackVersion
        }
        
        let lineManagerIds = user.lineManagerUserIds
        if lineManagerIds.isEmpty {
            userData["assignedManagerUserId"] = FieldValue.delete()
            userData["assignedManagerUserIds"] = FieldValue.delete()
        } else {
            userData["assignedManagerUserId"] = lineManagerIds[0]
            userData["assignedManagerUserIds"] = lineManagerIds
        }
        
        // RULEBOOK §8: `payBasis` plus exactly one amount (`readStoredRates` → `exclusiveRates`).
        let storedPay = CanonicalBusinessEngine.readStoredRates(
            payBasis: user.payBasis,
            dayRate: user.dayRate,
            hourlyRate: user.hourlyRate
        )
        let storedBasis = storedPay?.payBasis
        let storedAmount = storedBasis == "hourly" ? storedPay?.hourlyRate : storedPay?.dayRate
        for (key, value) in exclusivePayFields(payBasis: storedBasis, amount: storedBasis == nil ? nil : storedAmount) {
            userData[key] = value
        }
        if let p = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            userData["tradeTypePreset"] = p
        }
        if let c = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            userData["tradeTypeCustom"] = c
        }
        
        if let photo = user.profilePhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !photo.isEmpty {
            userData["profilePhotoURL"] = photo
        } else {
            userData["profilePhotoURL"] = FieldValue.delete()
        }
        
        // RULEBOOK 1.8.0: figures read before the organisation's leave defaults loaded are not the person's own and
        // are never saved (`annualLeaveDefaultsPending`).
        if !user.annualLeaveDefaultsPending {
            userData["annualLeaveDaysPerYear"] = AnnualLeavePolicy.clampDaysPerYear(user.annualLeaveDaysPerYear)
            userData["annualLeaveYearStartMonth"] = AnnualLeavePolicy.clampMonth(user.annualLeaveYearStartMonth)
            userData["annualLeaveYearEndMonth"] = AnnualLeavePolicy.clampMonth(user.annualLeaveYearEndMonth)
            userData["annualLeaveCarriesOver"] = user.annualLeaveCarriesOver
        }
        userData["annualLeaveEnabled"] = user.annualLeaveEnabled
        if let pot = user.annualLeaveYearAllowance {
            userData["annualLeaveYearAllowance"] = pot
        }
        if let key = user.annualLeaveYearAllowanceKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            userData["annualLeaveYearAllowanceKey"] = key
        }
        userData["hasNoLineManager"] = user.hasNoLineManager
        userData["timesheetsEnabled"] = user.timesheetsEnabled
        // UTR and VAT number live in users/{uid}/private/taxIds. See `saveSensitiveProfile`.
        return userData
    }

    /// Writes a profile (RULEBOOK §1, §11, §12).
    /// - An existing document gets `updateData` of the fields the rulebook's `userProfileWriteFields` names between
    ///   `previous` (the copy the caller edited) and `user`, plus `WriteMetadata`. Without `previous`, the server
    ///   document is read through `parseUserDocument` and used as that copy. Never a full merge-set. Line manager
    ///   ids with `hasNoLineManager`, pay basis with both rates, employment type with its transition and the name
    ///   fields are written as groups; a field the copy lacks is never deleted.
    /// - Never `organizationId` or `createdAt` (`userProfileWriteFields` create-only), and never a `profilePhotoURL`
    ///   delete (a stale copy without the photo must not remove it; the photo upload path writes it).
    /// - A document the server confirms missing is created once with the full profile.
    func saveUser(_ user: AppUser, previous: AppUser? = nil) async throws {
        let payload = Self.userDocumentPayload(user)
        if sessionsAreSeparate(for: user) {
            var membershipPayload = payload
            membershipPayload["updatedAt"] = Timestamp(date: Date())
            try await saveSeparateDeviceSession(user, payload: membershipPayload)
            return
        }
        let ref = db.collection("users").document(user.id)
        let uid = auth.currentUser?.uid
        let baseline: [String: Any]
        if let previous, previous.id == user.id {
            baseline = Self.userDocumentPayload(previous)
        } else {
            let snapshot = try await ref.getDocument(source: .server)
            guard snapshot.exists, let stored = snapshot.data() else {
                let create = payload.filter { !($0.value is FieldValue) }
                try await ref.setData(WriteMetadata.stamped(create, userId: uid))
                return
            }
            baseline = Self.userDocumentPayload(Self.parseAppUserDocument(userId: user.id, data: stored))
        }
        guard let write = CanonicalBusinessEngine.peopleDocumentWrite("userProfileWriteFields", before: baseline, next: payload) else {
            throw CanonicalWriteUnavailableError(function: "userProfileWriteFields")
        }
        var changes = write.firestoreFields(from: payload)
        changes.removeValue(forKey: "organizationId")
        changes.removeValue(forKey: "createdAt")
        if changes["profilePhotoURL"] is FieldValue {
            changes.removeValue(forKey: "profilePhotoURL")
        }
        guard !changes.isEmpty else { return }
        try await ref.updateData(WriteMetadata.stamped(changes, userId: uid))
    }

    /// Deactivate / reactivate: only `isActive` plus `WriteMetadata` on `users/{uid}` (RULEBOOK §11).
    func updateUserActiveFlag(userId: String, isActive: Bool) async throws {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await db.collection("users").document(trimmed)
            .updateData(WriteMetadata.stamped(["isActive": isActive], userId: auth.currentUser?.uid))
    }

    /// True when this phone is in a different company from `users/{uid}.organizationId`.
    private func sessionsAreSeparate(for user: AppUser) -> Bool {
        guard user.id == auth.currentUser?.uid,
              let shared = sharedUserOrganizationId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shared.isEmpty else { return false }
        return !organizationIdsMatch(shared, user.organizationId)
    }

    /// Writes the phone's profile onto `orgMemberships/{org}` and leaves the shared user document's company alone.
    /// Name, email, and phone still update on `users/{uid}` so a profile save sticks.
    private func saveSeparateDeviceSession(_ user: AppUser, payload: [String: Any]) async throws {
        try await patchUserIdentity(
            userId: user.id,
            firstName: user.firstName,
            surname: user.surname,
            email: user.email,
            mobileNumber: user.mobileNumber
        )
        try await snapshotCurrentUserOntoMembership(
            userId: user.id,
            organizationId: user.organizationId,
            userData: payload
        )
        deviceSessionProfile = user
    }

    /// Name, email, and phone only. Does not touch organisation, role, or permission flags.
    func patchUserIdentity(
        userId: String,
        firstName: String,
        surname: String,
        email: String,
        mobileNumber: String?
    ) async throws {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSurname = surname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let display = [trimmedFirst, trimmedSurname].filter { !$0.isEmpty }.joined(separator: " ")
        var payload: [String: Any] = [
            "firstName": trimmedFirst,
            "surname": trimmedSurname,
            "lastName": trimmedSurname,
            "email": trimmedEmail,
            "updatedAt": Timestamp(date: Date())
        ]
        if !display.isEmpty {
            payload["name"] = display
            payload["displayName"] = display
        }
        let trimmedMobile = mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedMobile.isEmpty {
            payload["mobileNumber"] = trimmedMobile
        } else {
            payload["mobileNumber"] = FieldValue.delete()
        }
        try await db.collection("users").document(userId).updateData(payload)
    }

    // MARK: - Sensitive profile (users/{uid}/private/taxIds)

    private func sensitiveProfileRef(userId: String) -> DocumentReference? {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let path = CanonicalBusinessEngine.sensitiveProfileDocPath(userId: trimmed) else { return nil }
        return db.document(path)
    }

    /// UTR and VAT number through `resolveSensitiveProfile`: the private document once it exists, else the legacy
    /// fields still on users/{uid}. Callers check `canViewSensitiveProfile` first; the rules refuse anyone else.
    func loadSensitiveProfile(userId: String, legacyUser: [String: Any]?) async throws -> CanonicalBusinessEngine.CanonicalSensitiveProfile? {
        guard let ref = sensitiveProfileRef(userId: userId) else { return nil }
        let snapshot = try await ref.getDocument()
        let privateDoc: [String: Any]? = snapshot.exists ? (snapshot.data() ?? [:]) : nil
        return CanonicalBusinessEngine.resolveSensitiveProfile(privateDoc: privateDoc, legacyUser: legacyUser)
    }

    /// Writes users/{uid}/private/taxIds from `sensitiveProfileWriteFields` (blank clears), then removes the legacy
    /// fields from users/{uid}. Does not send role, permissions, or organizationId.
    func saveSensitiveProfile(userId: String, utrNumber: String?, vatNumber: String?) async throws {
        guard let ref = sensitiveProfileRef(userId: userId),
              let signedIn = auth.currentUser?.uid,
              let write = CanonicalBusinessEngine.sensitiveProfileWriteFields(
                utrNumber: utrNumber,
                vatNumber: vatNumber,
                updatedByUserId: signedIn
              ) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not save UTR and VAT number. Try again."]
            )
        }
        guard write.ok, let fields = write.fields else {
            let limit = CanonicalBusinessEngine.sensitiveValueMax ?? 20
            let message = write.error == "too_long"
                ? "UTR and VAT number can be up to \(limit) characters each."
                : "Could not save UTR and VAT number. Try again."
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try await ref.setData([
            "utrNumber": fields.utrNumber,
            "vatNumber": fields.vatNumber,
            "updatedByUserId": fields.updatedByUserId,
            "updatedAt": FieldValue.serverTimestamp()
        ])
        do {
            try await db.collection("users").document(userId.trimmingCharacters(in: .whitespacesAndNewlines)).updateData([
                "utrNumber": FieldValue.delete(),
                "vatNumber": FieldValue.delete()
            ])
        } catch {
            // The private document already wins on read; the legacy copy is cleared on the next save.
            print("🔥🔥🔥 DEBUG: Could not clear legacy tax fields: \((error as NSError).code)")
        }
    }

    /// Timesheets toggle only. Does not send role, permissions, or organizationId.
    func patchOwnUserTimesheetsEnabled(userId: String, enabled: Bool) async throws {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Timesheets setting needs a user id."]
            )
        }
        try await db.collection("users").document(trimmed).updateData([
            "timesheetsEnabled": enabled,
            "updatedAt": Timestamp(date: Date())
        ])
    }

    func recordLegalPackAcceptance(
        userId: String,
        email: String,
        organizationName: String,
        authorisedToBind: Bool
    ) async throws {
        try await db.collection("users").document(userId).setData(
            [
                "legalPackVersion": CustomerLegalPack.version,
                "legalPackAcceptedAt": Timestamp(date: Date()),
                "legalAcceptances": [
                    "saas": true,
                    "dpa": true,
                    "aup": true,
                    "privacy": true,
                    "authorisedToBind": authorisedToBind,
                    "organizationName": organizationName,
                    "email": email,
                    "userId": userId,
                ],
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
        )
    }

    /// Permission flags that differ, plus `updatedAt`. Never writes `organizationId` or `isSuperAdmin`.
    /// A save of the signed-in user also omits `role`, `adminAccess`, and `permissions.adminAccess`.
    func patchChangedUserPermissions(
        userId: String,
        previous: UserPermissions,
        updated: UserPermissions,
        previousRole: UserRole,
        nextRole: UserRole?
    ) async throws {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Permissions need a user id."]
            )
        }
        let isSelf = auth.currentUser?.uid == trimmed
        var payload: [String: Any] = [:]
        let flags: [(String, Bool, Bool)] = [
            ("adminAccess", previous.adminAccess, updated.adminAccess),
            ("manager", previous.manager, updated.manager),
            ("operatives", previous.operatives, updated.operatives),
            ("skills", previous.skills, updated.skills),
            ("qualifications", previous.qualifications, updated.qualifications),
            ("materials", previous.materials, updated.materials),
            ("projects", previous.projects, updated.projects),
            ("smallWorks", previous.smallWorks, updated.smallWorks),
            ("operativeMode", previous.operativeMode, updated.operativeMode),
            ("annualLeaveSelfBook", previous.annualLeaveSelfBook, updated.annualLeaveSelfBook),
            ("weeklyReports", previous.weeklyReports, updated.weeklyReports),
            ("dailyOverview", previous.dailyOverview, updated.dailyOverview),
            ("subContractors", previous.subContractors, updated.subContractors),
            ("siteAudit", previous.siteAudit, updated.siteAudit),
            ("wholesalersOrderHistory", previous.wholesalersOrderHistory, updated.wholesalersOrderHistory),
        ]
        for (key, oldValue, newValue) in flags where oldValue != newValue {
            if isSelf && key == "adminAccess" { continue }
            payload[key] = newValue
            payload["permissions.\(key)"] = newValue
        }
        if !isSelf, let nextRole, nextRole != previousRole {
            payload["role"] = nextRole.rawValue
        }
        guard !payload.isEmpty else { return }
        payload["updatedAt"] = Timestamp(date: Date())
        try await db.collection("users").document(trimmed).updateData(payload)
    }

    /// Patch-only annual leave entitlement. Does not write organizationId.
    func updateAnnualLeaveEntitlement(
        userId: String,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        yearAllowance: Double? = nil,
        yearAllowanceKey: String? = nil,
        writeYearAllowance: Bool = false
    ) async throws {
        var payload: [String: Any] = [
            "annualLeaveDaysPerYear": AnnualLeavePolicy.clampDaysPerYear(daysPerYear),
            "annualLeaveYearStartMonth": AnnualLeavePolicy.clampMonth(startMonth),
            "annualLeaveYearEndMonth": AnnualLeavePolicy.clampMonth(endMonth),
            "annualLeaveCarriesOver": carriesOver,
            "updatedAt": Timestamp(date: Date()),
        ]
        if writeYearAllowance, let yearAllowance, let yearAllowanceKey, !yearAllowanceKey.isEmpty {
            payload["annualLeaveYearAllowance"] = yearAllowance
            payload["annualLeaveYearAllowanceKey"] = yearAllowanceKey
        }
        try await db.collection("users").document(userId).updateData(payload)
    }

    /// Patch-only: show or hide annual leave in the app. Does not write organizationId.
    func updateAnnualLeaveEnabled(userId: String, enabled: Bool) async throws {
        let payload: [String: Any] = [
            "annualLeaveEnabled": enabled,
            "updatedAt": Timestamp(date: Date()),
        ]
        try await db.collection("users").document(userId).updateData(payload)
    }

    /// Employment fields only, plus `updatedAt`. Does not write organizationId.
    /// `timesheetsEnabled` is included only when the caller passes it (admin saves). Manager patches omit it so the operative allow-list still matches.
    func updateUserEmploymentType(
        userId: String,
        employmentType: EmploymentType,
        transitionFrom: EmploymentType? = nil,
        effectiveAt: Date? = nil,
        timesheetsEnabled: Bool? = nil
    ) async throws {
        var payload: [String: Any] = [
            "employmentType": employmentType.rawValue,
            "updatedAt": Timestamp(date: Date()),
        ]
        if let transitionFrom {
            payload["employmentTypeTransitionFrom"] = transitionFrom.rawValue
        } else {
            payload["employmentTypeTransitionFrom"] = FieldValue.delete()
        }
        if let effectiveAt {
            payload["employmentTypeEffectiveAt"] = Timestamp(date: effectiveAt)
        } else {
            payload["employmentTypeEffectiveAt"] = FieldValue.delete()
        }
        if let timesheetsEnabled {
            payload["timesheetsEnabled"] = timesheetsEnabled
        }
        try await db.collection("users").document(userId).updateData(payload)
    }

    /// Keeps `organizations/{orgId}/userEmails/{email}` aligned when a member’s profile email changes.
    func reconcileUserEmailIndex(organizationId: String, userId: String, oldEmailNormalized: String, newEmail: String) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let newNorm = newEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let oldNorm = oldEmailNormalized.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newNorm.isEmpty else { return }
        let orgRef = db.collection("organizations").document(orgId)
        if oldNorm != newNorm {
            try? await orgRef.collection("userEmails").document(oldNorm).delete()
        }
        try await orgRef.collection("userEmails").document(newNorm).setData(["userId": userId], merge: true)
    }

    /// Sends a verification link to `newEmail`. After the user completes it, Firebase Authentication updates the **sign-in** email. Only valid for `auth.currentUser`.
    func sendVerifyBeforeUpdateEmail(to newEmail: String) async throws {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = auth.currentUser else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to update the sign-in email."]
            )
        }
        try await user.sendEmailVerification(beforeUpdatingEmail: trimmed, actionCodeSettings: nil)
    }
    
    /// A photo upload stores the fresh download URL and `profilePhotoUpdatedAt`, which tells every screen
    /// and web the picture changed (RULEBOOK §12, as web `SettingsScreen` writes it).
    func updateUserProfilePhotoURL(userId: String, url: String?) async throws {
        var payload: [String: Any] = [:]
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            payload["profilePhotoURL"] = url
        } else {
            payload["profilePhotoURL"] = FieldValue.delete()
        }
        payload["profilePhotoUpdatedAt"] = FieldValue.serverTimestamp()
        try await db.collection("users").document(userId)
            .updateData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))
    }

    func updateUserStaffTradeMetadata(userId: String, tradeTypePreset: String?, tradeTypeCustom: String?) async throws {
        var payload: [String: Any] = [
            "updatedAt": Timestamp(date: Date())
        ]
        let p = tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p, !p.isEmpty {
            payload["tradeTypePreset"] = p
        } else {
            payload["tradeTypePreset"] = FieldValue.delete()
        }
        if let c, !c.isEmpty {
            payload["tradeTypeCustom"] = c
        } else {
            payload["tradeTypeCustom"] = FieldValue.delete()
        }
        try await db.collection("users").document(userId).updateData(payload)
    }

    /// `payBasis` plus exactly one of `dayRate` / `hourlyRate`, the other deleted (RULEBOOK §8, `exclusiveRates`).
    /// `amount` nil clears the rate: all three fields are deleted, as web `applyExclusiveRateFields` does.
    static func exclusivePayFields(payBasis: String?, amount: Double?) -> [String: Any] {
        guard let amount, amount.isFinite else {
            return ["payBasis": FieldValue.delete(), "dayRate": FieldValue.delete(), "hourlyRate": FieldValue.delete()]
        }
        let requested = payBasis == "hourly" ? "hourly" : "day"
        let pay = CanonicalBusinessEngine.exclusiveRates(
            payBasis: requested,
            dayRate: requested == "day" ? amount : nil,
            hourlyRate: requested == "hourly" ? amount : nil
        )
        if (pay?.payBasis ?? requested) == "hourly" {
            return ["payBasis": "hourly", "hourlyRate": pay?.hourlyRate ?? amount, "dayRate": FieldValue.delete()]
        }
        return ["payBasis": "day", "dayRate": pay?.dayRate ?? amount, "hourlyRate": FieldValue.delete()]
    }

    /// Patch-only update for operative profile metadata managed from Manage Users.
    /// Writes only targeted fields (line manager, and the rate when `updateDayRate`) plus `WriteMetadata`.
    /// `dayRate` is the amount for `payBasis` (`day` when nil).
    func updateOperativeProfileMetadata(
        userId: String,
        assignedManagerUserId: String?,
        assignedManagerUserIds: [String]? = nil,
        hasNoLineManager: Bool? = nil,
        dayRate: Double?,
        updateDayRate: Bool = true,
        payBasis: String? = nil
    ) async throws {
        var payload: [String: Any] = [:]
        let ids: [String] = {
            if hasNoLineManager == true { return [] }
            if let assignedManagerUserIds {
                return assignedManagerUserIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let managerId = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !managerId.isEmpty {
                return [managerId]
            }
            return []
        }()
        if ids.isEmpty {
            payload["assignedManagerUserId"] = FieldValue.delete()
            payload["assignedManagerUserIds"] = FieldValue.delete()
        } else {
            payload["assignedManagerUserId"] = ids[0]
            payload["assignedManagerUserIds"] = ids
        }
        if updateDayRate {
            for (key, value) in Self.exclusivePayFields(payBasis: payBasis, amount: dayRate) {
                payload[key] = value
            }
        }
        try await db.collection("users").document(userId)
            .updateData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))
    }

    /// Rate-only patch on `users/{uid}`: `payBasis` plus one amount (`exclusivePayFields`) and `WriteMetadata`.
    func updateUserDayRateMetadata(userId: String, dayRate: Double?, payBasis: String? = nil) async throws {
        let payload = Self.exclusivePayFields(payBasis: payBasis, amount: dayRate)
        try await db.collection("users").document(userId)
            .updateData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))
    }

    /// Client heartbeat for “last seen”; merge-only so other writes are not replaced.
    func updateUserLastSeenAt(userId: String) async throws {
        try await db.collection("users").document(userId).setData(
            [
                "lastSeenAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
        )
    }

    /// Mirror of the person's pay and line manager at organizations/{orgId}/operativeProfiles/{userId}
    /// (web `saveUser` writes the same mirror). It is never read over `users/{uid}` and is never a
    /// fallback for a refused users write. Only someone who may change this person's pay writes it
    /// (`canChangePersonPay`, checked by the caller; firestore.rules `canChangePayOf`).
    func saveOperativeProfileMetadataFallback(
        organizationId: String,
        userId: String,
        assignedManagerUserId: String?,
        dayRate: Double?,
        payBasis: String? = nil
    ) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let ref = db.collection("organizations")
            .document(orgId)
            .collection("operativeProfiles")
            .document(userId)

        // RULEBOOK 1.8.0 §1: `operativeProfileWriteFields` (pay basis with both rates, manager id with the list,
        // each written together; `userId` / `createdAt` create-only), against the server copy.
        var payload: [String: Any] = ["userId": userId]
        if let managerId = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !managerId.isEmpty {
            payload["assignedManagerUserId"] = managerId
            payload["assignedManagerUserIds"] = [managerId]
        } else {
            payload["assignedManagerUserId"] = FieldValue.delete()
            payload["assignedManagerUserIds"] = FieldValue.delete()
        }
        for (key, value) in Self.exclusivePayFields(payBasis: payBasis, amount: dayRate) {
            payload[key] = value
        }
        try await writeOperationsDocument(ref, writeFields: "operativeProfileWriteFields") { _ in payload }
    }

    func loadOperativeProfileMetadataFallback(organizationId: String) async throws -> [String: OperativeProfileMetadata] {
        let orgId = try await ensureReadableOrganization(organizationId)
        let query = db.collection("organizations")
            .document(orgId)
            .collection("operativeProfiles")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await query.getDocuments(source: .server)
        } catch {
            snapshot = try await query.getDocuments()
        }

        var mapped: [String: OperativeProfileMetadata] = [:]
        // RULEBOOK 1.8.0 §1: `parseOperativeProfileDocument` (rates via `readStoredRates`; iOS read `dayRate` only).
        for doc in snapshot.documents {
            guard let row = CanonicalBusinessEngine.parseOperativeProfileDocument(documentId: doc.documentID, data: doc.data()) else { continue }
            let userId = row.text("userId")
            mapped[userId] = OperativeProfileMetadata(
                userId: userId,
                assignedManagerUserId: row.optionalText("assignedManagerUserId"),
                dayRate: row.number("dayRate"),
                payBasis: row.optionalText("payBasis"),
                hourlyRate: row.number("hourlyRate"),
                assignedManagerUserIds: row.strings("assignedManagerUserIds")
            )
        }
        return mapped
    }
    
    // Helper method to update only user permissions (for fixing admin status)
    /// Never persists isSuperAdmin for operatives – prevents elevation from ever being saved.
    func updateUserPermissions(userId: String, isSuperAdmin: Bool, adminAccess: Bool, role: UserRole) async throws {
        var isSuperAdminToWrite = isSuperAdmin
        if isSuperAdminToWrite {
            let doc = try? await db.collection("users").document(userId).getDocument()
            if let data = doc?.data(), data["operativeMode"] as? Bool == true {
                isSuperAdminToWrite = false
            }
        }
        try await db.collection("users").document(userId).updateData([
            "isSuperAdmin": isSuperAdminToWrite,
            "adminAccess": adminAccess,
            "role": role.rawValue
        ])
    }

    // MARK: - Ownership transfer (Super Admin reassignment)

    /// Transfers organisation ownership to another administrator.
    /// Writes `creatorUserId`, `isSuperAdmin`, `adminAccess`, and `role` only. Other permission toggles stay as they are.
    /// - Parameter alsoDemoteUserIds: Roster users who already have `isSuperAdmin`, including people whose `organizationId` is another company.
    func transferOrganizationOwnership(
        organizationId: String,
        newCreatorUserId: String,
        alsoDemoteUserIds: [String] = []
    ) async throws {
        let orgId = normalizedOrganizationId(organizationId)
        let newId = newCreatorUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty, !newId.isEmpty else {
            throw ownershipTransferError("Organization or new Super Admin is missing.")
        }
        guard let signedInId = currentUser?.uid.trimmingCharacters(in: .whitespacesAndNewlines), !signedInId.isEmpty else {
            throw ownershipTransferError("You need to be signed in to change the Super Admin.")
        }
        guard signedInId != newId else {
            throw ownershipTransferError("You are already the Super Admin.")
        }

        let orgRef = db.collection("organizations").document(orgId)
        let orgSnap = try await orgRef.getDocument()
        guard orgSnap.exists else {
            throw ownershipTransferError("Organization not loaded.")
        }
        let previousCreatorId = (orgSnap.data()?["creatorUserId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let signedInSnap = try await db.collection("users").document(signedInId).getDocument()
        let signedInFlag = signedInSnap.exists && storedUserFlag(signedInSnap.data() ?? [:], "isSuperAdmin")
        guard signedInFlag else {
            throw ownershipTransferError("Only the Super Admin can transfer ownership.")
        }

        let newOwnerSnap = try await db.collection("users").document(newId).getDocument()
        guard newOwnerSnap.exists, let newOwnerData = newOwnerSnap.data() else {
            throw ownershipTransferError("That administrator could not be found.")
        }
        guard !storedUserFlag(newOwnerData, "operativeMode") else {
            throw ownershipTransferError("Cannot make an operative the Super Admin.")
        }
        guard storedUserIsAdmin(newOwnerData) else {
            throw ownershipTransferError("Only an Admin can be made Super Admin.")
        }

        var outgoing = await currentSuperAdminUserIds(
            organizationId: orgId,
            previousCreatorUserId: previousCreatorId,
            signedInUserId: signedInId,
            alsoDemoteUserIds: alsoDemoteUserIds
        )
        outgoing.remove(newId)

        let now = Timestamp(date: Date())
        try await orgRef.updateData([
            "creatorUserId": newId,
            "updatedAt": now
        ])

        for userId in outgoing {
            let fields = outgoingAdministratorFields(at: now)
            try await writeSuperAdminTransferFields(userId: userId, fields: fields)
            await patchOrgMembershipSuperAdminFields(userId: userId, organizationId: orgId, fields: fields)
        }
        let ownerFields = incomingSuperAdminFields(at: now)
        try await writeSuperAdminTransferFields(userId: newId, fields: ownerFields)
        await patchOrgMembershipSuperAdminFields(userId: newId, organizationId: orgId, fields: ownerFields)

        if organizationIdsMatch(currentOrganization?.firestoreDocumentId, orgId) {
            currentOrganization?.creatorUserId = newId
        }
    }

    private func ownershipTransferError(_ message: String) -> NSError {
        NSError(domain: "OwnershipTransfer", code: 403, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Top-level flag wins. Nested `permissions` covers website writes. Missing is false.
    private func storedUserFlag(_ data: [String: Any], _ key: String) -> Bool {
        let nested = data["permissions"] as? [String: Any] ?? [:]
        if let top = firestoreBool(data[key]) { return top }
        if let nestedValue = firestoreBool(nested[key]) { return nestedValue }
        return false
    }

    private func storedUserIsAdmin(_ data: [String: Any]) -> Bool {
        if storedUserFlag(data, "adminAccess") { return true }
        let role = (data["role"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return role == UserRole.admin.rawValue || role.contains("admin")
    }

    /// People who must leave the super-admin role: every `isSuperAdmin` user linked to this organisation, the signed-in super admin, and the previous creator.
    private func currentSuperAdminUserIds(
        organizationId: String,
        previousCreatorUserId: String?,
        signedInUserId: String,
        alsoDemoteUserIds: [String]
    ) async -> Set<String> {
        var ids = Set<String>()
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            ids.insert(trimmed)
        }
        add(previousCreatorUserId)
        add(signedInUserId)
        for userId in alsoDemoteUserIds { add(userId) }

        let orgUsers = (try? await userDocuments(whereOrganizationIdEquals: organizationId, required: false)) ?? []
        for doc in orgUsers where storedUserFlag(doc.data(), "isSuperAdmin") {
            add(doc.documentID)
        }
        return ids
    }

    private func outgoingAdministratorFields(at now: Timestamp) -> [String: Any] {
        [
            "isSuperAdmin": false,
            "adminAccess": true,
            "role": UserRole.admin.rawValue,
            "permissions.adminAccess": true,
            "updatedAt": now
        ]
    }

    private func incomingSuperAdminFields(at now: Timestamp) -> [String: Any] {
        [
            "isSuperAdmin": true,
            "adminAccess": true,
            "role": UserRole.admin.rawValue,
            "permissions.adminAccess": true,
            "updatedAt": now
        ]
    }

    /// Keeps an existing phone-session snapshot in step with the transfer. Does not create a membership document.
    private func patchOrgMembershipSuperAdminFields(userId: String, organizationId: String, fields: [String: Any]) async {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let orgId = normalizedOrganizationId(organizationId)
        guard !trimmed.isEmpty, !orgId.isEmpty else { return }
        let ref = db.collection("users").document(trimmed).collection("orgMemberships").document(orgId)
        do {
            let snap = try await ref.getDocument()
            guard snap.exists else { return }
            var topLevel = fields
            topLevel.removeValue(forKey: "permissions.adminAccess")
            try await ref.updateData(topLevel)
        } catch {
            print("🔥🔥🔥 DEBUG: membership super-admin flag patch skipped for \(trimmed): \(error.localizedDescription)")
        }
    }

    /// Partial update. A nested `permissions.adminAccess` write keeps every other toggle. If that map is not a map, the top-level fields still save.
    private func writeSuperAdminTransferFields(userId: String, fields: [String: Any]) async throws {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ref = db.collection("users").document(trimmed)
        let snap = try await ref.getDocument()
        guard snap.exists else { return }
        do {
            try await ref.updateData(fields)
        } catch {
            var topLevel = fields
            topLevel.removeValue(forKey: "permissions.adminAccess")
            try await ref.updateData(topLevel)
        }
    }
    
    // Placeholder cleanup no longer needed - placeholders are no longer created
    
    func verifyOrganizationStructure() async {
        print("🔥🔥🔥 DEBUG: === Verifying Organization Structure ===")
        
        guard let organizationId = currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: No organization ID available")
            return
        }
        
        do {
            // Check if organization document exists
            let orgDoc = try await db.collection("organizations").document(organizationId).getDocument()
            if orgDoc.exists {
                print("🔥🔥🔥 DEBUG: Organization document exists: \(orgDoc.documentID)")
            } else {
                print("🔥🔥🔥 DEBUG: Organization document does not exist!")
            }
            
            // Check projects subcollection
            let projectsSnapshot = try await db.collection("organizations").document(organizationId).collection("projects").getDocuments()
            print("🔥🔥🔥 DEBUG: Projects subcollection has \(projectsSnapshot.documents.count) documents")
            
            // Check operatives subcollection
            let operativesSnapshot = try await db.collection("organizations").document(organizationId).collection("operatives").getDocuments()
            print("🔥🔥🔥 DEBUG: Operatives subcollection has \(operativesSnapshot.documents.count) documents")
            
            // Check clients subcollection
            let clientsSnapshot = try await db.collection("organizations").document(organizationId).collection("clients").getDocuments()
            print("🔥🔥🔥 DEBUG: Clients subcollection has \(clientsSnapshot.documents.count) documents")
            
                // Check bookings subcollection
                let bookingsSnapshot = try await db.collection("organizations").document(organizationId).collection("bookings").getDocuments()
                print("🔥🔥🔥 DEBUG: Bookings subcollection has \(bookingsSnapshot.documents.count) documents")
                
                // Check managers subcollection
                let managersSnapshot = try await db.collection("organizations").document(organizationId).collection("managers").getDocuments()
                print("🔥🔥🔥 DEBUG: Managers subcollection has \(managersSnapshot.documents.count) documents")
                
            } catch {
                print("🔥🔥🔥 DEBUG: Error verifying organization structure: \(error.localizedDescription)")
            }
        
        print("🔥🔥🔥 DEBUG: === End Organization Structure Verification ===")
    }
    
    // MARK: - Notifications

    /// RULEBOOK §13: a device push token belongs to the signed-in account only. It is written to
    /// `users/{uid}.pushTokens` of that account and never copied to other `users` documents on the same email.
    func registerPushToken(_ token: String) async {
        guard let authUser = currentUser else { return }
        let uid = authUser.uid
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await writePushTokens(userId: uid, currentDeviceToken: trimmed)
            registeredPushToken = trimmed
            print("🔥🔥🔥 DEBUG: Registered push token for user \(uid)")
        } catch {
            print("🔥🔥🔥 DEBUG: Failed to register push token: \(error.localizedDescription)")
        }
    }

    /// RULEBOOK §13: signing out removes this device's token from every `users` document it was written to —
    /// the signed-in account and, because older builds copied it there, every same-email `users` document in the
    /// open company (`pushTokens` arrayRemove, a partial update). Call before `signOut()`. Waits at most
    /// `timeoutSeconds` for the server; sign-out goes ahead either way.
    func removeThisDevicePushTokenBeforeSignOut(timeoutSeconds: Double = 5) async {
        guard let authUser = auth.currentUser else { return }
        var token = registeredPushToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
#if canImport(FirebaseMessaging)
        if token.isEmpty {
            token = Messaging.messaging().fcmToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
#endif
        guard !token.isEmpty else { return }
        let uid = authUser.uid
        let email = authUser.email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let orgId = currentOrganization?.firestoreDocumentId ?? ""
        let progress = PushTokenRemovalProgress()
        Task {
            await self.removePushToken(token, uid: uid, email: email, organizationId: orgId)
            progress.finished = true
        }
        var waited = 0.0
        while !progress.finished && waited < timeoutSeconds {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        registeredPushToken = nil
    }

    private func removePushToken(_ token: String, uid: String, email: String, organizationId: String) async {
        var docIds: [String] = [uid]
        if !email.isEmpty, !organizationId.isEmpty {
            // Same company only, as the old mirror wrote it. Users are never listed by email alone.
            do {
                let orgUsers = try await db.collection("users")
                    .whereField("organizationId", isEqualTo: organizationId)
                    .limit(to: 250)
                    .getDocuments()
                for doc in orgUsers.documents where doc.documentID != uid {
                    let docEmail = (doc.data()["email"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() ?? ""
                    if docEmail == email { docIds.append(doc.documentID) }
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Sign-out token cleanup could not list same-email users: \(error.localizedDescription)")
            }
        }
        for docId in docIds {
            do {
                try await db.collection("users").document(docId).updateData([
                    "pushTokens": FieldValue.arrayRemove([token])
                ])
            } catch {
                print("🔥🔥🔥 DEBUG: Sign-out token cleanup failed for a users document: \(error.localizedDescription)")
            }
        }
        print("🔥🔥🔥 DEBUG: Removed this device's push token from \(docIds.count) users document(s) before sign-out")
    }

    /// Drops one token after FCM/APNs reports it dead. Does not clear tokens that have not failed.
    func recordPushTokenFailure(token: String, message: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, LaunchStartupPolicy.isTerminalPushTokenFailure(message) else { return }
        guard let uid = currentUser?.uid, !uid.isEmpty else { return }
        failedPushTokens.insert(trimmed)
        do {
            try await writePushTokens(userId: uid, currentDeviceToken: "")
            print("🔥🔥🔥 DEBUG: Removed a dead push token. stored failures=\(failedPushTokens.count)")
        } catch {
            print("🔥🔥🔥 DEBUG: Failed to remove a dead push token: \(error.localizedDescription)")
        }
    }

    private func writePushTokens(userId: String, currentDeviceToken: String) async throws {
        let ref = db.collection("users").document(userId)
        // A failed read is not an empty list. Replacing pushTokens then would delete tokens this client never received.
        let snap = try await ref.getDocument(source: .server)
        let existing = (snap.data()?["pushTokens"] as? [String]) ?? []
        let next = LaunchStartupPolicy.nextStoredPushTokens(
            existing: existing,
            currentDeviceToken: currentDeviceToken,
            failedTokens: failedPushTokens
        )
        guard next != existing else { return }
        try await ref.setData([
            "pushTokens": next,
            "pushTokenUpdatedAt": Timestamp(date: Date())
        ], merge: true)
    }

    func forceRefreshAndRegisterPushToken() async -> String {
        guard currentUser != nil else { return "❌ Not signed in." }
#if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
#endif
#if canImport(FirebaseMessaging)
        return await withCheckedContinuation { continuation in
            Messaging.messaging().token { [weak self] token, error in
                if let error {
                    continuation.resume(returning: "❌ Failed to fetch FCM token: \(error.localizedDescription)")
                    return
                }
                guard let self, let token, !token.isEmpty else {
                    continuation.resume(returning: "❌ FCM token unavailable.")
                    return
                }
                Task {
                    await self.registerPushToken(token)
                    continuation.resume(returning: "✅ Refreshed and registered FCM token.")
                }
            }
        }
#else
        return "❌ FirebaseMessaging not available in this build."
#endif
    }
    
    func saveNotification(
        _ notification: AppNotification,
        organizationId: String,
        preserveExistingReadState: Bool = false,
        onlyIfMissing: Bool = false,
        actorUserId: String? = nil
    ) async throws {
        let idKey = notification.id.uuidString
        guard LaunchStartupPolicy.shouldStartInboxWrite(
            onlyIfMissing: onlyIfMissing,
            alreadyAcceptedIds: acceptedMissingNotificationIds,
            notificationId: idKey
        ) else { return }
        if onlyIfMissing {
            acceptedMissingNotificationIds.insert(idKey)
        }
        let ref = db.collection("organizations").document(organizationId).collection("notifications").document(WorkDocumentKeys.storedId(for: notification.id))
        var isRead = notification.isRead
        if onlyIfMissing || preserveExistingReadState {
            let existing = try? await ref.getDocument()
            if existing?.exists == true {
                if onlyIfMissing { return }
                if (existing?.data()?["isRead"] as? Bool) == true {
                    isRead = true
                }
            }
        }
        let relatedIdValue: Any
        if notification.type == .timesheetSubmissionReminder,
           let dayKey = notification.dayKey,
           AppNotification.isInboxDayKey(dayKey) {
            relatedIdValue = dayKey
        } else {
            relatedIdValue = notification.relatedKey ?? NSNull()
        }
        var data: [String: Any] = [
            "organizationId": notification.organizationId,
            "type": notification.typeText,
            "title": notification.title,
            "message": notification.message,
            "userId": notification.userId ?? NSNull(),
            "relatedId": relatedIdValue,
            "isRead": isRead,
            "createdAt": Timestamp(date: notification.createdAt),
            "requiresPermission": notification.requiresPermission ?? NSNull(),
            "deepLinkUserId": notification.deepLinkUserId ?? NSNull(),
            "deepLinkWeekStart": (notification.deepLinkWeekStart.map(Timestamp.init(date:)) ?? NSNull()) as Any
        ]
        if let dayKey = notification.dayKey, !dayKey.isEmpty {
            data["dayKey"] = dayKey
        }
        if let catalogue = notification.catalogue, catalogue == "projects" || catalogue == "smallWorks" {
            data["catalogue"] = catalogue
        }
        // RULEBOOK §13: the signed-in user who caused the row. Security rules accept only request.auth.uid;
        // the push function never pushes a row to its actor.
        if let actor = actorUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !actor.isEmpty {
            data["actorUserId"] = actor
        }

        do {
            try await ref.setData(data)
        } catch {
            if onlyIfMissing {
                acceptedMissingNotificationIds.remove(idKey)
            }
            throw error
        }
        print("🔥🔥🔥 DEBUG: [FIREBASE SAVE NOTIFICATION OK] org=\(organizationId) id=\(notification.id.uuidString) type=\(notification.type.rawValue) target=\(notification.userId ?? "broadcast")")
    }
    
    func loadNotifications(organizationId: String, userId: String, limit: Int = 50) async throws -> [AppNotification] {
        let owner = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else { return [] }
        let notificationsRef = db.collection("organizations").document(organizationId).collection("notifications")
            .whereField("userId", isEqualTo: owner)
        // Newest first (RULEBOOK §1 bounded downloads); the userId + createdAt index ships in web firestore.indexes.json.
        // The fallbacks below keep the unordered query if the index is missing.
        let boundedQuery = notificationsRef.order(by: "createdAt", descending: true).limit(to: max(1, limit))
        let snapshot: QuerySnapshot
        do {
            snapshot = try await boundedQuery.getDocuments(source: .server)
        } catch {
            let nsError = error as NSError
            if (nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7) || isOfflineNetworkError(error) {
                snapshot = try await boundedQuery.getDocuments(source: .cache)
            } else {
                // Fallback without order if the index is missing — still keep a hard limit.
                do {
                    snapshot = try await notificationsRef.limit(to: max(1, limit)).getDocuments(source: .server)
                } catch {
                    let fallbackError = error as NSError
                    if (fallbackError.domain == "FIRFirestoreErrorDomain" && fallbackError.code == 7) || isOfflineNetworkError(error) {
                        snapshot = try await notificationsRef.limit(to: max(1, limit)).getDocuments(source: .cache)
                    } else {
                        throw error
                    }
                }
            }
        }
        
        // RULEBOOK 1.8.0 §13: `parseNotificationDocument` (never a random id; unknown types kept).
        return snapshot.documents.compactMap {
            Self.appNotification(documentId: $0.documentID, data: $0.data(), organizationId: organizationId)
        }
    }

    /// One inbox row through `parseNotificationDocument`. Nil only without a document id or a type.
    static func appNotification(documentId: String, data: [String: Any], organizationId: String?) -> AppNotification? {
        guard let row = CanonicalBusinessEngine.parseNotificationDocument(
            documentId: documentId,
            data: data,
            organizationId: organizationId
        ) else { return nil }
        let storedType = row.text("type")
        var notification = AppNotification(
            id: JobKeys.inAppId(row.id),
            organizationId: row.optionalText("organizationId") ?? organizationId ?? "",
            type: AppNotification.NotificationType(stored: storedType),
            title: row.text("title"),
            message: row.text("message"),
            userId: row.optionalText("userId"),
            relatedKey: row.optionalText("relatedId"),
            isRead: row.bool("isRead"),
            createdAt: row.date("createdAtMs") ?? Date(timeIntervalSince1970: 0),
            requiresPermission: row.optionalText("requiresPermission"),
            deepLinkUserId: row.optionalText("deepLinkUserId"),
            deepLinkWeekStart: row.date("deepLinkWeekStartMs"),
            dayKey: row.optionalText("dayKey"),
            catalogue: row.optionalText("catalogue")
        )
        notification.storedType = storedType
        return notification
    }

    /// RULEBOOK 1.8.0 §13: marking a row read is `notificationReadWriteFields` — `{ isRead: true }` only.
    func markNotificationRead(_ notification: AppNotification, wasRead: Bool, organizationId: String) async throws {
        guard let answer = CanonicalBusinessEngine.callJSON("notificationReadWriteFields", arguments: [["isRead": wasRead]]) else {
            throw CanonicalWriteUnavailableError(function: "notificationReadWriteFields")
        }
        guard let set = (answer as? [String: Any])?["set"] as? [String: Any], !set.isEmpty else { return }
        try await db.collection("organizations").document(organizationId)
            .collection("notifications")
            .document(WorkDocumentKeys.storedId(for: notification.id))
            .updateData(set)
    }

    /// Applies `resolveInviteEmailClaim`. A non-empty `reuseUserId` is the leftover placeholder.
    /// An allow with no reuse id is a new document. This does not decide who is blocked.
    static func invitedUserDocumentId(
        decision: CanonicalBusinessEngine.CanonicalInviteEmailClaimDecision,
        generatedId: String
    ) -> String {
        let reuse = decision.reuseUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decision.action == "allow", !reuse.isEmpty { return reuse }
        return generatedId
    }

    /// The two fields the in-org Add User `users` query uses. Nil when either side is empty, so the query is not run.
    struct InviteEmailUsersQuery: Equatable {
        var organizationId: String
        var email: String
    }

    static func inviteEmailUsersQuery(organizationId: String, email: String) -> InviteEmailUsersQuery? {
        guard let lookup = CanonicalBusinessEngine.inviteEmailOrgLookupConstraints(
            organizationId: organizationId,
            email: email
        ) else { return nil }
        guard !lookup.organizationId.isEmpty, !lookup.email.isEmpty else { return nil }
        return InviteEmailUsersQuery(organizationId: lookup.organizationId, email: lookup.email)
    }

    /// Collections `createUserInvitation` may write. Nil when the script did not run.
    /// `operativeProfiles` is present only when `inviteWritesOperativeProfile` is true.
    static func inviteWriteCollectionNames() -> [String]? {
        guard let writesProfile = CanonicalBusinessEngine.inviteWritesOperativeProfile() else { return nil }
        var names = ["invitations", "users", "userEmails"]
        if writesProfile {
            names.append("operativeProfiles")
        }
        return names
    }

    /// A typed Add User day rate, stored on `users/{uid}`. `hourlyRate` stays nil.
    /// Nil when no rate was entered, or when the script did not allow that user-document write.
    struct InviteUserRateFields: Equatable {
        var payBasis: String
        var dayRate: Double
        var hourlyRate: Double?
    }

    static func inviteUserRateFields(dayRate: Double?) -> InviteUserRateFields? {
        guard let dayRate else { return nil }
        guard let collections = inviteWriteCollectionNames(),
              collections.contains("users"),
              collections.contains("operativeProfiles") == false else { return nil }
        return InviteUserRateFields(payBasis: "day", dayRate: dayRate, hourlyRate: nil)
    }

    /// Loads `users` rows for this email and `organizations/{orgId}/userEmails/{email}`.
    /// A failed `userEmails` read is a nil pointer, which the script treats as still claimed.
    func inviteEmailClaimInput(
        email: String,
        organizationId: String
    ) async throws -> CanonicalBusinessEngine.CanonicalInviteEmailClaimInput {
        guard let lookup = Self.inviteEmailUsersQuery(organizationId: organizationId, email: email) else {
            throw NSError(
                domain: "UserCreationError",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organisation and email are required to invite a user."]
            )
        }
        let emailLower = lookup.email
        let orgId = lookup.organizationId
        let existingDocs = try await db.collection("users")
            .whereField("email", isEqualTo: emailLower)
            .whereField("organizationId", isEqualTo: orgId)
            .getDocuments(source: .server)
        var existingUsers = existingDocs.documents.map { doc in
            Self.inviteClaimUser(userId: doc.documentID, data: doc.data())
        }
        let pointerRef = db.collection("organizations").document(orgId).collection("userEmails").document(emailLower)
        let pointerSnap: DocumentSnapshot?
        do {
            pointerSnap = try await pointerRef.getDocument(source: .server)
        } catch {
            print("🔥🔥🔥 DEBUG: userEmails read failed for \(emailLower) — claim check keeps pending invites")
            pointerSnap = nil
        }
        let pointer: CanonicalBusinessEngine.CanonicalInviteEmailPointer?
        if let pointerSnap {
            let pointedId = (pointerSnap.data()?["userId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var pointedUser: CanonicalBusinessEngine.CanonicalInviteEmailClaimUser?
            if pointerSnap.exists, !pointedId.isEmpty {
                let userSnap = try? await db.collection("users").document(pointedId).getDocument(source: .server)
                if let userSnap, userSnap.exists, let data = userSnap.data() {
                    pointedUser = Self.inviteClaimUser(userId: pointedId, data: data)
                }
            }
            if let pointedUser, existingUsers.contains(where: { $0.userId == pointedUser.userId }) == false {
                existingUsers.append(pointedUser)
            }
            pointer = CanonicalBusinessEngine.CanonicalInviteEmailPointer(
                exists: pointerSnap.exists,
                pointedUserId: pointedId.isEmpty ? nil : pointedId,
                pointedUser: pointedUser
            )
        } else {
            pointer = nil
        }
        return CanonicalBusinessEngine.CanonicalInviteEmailClaimInput(
            inviteEmail: emailLower,
            existingUsers: existingUsers,
            emailPointer: pointer
        )
    }

    /// Raw claim fields. Missing `passwordSet` stays nil; `parseAppUserDocument` still defaults that flag for the roster.
    private static func inviteClaimUser(
        userId: String,
        data: [String: Any]
    ) -> CanonicalBusinessEngine.CanonicalInviteEmailClaimUser {
        func text(_ key: String) -> String {
            (data[key] as? String) ?? ""
        }
        let mobile = text("mobileNumber")
        return CanonicalBusinessEngine.CanonicalInviteEmailClaimUser(
            userId: userId,
            email: text("email"),
            firstName: text("firstName"),
            surname: text("surname"),
            lastName: text("lastName").isEmpty ? nil : text("lastName"),
            name: text("name"),
            displayName: text("displayName"),
            passwordSet: firestoreBool(data["passwordSet"]),
            isActive: firestoreBool(data["isActive"]),
            mobileNumber: mobile.isEmpty ? nil : mobile
        )
    }
    
    // MARK: - User Invitation
    
    func createUserInvitation(email: String, organizationId: String, invitedBy: String, firstName: String, surname: String, mobileNumber: String?, permissions: UserPermissions, employmentType: EmploymentType = .selfEmployed, assignedManagerUserId: String? = nil, assignedManagerUserIds: [String]? = nil, hasNoLineManager: Bool = false, invitedOperativeDayRate: Double? = nil, invitedManagerDayRate: Double? = nil, invitedTradeTypePreset: String? = nil, invitedTradeTypeCustom: String? = nil, annualLeaveDaysPerYear: Double? = nil, annualLeaveYearStartMonth: Int? = nil, annualLeaveYearEndMonth: Int? = nil, annualLeaveCarriesOver: Bool? = nil, annualLeaveEnabled: Bool? = nil, annualLeaveYearAllowance: Double? = nil, annualLeaveYearAllowanceKey: String? = nil, timesheetsEnabled: Bool? = nil, vatNumber: String? = nil, utrNumber: String? = nil) async throws {
        print("🔥🔥🔥 DEBUG: createUserInvitation called with email: \(email), organizationId: \(organizationId), invitedBy: \(invitedBy)")
        guard let lookup = Self.inviteEmailUsersQuery(organizationId: organizationId, email: email) else {
            throw NSError(
                domain: "UserCreationError",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organisation and email are required to invite a user."]
            )
        }
        let organizationId = lookup.organizationId
        let email = lookup.email

        let claimInput = try await inviteEmailClaimInput(email: email, organizationId: organizationId)
        let emailLower = claimInput.inviteEmail
        guard let decision = CanonicalBusinessEngine.resolveInviteEmailClaim(claimInput) else {
            throw NSError(
                domain: "UserCreationError",
                code: 503,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not check whether \(email) is already in this organisation. Try again."
                ]
            )
        }
        guard decision.action == "allow" else {
            print("🔥🔥🔥 DEBUG: ❌ ERROR: Live email claim blocks \(email) action=\(decision.action)")
            throw NSError(
                domain: "UserCreationError",
                code: decision.action == "block" ? 409 : 503,
                userInfo: [
                    NSLocalizedDescriptionKey: decision.action == "block"
                        ? "A user with the email address '\(email)' already exists in this organization. Each email address can only be used once per organization."
                        : "Could not check whether \(email) is already in this organisation. Try again."
                ]
            )
        }
        guard let inviteCollections = Self.inviteWriteCollectionNames() else {
            throw NSError(
                domain: "UserCreationError",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Could not check the invite placeholder. Try again."]
            )
        }
        guard inviteCollections.contains("operativeProfiles") == false else {
            throw NSError(
                domain: "UserCreationError",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Invite rates belong on the user document."]
            )
        }

        // Create invitation document
        let invitationId = UUID().uuidString
        print("🔥🔥🔥 DEBUG: Generated invitation ID: \(invitationId)")
        
        var invitationData: [String: Any] = [
            "email": email,
            "organizationId": organizationId,
            "invitedBy": invitedBy,
            "firstName": firstName,
            "surname": surname,
            "employmentType": employmentType.rawValue,
            "permissions": [
                "adminAccess": permissions.adminAccess,
                "manager": permissions.manager,
                "operatives": permissions.operatives,
                "skills": false,
                "qualifications": permissions.qualifications,
                    "materials": permissions.materials,
                "projects": permissions.projects,
                "smallWorks": permissions.smallWorks,
                "operativeMode": permissions.operativeMode,
                "annualLeaveSelfBook": permissions.annualLeaveSelfBook,
                "weeklyReports": permissions.weeklyReports,
                "dailyOverview": permissions.dailyOverview,
                "subContractors": permissions.subContractors,
                "siteAudit": permissions.siteAudit,
                "wholesalersOrderHistory": permissions.wholesalersOrderHistory
            ],
            "createdAt": Timestamp(date: Date()),
            "isUsed": false
        ]
        
        let resolvedManagerIds: [String] = {
            if hasNoLineManager { return [] }
            if let assignedManagerUserIds {
                return assignedManagerUserIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let mid = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !mid.isEmpty {
                return [mid]
            }
            return []
        }()

        if (permissions.operativeMode || permissions.manager || permissions.adminAccess), !resolvedManagerIds.isEmpty {
            invitationData["assignedManagerUserId"] = resolvedManagerIds[0]
            invitationData["assignedManagerUserIds"] = resolvedManagerIds
        }
        if hasNoLineManager {
            invitationData["hasNoLineManager"] = true
        }
        if permissions.operativeMode, let fields = Self.inviteUserRateFields(dayRate: invitedOperativeDayRate) {
            invitationData["payBasis"] = fields.payBasis
            invitationData["dayRate"] = fields.dayRate
        }
        if permissions.manager, let fields = Self.inviteUserRateFields(dayRate: invitedManagerDayRate) {
            invitationData["payBasis"] = fields.payBasis
            invitationData["dayRate"] = fields.dayRate
        }
        if permissions.operativeMode || permissions.manager {
            let tp = invitedTradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tc = invitedTradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tp, !tp.isEmpty {
                invitationData["tradeTypePreset"] = tp
            }
            if let tc, !tc.isEmpty {
                invitationData["tradeTypeCustom"] = tc
            }
        }
        
        if let mobileNumber = mobileNumber, !mobileNumber.isEmpty {
            invitationData["mobileNumber"] = mobileNumber
        }
        
        let orgDefaults = currentOrganization?.settings.annualLeaveDefaults ?? .default
        let resolvedAnnualLeaveDays = annualLeaveDaysPerYear.map { AnnualLeavePolicy.clampDaysPerYear($0) } ?? orgDefaults.daysPerYear
        let resolvedAnnualLeaveStart = annualLeaveYearStartMonth.map { AnnualLeavePolicy.clampMonth($0) } ?? orgDefaults.startMonth
        let resolvedAnnualLeaveEnd = annualLeaveYearEndMonth.map { AnnualLeavePolicy.clampMonth($0) } ?? orgDefaults.endMonth
        let resolvedAnnualLeaveCarry = annualLeaveCarriesOver ?? orgDefaults.carriesOver
        let resolvedAnnualLeaveEnabled = annualLeaveEnabled ?? true
        invitationData["annualLeaveDaysPerYear"] = resolvedAnnualLeaveDays
        invitationData["annualLeaveYearStartMonth"] = resolvedAnnualLeaveStart
        invitationData["annualLeaveYearEndMonth"] = resolvedAnnualLeaveEnd
        invitationData["annualLeaveCarriesOver"] = resolvedAnnualLeaveCarry
        invitationData["annualLeaveEnabled"] = resolvedAnnualLeaveEnabled
        if let annualLeaveYearAllowance, let annualLeaveYearAllowanceKey, !annualLeaveYearAllowanceKey.isEmpty {
            invitationData["annualLeaveYearAllowance"] = annualLeaveYearAllowance
            invitationData["annualLeaveYearAllowanceKey"] = annualLeaveYearAllowanceKey
        }

        let resolvedTimesheetsEnabled = timesheetsEnabled ?? AppUser.defaultTimesheetsEnabled(for: permissions, employmentType: employmentType)
        invitationData["timesheetsEnabled"] = resolvedTimesheetsEnabled
        // UTR and VAT number go on the placeholder's private/taxIds document, never on the invitation.

        #if DEBUG
        print("🔥🔥🔥 DEBUG: Invitation keys: \(invitationData.keys.sorted().joined(separator: ", "))")
        #endif
        
        try await db.collection("invitations").document(invitationId).setData(invitationData)
        
        print("🔥🔥🔥 DEBUG: Invitation document created successfully")
        
        // Create user document immediately so they appear in manage users list
            // User will have passwordSet: false until they accept invitation
            let userId = Self.invitedUserDocumentId(decision: decision, generatedId: UUID().uuidString)
            guard let requiresAge = CanonicalBusinessEngine.userCreateRequiresAgeConfirmation(
                creatorUserId: invitedBy,
                targetUserId: userId
            ) else {
                throw NSError(
                    domain: "UserCreationError",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "Could not check the invite placeholder. Try again."]
                )
            }
            if requiresAge {
                throw NSError(
                    domain: "UserCreationError",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invite placeholders must not use the self-create path."]
                )
            }
            guard let placeholder = CanonicalBusinessEngine.invitePlaceholderUserWriteFields() else {
                throw NSError(
                    domain: "UserCreationError",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "Could not check the invite placeholder. Try again."]
                )
            }
            // Determine role based on permissions
            var userRole: UserRole = .basic
            if permissions.adminAccess {
                userRole = .admin
            } else if permissions.manager {
                userRole = .manager
            } else if permissions.operativeMode {
                userRole = .operative
            }
            
            let operativeManagerId: String? = {
                guard !hasNoLineManager else { return nil }
                guard (permissions.operativeMode || permissions.manager || permissions.adminAccess), let m = resolvedManagerIds.first else { return nil }
                return m
            }()
            
            let inviteTp = invitedTradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines)
            let inviteTc = invitedTradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines)
            let newUser = AppUser(
                id: userId,
                email: emailLower, // store lowercase for Firestore rule (userEmails claim)
                organizationId: organizationId,
                role: userRole,
                createdAt: Date(),
                firstName: firstName,
                surname: surname,
                mobileNumber: mobileNumber,
                isActive: placeholder.isActive,
                passwordSet: placeholder.passwordSet,
                permissions: permissions, // Use the permissions from the invitation
                isSuperAdmin: placeholder.isSuperAdmin,
                policyAccepted: placeholder.policyAccepted,
                assignedManagerUserId: operativeManagerId,
                assignedManagerUserIds: resolvedManagerIds,
                hasNoLineManager: hasNoLineManager,
                dayRate: permissions.operativeMode ? invitedOperativeDayRate : (permissions.manager ? invitedManagerDayRate : nil),
                tradeTypePreset: (permissions.operativeMode || permissions.manager) && inviteTp?.isEmpty == false ? inviteTp : nil,
                tradeTypeCustom: (permissions.operativeMode || permissions.manager) && inviteTc?.isEmpty == false ? inviteTc : nil,
                employmentType: employmentType,
                annualLeaveEnabled: resolvedAnnualLeaveEnabled,
                annualLeaveDaysPerYear: resolvedAnnualLeaveDays,
                annualLeaveYearStartMonth: resolvedAnnualLeaveStart,
                annualLeaveYearEndMonth: resolvedAnnualLeaveEnd,
                annualLeaveCarriesOver: resolvedAnnualLeaveCarry,
                annualLeaveYearAllowance: annualLeaveYearAllowance,
                annualLeaveYearAllowanceKey: annualLeaveYearAllowanceKey,
                timesheetsEnabled: resolvedTimesheetsEnabled
            )
            
            do {
                // Check current user's permissions before saving
                let currentUserId = currentUser?.uid
                
                if let currentUserId = currentUserId {
                    print("🔥🔥🔥 DEBUG: ========================================")
                    print("🔥🔥🔥 DEBUG: PERMISSION CHECK BEFORE CREATING USER")
                    print("🔥🔥🔥 DEBUG: Current user ID: \(currentUserId)")
                    print("🔥🔥🔥 DEBUG: This ID will be checked by Firestore rules")
                    print("🔥🔥🔥 DEBUG: ========================================")
                    
                    let currentUserDoc = try? await db.collection("users").document(currentUserId).getDocument()
                    if let currentUserData = currentUserDoc?.data() {
                        print("🔥🔥🔥 DEBUG: ========================================")
                        print("🔥🔥🔥 DEBUG: PERMISSION CHECK BEFORE CREATING USER")
                        print("🔥🔥🔥 DEBUG: Current user (inviter) Firebase document data:")
                        print("🔥🔥🔥 DEBUG: - Document exists: \(currentUserDoc?.exists ?? false)")
                        print("🔥🔥🔥 DEBUG: - Document ID: \(currentUserDoc?.documentID ?? "N/A")")
                        print("🔥🔥🔥 DEBUG: - User ID (auth.uid): \(currentUserId)")
                        print("🔥🔥🔥 DEBUG: - isSuperAdmin: \(currentUserData["isSuperAdmin"] ?? "N/A") (type: \(type(of: currentUserData["isSuperAdmin"])))")
                        print("🔥🔥🔥 DEBUG: - adminAccess: \(currentUserData["adminAccess"] ?? "N/A") (type: \(type(of: currentUserData["adminAccess"])))")
                        print("🔥🔥🔥 DEBUG: - role: \(currentUserData["role"] ?? "N/A") (type: \(type(of: currentUserData["role"])))")
                        print("🔥🔥🔥 DEBUG: - organizationId: \(currentUserData["organizationId"] ?? "N/A")")
                        print("🔥🔥🔥 DEBUG: ========================================")
                        
                        // Check exact values and types
                        let isSuperAdmin = currentUserData["isSuperAdmin"] as? Bool ?? false
                        let adminAccess = currentUserData["adminAccess"] as? Bool ?? false
                        let role = currentUserData["role"] as? String ?? ""
                        
                        print("🔥🔥🔥 DEBUG: Parsed values:")
                        print("🔥🔥🔥 DEBUG: - isSuperAdmin (bool): \(isSuperAdmin)")
                        print("🔥🔥🔥 DEBUG: - adminAccess (bool): \(adminAccess)")
                        print("🔥🔥🔥 DEBUG: - role (string): '\(role)'")
                        
                        let hasAdmin = isSuperAdmin || adminAccess || role == "admin"
                        print("🔥🔥🔥 DEBUG: Has admin permissions: \(hasAdmin)")
                        
                        if !hasAdmin {
                            print("🔥🔥🔥 DEBUG: ⚠️ WARNING: Current user does not have admin permissions!")
                            print("🔥🔥🔥 DEBUG: This user should have isSuperAdmin=true or adminAccess=true or role='admin'")
                            print("🔥🔥🔥 DEBUG: Please check the user document in Firebase Console and update it manually")
                            print("🔥🔥🔥 DEBUG: Make sure the fields are BOOLEAN (true/false) not STRING ('true'/'false')")
                            print("🔥🔥🔥 DEBUG: User document path: users/\(currentUserId)")
                        } else {
                            print("🔥🔥🔥 DEBUG: ✅ User HAS admin permissions - rules should allow create")
                            print("🔥🔥🔥 DEBUG: Firestore rules will check: isAdminOrSuperAdmin() function")
                            print("🔥🔥🔥 DEBUG: This function checks: isSuperAdmin==true OR adminAccess==true OR role=='admin'")
                            print("🔥🔥🔥 DEBUG: ========================================")
                            print("🔥🔥🔥 DEBUG: CRITICAL: If you still get permission denied:")
                            print("🔥🔥🔥 DEBUG: 1. Verify rules are deployed in Firebase Console")
                            print("🔥🔥🔥 DEBUG: 2. Check that isSuperAdmin/adminAccess are BOOLEAN (not string)")
                            print("🔥🔥🔥 DEBUG: 3. Wait 2-3 minutes after deploying rules")
                            print("🔥🔥🔥 DEBUG: 4. Try logging out and back in")
                            print("🔥🔥🔥 DEBUG: ========================================")
                        }
                    } else {
                        print("🔥🔥🔥 DEBUG: ⚠️ WARNING: Could not load current user document!")
                        print("🔥🔥🔥 DEBUG: Document may not exist at path: users/\(currentUserId)")
                        print("🔥🔥🔥 DEBUG: This means the user document needs to be created first")
                    }
                } else {
                    print("🔥🔥🔥 DEBUG: ⚠️ WARNING: No current user ID available!")
                }
                
                print("🔥🔥🔥 DEBUG: ========================================")
                print("🔥🔥🔥 DEBUG: ATTEMPTING TO CREATE NEW USER DOCUMENT")
                print("🔥🔥🔥 DEBUG: ========================================")
                print("🔥🔥🔥 DEBUG: New user document ID: \(userId)")
                print("🔥🔥🔥 DEBUG: New user email: \(email)")
                print("🔥🔥🔥 DEBUG: Organization ID: \(organizationId)")
                print("🔥🔥🔥 DEBUG: Current authenticated user UID: \(currentUserId ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Since userId (\(userId)) != currentUserId (\(currentUserId ?? "N/A")), rules will check isAdminOrSuperAdmin()")
                print("🔥🔥🔥 DEBUG: Rules check: isAdminOrSuperAdmin() must return true")
                print("🔥🔥🔥 DEBUG: ========================================")
                
                // Verify current user's permissions one more time right before create
                if let currentUserId = currentUserId {
                    let verifyDoc = try? await db.collection("users").document(currentUserId).getDocument()
                    if let verifyData = verifyDoc?.data() {
                        let verifyIsSuperAdmin = verifyData["isSuperAdmin"] as? Bool ?? false
                        let verifyAdminAccess = verifyData["adminAccess"] as? Bool ?? false
                        let verifyRole = verifyData["role"] as? String ?? ""
                        print("🔥🔥🔥 DEBUG: Final verification before create:")
                        print("🔥🔥🔥 DEBUG: - isSuperAdmin: \(verifyIsSuperAdmin) (type: \(type(of: verifyData["isSuperAdmin"])))")
                        print("🔥🔥🔥 DEBUG: - adminAccess: \(verifyAdminAccess) (type: \(type(of: verifyData["adminAccess"])))")
                        print("🔥🔥🔥 DEBUG: - role: '\(verifyRole)' (type: \(type(of: verifyData["role"])))")
                        print("🔥🔥🔥 DEBUG: - Has admin: \(verifyIsSuperAdmin || verifyAdminAccess || verifyRole == "admin")")
                    }
                }
                
                // Log what we're about to save
                var userData: [String: Any] = [
                    "email": newUser.email,
                    "organizationId": newUser.organizationId,
                    "role": newUser.role.rawValue,
                    "createdAt": Timestamp(date: newUser.createdAt),
                    "firstName": newUser.firstName,
                    "surname": newUser.surname,
                    "isActive": newUser.isActive,
                    "passwordSet": newUser.passwordSet,
                    "adminAccess": newUser.permissions.adminAccess,
                    "manager": newUser.permissions.manager,
                    "operatives": newUser.permissions.operatives,
                    "skills": false,
                    "qualifications": newUser.permissions.qualifications,
                    "materials": newUser.permissions.materials,
                    "operativeMode": newUser.permissions.operativeMode,
                    "annualLeaveSelfBook": newUser.permissions.annualLeaveSelfBook,
                    "weeklyReports": newUser.permissions.weeklyReports,
                    "dailyOverview": newUser.permissions.dailyOverview,
                    "subContractors": newUser.permissions.subContractors,
                    "siteAudit": newUser.permissions.siteAudit,
                    "wholesalersOrderHistory": newUser.permissions.wholesalersOrderHistory,
                    "isSuperAdmin": newUser.isSuperAdmin
                ]
                if let mobileNumber = newUser.mobileNumber {
                    userData["mobileNumber"] = mobileNumber
                }
                print("🔥🔥🔥 DEBUG: Data to be saved:")
                for (key, value) in userData {
                    print("🔥🔥🔥 DEBUG:   \(key): \(value) (type: \(type(of: value)))")
                }
                
                // Use saveUser function (it does the same thing but with proper error handling)
                print("🔥🔥🔥 DEBUG: Attempting to save user document to users/\(userId)...")
                print("🔥🔥🔥 DEBUG: Current auth UID: \(currentUserId ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Rules will check: isAdminOrSuperAdmin() for UID \(currentUserId ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Document path: users/\(userId)")
                print("🔥🔥🔥 DEBUG: This is a CREATE operation (document doesn't exist yet)")
                
                // Claim this email in the org so only one user doc per email can exist (Firestore rule)
                let userEmailsRef = db.collection("organizations").document(organizationId).collection("userEmails").document(emailLower)
                try await userEmailsRef.setData(["userId": userId])
                print("🔥🔥🔥 DEBUG: Set userEmails claim for \(emailLower) -> \(userId)")
                
                try await saveUser(newUser)
                if let fields = Self.inviteUserRateFields(dayRate: newUser.dayRate) {
                    try await db.collection("users").document(userId).setData([
                        "payBasis": fields.payBasis,
                        "dayRate": fields.dayRate
                    ], merge: true)
                }
                let inviteVAT = vatNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let inviteUTR = utrNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !inviteVAT.isEmpty || !inviteUTR.isEmpty {
                    try await saveSensitiveProfile(userId: userId, utrNumber: inviteUTR, vatNumber: inviteVAT)
                }
                print("🔥🔥🔥 DEBUG: ✅ saveUser succeeded!")
                print("🔥🔥🔥 DEBUG: ✅ User document saved successfully for invited user: \(email)")
                print("🔥🔥🔥 DEBUG: User ID: \(userId)")
                print("🔥🔥🔥 DEBUG: Organization ID: \(organizationId)")
                print("🔥🔥🔥 DEBUG: User firstName: \(firstName), surname: \(surname)")
                print("🔥🔥🔥 DEBUG: User email: \(email)")
                
                // Verify the user was saved by reading it back
                let savedUser = try? await db.collection("users").document(userId).getDocument()
                if let savedData = savedUser?.data() {
                    print("🔥🔥🔥 DEBUG: ✅ Verified saved user - Email: \(savedData["email"] ?? "N/A"), OrgId: \(savedData["organizationId"] ?? "N/A")")
                } else {
                    print("🔥🔥🔥 DEBUG: ⚠️ Could not verify saved user - document may not exist")
                }
            } catch {
                print("🔥🔥🔥 DEBUG: ❌ Error saving user: \(error)")
                print("🔥🔥🔥 DEBUG: Error type: \(type(of: error))")
                if let nsError = error as NSError? {
                    print("🔥🔥🔥 DEBUG: Error domain: \(nsError.domain), code: \(nsError.code)")
                    print("🔥🔥🔥 DEBUG: Error userInfo: \(nsError.userInfo)")
                }
                throw error
            }
        
        // Send invitation email
        await sendInvitationEmail(email: email, firstName: firstName, surname: surname, invitationId: invitationId)
    }
    
    func sendInvitationEmail(email: String, firstName: String, surname: String, invitationId: String) async {
        print("🔥🔥🔥 DEBUG: Sending invitation email to: \(email)")
        
        let organizationName = CanonicalBusinessEngine.parseOrganizationName(
            Organization.nameParsePayload(from: ["name": currentOrganization?.name ?? ""])
        ) ?? ""
        let resendService = ResendEmailService()
        let success = await resendService.sendPasswordSetupEmail(
            to: email,
            firstName: firstName,
            surname: surname,
            invitationCode: invitationId,
            fromName: organizationName.isEmpty ? nil : organizationName
        )
        
        if success {
            print("🔥🔥🔥 DEBUG: ✅ Invitation email sent successfully to: \(email)")
        } else {
            print("🔥🔥🔥 DEBUG: ❌ Failed to send invitation email to: \(email)")
            // Fallback to plain text email via EmailService
            let displayFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            let helloName = displayFirst.isEmpty ? "there" : displayFirst
            let trimmedSurname = surname.trimmingCharacters(in: .whitespacesAndNewlines)
            let hello = trimmedSurname.isEmpty ? helloName : "\(helloName) \(trimmedSurname)"
            let invitedLine = organizationName.isEmpty
                ? "You have been invited to join the Project Planner system."
                : "\(organizationName) has invited you to join them on Project Planner."
            let subject = "Welcome to Project Planner - Set Up Your Account"
            let body = """
            Hello \(hello),
            
            \(invitedLine)
            
            To set up your account and create your password, please visit:
            https://www.projectplanner.us/setup-password.html?token=\(invitationId)
            
            Once you've set up your password, you'll be able to access the Project Planner system.
            
            If you have any questions, please contact your administrator.
            """
            
            let fallbackSuccess = await EmailService.shared.sendEmail(
                recipient: email,
                subject: subject,
                body: body
            )
            
            if fallbackSuccess {
                print("🔥🔥🔥 DEBUG: ✅ Fallback email sent successfully")
            }
            // Don't throw error - invitation is still created, admin can resend
        }
    }
    
    // MARK: - Admin Functions
    
    func getAllUsers() async throws -> [UserData] {
        guard let orgId = currentOrganization?.firestoreDocumentId else { return [] }
        let snapshot = try await db.collection("users")
            .whereField("organizationId", isEqualTo: orgId)
            .limit(to: 200)
            .getDocuments()
        
        return snapshot.documents.compactMap { doc in
            let data = doc.data()
            
            return UserData(
                id: doc.documentID,
                email: data["email"] as? String ?? "",
                displayName: data["displayName"] as? String ?? "",
                organizationId: data["organizationId"] as? String ?? "",
                role: data["role"] as? String ?? "basic",
                createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            )
        }
    }
    
    /// Firebase Authentication's built-in password-reset email (OOB link). Use when the email is **already registered** in Auth
    /// (e.g. invited user tried setup before, or same email was used in dev) — distinct from invitation / Resend setup links.
    func resetUserPassword(email: String) async throws {
        try await auth.sendPasswordReset(withEmail: email)
    }
    
    // MARK: - Booking Methods

    private func resolveWritableOrganizationId(preferred organizationId: String) async throws -> String {
        let preferredOrgId = normalizedOrganizationId(organizationId)
        do {
            let orgId = try await ensureReadableOrganization(preferredOrgId)
            await repairCurrentUserOrganizationAccess(organizationId: orgId)
            return orgId
        } catch {
            print("🔥🔥🔥 DEBUG: Preferred booking org \(preferredOrgId) was not readable: \(error.localizedDescription)")
        }

        if let userId = currentUser?.uid,
           let linkedOrgId = try? await validateUserOrganizationLink(userId: userId),
           !linkedOrgId.isEmpty {
            print("🔥🔥🔥 DEBUG: Falling back booking org to linked org \(linkedOrgId)")
            let fallbackOrgId = try await ensureReadableOrganization(linkedOrgId)
            await repairCurrentUserOrganizationAccess(organizationId: fallbackOrgId)
            return fallbackOrgId
        }

        throw NSError(
            domain: "FirebaseBackend",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Could not resolve a writable organization for bookings."]
        )
    }
    
    /// RULEBOOK §1 partial writes. `changedFields` nil is a create: every field plus `id` and `createdAt`.
    /// Otherwise (1.7.0) the edited fields (`BookingWritePatch.labourFieldNames`, with the slot group
    /// `BOOKING_SLOT_WRITE_GROUP` sent together) go through `bookingUpdateWriteFields` against the stored booking and
    /// only what differs is written with `updateData`; `bookedBy` is never rewritten. An edit of a booking that is
    /// gone is refused as not-found (`bookingReplayRefusedIsFinal`), never turned into a create.
    /// Both carry `WriteMetadata`. A tombstoned or (for non-managers) cancelled booking is refused by the rules.
    func saveBooking(_ booking: Booking, organizationId: String, changedFields: Set<String>? = nil) async throws {
        print("🔥🔥🔥 DEBUG: saveBooking called with organizationId: \(organizationId), bookingId: \(booking.id.uuidString)")
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        let ref = db.collection("organizations").document(orgId).collection("bookings").document(booking.documentKey)
        let uid = currentUser?.uid

        if let changedFields {
            var fields = changedFields
            if let slotGroup = CanonicalBusinessEngine.constant("BOOKING_SLOT_WRITE_GROUP", as: [String].self),
               !fields.isDisjoint(with: slotGroup) {
                fields.formUnion(slotGroup)
            }
            let next = BookingWritePatch.patch(
                BookingWritePatch.labourValues(booking, deletesClearedFields: true),
                fields: fields
            )
            guard !next.isEmpty else { return }
            let snapshot = try await ref.getDocument(source: .server)
            guard snapshot.exists, let stored = snapshot.data() else {
                throw NSError(
                    domain: "FIRFirestoreErrorDomain",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: CanonicalBusinessEngine.bookingReplayRefusedMessage]
                )
            }
            guard let write = CanonicalBusinessEngine.bookingUpdateWrite(before: stored, next: next) else {
                throw CanonicalWriteUnavailableError(function: "bookingUpdateWriteFields")
            }
            let patch = write.firestoreFields(from: next)
            guard !patch.isEmpty else { return }
            print("🔥🔥🔥 DEBUG: Updating booking fields \(patch.keys.sorted()) at organizations/\(orgId)/bookings/\(booking.documentKey)")
            try await ref.updateData(WriteMetadata.stamped(patch, userId: uid))
            return
        }

        var bookingData = BookingWritePatch.labourValues(booking, deletesClearedFields: false)
        bookingData["id"] = booking.documentKey
        bookingData["createdAt"] = Timestamp(date: booking.createdAt)

        print("🔥🔥🔥 DEBUG: Creating booking at organizations/\(orgId)/bookings/\(booking.documentKey)")

        try await ref.setData(WriteMetadata.stamped(bookingData, userId: uid), merge: true)

        print("🔥🔥🔥 DEBUG: Booking saved successfully to Firebase")
    }
    
    /// Earlier of the warning-scan start and the current week. Launch does not subscribe to older bookings.
    func launchScheduleLowerBound(now: Date = Date()) -> Date {
        let detection = currentOrganization?.settings.warningDetection ?? .default
        let invoicing = currentOrganization?.settings.invoicing ?? .default
        let bounds = CanonicalBusinessEngine.warningBounds(
            detection: detection,
            invoicing: invoicing,
            reference: now
        )
        let week = WeekRange.from(start: now)
        // `bookingLoadStart`: the earlier of the warning window and this week, as web loads.
        if let warningKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(bounds.start),
           let weekKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(week.start),
           let start = CanonicalBusinessEngine.bookingLoadStart(loadedFromDayKey: nil, neededDayKeys: [weekKey, warningKey]),
           let startKey = start.startDayKey,
           let day = CanonicalBusinessEngine.date(fromDayKey: startKey) {
            return day
        }
        return LaunchStartupPolicy.launchBookingLowerBound(warningStart: bounds.start, weekStart: week.start)
    }

    func prepareLaunchScheduleQueryIfNeeded(now: Date = Date()) {
        guard !scheduleHistoryIsFull, scheduleHistoryStart == nil else { return }
        scheduleHistoryStart = launchScheduleLowerBound(now: now)
    }

    /// True when the listener bound moved earlier and stores should reload.
    @discardableResult
    func noteScheduleNeedsDate(_ date: Date) -> Bool {
        if scheduleHistoryIsFull { return false }
        prepareLaunchScheduleQueryIfNeeded()
        guard let current = scheduleHistoryStart else { return false }
        // `bookingLoadStart` decides whether this day is outside the download and where it now starts.
        if let loadedKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(current),
           let neededKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(date),
           let start = CanonicalBusinessEngine.bookingLoadStart(loadedFromDayKey: loadedKey, neededDayKeys: [neededKey]) {
            guard start.reload, let key = start.startDayKey,
                  let day = CanonicalBusinessEngine.date(fromDayKey: key) else { return false }
            scheduleHistoryStart = day
            return true
        }
        let day = Calendar.current.startOfDay(for: date)
        guard day < current else { return false }
        scheduleHistoryStart = day
        return true
    }

    /// Weekly report, invoicing, and a project week outside the launch window ask for the archive.
    @discardableResult
    func noteScheduleNeedsFullHistory() -> Bool {
        guard !scheduleHistoryIsFull else { return false }
        scheduleHistoryIsFull = true
        scheduleHistoryStart = nil
        return true
    }

    func scheduleBookingQueryStart() -> Date? {
        scheduleHistoryIsFull ? nil : scheduleHistoryStart
    }

    func loadBookings(organizationId: String, startingOn start: Date? = nil) async throws -> [Booking] {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        var bookingsQuery: Query = db.collection("organizations").document(orgId).collection("bookings")
        if let start {
            bookingsQuery = bookingsQuery.whereField("date", isGreaterThanOrEqualTo: Timestamp(date: start))
        }
        let snapshot = try await getQueryPreferringServer(bookingsQuery)
        let bookings = bookingsFromFirestoreDocuments(snapshot.documents)
        if bookings.isEmpty {
            NSLog("BOOKINGS_EMPTY org=%@ start=%@ fromCache=%d — no booking documents in range", orgId, start.map { CanonicalBusinessEngine.isoString(from: $0) } ?? "all", snapshot.metadata.isFromCache ? 1 : 0)
        }
        return bookings
    }

    private func getQueryPreferringServer(_ query: Query) async throws -> QuerySnapshot {
        do {
            return try await Self.readCollectionFromServer(query, timeoutSeconds: 8)
        } catch {
            let timedOut = error is ServerReadTimeoutError
            guard timedOut || isFirestorePermissionDenied(error) || isOfflineNetworkError(error) else { throw error }
            let cached = try await query.getDocuments(source: .cache)
            if cached.documents.isEmpty {
                throw error
            }
            return cached
        }
    }

    /// Firestore values as JSON for the rulebook. Timestamps become `{ seconds, nanoseconds }`, which
    /// `bookingDateMs` reads; references become their path. Other non-JSON values become null.
    nonisolated static func firestoreJSON(_ value: Any) -> Any {
        switch value {
        case let timestamp as Timestamp:
            return ["seconds": timestamp.seconds, "nanoseconds": timestamp.nanoseconds]
        case let date as Date:
            return date.timeIntervalSince1970 * 1000
        case let reference as DocumentReference:
            return reference.path
        case let map as [String: Any]:
            return map.mapValues { firestoreJSON($0) }
        case let list as [Any]:
            return list.map { firestoreJSON($0) }
        case is String, is NSNumber, is NSNull:
            return value
        default:
            return NSNull()
        }
    }

    /// Operative bookings read through the rulebook's `parseBookingDocument`, the same reader web uses, so a
    /// lower-case status, a slot alias or a text date no longer drops a booking on iOS only.
    /// Falls back to `bookingFromFirestoreDocument` when the script does not answer.
    func bookingsFromFirestoreDocuments(_ documents: [QueryDocumentSnapshot]) -> [Booking] {
        let payload: [[String: Any]] = documents.map { ["id": $0.documentID, "data": Self.firestoreJSON($0.data())] }
        guard let parsed = CanonicalBusinessEngine.parseBookingDocuments(payload) else {
            NSLog("BOOKINGS_PARSE_FAILED docs=%d — canonical script did not answer; using the fallback reader", documents.count)
            let fallback = documents.compactMap { bookingFromFirestoreDocument($0) }
            lastBookingDecodeReport = BookingDecodeReport(total: documents.count, refused: documents.count - fallback.count, repaired: 0, scriptFailed: true)
            return fallback
        }
        let bookings = parsed.compactMap(Self.booking(fromCanonical:))
        lastBookingDecodeReport = BookingDecodeReport(total: documents.count, refused: documents.count - bookings.count, repaired: 0, scriptFailed: false)
        if bookings.count < documents.count {
            NSLog("BOOKINGS_REFUSED kept=%d of %d — see BOOKING_UNREADABLE_ON_IOS lines for the ids", bookings.count, documents.count)
        }
        return bookings
    }

    nonisolated static func booking(fromCanonical row: CanonicalBusinessEngine.CanonicalParsedBooking) -> Booking? {
        // RULEBOOK 1.7.0 §1: a job id is kept as stored (a lower-case or non-UUID job id no longer drops the booking).
        let storedProjectId = row.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storedProjectId.isEmpty,
              let timeSlot = TimeSlot.fromStored(row.timeSlot),
              let status = BookingStatus(rawValue: row.status) else {
            NSLog("BOOKING_UNREADABLE_ON_IOS id=%@ project=%@ slot=%@ status=%@", row.id, row.projectId, row.timeSlot, row.status)
            return nil
        }
        var booking = Booking(
            // A document id that is not a UUID keeps one stable in-app id instead of a new random one per read.
            id: UUID(uuidString: row.id) ?? OperativeKeyRegistry.derivedUUID(for: "booking.\(row.id)"),
            operativeId: Booking.internalOperativeId(for: row.operativeId),
            projectId: WorkDocumentKeys.inAppId(for: storedProjectId),
            date: Date(timeIntervalSince1970: row.dateMs / 1000),
            timeSlot: timeSlot,
            bookedBy: row.bookedBy,
            notes: row.notes.isEmpty ? nil : row.notes,
            status: status,
            workStartTime: row.workStartTime,
            workEndTime: row.workEndTime,
            isBreakRemoved: row.isBreakRemoved,
            otMultiplierOverride: row.otMultiplierOverride,
            bookingGroupId: row.bookingGroupId,
            createdAt: row.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            updatedAt: row.updatedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
        booking.operativeKey = row.operativeId
        booking.projectKey = storedProjectId
        // Firestore ids are case-sensitive: keep any id that `uuidString` would not spell the same way.
        booking.documentId = row.id == booking.id.uuidString ? nil : row.id
        return booking
    }

    /// Manager site bookings read through the rulebook's `parseManagerSiteBookingDocument` (web uses the same reader).
    func managerSiteBookingsFromFirestoreDocuments(_ documents: [QueryDocumentSnapshot]) -> [ManagerSiteBooking] {
        let payload: [[String: Any]] = documents.map { ["id": $0.documentID, "data": Self.firestoreJSON($0.data())] }
        guard let parsed = CanonicalBusinessEngine.parseManagerSiteBookingDocuments(payload) else {
            return documents.compactMap { managerSiteBookingFromFirestoreDocument($0) }
        }
        return parsed.compactMap { row in
            guard let timeSlot = ManagerTimeSlot.fromStored(row.timeSlot),
                  let locationType = ManagerLocationType(rawValue: row.locationType) else { return nil }
            // RULEBOOK 1.7.0 §1: the document id and the job id are kept as stored (a non-UUID id gets a stable
            // in-app UUID and is written back unchanged).
            let locationKey = row.locationId?.trimmingCharacters(in: .whitespacesAndNewlines)
            var booking = ManagerSiteBooking(
                id: UUID(uuidString: row.id) ?? OperativeKeyRegistry.derivedUUID(for: "managerBooking.\(row.id)"),
                userId: row.userId,
                date: Date(timeIntervalSince1970: row.dateMs / 1000),
                timeSlot: timeSlot,
                locationType: locationType,
                locationId: (locationKey?.isEmpty == false ? locationKey : nil).map { WorkDocumentKeys.inAppId(for: $0) },
                customLocationName: row.customLocationName,
                workStartTime: row.workStartTime,
                workEndTime: row.workEndTime,
                isBreakRemoved: row.isBreakRemoved,
                bookingGroupId: row.bookingGroupId,
                createdAt: row.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                updatedAt: row.updatedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            )
            booking.documentId = row.id == booking.id.uuidString ? nil : row.id
            booking.locationKey = locationKey?.isEmpty == false ? locationKey : nil
            return booking
        }
    }

    func bookingFromFirestoreDocument(_ doc: QueryDocumentSnapshot) -> Booking? {
        let data = doc.data()
            
            // operativeId may be a Firebase Auth uid, not a UUID (web #189). Keep the booking and its stored id.
            guard let operativeIdString = (data["operativeId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !operativeIdString.isEmpty,
                  let projectIdString = (data["projectId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !projectIdString.isEmpty,
                  let date = (data["date"] as? Timestamp)?.dateValue(),
                  let timeSlotString = data["timeSlot"] as? String,
                  let timeSlot = TimeSlot.fromStored(timeSlotString),
                  let bookedBy = data["bookedBy"] as? String,
                  let statusString = data["status"] as? String,
                  let status = BookingStatus(rawValue: statusString) else {
                return nil
            }
            
            // Same stable in-app id as `booking(fromCanonical:)`, never a fresh random one.
            let id = UUID(uuidString: doc.documentID) ?? OperativeKeyRegistry.derivedUUID(for: "booking.\(doc.documentID)")
            let notes = data["notes"] as? String
            let workStartTime = data["workStartTime"] as? String
            let workEndTime = data["workEndTime"] as? String
            let isBreakRemoved = (data["isBreakRemoved"] as? Bool) ?? false
            let otMultiplierOverride: Double? = {
                guard let v = data["otMultiplierOverride"] else { return nil }
                if let n = v as? NSNumber { return n.doubleValue }
                if let d = v as? Double { return d }
                return nil
            }()
            let bookingGroupId = data["bookingGroupId"] as? String
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()

            var booking = Booking(
                id: id,
                operativeId: Booking.internalOperativeId(for: operativeIdString),
                projectId: WorkDocumentKeys.inAppId(for: projectIdString),
                date: date,
                timeSlot: timeSlot,
                bookedBy: bookedBy,
                notes: notes,
                status: status,
                workStartTime: workStartTime,
                workEndTime: workEndTime,
                isBreakRemoved: isBreakRemoved,
                otMultiplierOverride: otMultiplierOverride,
                bookingGroupId: bookingGroupId,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            booking.operativeKey = operativeIdString
            booking.projectKey = projectIdString
            booking.documentId = doc.documentID == booking.id.uuidString ? nil : doc.documentID
            return booking
    }

    func listenBookings(
        organizationId: String,
        startingOn start: Date? = nil,
        onChange: @escaping (_ bookings: [Booking], _ fromCache: Bool) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        let target = "bookings:\(orgId)|\(start?.timeIntervalSince1970 ?? -1)"
        guard LaunchStartupPolicy.shouldAttachListener(
            activeTarget: bookingsLiveListenerTarget,
            requestedTarget: target
        ) else { return }
        bookingsLiveListener?.remove()
        bookingsLiveListenerTarget = target
        var bookingsQuery: Query = db.collection("organizations").document(orgId).collection("bookings")
        if let start {
            bookingsQuery = bookingsQuery.whereField("date", isGreaterThanOrEqualTo: Timestamp(date: start))
        }
        bookingsLiveListener = bookingsQuery
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    NSLog("BOOKINGS_LISTENER_FAILED org=%@ error=%@", orgId, error.localizedDescription)
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .bookingsListenerFailed, object: nil, userInfo: ["organizationId": orgId])
                    }
                    return
                }
                guard let snapshot else { return }
                let fromCache = snapshot.metadata.isFromCache
                Task { @MainActor in
                    guard let self else { return }
                    let currentOrganizationId = self.currentOrganization?.firestoreDocumentId
                    guard WarningsBookingScanScheduler.acceptsListener(
                        listenerOrganizationId: orgId,
                        currentOrganizationId: currentOrganizationId,
                        sessionOrganizationId: self.sessionOrganizationId
                    ) else {
                        print("🔥🔥🔥 DEBUG: bookings live listener ignored (organisation is no longer current) listener=\(orgId) current=\(currentOrganizationId ?? "nil") session=\(self.sessionOrganizationId)")
                        return
                    }
                    if fromCache && snapshot.documents.isEmpty {
                        print("🔥🔥🔥 DEBUG: BOOKINGS_KEPT — ignored an empty cache snapshot")
                        return
                    }
                    let list = self.bookingsFromFirestoreDocuments(snapshot.documents)
                    onChange(list, fromCache)
                }
            }
    }
    
    func deleteBooking(_ booking: Booking, organizationId: String) async throws {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        do {
            try await deleteBookingWithTombstone(
                collection: "bookings",
                bookingId: booking.documentKey,
                organizationId: orgId
            )
        } catch {
            let nsError = error as NSError
            // web firestore.rules: deleting a labour booking (and writing its tombstone) is admins only.
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                throw NSError(
                    domain: "FirebaseBackend",
                    code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Only an organisation admin can delete a labour booking. Ask an admin, or cancel the booking instead.",
                        NSUnderlyingErrorKey: nsError
                    ]
                )
            }
            throw error
        }
    }

    /// RULEBOOK §2 / §16: deletes `organizations/{orgId}/{collection}/{bookingId}` and writes the tombstone
    /// `bookingTombstonePath` with `bookingTombstoneWriteFields` plus the server `deletedAt`, in ONE batch.
    /// The tombstone carries only its own fields (the rule allows nothing else; no write metadata).
    private func deleteBookingWithTombstone(collection: String, bookingId: String, organizationId orgId: String) async throws {
        guard let uid = currentUser?.uid,
              let path = CanonicalBusinessEngine.bookingTombstonePath(organizationId: orgId, bookingId: bookingId),
              var tombstone = CanonicalBusinessEngine.bookingTombstoneWriteFields(
                bookingId: bookingId,
                collection: collection,
                deletedBy: uid,
                deletedFrom: "ios"
              ) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not delete this booking: sign in again and retry."]
            )
        }
        tombstone["deletedAt"] = FieldValue.serverTimestamp()
        let batch = db.batch()
        batch.deleteDocument(db.collection("organizations").document(orgId).collection(collection).document(bookingId))
        batch.setData(tombstone, forDocument: db.document(path))
        do {
            try await batch.commit()
        } catch {
            let nsError = error as NSError
            // Tombstones are never updated. One already there means the booking is already deleted
            // (a second delete, or a replay whose first commit reached the server): nothing left to do.
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7,
               let existing = try? await db.document(path).getDocument(source: .server),
               existing.exists {
                return
            }
            throw error
        }
    }

    // MARK: - Manager / Admin site bookings (where I'm working – AM, PM, Full Day, Office)

    /// RULEBOOK §1 partial writes. `changedFields` nil is a create (every field plus `id`, `organizationId`,
    /// `createdAt`); otherwise only those fields (`BookingWritePatch.managerFieldNames`) with `updateData`.
    func saveManagerSiteBooking(_ booking: ManagerSiteBooking, organizationId: String, changedFields: Set<String>? = nil) async throws {
        let ref = db.collection("organizations").document(organizationId).collection("managerSiteBookings").document(booking.documentKey)
        let uid = currentUser?.uid
        if let changedFields {
            let patch = BookingWritePatch.patch(
                BookingWritePatch.managerValues(booking, deletesClearedFields: true),
                fields: changedFields
            )
            guard !patch.isEmpty else { return }
            try await ref.updateData(WriteMetadata.stamped(patch, userId: uid))
            return
        }
        var data = BookingWritePatch.managerValues(booking, deletesClearedFields: false)
        data["id"] = booking.documentKey
        data["organizationId"] = organizationId
        data["createdAt"] = Timestamp(date: booking.createdAt)
        try await ref.setData(WriteMetadata.stamped(data, userId: uid), merge: true)
    }

    func loadManagerSiteBookings(organizationId: String, startingOn start: Date? = nil) async throws -> [ManagerSiteBooking] {
        var query: Query = db.collection("organizations").document(organizationId).collection("managerSiteBookings")
        if let start {
            query = query.whereField("date", isGreaterThanOrEqualTo: Timestamp(date: start))
        }
        let snapshot = try await getQueryPreferringServer(query)
        return managerSiteBookingsFromFirestoreDocuments(snapshot.documents)
    }

    func managerSiteBookingFromFirestoreDocument(_ doc: QueryDocumentSnapshot) -> ManagerSiteBooking? {
        let data = doc.data()
        guard let userId = data["userId"] as? String,
              let date = (data["date"] as? Timestamp)?.dateValue(),
              let timeSlotRaw = data["timeSlot"] as? String,
              let timeSlot = ManagerTimeSlot.fromStored(timeSlotRaw),
              let locationTypeRaw = data["locationType"] as? String,
              let locationType = ManagerLocationType(rawValue: locationTypeRaw) else { return nil }
        let id = UUID(uuidString: doc.documentID) ?? OperativeKeyRegistry.derivedUUID(for: "managerBooking.\(doc.documentID)")
        let locationKey = (data["locationId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationId = (locationKey?.isEmpty == false ? locationKey : nil).map { WorkDocumentKeys.inAppId(for: $0) }
        let customLocationName = data["customLocationName"] as? String
        let workStartTime = data["workStartTime"] as? String
        let workEndTime = data["workEndTime"] as? String
        let isBreakRemoved = (data["isBreakRemoved"] as? Bool) ?? false
        let bookingGroupId = data["bookingGroupId"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        var booking = ManagerSiteBooking(
            id: id,
            userId: userId,
            date: date,
            timeSlot: timeSlot,
            locationType: locationType,
            locationId: locationId,
            customLocationName: customLocationName,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved,
            bookingGroupId: bookingGroupId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        booking.documentId = doc.documentID == id.uuidString ? nil : doc.documentID
        booking.locationKey = locationKey?.isEmpty == false ? locationKey : nil
        return booking
    }

    func listenManagerSiteBookings(
        organizationId: String,
        startingOn start: Date? = nil,
        onChange: @escaping ([ManagerSiteBooking]) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        let target = "managerSiteBookings:\(orgId)|\(start?.timeIntervalSince1970 ?? -1)"
        guard LaunchStartupPolicy.shouldAttachListener(
            activeTarget: managerScheduleLiveListenerTarget,
            requestedTarget: target
        ) else { return }
        managerScheduleLiveListener?.remove()
        managerScheduleLiveListenerTarget = target
        var query: Query = db.collection("organizations").document(orgId).collection("managerSiteBookings")
        if let start {
            query = query.whereField("date", isGreaterThanOrEqualTo: Timestamp(date: start))
        }
        managerScheduleLiveListener = query
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("🔥🔥🔥 DEBUG: manager schedule live listener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot else { return }
                let fromCache = snapshot.metadata.isFromCache
                Task { @MainActor in
                    guard let self else { return }
                    let currentOrganizationId = self.currentOrganization?.firestoreDocumentId
                    guard WarningsBookingScanScheduler.acceptsListener(
                        listenerOrganizationId: orgId,
                        currentOrganizationId: currentOrganizationId,
                        sessionOrganizationId: self.sessionOrganizationId
                    ) else {
                        print("🔥🔥🔥 DEBUG: manager schedule live listener ignored (organisation is no longer current) listener=\(orgId) current=\(currentOrganizationId ?? "nil") session=\(self.sessionOrganizationId)")
                        return
                    }
                    if fromCache && snapshot.documents.isEmpty {
                        print("🔥🔥🔥 DEBUG: manager schedule kept — ignored an empty cache snapshot")
                        return
                    }
                    let list = self.managerSiteBookingsFromFirestoreDocuments(snapshot.documents)
                    onChange(list)
                }
            }
    }

    func deleteManagerSiteBooking(_ booking: ManagerSiteBooking, organizationId: String) async throws {
        // Delete + `deletedBookings` tombstone in one batch (any member may write a managerSiteBookings tombstone).
        try await deleteBookingWithTombstone(
            collection: "managerSiteBookings",
            bookingId: booking.documentKey,
            organizationId: organizationId
        )
    }

    // MARK: - Holiday Bookings

    /// Creates ONE leave request document covering `startDate`–`endDate` (§9, `holidayRequestWriteFields`).
    /// Use `updateHolidayBookingFields` / `decideHolidayBooking` for an existing document.
    /// Returns the booking as stored (organisation-zone midnights, normalised slot and status).
    @discardableResult
    func saveHolidayBooking(_ booking: HolidayBooking, organizationId: String) async throws -> HolidayBooking {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        guard let fields = CanonicalBusinessEngine.holidayRequestWriteFields(
            id: booking.documentId,
            organizationId: orgId,
            userId: booking.userId,
            operativeId: booking.operativeIdRaw,
            startDayKey: booking.startDayKey,
            endDayKey: booking.endDayKey,
            timeSlot: booking.timeSlot.rawValue,
            status: booking.status.rawValue,
            approvedByUserId: booking.approvedByUserId
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "This annual leave request is not complete."])
        }
        let isApproved = fields.status == HolidayStatus.approved.rawValue
        let data: [String: Any] = WriteMetadata.stamped([
            "id": fields.id,
            "organizationId": fields.organizationId,
            "userId": fields.userId.map { $0 as Any } ?? NSNull(),
            "operativeId": fields.operativeId.map { $0 as Any } ?? NSNull(),
            "startDate": Timestamp(date: fields.startDate),
            "endDate": Timestamp(date: fields.endDate),
            "status": fields.status,
            "timeSlot": fields.timeSlot,
            "approvedByUserId": fields.approvedByUserId.map { $0 as Any } ?? NSNull(),
            "approvedAt": isApproved ? (FieldValue.serverTimestamp() as Any) : (NSNull() as Any),
            "cancellationRequestedAt": NSNull(),
            "cancellationRequestedByUserId": NSNull(),
            "decisionNote": NSNull(),
            "createdAt": FieldValue.serverTimestamp(),
        ], userId: auth.currentUser?.uid)
        try await db.collection("organizations").document(orgId).collection("holidayBookings").document(fields.id).setData(data)
        var stored = booking
        stored.organizationId = fields.organizationId
        stored.startDate = fields.startDate
        stored.endDate = fields.endDate
        stored.status = HolidayStatus(rawValue: fields.status) ?? booking.status
        stored.timeSlot = HolidayTimeSlot(rawValue: fields.timeSlot) ?? booking.timeSlot
        stored.approvedByUserId = fields.approvedByUserId
        stored.approvedAt = isApproved ? Date() : nil
        stored.cancellationRequestedAt = nil
        stored.cancellationRequestedByUserId = nil
        stored.decisionNote = nil
        return stored
    }

    /// Partial update of an existing leave document: only `fields` plus `WriteMetadata` (§1).
    /// `documentId` is the stored document id (`HolidayBooking.documentId`), never the in-memory UUID.
    func updateHolidayBookingFields(documentId: String, fields: [String: Any], organizationId: String) async throws {
        guard !fields.isEmpty else { return }
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        try await db.collection("organizations").document(orgId).collection("holidayBookings")
            .document(documentId)
            .updateData(WriteMetadata.stamped(fields, userId: auth.currentUser?.uid))
    }

    /// Approve or decline in one partial update (`holidayDecisionWriteFields`): status, approver,
    /// optional trimmed note (blank clears it), server `approvedAt`, and `WriteMetadata`.
    @discardableResult
    func decideHolidayBooking(
        _ booking: HolidayBooking,
        status: HolidayStatus,
        approverUid: String,
        decisionNote: String?,
        organizationId: String
    ) async throws -> CanonicalHolidayDecisionFields {
        guard let decision = CanonicalBusinessEngine.holidayDecisionWriteFields(
            status: status.rawValue,
            approverUid: approverUid,
            decisionNote: decisionNote
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "That decision is not valid."])
        }
        try await updateHolidayBookingFields(
            documentId: booking.documentId,
            fields: [
                "status": decision.status,
                "approvedByUserId": decision.approvedByUserId,
                "decisionNote": decision.decisionNote.map { $0 as Any } ?? NSNull(),
                "approvedAt": FieldValue.serverTimestamp(),
            ],
            organizationId: organizationId
        )
        return decision
    }

    /// Document ids in `organizations/{orgId}/dismissedWarnings`. Empty when the read fails,
    /// so a denied or offline read does not hide qualification rows.
    func loadDismissedQualificationKeys(organizationId: String) async -> Set<String> {
        let trimmed = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let snapshot = try await db.collection("organizations").document(trimmed)
                .collection("dismissedWarnings")
                .getDocuments()
            return Set(snapshot.documents.map(\.documentID))
        } catch {
            print("🔥🔥🔥 DEBUG: dismissedWarnings read failed for \(trimmed): \(error.localizedDescription)")
            return []
        }
    }

    /// Records that an expired qualification warning was dismissed. The document id is the
    /// script's `qualificationDismissKey`. Upcoming expiries must not be written here.
    func dismissExpiredQualification(
        operativeId: String,
        qualificationId: String,
        expiryDayKey: String,
        dismissKey: String
    ) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines),
              !orgId.isEmpty else {
            throw NSError(domain: "FirebaseBackend", code: 404, userInfo: [NSLocalizedDescriptionKey: "No organisation is open."])
        }
        guard let uid = auth.currentUser?.uid, !uid.isEmpty else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "No user signed in"])
        }
        let key = dismissKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key == CanonicalBusinessEngine.qualificationDismissKey(
                operativeId: operativeId,
                qualificationId: qualificationId,
                expiryDayKey: expiryDayKey
              ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "This qualification warning cannot be dismissed."])
        }
        try await db.collection("organizations").document(orgId)
            .collection("dismissedWarnings")
            .document(key)
            .setData([
                "kind": "qualification_expired",
                "dismissKey": key,
                "operativeId": operativeId,
                "qualificationId": qualificationId,
                "expiryDayKey": expiryDayKey,
                "dismissedAt": FieldValue.serverTimestamp(),
                "dismissedByUserId": uid,
            ], merge: true)
    }

    func loadHolidayBookings(organizationId: String) async throws -> [HolidayBooking] {
        // Read path only — do not run writable-org repair (that can hang launch).
        let orgId = try await ensureReadableOrganization(organizationId)
        let holidaysRef = db.collection("organizations").document(orgId).collection("holidayBookings")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await holidaysRef.getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [HOLIDAY LOAD] Server denied holidayBookings read for \(orgId) - trying cache fallback")
                snapshot = try await holidaysRef.getDocuments(source: .cache)
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: [HOLIDAY LOAD] Offline while loading holidayBookings for \(orgId) - trying cache fallback")
                snapshot = try await holidaysRef.getDocuments(source: .cache)
            } else {
                throw error
            }
        }
        let parsed = holidayBookingsFromFirestore(snapshot.documents, organizationId: orgId)
        print("🔥🔥🔥 DEBUG: [HOLIDAY LOAD] docs=\(snapshot.documents.count) parsed=\(parsed.count) skipped=\(snapshot.documents.count - parsed.count)")
        return parsed
    }

    /// RULEBOOK 1.5.0 §1 "Document readers", §9: leave documents are read only through the rulebook's
    /// `parseHolidayDocuments` (web reads them with the same function), so keys, status and slot synonyms,
    /// stored-case ids and organisation-zone day keys match web. Unreadable documents are dropped.
    private func holidayBookingsFromFirestore(
        _ documents: [QueryDocumentSnapshot],
        organizationId orgId: String
    ) -> [HolidayBooking] {
        let rows: [(id: String, data: [String: Any])] = documents.map { doc in
            (id: doc.documentID, data: doc.data())
        }
        return Self.holidayBookings(fromDocuments: rows, organizationId: orgId)
    }

    /// `parseHolidayDocuments` over stored `{ id, data }` rows (Firestore values; converted with
    /// `firestoreJSON` for the script), mapped onto `HolidayBooking`. Tests call this with raw documents.
    static func holidayBookings(
        fromDocuments documents: [(id: String, data: [String: Any])],
        organizationId orgId: String
    ) -> [HolidayBooking] {
        let rows: [(id: String, data: [String: Any])] = documents.map { doc in
            (id: doc.id, data: (Self.firestoreJSON(doc.data) as? [String: Any]) ?? [:])
        }
        let records: [CanonicalHolidayDocument]
        if let all = CanonicalBusinessEngine.parseHolidayDocuments(rows) {
            records = all
        } else {
            // One document the script cannot take (for example a non-finite number) must not hide the rest.
            NSLog("HOLIDAYS_PARSE_FAILED docs=%d — reading leave documents one at a time", documents.count)
            records = rows.compactMap { CanonicalBusinessEngine.parseHolidayDocument(documentId: $0.id, data: $0.data) }
        }
        var rawById: [String: [String: Any]] = [:]
        for doc in documents where rawById[doc.id] == nil {
            rawById[doc.id] = doc.data
        }
        return records.compactMap { record in
            Self.holidayBooking(fromCanonical: record, raw: rawById[record.id] ?? [:], organizationId: orgId)
        }
    }

    /// Maps one `parseHolidayDocument` record onto `HolidayBooking`, keeping the document id, the stored
    /// `userId` / `operativeId` strings and the reader's day keys. Only the display timestamps the reader does
    /// not return (`createdAt`, `updatedAt`, `approvedAt`, `cancellationRequestedAt`) are read here.
    static func holidayBooking(
        fromCanonical record: CanonicalHolidayDocument,
        raw data: [String: Any],
        organizationId orgId: String
    ) -> HolidayBooking? {
        guard let startDate = OrganizationRulebookContext.date(fromDayKey: record.startDayKey),
              let endDate = OrganizationRulebookContext.date(fromDayKey: record.endDayKey) else {
            print("🔥🔥🔥 DEBUG: [HOLIDAY LOAD] skip \(record.id) — day keys \(record.startDayKey)…\(record.endDayKey)")
            return nil
        }
        func storedDate(_ key: String) -> Date? { firestoreDate(data[key]) }
        let createdAt = storedDate("createdAt") ?? Date()
        let updatedAt = storedDate("updatedAt") ?? createdAt
        let cancellationRequestedAt: Date? = record.cancellationRequested
            ? (storedDate("cancellationRequestedAt") ?? updatedAt)
            : nil
        return HolidayBooking(
            id: Manager.stableId(forFirestoreDocumentId: record.id),
            documentId: record.id,
            organizationId: record.organizationId ?? orgId,
            userId: record.userId,
            operativeIdRaw: record.operativeId,
            startDate: startDate,
            endDate: endDate,
            startDayKey: record.startDayKey,
            endDayKey: record.endDayKey,
            status: HolidayStatus(rawValue: record.status) ?? (record.approved ? .approved : .pending),
            timeSlot: HolidayTimeSlot(rawValue: record.timeSlot) ?? .fullDay,
            approvedByUserId: record.approvedByUserId,
            approvedAt: storedDate("approvedAt"),
            cancellationRequestedAt: cancellationRequestedAt,
            cancellationRequestedByUserId: record.cancellationRequestedByUserId,
            decisionNote: record.decisionNote,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Deletes the document the record was read from (`documentId`, stored case; web ids need not be UUIDs).
    func deleteHolidayBooking(_ booking: HolidayBooking, organizationId: String) async throws {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        try await db.collection("organizations").document(orgId).collection("holidayBookings").document(booking.documentId).delete()
    }

    func recordOperativeDayRateChange(
        organizationId: String,
        userId: String?,
        operativeId: UUID?,
        dayRate: Double?,
        effectiveAt: Date,
        payBasis: String? = nil
    ) async throws {
        let trimmedUser = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = (trimmedUser?.isEmpty == false) ? trimmedUser : nil
        guard uid != nil || operativeId != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "recordOperativeDayRateChange requires userId and/or operativeId"]
            )
        }
        // RULEBOOK §8 `payRateHistoryWriteFields`: { userId, operativeId, dayRate, payBasis, effectiveAt } with
        // `effectiveAt` organisation-zone midnight; a nil rate writes a "rate cleared" row (dayRate and payBasis
        // null). The app adds `createdAt` and write metadata. History is never rewritten.
        guard let fields = CanonicalBusinessEngine.payRateHistoryWriteFields(
            userId: uid,
            // The stored operative id (a non-UUID or lower-case id keeps its stored form), never a re-cased UUID.
            operativeId: operativeId.map { Booking.storedOperativeId(for: $0) },
            rate: dayRate,
            payBasis: payBasis,
            effective: effectiveAt
        ) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Could not build the rate history row."]
            )
        }
        let payload: [String: Any] = [
            "dayRate": fields.dayRate.map { $0 as Any } ?? NSNull(),
            "payBasis": fields.payBasis.map { $0 as Any } ?? NSNull(),
            "effectiveAt": Timestamp(date: fields.effectiveAt),
            "userId": fields.userId,
            "operativeId": fields.operativeId,
            "createdAt": FieldValue.serverTimestamp()
        ]
        try await db.collection("organizations")
            .document(organizationId)
            .collection("operativeDayRateHistory")
            .document(UUID().uuidString)
            .setData(WriteMetadata.stamped(payload, userId: auth.currentUser?.uid))
    }

    func loadOperativeDayRateHistory(organizationId: String) async throws -> OperativeDayRateHistoryCollection {
        let snapshot = try await db.collection("organizations")
            .document(organizationId)
            .collection("operativeDayRateHistory")
            .getDocuments()
        return Self.operativeDayRateHistory(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) })
    }

    /// RULEBOOK 1.6.0 §1 "Document readers", §8: `operativeDayRateHistory` rows are read only through the
    /// rulebook's `parsePayRateHistoryDocuments` (a "rate cleared" row keeps `dayRate` nil; a missing basis on an old
    /// row is day). The entry keeps its document id and the stored `operativeId` (a non-UUID id is kept, never
    /// dropped); `byOperativeId` is keyed by the in-app operative UUID string (`Booking.internalOperativeId`, the
    /// same id `Operative.id` uses), so a lookup with `operative.id.uuidString` finds rows stored in any case.
    static func operativeDayRateHistory(fromDocuments documents: [(id: String, data: [String: Any])]) -> OperativeDayRateHistoryCollection {
        let rows: [CanonicalDocumentRow]
        if let all = CanonicalBusinessEngine.parsePayRateHistoryDocuments(documents) {
            rows = all
        } else {
            NSLog("PAY_HISTORY_PARSE_FAILED docs=%d — reading history rows one at a time", documents.count)
            rows = documents.compactMap { CanonicalBusinessEngine.parsePayRateHistoryDocument(documentId: $0.id, data: $0.data) }
                .sorted { ($0.number("effectiveAt") ?? 0, $0.number("createdAt") ?? 0) < ($1.number("effectiveAt") ?? 0, $1.number("createdAt") ?? 0) }
        }
        var byUserId: [String: [OperativeDayRateHistoryEntry]] = [:]
        var byOperativeId: [String: [OperativeDayRateHistoryEntry]] = [:]
        for row in rows {
            guard let effectiveAt = row.date("effectiveAt") else { continue }
            let userId = row.optionalText("userId")
            let operativeIdRaw = row.optionalText("operativeId")
            let operativeId = operativeIdRaw.map { Booking.internalOperativeId(for: $0) }
            var entry = OperativeDayRateHistoryEntry(
                id: Manager.stableId(forFirestoreDocumentId: row.id),
                userId: userId,
                operativeId: operativeId,
                dayRate: row.bool("cleared") ? nil : row.number("dayRate"),
                effectiveAt: effectiveAt,
                createdAt: row.date("createdAt") ?? effectiveAt,
                payBasis: row.optionalText("payBasis")
            )
            entry.documentId = row.id
            entry.operativeIdRaw = operativeIdRaw
            if let userId {
                byUserId[userId, default: []].append(entry)
            }
            if let operativeId {
                byOperativeId[operativeId.uuidString, default: []].append(entry)
            }
        }
        return OperativeDayRateHistoryCollection(byUserId: byUserId, byOperativeId: byOperativeId)
    }

    // MARK: - Data Validation & Safeguards
    
    /// Validates that an organization exists before allowing operations
    func validateOrganizationExists(_ organizationId: String) async throws -> Bool {
        let trimmed = normalizedOrganizationId(organizationId)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Organization ID is empty"])
        }
        do {
            let doc = try await db.collection("organizations").document(trimmed).getDocument(source: .server)
            guard doc.exists else {
                print("🔥🔥🔥 DEBUG: ❌ Organization validation failed - organization does not exist: \(trimmed)")
                throw NSError(domain: "FirebaseBackend", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organization not found"])
            }
            return true
        } catch {
            if isFirestorePermissionDenied(error) {
                // Match ensureReadableOrganization: some orgs deny root doc reads while subcollection writes still succeed.
                print("🔥🔥🔥 DEBUG: ⚠️ Org root read denied for \(trimmed) during validation — skipping strict existence check")
                return true
            }
            throw error
        }
    }
    
    /// Validates that user has organizationId before saving data
    func validateUserOrganizationLink(userId: String) async throws -> String {
        let userDoc = try await db.collection("users").document(userId).getDocument(source: .server)
        guard userDoc.exists, let userData = userDoc.data(),
              let organizationId = organizationIdFromFirestore(userData["organizationId"]) else {
            print("🔥🔥🔥 DEBUG: ❌ User validation failed - missing organizationId for user: \(userId)")
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "User is not linked to an organization"])
        }
        
        // Validate organization exists
        _ = try await validateOrganizationExists(organizationId)
        return organizationId
    }
    
    /// Confirms the signed-in user document exists before a save.
    /// Does not write organizationId, role, adminAccess, isSuperAdmin, or permissions.adminAccess.
    @MainActor
    func ensureUserDocumentLinked(organizationId: String) async throws {
        guard let userId = currentUser?.uid,
              let userEmail = currentUser?.email else {
            print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ❌ User not authenticated")
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        
        let orgIdStr = normalizedOrganizationId(organizationId)
        print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] Starting for user: \(userId), org: \(orgIdStr)")
        
        let userDocRef = db.collection("users").document(userId)
        
        do {
            let userDoc = try await userDocRef.getDocument(source: .server)
            
            if userDoc.exists {
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] User document exists — not writing organizationId or privilege fields")
            } else {
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] User document doesn't exist - creating it without organizationId or role")
                try await userDocRef.setData([
                    "email": userEmail,
                    "isActive": true,
                    "createdAt": Timestamp(date: Date()),
                    "updatedAt": Timestamp(date: Date())
                ])
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ✅ User document created without organizationId or role")
                
                let verifyDoc = try await userDocRef.getDocument()
                if verifyDoc.exists {
                    print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ✅ Verification passed - user document exists")
                } else {
                    print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ⚠️ Verification failed - user document was not created")
                }
            }
        } catch {
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ❌ Error: \(error.localizedDescription)")
            print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] Error domain: \(nsError.domain), code: \(nsError.code)")
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ❌ PERMISSION DENIED - User may not have permission to update their own document")
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] This is OK - validation will check organization members as fallback")
            }
            throw error
        }
    }
    
    func recoverMissingOrganizationLink(userId: String, userEmail: String) async -> Bool {
        print("🔥🔥🔥 DEBUG: 🔧 Attempting to recover missing organization link for user: \(userId), email: \(userEmail)")
        if isRecoveringOrganizationLink {
            print("🔥🔥🔥 DEBUG: Organization recovery already in progress, skipping duplicate")
            return currentOrganization != nil
        }
        if let msg = errorMessage?.lowercased(), msg.contains("offline") {
            print("🔥🔥🔥 DEBUG: Skipping organization recovery while offline")
            return false
        }
        isRecoveringOrganizationLink = true
        defer { isRecoveringOrganizationLink = false }

        do {
            // Strategy 1/2: only orgs this uid belongs to — never scan the full collection (jetsam).
            let memberships = try await loadOrganizationMembershipDocuments(userId: userId)
            print("🔥🔥🔥 DEBUG: Found \(memberships.count) organisations for this user")
            if let preferred = memberships.first(where: { $0.role == "admin" }) ?? memberships.first {
                let organizationId = preferred.id
                let userRole = preferred.role
                let orgData = preferred.data
                print("🔥🔥🔥 DEBUG: ✅ Found organisation via membership: \(organizationId) (role: \(userRole))")
                print("🔥🔥🔥 DEBUG: Not writing users/\(userId).organizationId — opening \(organizationId) locally")

                await loadUserOrganization(userId: userId)
                if currentOrganization == nil {
                    await setCurrentOrganizationFromRecovery(orgId: organizationId, orgData: orgData, fallbackRole: userRole)
                }
                return currentOrganization != nil
            }
            
            // Strategy 3: Check user document for any organizationId that might exist
            let userDoc = try await db.collection("users").document(userId).getDocument(source: .server)
            if userDoc.exists, let userData = userDoc.data(),
               let orgId = organizationIdFromFirestore(userData["organizationId"]) {
                print("🔥🔥🔥 DEBUG: ✅ Found organizationId in user document: \(orgId)")
                // Verify organization exists
                let orgDoc = try await db.collection("organizations").document(orgId).getDocument(source: .server)
                if orgDoc.exists {
                    await loadUserOrganization(userId: userId)
                    return currentOrganization != nil
                }
            }
            
            // Same-email discovery across every users document is refused. There is no company to scope it to here.
            print("🔥🔥🔥 DEBUG: Skipping unscoped same-email user scan for \(userEmail)")
            if currentOrganization != nil {
                return true
            }

            // Do not scan the full `organizations` collection as a last resort — that jetsams
            // the Simulator. Membership and the user document already ran. Same-email listing did not.
            print("🔥🔥🔥 DEBUG: ⚠️ Could not find organization through any recovery strategy")
            print("🔥🔥🔥 DEBUG: User may need to contact support or recreate account")
            
            return false
        } catch {
            print("🔥🔥🔥 DEBUG: ❌ Error during recovery: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Enhanced save with validation - ensures organizationId is valid before saving
    func saveProjectWithValidation(_ project: Project, organizationId: String) async throws {
        // Validate organization exists
        _ = try await validateOrganizationExists(organizationId)
        
        // Validate organizationId matches
        guard project.id.uuidString != "INITIAL-PLACEHOLDER" else {
            print("🔥🔥🔥 DEBUG: ⚠️ Skipping save of legacy placeholder project")
            return
        }
        
        // Save project (an edit of a stored project; never re-creates one deleted elsewhere)
        try await saveProject(project, organizationId: organizationId, mode: .update)
    }
    
    /// Enhanced load with recovery - automatically attempts recovery if organization link is missing
    @MainActor
    func loadUserOrganizationWithRecovery(userId: String) async {
        await loadUserOrganization(userId: userId)
        if let msg = errorMessage, msg.lowercased().contains("offline") {
            print("🔥🔥🔥 DEBUG: Skipping organization recovery retries while offline")
            return
        }
        
        // If organization is still nil after loading, attempt recovery
        if currentOrganization == nil, let userEmail = currentUser?.email {
            print("🔥🔥🔥 DEBUG: ⚠️ Organization is nil after load, attempting recovery...")
            let recovered = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
            if recovered, currentOrganization != nil {
                print("🔥🔥🔥 DEBUG: ✅ Recovery successful! Organization loaded: \(currentOrganization?.name ?? "N/A")")
                // Post notification that organization was recovered so stores can reload
                broadcastOrganizationDidLoadIfNeeded()
            } else {
                // Try one more time with a delay
                print("🔥🔥🔥 DEBUG: ⚠️ First recovery attempt failed, retrying in 2 seconds...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let retryRecovered = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                if retryRecovered, currentOrganization != nil {
                    print("🔥🔥🔥 DEBUG: ✅ Retry recovery successful!")
                    broadcastOrganizationDidLoadIfNeeded()
                } else {
                    errorMessage = "Organization not found. Tap 'Force Reload' in Settings to try again."
                }
            }
        } else if currentOrganization != nil {
            // Organization loaded successfully - notify stores to reload data
            print("🔥🔥🔥 DEBUG: ✅ Organization loaded successfully: \(currentOrganization?.name ?? "N/A")")
            broadcastOrganizationDidLoadIfNeeded()
        }
    }
    
    /// Force reload organization and all data - for manual recovery
    @MainActor
    func forceReloadOrganization() async {
        guard let userId = currentUser?.uid else {
            errorMessage = "User not authenticated"
            return
        }
        
        print("🔥🔥🔥 DEBUG: 🔄 Force reloading organization...")
        isLoading = true
        errorMessage = nil
        
        // Allow PlannerStoreWiring to run a fresh single-flight bootstrap after reload.
        hasBootstrappedOrgDataLoad = false
        isBootstrappingOrgDataLoad = false
        launchQuietUntil = nil

        // Refresh the company already chosen on this phone. Do not adopt another platform's organisation.
        currentOrganization = nil
        
        // First, try normal load
        await loadUserOrganization(userId: userId)
        if let msg = errorMessage, msg.lowercased().contains("offline") {
            isLoading = false
            print("🔥🔥🔥 DEBUG: Force reload aborted due to offline network")
            return
        }
        
        // If still nil, try recovery with all strategies
        if currentOrganization == nil {
            print("🔥🔥🔥 DEBUG: ⚠️ Normal load failed, attempting recovery...")
            if let userEmail = currentUser?.email {
                let recovered = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                if recovered {
                    print("🔥🔥🔥 DEBUG: ✅ Recovery successful!")
                } else {
                    // Try one more time with a longer delay
                    print("🔥🔥🔥 DEBUG: ⚠️ First recovery failed, retrying...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    _ = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                }
            }
        }
        
        // Post notification to reload all data
        broadcastOrganizationDidLoadIfNeeded(force: true)
        
        isLoading = false
        
        if currentOrganization != nil {
            print("🔥🔥🔥 DEBUG: ✅ Force reload successful: \(currentOrganization?.name ?? "N/A")")
            errorMessage = nil
        } else {
            let diagnostic = await diagnoseMissingData()
            print("🔥🔥🔥 DEBUG: ❌ Force reload failed. Diagnostic:\n\(diagnostic)")
            errorMessage = "Could not recover organization. Check diagnostic report in console."
        }
    }
    
    /// Validates data integrity before save operations
    func validateDataIntegrity(organizationId: String) async throws {
        // Check organization exists
        _ = try await validateOrganizationExists(organizationId)
        
        // Check user has access
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        
        // Try to validate user organization link
        // If user document doesn't have organizationId, check if user is in organization's members list
        do {
            let userOrgId = try await validateUserOrganizationLink(userId: userId)
            guard organizationIdsMatch(userOrgId, organizationId) else {
                throw NSError(domain: "FirebaseBackend", code: 403, userInfo: [NSLocalizedDescriptionKey: "User does not belong to this organization"])
            }
        } catch {
            // If user document validation fails, check if user is in organization's members list as fallback
            print("🔥🔥🔥 DEBUG: [validateDataIntegrity] User document validation failed, checking organization members as fallback...")
            let orgDoc = try await db.collection("organizations").document(organizationId).getDocument(source: .server)
            guard orgDoc.exists, let orgData = orgDoc.data() else {
                throw NSError(domain: "FirebaseBackend", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organization not found"])
            }
            
            // Check if user is in members list
            if let members = orgData["members"] as? [String: String], members[userId] != nil {
                print("🔥🔥🔥 DEBUG: [validateDataIntegrity] ✅ User is in organization members list - validation passed")
                // Try to update user document with organizationId for future saves
                do {
                    try await ensureUserDocumentLinked(organizationId: organizationId)
                } catch {
                    print("🔥🔥🔥 DEBUG: [validateDataIntegrity] ⚠️ Could not update user document: \(error.localizedDescription)")
                    // Continue anyway since user is in members list
                }
                return // Validation passed
            }
            
            // If we get here, user is not in members list either - throw original error
            print("🔥🔥🔥 DEBUG: [validateDataIntegrity] ❌ User is not in organization members list")
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "User is not linked to an organization"])
        }
    }
    
    /// Comprehensive diagnostic to check why data might be missing
    @MainActor
    func diagnoseMissingData() async -> String {
        var report = "🔍 DATA DIAGNOSTIC REPORT\n"
        report += "========================\n\n"
        
        // 1. Check authentication
        report += "1. AUTHENTICATION STATUS\n"
        if isAuthenticated {
            report += "   ✅ User is authenticated\n"
            if let user = currentUser {
                report += "   User ID: \(user.uid)\n"
                report += "   Email: \(user.email ?? "N/A")\n"
            }
        } else {
            report += "   ❌ User is NOT authenticated\n"
            report += "   ACTION: User needs to sign in\n"
            return report
        }
        
        guard let userId = currentUser?.uid else {
            report += "   ❌ Cannot get user ID\n"
            return report
        }
        
        // 2. Check user document
        report += "\n2. USER DOCUMENT\n"
        do {
            let userDoc = try await db.collection("users").document(userId).getDocument()
            if userDoc.exists {
                report += "   ✅ User document exists\n"
                if let userData = userDoc.data() {
                    report += "   User data keys: \(userData.keys.joined(separator: ", "))\n"
                    
                    if let orgId = userData["organizationId"] as? String {
                        report += "   ✅ organizationId found: \(orgId)\n"
                        
                        // 3. Check organization document
                        report += "\n3. ORGANIZATION DOCUMENT\n"
                        let orgDoc = try await db.collection("organizations").document(orgId).getDocument()
                        if orgDoc.exists {
                            report += "   ✅ Organization document exists\n"
                            if let orgData = orgDoc.data() {
                                let orgName = orgData["name"] as? String ?? "Unknown"
                                report += "   Organization name: \(orgName)\n"
                                
                                // 4. Check data in subcollections
                                report += "\n4. DATA IN SUBCOLLECTIONS\n"
                                
                                // Projects
                                let projectsSnapshot = try await db.collection("organizations")
                                    .document(orgId)
                                    .collection("projects")
                                    .getDocuments()
                                let projectCount = projectsSnapshot.documents.count
                                report += "   Projects: \(projectCount) found\n"
                                if projectCount > 0 {
                                    report += "   ✅ Projects exist in Firebase\n"
                                } else {
                                    report += "   ⚠️ No projects found (this might be normal if none created)\n"
                                }
                                
                                // Operatives
                                let operativesSnapshot = try await db.collection("organizations")
                                    .document(orgId)
                                    .collection("operatives")
                                    .getDocuments()
                                let operativeCount = operativesSnapshot.documents.count
                                report += "   Operatives: \(operativeCount) found\n"
                                if operativeCount > 0 {
                                    report += "   ✅ Operatives exist in Firebase\n"
                                } else {
                                    report += "   ⚠️ No operatives found (this might be normal if none created)\n"
                                }
                                
                                // Managers
                                let managersSnapshot = try await db.collection("organizations")
                                    .document(orgId)
                                    .collection("managers")
                                    .getDocuments()
                                let managerCount = managersSnapshot.documents.count
                                report += "   Managers: \(managerCount) found\n"
                                if managerCount > 0 {
                                    report += "   ✅ Managers exist in Firebase\n"
                                } else {
                                    report += "   ⚠️ No managers found (this might be normal if none created)\n"
                                }
                                
                                // Clients
                                let clientsSnapshot = try await db.collection("organizations")
                                    .document(orgId)
                                    .collection("clients")
                                    .getDocuments()
                                let clientCount = clientsSnapshot.documents.count
                                report += "   Clients: \(clientCount) found\n"
                                if clientCount > 0 {
                                    report += "   ✅ Clients exist in Firebase\n"
                                } else {
                                    report += "   ⚠️ No clients found (this might be normal if none created)\n"
                                }
                                
                                // 5. Check current state
                                report += "\n5. APP STATE\n"
                                if currentOrganization != nil {
                                    report += "   ✅ Organization loaded in app: \(currentOrganization?.name ?? "N/A")\n"
                                } else {
                                    report += "   ❌ Organization NOT loaded in app\n"
                                    report += "   ACTION: Try 'Force Reload Data' button\n"
                                }
                                
                                report += "\n6. RECOMMENDATION\n"
                                if currentOrganization == nil {
                                    report += "   ⚠️ Organization exists in Firebase but not loaded in app\n"
                                    report += "   ACTION: Tap 'Force Reload Data' in Settings\n"
                                } else if projectCount == 0 && operativeCount == 0 && managerCount == 0 && clientCount == 0 {
                                    report += "   ℹ️ No data exists in Firebase (this is normal for new accounts)\n"
                                } else {
                                    report += "   ✅ Data exists in Firebase. If not showing in app, try 'Force Reload Data'\n"
                                }
                                
                            } else {
                                report += "   ❌ Organization document has no data\n"
                            }
                        } else {
                            report += "   ❌ Organization document does NOT exist\n"
                            report += "   Organization ID: \(orgId)\n"
                            report += "   ACTION: Try recovery or contact support\n"
                        }
                    } else {
                        report += "   ❌ organizationId NOT found in user document\n"
                        report += "   ACTION: Try 'Force Reload Data' to trigger recovery\n"
                    }
                } else {
                    report += "   ❌ User document has no data\n"
                }
            } else {
                report += "   ❌ User document does NOT exist\n"
                report += "   ACTION: User may need to recreate account\n"
            }
        } catch {
            report += "   ❌ Error reading user document: \(error.localizedDescription)\n"
        }
        
        return report
    }
    
    /// Manually link user to a specific organization by ID
    /// Use this if you know the organization ID and want to force the link
    @MainActor
    func manuallyLinkToOrganization(organizationId: String) async -> Bool {
        do {
            try await switchActiveOrganization(to: organizationId)
            print("🔥🔥🔥 DEBUG: ✅✅✅ Organization loaded via manual link")
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: ❌ Error linking to organization: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Finds a better organization for this user when current org has no projects/small works.
    /// Returns true if the app switched `currentOrganization` and persisted the new org locally.
    @MainActor
    func autoSwitchToOrganizationWithWorkData(userId: String, currentOrganizationId: String) async -> Bool {
        // An empty project list must not move this phone to another company. The user stays until they tap Switch organisation.
        print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Skipped — this phone keeps \(currentOrganizationId)")
        _ = userId
        return false
    }
}

// MARK: - Data Models

struct UserData {
    let id: String
    let email: String
    let displayName: String
    let organizationId: String
    let role: String
    let createdAt: Date
}

struct OrganizationData {
    let id: String
    let name: String
    let members: [String: String] // userId: role
    let settings: [String: Any]
    let createdAt: Date
}

// MARK: - Firestore Rules Test Extension

extension FirebaseBackend {
    
    /// Test if Firestore rules are properly deployed by attempting a test write
    /// This helps diagnose if rules are actually deployed or if there's a permission issue
    func testFirestoreRules() async -> (success: Bool, message: String) {
        guard let currentUserId = currentUser?.uid else {
            return (false, "Not authenticated")
        }
        
        print("🔥🔥🔥 DEBUG: [RulesTest] Testing Firestore rules deployment...")
        print("🔥🔥🔥 DEBUG: [RulesTest] Current user ID: \(currentUserId)")
        
        // Try to read the current user's document (should always work if authenticated)
        do {
            let userDoc = try await db.collection("users").document(currentUserId).getDocument()
            if userDoc.exists {
                let data = userDoc.data() ?? [:]
                let isSuperAdmin = data["isSuperAdmin"] as? Bool ?? false
                let adminAccess = data["adminAccess"] as? Bool ?? false
                let role = data["role"] as? String ?? ""
                
                print("🔥🔥🔥 DEBUG: [RulesTest] ✅ Can read user document")
                print("🔥🔥🔥 DEBUG: [RulesTest] - isSuperAdmin: \(isSuperAdmin) (type: \(type(of: data["isSuperAdmin"])))")
                print("🔥🔥🔥 DEBUG: [RulesTest] - adminAccess: \(adminAccess) (type: \(type(of: data["adminAccess"])))")
                print("🔥🔥🔥 DEBUG: [RulesTest] - role: '\(role)' (type: \(type(of: data["role"])))")
                
                let hasAdmin = isSuperAdmin || adminAccess || role == "admin"
                
                if hasAdmin {
                    // Try a test write to verify rules allow admin writes
                    let testData: [String: Any] = [
                        "rulesTest": Timestamp(date: Date()),
                        "testedBy": currentUserId
                    ]
                    
                    // Try to update a test field (we'll remove it immediately)
                    try await db.collection("users").document(currentUserId).updateData(testData)
                    print("🔥🔥🔥 DEBUG: [RulesTest] ✅ Can write to user document - rules are working!")
                    
                    // Clean up test field
                    try? await db.collection("users").document(currentUserId).updateData([
                        "rulesTest": FieldValue.delete(),
                        "testedBy": FieldValue.delete()
                    ])
                    
                    return (true, "✅ Firestore rules are deployed and working correctly. Your user has admin permissions.")
                } else {
                    return (false, "⚠️ Rules are deployed, but your user document doesn't have admin permissions. Set isSuperAdmin=true, adminAccess=true, or role='admin' in Firebase Console.")
                }
            } else {
                return (false, "❌ User document doesn't exist. Please sign out and sign back in.")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: [RulesTest] ❌ Error testing rules: \(error)")
            if let nsError = error as NSError? {
                if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                    return (false, "❌ Permission denied. This means:\n1. Firestore rules are NOT deployed, OR\n2. Your user document doesn't have admin permissions.\n\nPlease:\n- Deploy rules to Firebase Console\n- Set isSuperAdmin=true, adminAccess=true, or role='admin' in your user document")
                }
            }
            return (false, "❌ Error testing rules: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Materials

    /// RULEBOOK 1.8.0 §1: a `materials/{id}` line read through `parseMaterialLineDocument` (non-UUID ids, odd units,
    /// numeric-string quantities and web lines are kept; the day is the organisation-zone `dayKey`, never device
    /// midnight). Ids map to stable in-app UUIDs with their stored spelling remembered. Nil without a job or name.
    static func materialItem(documentId: String, data: [String: Any]) -> MaterialItem? {
        guard let row = CanonicalBusinessEngine.parseMaterialLineDocument(documentId: documentId, data: data) else { return nil }
        let day = row.optionalText("dayKey").flatMap { OrganizationRulebookContext.date(fromDayKey: $0) }
            ?? row.date("dateMs")
            ?? row.date("addedAtMs")
            ?? Date()
        let quantity = row.number("quantity") ?? 1
        return MaterialItem(
            id: JobKeys.inAppId(row.id),
            quantity: max(0, Int(quantity.rounded())),
            unit: MaterialUnit(rawValue: row.text("unit")) ?? .number,
            material: row.text("material"),
            addedBy: row.text("addedBy"),
            addedByUserId: row.optionalText("addedByUserId"),
            addedAt: row.date("addedAtMs") ?? Date(timeIntervalSince1970: 0),
            editedBy: row.optionalText("editedBy"),
            editedByUserId: row.optionalText("editedByUserId"),
            editedAt: row.date("editedAtMs"),
            projectId: JobKeys.inAppId(row.text("projectId")),
            date: day,
            status: MaterialWorkflowStatus(rawValue: row.text("status")) ?? .draft,
            catalogueItemId: row.optionalText("catalogueItemId").map { JobKeys.inAppId($0) },
            brand: row.optionalText("brand"),
            productCode: row.optionalText("productCode"),
            size: row.optionalText("size"),
            length: row.optionalText("length"),
            lengthUnit: MaterialLengthUnit(rawValue: row.text("lengthUnit")),
            category: row.optionalText("category"),
            websiteURL: row.optionalText("websiteURL"),
            notes: row.optionalText("notes"),
            lastSentAt: row.date("lastSentAtMs"),
            lastSentRequestType: MaterialOrderRequest.RequestType(rawValue: row.text("lastSentRequestType"))
        )
    }

    private func materialItemFromFirestoreDocument(_ documentId: String, _ data: [String: Any]) -> MaterialItem? {
        Self.materialItem(documentId: documentId, data: data)
    }

    /// RULEBOOK 1.8.0 §1: the stored shape of a material line from `materialLineFields` (organisation-zone `dayKey`
    /// plus `date` at organisation-zone midnight; `material`/`name` and `length`/`sizeOrLength` mirrored; blanks null
    /// so a partial save removes them). Ids are written as stored. Native Timestamps for the instants.
    static func materialLinePayload(_ material: MaterialItem, addedByUserId: String?) -> [String: Any]? {
        let input: [String: Any] = [
            "id": WorkDocumentKeys.storedId(for: material.id),
            "projectId": JobKeys.storedJobId(for: material.projectId),
            "quantity": material.quantity,
            "unit": material.unit.rawValue,
            "material": material.material,
            "dayKey": OrganizationRulebookContext.dayKey(material.date),
            "status": material.status.rawValue,
            "addedBy": material.addedBy,
            "addedByUserId": addedByUserId ?? NSNull(),
            "editedBy": material.editedBy ?? NSNull(),
            "editedByUserId": material.editedByUserId ?? NSNull(),
            "catalogueItemId": material.catalogueItemId.map { WorkDocumentKeys.storedId(for: $0) as Any } ?? NSNull(),
            "brand": material.brand ?? NSNull(),
            "productCode": material.productCode ?? NSNull(),
            "category": material.category ?? NSNull(),
            "size": material.size ?? NSNull(),
            "length": material.length ?? NSNull(),
            "lengthUnit": material.lengthUnit?.rawValue ?? NSNull(),
            "websiteURL": material.websiteURL ?? NSNull(),
            "notes": material.notes ?? NSNull(),
        ]
        guard var fields = CanonicalBusinessEngine.materialLineFields(input) else { return nil }
        fields["date"] = ScriptFirestoreValue.timestamp(ms: fields["date"]) ?? NSNull()
        fields["addedAt"] = Timestamp(date: material.addedAt)
        fields["editedAt"] = material.editedAt.map { Timestamp(date: $0) as Any } ?? NSNull()
        if let lastSentAt = material.lastSentAt { fields["lastSentAt"] = Timestamp(date: lastSentAt) }
        if let lastSentRequestType = material.lastSentRequestType { fields["lastSentRequestType"] = lastSentRequestType.rawValue }
        return fields
    }
    
    private func truthyFirestoreBool(_ value: Any?) -> Bool {
        (value as? Bool == true) || (value as? Int == 1)
    }

    private func normalizedMaterialOwnerString(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    private func materialAddedByMatchesAuthUser(_ material: MaterialItem) -> Bool {
        let normalizedAddedBy = normalizedMaterialOwnerString(material.addedBy)
        let authDisplay = normalizedMaterialOwnerString(currentUser?.displayName)
        let authEmail = normalizedMaterialOwnerString(currentUser?.email)
        return normalizedAddedBy == authDisplay || normalizedAddedBy == authEmail
    }

    private func materialAddedByMatchesUserDocument(_ material: MaterialItem, userData: [String: Any]) -> Bool {
        let normalizedAddedBy = normalizedMaterialOwnerString(material.addedBy)
        let email = normalizedMaterialOwnerString(userData["email"] as? String)
        let firstName = normalizedMaterialOwnerString(userData["firstName"] as? String)
        let surname = normalizedMaterialOwnerString(userData["surname"] as? String)
        let lastName = normalizedMaterialOwnerString(userData["lastName"] as? String)
        let fullName = [firstName, surname].filter { !$0.isEmpty }.joined(separator: " ")
        let alternateFullName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return normalizedAddedBy == email ||
            (!fullName.isEmpty && normalizedAddedBy == fullName) ||
            (!alternateFullName.isEmpty && normalizedAddedBy == alternateFullName)
    }

    private func currentUserOwnsLegacyMaterial(_ material: MaterialItem, organizationId: String) async -> Bool {
        guard let uid = currentUser?.uid else { return false }
        let orgId = normalizedOrganizationId(organizationId)
        guard let snap = try? await db.collection("users").document(uid).getDocument(source: .server),
              snap.exists,
              let userData = snap.data(),
              organizationIdsMatch(organizationIdFromFirestore(userData["organizationId"]), orgId) else {
            return materialAddedByMatchesAuthUser(material)
        }
        return materialAddedByMatchesUserDocument(material, userData: userData) || materialAddedByMatchesAuthUser(material)
    }
    
    /// Mirrors materials delete rules: admins/managers may delete any; others only their own booking.
    private func canCurrentUserDeleteMaterial(_ material: MaterialItem, organizationId: String) async -> Bool {
        guard let uid = currentUser?.uid else { return false }
        let orgId = normalizedOrganizationId(organizationId)
        guard let snap = try? await db.collection("users").document(uid).getDocument(source: .server),
              snap.exists,
              let userData = snap.data(),
              organizationIdsMatch(organizationIdFromFirestore(userData["organizationId"]), orgId) else {
            if let ownerId = material.addedByUserId, !ownerId.isEmpty {
                return ownerId == uid
            }
            return materialAddedByMatchesAuthUser(material)
        }
        let isSuperAdmin = truthyFirestoreBool(userData["isSuperAdmin"])
        let adminAccess = truthyFirestoreBool(userData["adminAccess"])
        let role = userData["role"] as? String ?? ""
        let adminLike = isSuperAdmin || adminAccess || role == "admin"
        let manager = truthyFirestoreBool(userData["manager"])
        if adminLike || manager {
            return true
        }
        if let ownerId = material.addedByUserId, !ownerId.isEmpty {
            return ownerId == uid
        }
        return materialAddedByMatchesUserDocument(material, userData: userData) || materialAddedByMatchesAuthUser(material)
    }
    
    /// Same path resolution as material writes so loads and listeners see newly saved rows.
    func resolveOrganizationIdForMaterials(preferredOrganizationId: String) async throws -> String {
        let preferredOrgId = normalizedOrganizationId(preferredOrganizationId)
        do {
            return try await ensureReadableOrganization(preferredOrgId)
        } catch {
            print("🔥🔥🔥 DEBUG: Preferred materials org \(preferredOrgId) was not readable: \(error.localizedDescription)")
            let fallback = await resolveOrganizationIdForFirebaseWrites(preferredFallback: preferredOrganizationId)
                ?? preferredOrgId
            guard !fallback.isEmpty else {
                throw NSError(
                    domain: "FirebaseBackend",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
                )
            }
            let orgId = try await ensureReadableOrganization(fallback)
            print("🔥🔥🔥 DEBUG: Falling back materials org to \(orgId)")
            return orgId
        }
    }
    
    func saveMaterialItem(_ material: MaterialItem, organizationId: String) async throws {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [saveMaterialItem] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)

        // RULEBOOK 1.8.0 §1: the line lives at its stored document id; the day is an organisation-zone day key.
        let docRef = db.collection("organizations").document(orgId)
            .collection("materials")
            .document(WorkDocumentKeys.storedId(for: material.id))

        let serverSnapshot = try await docRef.getDocument(source: .server)
        if serverSnapshot.exists,
           let serverData = serverSnapshot.data(),
           let serverMaterial = materialItemFromFirestoreDocument(serverSnapshot.documentID, serverData) {
            guard await canCurrentUserDeleteMaterial(serverMaterial, organizationId: orgId) else {
                throw NSError(
                    domain: "FirebaseBackend",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "You can only edit materials that you booked."]
                )
            }
        }

        var effectiveAddedByUserId = material.addedByUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if effectiveAddedByUserId?.isEmpty == true {
            effectiveAddedByUserId = nil
        }
        if effectiveAddedByUserId == nil {
            let authUid = currentUser?.uid ?? Auth.auth().currentUser?.uid
            if let authUid, !authUid.isEmpty {
                effectiveAddedByUserId = authUid
            }
        }
        if effectiveAddedByUserId == nil,
           let uid = currentUser?.uid,
           await currentUserOwnsLegacyMaterial(material, organizationId: orgId) {
            // Legacy material rows predate addedByUserId. Claim with a one-field update first so rules can
            // verify the existing addedBy value before the full edit save.
            do {
                try await docRef.updateData(["addedByUserId": uid])
            } catch {
                print("⚠️ [FirebaseBackend] Legacy material owner backfill skipped: \(error.localizedDescription)")
            }
            effectiveAddedByUserId = uid
        }
        
        guard let data = Self.materialLinePayload(material, addedByUserId: effectiveAddedByUserId) else {
            throw CanonicalWriteUnavailableError(function: "materialLineFields")
        }
        let uid = currentUser?.uid
        // RULEBOOK 1.8.0 §1 "Partial writes only": a new line is created whole; an edit writes only the fields
        // `materialLineWriteFields` names against the server copy (never a full `setData`, which deleted fields the
        // other app writes). `addedAt` / `addedBy` / `addedByUserId` are never rewritten.
        if serverSnapshot.exists, let stored = serverSnapshot.data() {
            guard let write = CanonicalBusinessEngine.peopleDocumentWrite("materialLineWriteFields", before: stored, next: data) else {
                throw CanonicalWriteUnavailableError(function: "materialLineWriteFields")
            }
            let changes = write.firestoreFields(from: data)
            if !changes.isEmpty {
                try await docRef.updateData(WriteMetadata.stamped(changes, userId: uid))
            }
        } else {
            let createPayload = data.filter { !($0.value is NSNull) }
            try await docRef.setData(WriteMetadata.stamped(createPayload, userId: uid))
        }

        if material.catalogueItemId == nil {
            // Reads the whole catalogue first. The material line is already saved, so this must not hold the sheet open.
            Task {
                do {
                    try await self.upsertMaterialCatalogueFromMaterial(material, organizationId: orgId)
                } catch {
                    print("⚠️ [FirebaseBackend] Catalogue upsert from material failed: \(error.localizedDescription)")
                }
            }
        }
        
        print("✅ [FirebaseBackend] Material saved successfully to Firebase")
    }

    private func upsertMaterialCatalogueFromMaterial(_ material: MaterialItem, organizationId: String) async throws {
        let trimmedName = material.material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let catalogItems = (try? await loadMaterialCatalogue(organizationId: organizationId)) ?? []
        let normalizedName = MaterialCatalogDuplicateDetection.normalizeName(trimmedName)
        let normalizedCode = MaterialCatalogDuplicateDetection.normalizeCode(material.productCode)
        let existing = catalogItems.first { item in
            MaterialCatalogDuplicateDetection.normalizeName(item.name) == normalizedName
                || (!normalizedCode.isEmpty && MaterialCatalogDuplicateDetection.normalizeCode(item.productCode) == normalizedCode)
        }
        guard existing == nil else { return }

        let inferredBrand = material.brand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let creatorName = currentUser?.displayName ?? currentUser?.email ?? material.addedBy
        let catalogItem = MaterialCatalogItem(
            name: trimmedName,
            brand: (inferredBrand?.isEmpty == false) ? inferredBrand! : "Custom",
            productCode: material.productCode,
            defaultUnit: material.unit,
            size: material.size,
            length: material.length,
            lengthUnit: material.lengthUnit,
            category: normalizedMaterialCategory(material.category),
            createdByUserId: currentUser?.uid ?? material.addedByUserId ?? "unknown",
            createdByName: creatorName
        )
        try await saveMaterialCatalogueItem(catalogItem, organizationId: organizationId)
    }

    func backfillMaterialCatalogueFromExistingMaterials(organizationId: String) async throws {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let existingCatalogue = (try? await loadMaterialCatalogue(organizationId: orgId)) ?? []
        // One-time historical bootstrap only.
        // Ongoing additions should come from save-time upsert, so we do not recreate deleted catalogue rows.
        guard existingCatalogue.isEmpty else { return }
        var knownKeys = Set(existingCatalogue.map { materialCatalogueNameKey(name: $0.name) })

        let materialsSnapshot = try await db.collection("organizations").document(orgId)
            .collection("materials")
            .getDocuments(source: .server)

        for doc in materialsSnapshot.documents {
            guard let material = materialItemFromFirestoreDocument(doc.documentID, doc.data()) else { continue }
            let normalizedName = material.material.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }
            let key = materialCatalogueNameKey(name: normalizedName)
            guard !knownKeys.contains(key) else { continue }
            let creatorName = currentUser?.displayName ?? currentUser?.email ?? material.addedBy
            let brand = material.brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let entry = MaterialCatalogItem(
                name: normalizedName,
                brand: brand.isEmpty ? "Custom" : brand,
                productCode: material.productCode,
                defaultUnit: material.unit,
                size: material.size,
                length: material.length,
                lengthUnit: material.lengthUnit,
                category: normalizedMaterialCategory(material.category),
                createdByUserId: currentUser?.uid ?? material.addedByUserId ?? "unknown",
                createdByName: creatorName
            )
            try? await saveMaterialCatalogueItem(entry, organizationId: orgId)
            knownKeys.insert(key)
        }
    }
    
    func loadMaterialItems(organizationId: String, projectId: UUID) async throws -> [MaterialItem] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        // RULEBOOK 1.8.0 §1 "Job keys": lines store the job's document id as stored; older iOS lines on a
        // lower-case job stored the upper-case UUID, so both spellings are matched.
        let materialsQuery = db.collection("organizations").document(orgId)
            .collection("materials")
            .whereField("projectId", in: JobKeys.queryValues(for: projectId))
        let snapshot: QuerySnapshot
        do {
            snapshot = try await materialsQuery.getDocuments(source: .server)
        } catch {
            print("⚠️ [FirebaseBackend] Server materials read failed, using cache/default: \(error.localizedDescription)")
            snapshot = try await materialsQuery.getDocuments()
        }
        
        print("🔍 [FirebaseBackend] Found \(snapshot.documents.count) material documents in Firebase")
        
        var materials: [MaterialItem] = []
        
        for doc in snapshot.documents {
            guard let materialItem = materialItemFromFirestoreDocument(doc.documentID, doc.data()) else {
                print("⚠️ [FirebaseBackend] Skipping material document - missing required fields")
                continue
            }
            materials.append(materialItem)
            print("   ✅ Loaded: \(materialItem.material) for date \(materialItem.date)")
        }
        
        print("✅ [FirebaseBackend] Returning \(materials.count) materials")
        return materials
    }

    func loadAllMaterialItemsForOrganization(organizationId: String) async throws -> [MaterialItem] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let materialsQuery = db.collection("organizations").document(orgId)
            .collection("materials")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await materialsQuery.getDocuments(source: .server)
        } catch {
            snapshot = try await materialsQuery.getDocuments()
        }

        var materials: [MaterialItem] = []
        for doc in snapshot.documents {
            guard let item = materialItemFromFirestoreDocument(doc.documentID, doc.data()) else { continue }
            materials.append(item)
        }
        return materials
    }

    func observeMaterialItems(
        organizationId: String,
        projectId: UUID,
        onChange: @escaping @MainActor ([MaterialItem], SnapshotMetadata) -> Void
    ) -> ListenerRegistration {
        let orgId = normalizedOrganizationId(organizationId)
        return db.collection("organizations").document(orgId)
            .collection("materials")
            .whereField("projectId", in: JobKeys.queryValues(for: projectId))
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("❌ [FirebaseBackend] observeMaterialItems error: \(error.localizedDescription)")
                    return
                }

                guard let snapshot else { return }
                let metadata = snapshot.metadata
                // Empty local-cache snapshots can arrive before the server/index reflects new writes; don't wipe a good list.
                if snapshot.documents.isEmpty, metadata.isFromCache {
                    return
                }

                let docs = snapshot.documents
                var loaded: [MaterialItem] = []

                for doc in docs {
                    guard let item = self.materialItemFromFirestoreDocument(doc.documentID, doc.data()) else { continue }
                    loaded.append(item)
                }

                Task { @MainActor in
                    onChange(loaded, metadata)
                }
            }
    }
    
    func deleteMaterialItem(_ materialId: UUID, organizationId: String) async throws {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let docRef = db.collection("organizations").document(orgId)
            .collection("materials")
            .document(WorkDocumentKeys.storedId(for: materialId))
        let snapshot = try await docRef.getDocument(source: .server)
        guard let data = snapshot.data(),
              let material = materialItemFromFirestoreDocument(snapshot.documentID, data) else {
            throw NSError(domain: "FirebaseBackend", code: 404, userInfo: [NSLocalizedDescriptionKey: "Material could not be found."])
        }
        guard await canCurrentUserDeleteMaterial(material, organizationId: orgId) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "You can only delete materials that you booked."]
            )
        }
        if (material.addedByUserId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let uid = currentUser?.uid,
           await currentUserOwnsLegacyMaterial(material, organizationId: orgId) {
            do {
                try await docRef.updateData(["addedByUserId": uid])
            } catch {
                print("⚠️ [FirebaseBackend] Legacy material owner backfill before delete failed: \(error.localizedDescription)")
                throw NSError(
                    domain: "FirebaseBackend",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "This older material needs its owner recorded before it can be deleted. Please deploy the updated Firestore rules, then try again."]
                )
            }
        }
        try await docRef.delete()
    }
    
    /// Deletes materials for **this project only** whose **needed** `date` is older than `keepDays` before today. Other jobs in the org are untouched.
    func cleanupOldMaterials(organizationId: String, projectId: UUID, keepDays: Int) async throws {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        // RULEBOOK 1.8.0 §1: the needed day is the line's organisation-zone `dayKey` (`parseMaterialLineDocument`).
        let calendar = OrganizationRulebookContext.calendar
        let today = Date()
        let cutoffDayKey = OrganizationRulebookContext.dayKey(
            calendar.date(byAdding: .day, value: -keepDays, to: today) ?? today
        )
        
        let snapshot = try await db.collection("organizations").document(orgId)
            .collection("materials")
            .whereField("projectId", in: JobKeys.queryValues(for: projectId))
            .getDocuments()
        
        let toDelete = snapshot.documents.filter { doc in
            guard let dayKey = CanonicalBusinessEngine.parseMaterialLineDocument(documentId: doc.documentID, data: doc.data())?
                .optionalText("dayKey") else { return false }
            return dayKey < cutoffDayKey
        }
        
        var batch = db.batch()
        var batchCount = 0
        let maxBatchSize = 500 // Firestore batch limit
        
        for doc in toDelete {
            batch.deleteDocument(doc.reference)
            batchCount += 1
            
            if batchCount >= maxBatchSize {
                try await batch.commit()
                batch = db.batch()
                batchCount = 0
            }
        }
        
        if batchCount > 0 {
            try await batch.commit()
        }
        
        print("🧹 [materials] Project \(projectId): removed \(toDelete.count) rows older than \(keepDays) days (needed date)")
    }

    // MARK: - Site Audits

    /// Resolves the org document id for Firestore paths, preferring `users/{uid}.organizationId` from the server
    /// so writes match Security Rules (exact reference id / casing from Firestore vs stale UI cache).
    func resolveOrganizationIdForFirebaseWrites(preferredFallback: String?) async -> String? {
        let trimmedFallback = preferredFallback.map { normalizedOrganizationId($0) } ?? ""
        guard let uid = currentUser?.uid else {
            return trimmedFallback.isEmpty ? nil : trimmedFallback
        }
        do {
            let snap = try await db.collection("users").document(uid).getDocument(source: .server)
            if let data = snap.data(),
               let fromUser = organizationIdFromFirestore(data["organizationId"]) {
                let t = normalizedOrganizationId(fromUser)
                if !t.isEmpty {
                    print("🔥🔥🔥 DEBUG: resolveOrganizationIdForFirebaseWrites using users document org id: \(t)")
                    return t
                }
            }
        } catch {
            print("🔥🔥🔥 DEBUG: resolveOrganizationIdForFirebaseWrites user read failed: \(error.localizedDescription)")
        }
        if !trimmedFallback.isEmpty {
            print("🔥🔥🔥 DEBUG: resolveOrganizationIdForFirebaseWrites using caller fallback: \(trimmedFallback)")
            return trimmedFallback
        }
        if let c = currentOrganization?.firestoreDocumentId {
            let t = normalizedOrganizationId(c)
            if !t.isEmpty { return t }
        }
        return nil
    }

    func saveSiteAudit(_ audit: SiteAudit, organizationId: String) async throws {
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save a site audit."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        guard !orgId.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings or sign in again, then retry."]
            )
        }
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [saveSiteAudit] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)

        // RULEBOOK 1.8.0 §1: `siteAuditWriteFields` against the server copy (`createdAt`, `createdByUserId` and
        // `organizationId` never rewritten); each item laid over its stored row (`mergeStoredRows`) so fields the
        // other app writes are kept. The audit lives at its stored id and names the job by its stored id.
        let ref = db.collection("organizations").document(orgId)
            .collection("siteAudits")
            .document(WorkDocumentKeys.storedId(for: audit.id))
        try await writeOperationsDocument(ref, writeFields: "siteAuditWriteFields") { stored in
            try Self.siteAuditPayload(audit, organizationId: orgId, storedItems: stored?["items"])
        }
    }

    static func siteAuditPayload(_ audit: SiteAudit, organizationId: String, storedItems: Any?) throws -> [String: Any] {
        let itemRows: [[String: Any]] = audit.items.map { item in
            [
                "id": WorkDocumentKeys.storedId(for: item.id),
                "title": item.title,
                "location": item.location,
                "assignee": item.assignee,
                "comments": item.comments,
                "annotations": item.annotations,
                "createdAt": Timestamp(date: item.createdAt),
                "imageURL": item.imageURL ?? NSNull(),
                "imageCapturedAt": item.imageCapturedAt.map { Timestamp(date: $0) as Any } ?? NSNull(),
            ]
        }
        guard let merged = CanonicalBusinessEngine.mergeStoredRows(stored: storedItems, next: itemRows) else {
            throw CanonicalWriteUnavailableError(function: "mergeStoredRows")
        }
        return [
            "id": WorkDocumentKeys.storedId(for: audit.id),
            "organizationId": organizationId,
            "projectId": JobKeys.storedJobId(for: audit.projectId),
            "projectJobNumber": audit.projectJobNumber,
            "projectName": audit.projectName,
            "type": audit.storedTypeText,
            "customTitle": audit.customTitle,
            "authorName": audit.authorName,
            "date": Timestamp(date: audit.date),
            "createdAt": Timestamp(date: audit.createdAt),
            "createdByUserId": audit.createdByUserId,
            "visibleToOperatives": audit.visibleToOperatives,
            "items": merged.map { (ScriptFirestoreValue.native($0) as? [String: Any]) ?? $0 },
        ]
    }

    func loadSiteAudits(organizationId: String, projectId: UUID? = nil, createdByUserId: String? = nil) async throws -> [SiteAudit] {
        var query: Query = db.collection("organizations").document(organizationId)
            .collection("siteAudits")

        if let projectId {
            query = query.whereField("projectId", in: JobKeys.queryValues(for: projectId))
        }
        if let createdByUserId {
            query = query.whereField("createdByUserId", isEqualTo: createdByUserId)
        }

        let snapshot = try await query.getDocuments()
        let audits = snapshot.documents.compactMap { Self.siteAudit(documentId: $0.documentID, data: $0.data()) }
        return audits.sorted { $0.createdAt > $1.createdAt }
    }

    /// RULEBOOK 1.8.0 §1: one audit through `parseSiteAuditDocument` (non-UUID ids, unknown types and items
    /// without an id are kept; an item without an id gets a derived id).
    static func siteAudit(documentId: String, data: [String: Any]) -> SiteAudit? {
        guard let row = CanonicalBusinessEngine.parseSiteAuditDocument(documentId: documentId, data: data) else { return nil }
        let items = row.rows("items").map { item in
            SiteAuditItem(
                id: JobKeys.inAppId(item.id),
                title: item.text("title"),
                location: item.text("location"),
                assignee: item.text("assignee"),
                comments: item.text("comments"),
                annotations: item.text("annotations"),
                imageURL: item.optionalText("imageURL"),
                imageCapturedAt: item.date("imageCapturedAtMs"),
                createdAt: item.date("createdAtMs") ?? Date(timeIntervalSince1970: 0)
            )
        }
        let storedType = row.text("type")
        let date = row.optionalText("dayKey").flatMap { OrganizationRulebookContext.date(fromDayKey: $0) }
            ?? row.date("dateMs") ?? Date(timeIntervalSince1970: 0)
        var audit = SiteAudit(
            id: JobKeys.inAppId(row.id),
            projectId: JobKeys.inAppId(row.text("projectId")),
            projectJobNumber: row.text("projectJobNumber"),
            projectName: row.text("projectName"),
            type: SiteAuditType(rawValue: storedType) ?? .general,
            customTitle: row.text("customTitle"),
            authorName: row.text("authorName"),
            date: row.date("dateMs") ?? date,
            items: items,
            createdAt: row.date("createdAtMs") ?? date,
            createdByUserId: row.text("createdByUserId"),
            visibleToOperatives: row.bool("visibleToOperatives", default: true)
        )
        audit.storedType = storedType
        return audit
    }
    
    // MARK: - Wholesalers
    
    /// RULEBOOK 1.8.0 §1 "Partial writes only": an operations document saved as a partial update. `makePayload`
    /// gets the server copy (nil when the document is missing) and returns the native fields the save would write
    /// (`NSNull` / `FieldValue.delete()` for "no value"). A missing document is created whole; otherwise only the
    /// fields `writeFields` names are written, with `WriteMetadata`. Never a whole-document overwrite.
    func writeOperationsDocument(
        _ ref: DocumentReference,
        writeFields: String,
        makePayload: ([String: Any]?) throws -> [String: Any]
    ) async throws {
        let uid = auth.currentUser?.uid
        let snapshot = try await ref.getDocument(source: .server)
        let stored = snapshot.exists ? snapshot.data() : nil
        let payload = try makePayload(stored)
        guard let stored else {
            let createPayload = payload.filter { !($0.value is FieldValue) && !($0.value is NSNull) }
            try await ref.setData(WriteMetadata.stamped(createPayload, userId: uid))
            return
        }
        guard let write = CanonicalBusinessEngine.peopleDocumentWrite(writeFields, before: stored, next: payload) else {
            throw CanonicalWriteUnavailableError(function: writeFields)
        }
        var changes = write.firestoreFields(from: payload)
        changes.removeValue(forKey: "updatedAt")
        guard !changes.isEmpty else { return }
        try await ref.updateData(WriteMetadata.stamped(changes, userId: uid))
    }

    /// RULEBOOK 1.8.0 §1: a wholesaler saved with `wholesalerWriteFields` (contacts with the primary contact written
    /// together; each contact laid over its stored row with `mergeStoredRows`, so fields web writes are kept).
    func saveWholesaler(_ wholesaler: Wholesaler, organizationId: String) async throws {
        let ref = db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(WorkDocumentKeys.storedId(for: wholesaler.id))
        try await writeOperationsDocument(ref, writeFields: "wholesalerWriteFields") { stored in
            try Self.wholesalerPayload(wholesaler, storedContacts: stored?["contacts"])
        }
    }

    static func wholesalerPayload(_ wholesaler: Wholesaler, storedContacts: Any?, keepStoredPhone: Bool = false) throws -> [String: Any] {
        func blank(_ value: String?) -> Any {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? NSNull() : trimmed
        }
        let contactRows: [[String: Any]] = wholesaler.contacts.map { contact -> [String: Any] in
            let phone = contact.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A cleared mobile is written '' (a null would keep the stored one through `mergeStoredRows`).
            let phoneValue: Any
            if !phone.isEmpty {
                phoneValue = phone
            } else if keepStoredPhone && contact.phone == nil {
                phoneValue = NSNull()
            } else {
                phoneValue = ""
            }
            return [
                "id": WorkDocumentKeys.storedId(for: contact.id),
                "name": contact.name,
                "email": contact.email,
                "createdAt": Timestamp(date: contact.createdAt),
                "isPrimary": contact.isPrimary,
                "phone": phoneValue,
            ]
        }
        guard let merged = CanonicalBusinessEngine.mergeStoredRows(stored: storedContacts, next: contactRows) else {
            throw CanonicalWriteUnavailableError(function: "mergeStoredRows")
        }
        let primary = wholesaler.primaryContact.map { WorkDocumentKeys.storedId(for: $0.id) as Any } ?? NSNull()
        return [
            "id": WorkDocumentKeys.storedId(for: wholesaler.id),
            "name": wholesaler.name,
            "contacts": merged.map { (ScriptFirestoreValue.native($0) as? [String: Any]) ?? $0 },
            "primaryContactId": primary,
            "address": blank(wholesaler.address),
            "trade": blank(wholesaler.trade),
            "accountNumber": blank(wholesaler.accountNumber),
            "createdAt": Timestamp(date: wholesaler.createdAt),
        ]
    }

    func deleteWholesaler(wholesalerId: UUID, organizationId: String) async throws {
        try await db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(WorkDocumentKeys.storedId(for: wholesalerId))
            .delete()
    }
    
    /// RULEBOOK 1.8.0 §1: wholesalers through `parseWholesalerDocument` (a firm with no `updatedAt`, a contact with a
    /// non-UUID id or without one is kept; exactly one primary contact).
    func loadWholesalers(organizationId: String) async throws -> [Wholesaler] {
        let snapshot = try await db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .getDocuments()
        return snapshot.documents.compactMap { Self.wholesaler(documentId: $0.documentID, data: $0.data()) }
    }

    static func wholesaler(documentId: String, data: [String: Any]) -> Wholesaler? {
        guard let row = CanonicalBusinessEngine.parseWholesalerDocument(documentId: documentId, data: data) else { return nil }
        let contacts = row.rows("contacts").map { contact in
            WholesalerContact(
                id: JobKeys.inAppId(contact.id),
                name: contact.text("name"),
                email: contact.text("email"),
                isPrimary: contact.bool("isPrimary"),
                createdAt: contact.date("createdAtMs") ?? Date(timeIntervalSince1970: 0),
                phone: contact.optionalText("phone")
            )
        }
        let createdAt = row.date("createdAtMs") ?? Date(timeIntervalSince1970: 0)
        return Wholesaler(
            id: JobKeys.inAppId(row.id),
            name: row.text("name"),
            address: row.optionalText("address"),
            trade: row.optionalText("trade"),
            accountNumber: row.optionalText("accountNumber"),
            primaryContactId: row.optionalText("primaryContactId").map { JobKeys.inAppId($0) },
            contacts: contacts,
            createdAt: createdAt,
            updatedAt: row.date("updatedAtMs") ?? createdAt
        )
    }
    
    /// Adds or updates one contact: the firm is read through `parseWholesalerDocument` and saved with
    /// `wholesalerWriteFields` (a mobile saved on web is kept when this edit carried none).
    func addContactToWholesaler(_ contact: WholesalerContact, wholesalerId: UUID, organizationId: String) async throws {
        let wholesalerRef = db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(WorkDocumentKeys.storedId(for: wholesalerId))
        try await writeOperationsDocument(wholesalerRef, writeFields: "wholesalerWriteFields") { stored in
            guard let stored, var firm = Self.wholesaler(documentId: wholesalerRef.documentID, data: stored) else {
                throw NSError(domain: "WholesalerNotFound", code: 404, userInfo: [NSLocalizedDescriptionKey: "Wholesaler not found"])
            }
            if let index = firm.contacts.firstIndex(where: { $0.id == contact.id }) {
                firm.contacts[index] = contact
            } else {
                firm.contacts.append(contact)
            }
            return try Self.wholesalerPayload(firm, storedContacts: stored["contacts"], keepStoredPhone: true)
        }
    }
    
    // MARK: - Subcontractors
    
    func saveSubcontractor(_ subcontractor: Subcontractor, organizationId: String) async throws {
        let contactsData = subcontractor.contacts.map { contact in
            [
                "id": WorkDocumentKeys.storedId(for: contact.id),
                "name": contact.name,
                "email": contact.email,
                "contactNumber": contact.contactNumber,
                "position": contact.position.rawValue,
                "tradeType": contact.displayTrade,
                "createdAt": Timestamp(date: contact.createdAt)
            ] as [String : Any]
        }
        
        // RULEBOOK 1.6.0 §1, §11: a partial update of the fields `subcontractorWriteFields` names (the contacts
        // list is one field, written whole when it changes); a new firm is created whole. `id`, `createdAt` and
        // `organizationId` are written on create only.
        let data: [String: Any] = [
            "id": subcontractor.documentId,
            "name": subcontractor.name,
            "subcontractorType": subcontractor.subcontractorType,
            "website": subcontractor.website.map { $0 as Any } ?? FieldValue.delete(),
            "address": subcontractor.address.map { $0 as Any } ?? FieldValue.delete(),
            "contacts": contactsData,
            "createdAt": Timestamp(date: subcontractor.createdAt)
        ]
        
        let ref = db.collection("organizations").document(organizationId)
            .collection("subcontractors")
            .document(subcontractor.documentId)
        try await writeChangedRosterRow(ref, payload: data, previousPayload: nil, writeFields: "subcontractorWriteFields")

        let extraTrades = subcontractor.contacts.map(\.displayTrade) + [subcontractor.subcontractorType]
        try? await mergeOrganizationTradeTypes(extraTrades, organizationId: organizationId)
    }

    /// RULEBOOK 1.8.0 §1: `settings/tradeTypeInventory` through `parseTradeTypeInventory`.
    func loadOrganizationTradeTypes(organizationId: String) async -> [String] {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else { return [] }
        do {
            let snap = try await db.collection("organizations").document(orgId)
                .collection("settings")
                .document("tradeTypeInventory")
                .getDocument()
            return CanonicalBusinessEngine.parseTradeTypeInventory(snap.data()) ?? []
        } catch {
            return []
        }
    }

    /// RULEBOOK 1.8.0 §1: `tradeTypeInventoryWriteFields` (the stored list plus new trades, never removing one; no
    /// write when nothing is new), written as a merge of `trades`.
    func mergeOrganizationTradeTypes(_ trades: [String], organizationId: String) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        guard !trades.isEmpty else { return }
        let ref = db.collection("organizations").document(orgId)
            .collection("settings")
            .document("tradeTypeInventory")
        let stored = try await ref.getDocument().data()
        guard let answer = CanonicalBusinessEngine.tradeTypeInventoryWriteFields(stored: stored, incoming: trades) else {
            throw CanonicalWriteUnavailableError(function: "tradeTypeInventoryWriteFields")
        }
        guard let merged = answer else { return }
        try await ref.setData(WriteMetadata.stamped(["trades": merged], userId: currentUser?.uid), merge: true)
    }

    /// `organizations/{orgId}/subcontractors`, read through `parseSubcontractorDocument` (`subcontractors(fromDocuments:)`).
    func loadSubcontractors(organizationId: String) async throws -> [Subcontractor] {
        let snapshot = try await db.collection("organizations").document(organizationId)
            .collection("subcontractors").getDocuments()
        return Self.subcontractors(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) })
            .sorted { $0.name < $1.name }
    }

    static func subcontractors(fromDocuments documents: [(id: String, data: [String: Any])]) -> [Subcontractor] {
        documents.compactMap { doc -> Subcontractor? in
            guard let row = CanonicalBusinessEngine.parseSubcontractorDocument(documentId: doc.id, data: doc.data) else { return nil }
            let createdAt = row.date("createdAtMs") ?? Date(timeIntervalSince1970: 0)
            let contacts: [SubcontractorContact] = row.rows("contacts").map { contact in
                // RULEBOOK 1.8.0 §1: a contact stored without an id carries the reader's `subcontractorContactId`
                // (the same on web), so `bookedContactIds` match it on both platforms.
                let contactId = contact.id
                let positionRaw = contact.text("position")
                return SubcontractorContact(
                    // RULEBOOK 1.7.0: remembered so a subcontractor booking writes the stored contact id back.
                    id: WorkDocumentKeys.inAppId(for: contactId),
                    name: contact.text("name"),
                    email: contact.text("email"),
                    contactNumber: contact.text("contactNumber"),
                    position: SubcontractorContactPosition(rawValue: positionRaw) ?? .installer,
                    tradeType: contact.optionalText("tradeType") ?? positionRaw,
                    createdAt: contact.date("createdAtMs") ?? createdAt
                )
            }
            return Subcontractor(
                id: WorkDocumentKeys.inAppId(for: row.id),
                name: row.text("name"),
                subcontractorType: row.text("subcontractorType"),
                website: row.optionalText("website"),
                address: row.optionalText("address"),
                contacts: contacts,
                createdAt: createdAt,
                updatedAt: row.date("updatedAtMs") ?? createdAt,
                firestoreDocumentId: row.id
            )
        }
    }
    
    /// RULEBOOK 1.7.0 §1: a new subcontractor booking is created with `subcontractorBookingCreateFields` at
    /// `subcontractorBookings/{id}` (the same `id` in the document, `status`, `isBreakRemoved` and the contact lists
    /// always written). An edit writes only what `subcontractorBookingWriteFields` names against the stored copy;
    /// `bookedBy` is never rewritten and a booking deleted elsewhere is never re-created. Ids are the stored ids.
    /// `operativeNames` are the firm contacts' names on site (nil leaves the stored names alone).
    func saveSubcontractorBooking(_ booking: SubcontractorBooking, organizationId: String, operativeNames: [String]? = nil) async throws {
        let ref = db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .document(booking.documentId)
        let uid = currentUser?.uid
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard booking.firestoreDocumentId != nil else {
            guard var fields = CanonicalBusinessEngine.subcontractorBookingCreateFields(
                id: booking.documentId,
                subcontractorId: booking.storedSubcontractorId,
                projectId: booking.storedProjectId,
                date: booking.date,
                timeSlot: booking.timeSlot.rawValue,
                workStartTime: nonEmpty(booking.workStartTime),
                workEndTime: nonEmpty(booking.workEndTime),
                isBreakRemoved: booking.isBreakRemoved,
                bookedBy: booking.bookedBy,
                status: booking.status.rawValue,
                bookedContactIds: booking.storedContactIds,
                bookedOperativeNames: operativeNames ?? booking.storedOperativeNames,
                createdAt: booking.createdAt
            ) else {
                throw CanonicalWriteUnavailableError(function: "subcontractorBookingCreateFields")
            }
            // The rulebook gives instants as milliseconds; this app writes its Timestamp type.
            fields["date"] = Timestamp(date: booking.date)
            fields["createdAt"] = Timestamp(date: booking.createdAt)
            fields["updatedAt"] = Timestamp(date: booking.createdAt)
            try await ref.setData(WriteMetadata.stamped(fields, userId: uid))
            return
        }
        let snapshot = try await ref.getDocument(source: .server)
        guard snapshot.exists, let stored = snapshot.data() else {
            throw NSError(
                domain: "FIRFirestoreErrorDomain",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: CanonicalBusinessEngine.bookingReplayRefusedMessage]
            )
        }
        var next: [String: Any] = [
            "subcontractorId": booking.storedSubcontractorId,
            "projectId": booking.storedProjectId,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "workStartTime": nonEmpty(booking.workStartTime).map { $0 as Any } ?? FieldValue.delete(),
            "workEndTime": nonEmpty(booking.workEndTime).map { $0 as Any } ?? FieldValue.delete(),
            "isBreakRemoved": booking.isBreakRemoved,
            "status": booking.status.rawValue,
            "bookedContactIds": booking.storedContactIds
        ]
        if let operativeNames { next["bookedOperativeNames"] = operativeNames }
        guard let write = CanonicalBusinessEngine.subcontractorBookingWrite(before: stored, next: next) else {
            throw CanonicalWriteUnavailableError(function: "subcontractorBookingWriteFields")
        }
        let changes = write.firestoreFields(from: next)
        guard !changes.isEmpty else { return }
        try await ref.updateData(WriteMetadata.stamped(changes, userId: uid))
    }

    func deleteSubcontractorBooking(_ booking: SubcontractorBooking, organizationId: String) async throws {
        try await db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .document(booking.documentId)
            .delete()
    }
    
    func loadSubcontractorBookings(organizationId: String) async throws -> [SubcontractorBooking] {
        let snapshot = try await db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .getDocuments()
        return Self.subcontractorBookings(fromDocuments: snapshot.documents.map { (id: $0.documentID, data: $0.data()) })
    }

    /// RULEBOOK 1.7.0 §1 "Document readers": `subcontractorBookings/{id}` are read only through
    /// `parseSubcontractorBookingDocument` (web uses the same reader), so a booking web created (lower-case id, no
    /// `id`, `status` or slot field) shows here. The document id and the firm, job and contact ids are kept as
    /// stored; a non-UUID id gets a stable in-app UUID. Tests call this with raw documents.
    static func subcontractorBookings(fromDocuments documents: [(id: String, data: [String: Any])]) -> [SubcontractorBooking] {
        documents.compactMap { doc -> SubcontractorBooking? in
            guard let row = CanonicalBusinessEngine.parseSubcontractorBookingDocument(documentId: doc.id, data: doc.data),
                  let date = row.date("dateMs"),
                  let timeSlot = TimeSlot.fromStored(row.text("timeSlot")),
                  let status = BookingStatus(rawValue: row.text("status")) else { return nil }
            let contactKeys = row.strings("bookedContactIds")
            let createdAt = row.date("createdAtMs") ?? date
            var booking = SubcontractorBooking(
                id: WorkDocumentKeys.inAppId(for: row.id),
                subcontractorId: WorkDocumentKeys.inAppId(for: row.text("subcontractorId")),
                projectId: WorkDocumentKeys.inAppId(for: row.text("projectId")),
                date: date,
                timeSlot: timeSlot,
                workStartTime: row.optionalText("workStartTime"),
                workEndTime: row.optionalText("workEndTime"),
                isBreakRemoved: row.bool("isBreakRemoved"),
                bookedBy: row.text("bookedBy"),
                status: status,
                bookedContactIds: contactKeys.map { WorkDocumentKeys.inAppId(for: $0) },
                createdAt: createdAt,
                updatedAt: row.date("updatedAtMs") ?? createdAt
            )
            booking.firestoreDocumentId = row.id
            booking.subcontractorKey = row.text("subcontractorId")
            booking.projectKey = row.text("projectId")
            booking.bookedContactKeys = contactKeys
            booking.storedOperativeNames = row.strings("bookedOperativeNames")
            return booking
        }
        .sorted { $0.date < $1.date }
    }
    
    // MARK: - Material catalogue

    func loadMaterialCatalogue(organizationId: String) async throws -> [MaterialCatalogItem] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection("organizations").document(orgId)
                .collection("materialCatalogue")
                .getDocuments(source: .server)
        } catch {
            snapshot = try await db.collection("organizations").document(orgId)
                .collection("materialCatalogue")
                .getDocuments()
        }
        // RULEBOOK 1.8.0 §1: `parseMaterialCatalogueDocument` (document id in stored case, `sizeOrLength` / `packSize`
        // read as the length, missing brand "Custom"). No write on read.
        let loaded = snapshot.documents.compactMap { Self.materialCatalogItem(documentId: $0.documentID, data: $0.data()) }
        return loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// RULEBOOK 1.8.0 §1: one catalogue item saved as a partial update (`materialCatalogueItemWriteFields`; creator
    /// fields and `createdAt` never rewritten), or created whole when it is new.
    func saveMaterialCatalogueItem(_ item: MaterialCatalogItem, organizationId: String) async throws {
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        guard let payload = Self.materialCatalogueItemPayload(item) else {
            throw CanonicalWriteUnavailableError(function: "materialCatalogueItemFields")
        }
        let ref = db.collection("organizations").document(orgId)
            .collection("materialCatalogue")
            .document(WorkDocumentKeys.storedId(for: item.id))
        try await writeChangedRosterRow(ref, payload: payload, previousPayload: nil, writeFields: "materialCatalogueItemWriteFields")
    }

    func deleteMaterialCatalogueItem(_ itemId: UUID, organizationId: String) async throws {
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        try await db.collection("organizations").document(orgId)
            .collection("materialCatalogue")
            .document(WorkDocumentKeys.storedId(for: itemId))
            .delete()
    }

    /// RULEBOOK 1.8.0 §1: saving the catalogue as a list (CSV import) with `materialCatalogueWrites` — never
    /// delete-all and rewrite. Each changed item is a partial write; an unchanged item is not written; a stored item
    /// missing from `next` is deleted only when `loaded` (the list on screen came from a successful catalogue load),
    /// the server copy was read now, and `next` is not empty. `onProgress` reports committed writes plus deletes.
    @discardableResult
    func writeMaterialCatalogue(
        _ next: [MaterialCatalogItem],
        loaded: Bool,
        organizationId: String,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> (written: Int, removed: Int) {
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        let collection = db.collection("organizations").document(orgId).collection("materialCatalogue")
        let storedSnapshot = try await collection.getDocuments(source: .server)
        let stored = storedSnapshot.documents.map { (id: $0.documentID, data: $0.data()) }
        let nextRows = next.compactMap { Self.materialCatalogueItemInput($0) }
        guard let plan = CanonicalBusinessEngine.materialCatalogueWrites(stored: stored, next: nextRows, loaded: loaded) else {
            throw CanonicalWriteUnavailableError(function: "materialCatalogueWrites")
        }
        let uid = currentUser?.uid
        var completed = 0
        var index = 0
        while index < plan.write.count {
            let batch = db.batch()
            let end = min(index + Self.materialCatalogueBatchSize, plan.write.count)
            for row in plan.write[index..<end] {
                let set = (ScriptFirestoreValue.native(row.set) as? [String: Any]) ?? [:]
                let ref = collection.document(row.id)
                if row.create {
                    batch.setData(WriteMetadata.stamped(set.filter { !($0.value is NSNull) }, userId: uid), forDocument: ref)
                } else {
                    var changes = set
                    for key in row.remove { changes[key] = FieldValue.delete() }
                    batch.updateData(WriteMetadata.stamped(changes, userId: uid), forDocument: ref)
                }
            }
            try await batch.commit()
            completed = end
            index = end
            let progressValue = completed
            await MainActor.run { onProgress?(progressValue) }
        }
        index = 0
        while index < plan.remove.count {
            let batch = db.batch()
            let end = min(index + Self.materialCatalogueBatchSize, plan.remove.count)
            for id in plan.remove[index..<end] {
                batch.deleteDocument(collection.document(id))
            }
            try await batch.commit()
            index = end
            let progressValue = plan.write.count + end
            await MainActor.run { onProgress?(progressValue) }
        }
        return (plan.write.count, plan.remove.count)
    }

    private static let materialCatalogueBatchSize = 100

    private func resolvedOrganizationIdForMaterialCatalogueWrite(_ organizationId: String) async throws -> String {
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to update the material catalogue."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [materialCatalogue write] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)
        return orgId
    }

    func updateMaterialWorkflowStatuses(
        materialIds: [UUID],
        status: MaterialWorkflowStatus,
        requestType: MaterialOrderRequest.RequestType,
        organizationId: String
    ) async throws {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let now = Date()
        for id in materialIds {
            let docRef = db.collection("organizations").document(orgId)
                .collection("materials")
                .document(WorkDocumentKeys.storedId(for: id))
            let snap = try await docRef.getDocument(source: .server)
            guard snap.exists,
                  let data = snap.data(),
                  let row = CanonicalBusinessEngine.parseMaterialLineDocument(documentId: snap.documentID, data: data) else { continue }
            // RULEBOOK 1.8.0 §1: `materialSendStatusWriteFields` (Order → ordered; Quote → sentForQuote, an ordered
            // line is never downgraded). The security rules allow staff exactly these keys plus `updatedAt`.
            guard let next = CanonicalBusinessEngine.materialSendStatusWriteFields(
                currentStatus: row.text("status"),
                requestType: requestType.rawValue
            ) else {
                throw CanonicalWriteUnavailableError(function: "materialSendStatusWriteFields")
            }
            try await docRef.updateData([
                "status": next.status,
                "lastSentAt": Timestamp(date: now),
                "lastSentRequestType": next.lastSentRequestType,
                "updatedAt": Timestamp(date: now)
            ])
        }
    }

    /// The `MaterialCatalogueItemInput` for an item: stored ids, native `createdAt`.
    static func materialCatalogueItemInput(_ item: MaterialCatalogItem) -> [String: Any]? {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return [
            "id": WorkDocumentKeys.storedId(for: item.id),
            "name": name,
            "brand": item.brand,
            "productCode": item.productCode ?? NSNull(),
            "defaultUnit": item.defaultUnit.rawValue,
            "size": item.size ?? NSNull(),
            "length": item.length ?? NSNull(),
            "lengthUnit": item.lengthUnit?.rawValue ?? NSNull(),
            "category": item.category ?? NSNull(),
            "createdAt": Timestamp(date: item.createdAt),
            "createdByUserId": item.createdByUserId,
            "createdByName": item.createdByName,
        ]
    }

    /// `materialCatalogueItemFields` with native values (Timestamps), ready for `writeChangedRosterRow`.
    static func materialCatalogueItemPayload(_ item: MaterialCatalogItem) -> [String: Any]? {
        guard let input = materialCatalogueItemInput(item),
              let fields = CanonicalBusinessEngine.materialCatalogueItemFields(input) else { return nil }
        var payload = (ScriptFirestoreValue.native(fields) as? [String: Any]) ?? [:]
        payload["createdAt"] = Timestamp(date: item.createdAt)
        return payload
    }

    /// RULEBOOK 1.8.0 §1: one `materialCatalogue/{id}` item through `parseMaterialCatalogueDocument`.
    static func materialCatalogItem(documentId: String, data: [String: Any]) -> MaterialCatalogItem? {
        guard let row = CanonicalBusinessEngine.parseMaterialCatalogueDocument(documentId: documentId, data: data) else { return nil }
        return MaterialCatalogItem(
            id: JobKeys.inAppId(row.id),
            name: row.text("name"),
            brand: row.text("brand"),
            productCode: row.optionalText("productCode"),
            defaultUnit: MaterialUnit(rawValue: row.text("defaultUnit")) ?? .number,
            size: row.optionalText("size"),
            length: row.optionalText("length"),
            lengthUnit: MaterialLengthUnit(rawValue: row.text("lengthUnit")),
            category: row.optionalText("category"),
            createdAt: row.date("createdAtMs") ?? Date(timeIntervalSince1970: 0),
            createdByUserId: row.text("createdByUserId"),
            createdByName: row.text("createdByName")
        )
    }

    private func normalizedMaterialCategory(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Other" : trimmed
    }

    private func materialCatalogueNameKey(name: String) -> String {
        MaterialCatalogDuplicateDetection.normalizeName(name)
    }

    // MARK: - Email Service
    
    func sendMaterialRequest(_ request: MaterialOrderRequest, organizationId: String) async throws {
        let isQuote = request.requestType == .quote
        let senderEmail = request.senderEmail.isEmpty
            ? (currentUser?.email ?? "info@projectplanner.us")
            : request.senderEmail
        let senderName = request.senderName.isEmpty
            ? (request.sentBy.split(separator: "\n").first.map(String.init) ?? "Project Planner")
            : request.senderName
        let company = request.senderCompany.isEmpty
            ? (currentOrganization?.name ?? "")
            : request.senderCompany
        let logoURL = request.companyLogoURL ?? currentOrganization?.companyLogoURL
        var wholesalerSent = 0

        for contact in request.recipientContacts {
            let contactName = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let supplierFirst = contactName.split(separator: " ").first.map(String.init) ?? contactName
            // Plain-text emails use the full wholesaler contact name; HTML keeps the short greeting.
            let supplierGreeting = request.sendAsPlainText
                ? (contactName.isEmpty ? supplierFirst : contactName)
                : supplierFirst
            let emailContext = MaterialRequestEmailBuilder.Context(
                supplierName: supplierGreeting,
                userName: senderName,
                userEmail: senderEmail,
                userPhone: request.senderPhone,
                userCompany: company,
                jobNumber: request.projectNumber,
                siteName: request.projectName,
                deliveryAddress: request.siteAddress,
                requestedDate: CanonicalBusinessEngine.orderDeliveryRequiredLabel(
                    requestType: request.requestType.rawValue,
                    at: request.requiredDeliveryDate
                ),
                quoteNeededBy: nil,
                companyLogoURL: logoURL,
                materials: request.materials,
                sentAt: request.sentAt
            )
            let emailBody: String
            if request.sendAsPlainText {
                let plain = MaterialRequestEmailBuilder.buildPlainTextEmail(context: emailContext, isQuote: isQuote)
                emailBody = MaterialRequestEmailBuilder.plainTextAsSimpleHTML(plain)
            } else {
                emailBody = isQuote
                    ? MaterialRequestEmailBuilder.buildQuoteEmail(context: emailContext)
                    : MaterialRequestEmailBuilder.buildOrderEmail(context: emailContext)
            }
            let subject = isQuote
                ? MaterialRequestEmailBuilder.quoteSubject(jobNumber: request.projectNumber, company: company)
                : MaterialRequestEmailBuilder.orderSubject(jobNumber: request.projectNumber, company: company)
            let replyTo = ExportTextEscaping.sanitizeReplyToAddress(senderEmail)
            let fromName = ExportTextEscaping.sanitizeFromDisplayName("\(senderName) (via Project Planner)")

            let emailService = ResendEmailService()
            let success = await emailService.sendEmail(
                to: contact.email,
                subject: subject,
                htmlContent: emailBody,
                replyTo: replyTo,
                fromName: fromName
            )

            if success {
                print("✅ Email sent successfully to \(contact.email)")
                wholesalerSent += 1
                let copyAddress = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !copyAddress.isEmpty {
                    let copied = await emailService.sendEmail(
                        to: copyAddress,
                        subject: ExportTextEscaping.sanitizeEmailSubject("Copy: \(subject)"),
                        htmlContent: emailBody,
                        replyTo: replyTo,
                        fromName: fromName
                    )
                    if !copied {
                        print("🔥🔥🔥 DEBUG: [materials/send] user copy failed for \(copyAddress)")
                    }
                }
            } else {
                print("❌ Failed to send email to \(contact.email)")
            }
        }

        guard wholesalerSent > 0 else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to send material list"]
            )
        }

        let requestedStatus: MaterialWorkflowStatus = request.requestType == .quote ? .sentForQuote : .ordered
        do {
            try await updateMaterialWorkflowStatuses(
                materialIds: request.materials.map(\.id),
                status: requestedStatus,
                requestType: request.requestType,
                organizationId: organizationId
            )
        } catch {
            print("🔥🔥🔥 DEBUG: [materials/send] email sent; material status write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Material send history

    func saveMaterialSendRecord(_ record: MaterialSendRecord, organizationId: String) async throws {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        // RULEBOOK 1.8.0 §1: `materialSendRecordCreateFields` (records are written once; `requestType` Quote / Order;
        // `deliveryRequiredAt` only on an order). Ids are the stored ids of the record, the job and each line.
        guard var data = Self.materialSendRecordPayload(record) else {
            throw CanonicalWriteUnavailableError(function: "materialSendRecordCreateFields")
        }
        data = WriteMetadata.stamped(data, userId: currentUser?.uid)
        try await db.collection("organizations").document(orgId)
            .collection("materialSendRecords")
            .document(WorkDocumentKeys.storedId(for: record.id))
            .setData(data)
    }

    /// The stored shape of a new send record from `materialSendRecordCreateFields`, instants as Timestamps.
    static func materialSendRecordPayload(_ record: MaterialSendRecord) -> [String: Any]? {
        var input: [String: Any] = [
            "id": WorkDocumentKeys.storedId(for: record.id),
            "projectId": JobKeys.storedJobId(for: record.projectId),
            "requestType": record.requestType.rawValue,
            "sentAt": record.sentAt.timeIntervalSince1970 * 1000,
            "sentBy": record.sentBy,
            "recipients": record.recipients.map { recipient -> [String: Any] in
                ["name": recipient.name, "email": recipient.email, "wholesalerName": recipient.wholesalerName ?? NSNull()]
            },
            "lines": record.lines.map { line -> [String: Any] in
                [
                    "materialId": WorkDocumentKeys.storedId(for: line.materialId),
                    "name": line.name,
                    "quantity": line.quantity,
                    "unit": line.unit.rawValue,
                    "brand": line.brand ?? NSNull(),
                    "productCode": line.productCode ?? NSNull(),
                    "lengthDisplay": line.lengthDisplay ?? NSNull(),
                ]
            },
        ]
        if let materialsDate = record.materialsDate { input["materialsDate"] = materialsDate.timeIntervalSince1970 * 1000 }
        if let deliveryRequiredAt = record.deliveryRequiredAt {
            input["deliveryRequiredAt"] = deliveryRequiredAt.timeIntervalSince1970 * 1000
        }
        guard var fields = CanonicalBusinessEngine.materialSendRecordCreateFields(input) else { return nil }
        for key in ["sentAt", "materialsDate", "deliveryRequiredAt"] {
            if fields[key] != nil { fields[key] = ScriptFirestoreValue.timestamp(ms: fields[key]) ?? NSNull() }
        }
        return fields.filter { !($0.value is NSNull) }
    }

    func loadAllMaterialSendRecords(organizationId: String) async throws -> [MaterialSendRecord] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let snapshot = try await db.collection("organizations").document(orgId)
            .collection("materialSendRecords")
            .getDocuments(source: .server)
        return snapshot.documents.compactMap { Self.materialSendRecord(documentId: $0.documentID, data: $0.data()) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    func loadMaterialSendRecords(organizationId: String, projectId: UUID) async throws -> [MaterialSendRecord] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let snapshot = try await db.collection("organizations").document(orgId)
            .collection("materialSendRecords")
            .whereField("projectId", in: JobKeys.queryValues(for: projectId))
            .getDocuments(source: .server)
        return snapshot.documents.compactMap { Self.materialSendRecord(documentId: $0.documentID, data: $0.data()) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    /// RULEBOOK 1.8.0 §1: one send record through `parseMaterialSendRecordDocument` (non-UUID ids, lower-case request
    /// types and unknown units kept; `deliveryRequiredAt` only on an order).
    static func materialSendRecord(documentId: String, data: [String: Any]) -> MaterialSendRecord? {
        guard let row = CanonicalBusinessEngine.parseMaterialSendRecordDocument(documentId: documentId, data: data),
              let sentAt = row.date("sentAtMs") else { return nil }
        let recipients = row.rows("recipients").map { recipient in
            MaterialSendRecipientSnapshot(
                name: recipient.text("name"),
                email: recipient.text("email"),
                wholesalerName: recipient.optionalText("wholesalerName")
            )
        }
        let lines = row.rows("lines").map { line in
            MaterialSendLineSnapshot(
                materialId: JobKeys.inAppId(line.text("materialId")),
                name: line.text("name"),
                quantity: max(0, Int((line.number("quantity") ?? 1).rounded())),
                unit: MaterialUnit(rawValue: line.text("unit")) ?? .number,
                brand: line.optionalText("brand"),
                productCode: line.optionalText("productCode"),
                lengthDisplay: line.optionalText("lengthDisplay")
            )
        }
        let materialsDate = row.optionalText("materialsDayKey").flatMap { OrganizationRulebookContext.date(fromDayKey: $0) }
            ?? row.date("materialsDateMs")
        return MaterialSendRecord(
            id: JobKeys.inAppId(row.id),
            projectId: JobKeys.inAppId(row.text("projectId")),
            requestType: row.text("requestType") == "order" ? .order : .quote,
            sentAt: sentAt,
            materialsDate: materialsDate,
            deliveryRequiredAt: row.date("deliveryRequiredAtMs"),
            sentBy: row.text("sentBy"),
            recipients: recipients,
            lines: lines
        )
    }
    
    // MARK: - Health & Safety (Project / Small Works)

    // MARK: - Timesheets (Operative + Manager sign-off state)

    private func timesheetStateDocumentRef(
        organizationId: String,
        userId: String,
        weekStart: Date
    ) throws -> DocumentReference {
        guard let startDayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
              let docId = CanonicalBusinessEngine.timesheetDocumentId(userId: userId, startDayKey: startDayKey) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not identify this timesheet period."]
            )
        }
        return db.collection("organizations")
            .document(organizationId)
            .collection("settings")
            .document(docId)
    }

    /// Live `settings/timesheet_{uid}_{unix}` (`timesheetDocumentId`) while a timesheet screen is open, so a sign-off,
    /// review or export made on web shows without reopening it. `onServerChange` runs for confirmed server copies
    /// only (this device's own unsent write and cache copies are skipped). `key` names the screen's listener;
    /// the screen stops it with `stopLiveListener(key:)` when it closes.
    func listenTimesheetState(
        key: String,
        organizationId: String,
        userId: String,
        weekStart: Date,
        onServerChange: @escaping @MainActor () -> Void
    ) {
        guard let ref = try? timesheetStateDocumentRef(organizationId: normalizedOrganizationId(organizationId), userId: userId, weekStart: weekStart) else { return }
        let documentId = ref.documentID
        listenOrganizationDocument(
            key: key,
            organizationId: organizationId,
            document: { $0.collection("settings").document(documentId) }
        ) { data, fromCache, pending in
            guard data != nil, !fromCache, !pending else { return }
            onServerChange()
        }
    }

    func loadTimesheetState(
        organizationId: String,
        userId: String,
        weekStart: Date
    ) async throws -> [String: Any]? {
        let snapshot = try await timesheetStateDocumentRef(
            organizationId: organizationId,
            userId: userId,
            weekStart: weekStart
        ).getDocument()
        guard var data = snapshot.data() else { return nil }
        // The sheet id `parseTimesheetEntries` derives entry ids from (as `listTimesheetStates` rows carry it).
        data["__documentId"] = snapshot.documentID
        return data
    }

    /// Writes the changed timesheet fields only (rulebook §6, §1 "Writes carry metadata").
    /// `payload` is what changed (dotted `extraEntryReviews.{id}` keys allowed). An existing document
    /// gets `updateData`; a new one gets `setData(merge:)` with dotted keys nested, never dotted.
    /// `storedDocument` is the server copy the caller just read (period fields are written only when
    /// they differ from it); `documentExists` nil reads the document first.
    func saveTimesheetState(
        organizationId: String,
        userId: String,
        weekStart: Date,
        weekEnd: Date,
        payload: [String: Any],
        storedDocument: [String: Any]? = nil,
        documentExists: Bool? = nil
    ) async throws {
        guard let startDayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
              let endDayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekEnd),
              let startInstant = CanonicalBusinessEngine.date(fromDayKey: startDayKey),
              let endInstant = CanonicalBusinessEngine.date(fromDayKey: endDayKey),
              let periodFields = CanonicalBusinessEngine.timesheetPeriodWriteFields(
                userId: userId,
                startDayKey: startDayKey,
                endDayKey: endDayKey
              ) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not identify this timesheet period."]
            )
        }
        let ref = try timesheetStateDocumentRef(
            organizationId: organizationId,
            userId: userId,
            weekStart: weekStart
        )
        let exists: Bool
        if let documentExists {
            exists = documentExists
        } else {
            exists = try await ref.getDocument().exists
        }
        let stored = exists ? storedDocument : nil
        var data = payload
        func putIfChanged(_ key: String, _ value: String) {
            if (stored?[key] as? String) != value { data[key] = value }
        }
        func putInstantIfChanged(_ key: String, _ value: Date) {
            let storedDate = (stored?[key] as? Timestamp)?.dateValue()
            if storedDate.map({ abs($0.timeIntervalSince(value)) >= 0.001 }) ?? true {
                data[key] = Timestamp(date: value)
            }
        }
        putIfChanged("userId", periodFields.userId)
        putIfChanged("weekStartKey", periodFields.weekStartKey)
        putIfChanged("weekEndKey", periodFields.weekEndKey)
        putInstantIfChanged("weekStart", startInstant)
        putInstantIfChanged("weekEnd", endInstant)
        // Nothing changed on an existing sheet: no write at all.
        if exists && data.isEmpty { return }
        let stamped = WriteMetadata.stamped(data, userId: Auth.auth().currentUser?.uid)
        if exists {
            try await ref.updateData(stamped)
        } else {
            // A new document: nest any dotted key (`extraEntryReviews.{id}`) so setData never sees one.
            var nested: [String: Any] = [:]
            for (key, value) in stamped {
                let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    var inner = nested[parts[0]] as? [String: Any] ?? [:]
                    inner[parts[1]] = value
                    nested[parts[0]] = inner
                } else {
                    nested[key] = value
                }
            }
            try await ref.setData(nested, merge: true)
        }
    }

    func listTimesheetStates(
        organizationId: String,
        userId: String,
        limit: Int = 200
    ) async throws -> [[String: Any]] {
        // Query by userId only, then sort/limit in memory.
        // Ordering by weekStart requires a composite index that may not exist yet and was
        // crashing/failing My Timesheets history loads in Simulator.
        let snapshot = try await db.collection("organizations")
            .document(organizationId)
            .collection("settings")
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        let rows: [[String: Any]] = snapshot.documents.map { doc in
            var row = doc.data()
            row["__documentId"] = doc.documentID
            return row
        }
        let sorted = rows.sorted { lhs, rhs in
            let left = (lhs["weekStart"] as? Timestamp)?.dateValue() ?? .distantPast
            let right = (rhs["weekStart"] as? Timestamp)?.dateValue() ?? .distantPast
            return left > right
        }
        return Array(sorted.prefix(max(1, limit)))
    }

    private func hsCollectionName(for project: Project) -> String {
        project.jobType == .smallWorks ? "smallWorks" : "projects"
    }

    /// RULEBOOK 1.8.0 §1 "Job keys": `settings/healthSafetyDocumentId(job, isSmallWorks)` —
    /// `healthSafety_{projects|smallWorks}_{KEY}`, KEY the job's stored document id upper-cased (what iOS has always
    /// written for a UUID job); never built from the in-app UUID, so a non-UUID job id works.
    private func hsStateDocumentRef(organizationId: String, project: Project) -> DocumentReference {
        let isSmallWorks = project.jobType == .smallWorks
        let docId = CanonicalBusinessEngine.healthSafetyDocumentId(jobId: project.documentId, isSmallWorks: isSmallWorks)
            ?? "healthSafety_\(hsCollectionName(for: project))_\(project.documentId.uppercased())"
        return db.collection("organizations")
            .document(organizationId)
            .collection("settings")
            .document(docId)
    }

    /// Every settings document to read for the job (`healthSafetyDocumentIds`: the shared id, then an older
    /// stored-case id web wrote).
    private func hsStateDocumentRefs(organizationId: String, project: Project) -> [DocumentReference] {
        let ids = CanonicalBusinessEngine.healthSafetyDocumentIds(
            jobId: project.documentId,
            isSmallWorks: project.jobType == .smallWorks
        ) ?? []
        let settings = db.collection("organizations").document(organizationId).collection("settings")
        let refs = ids.map { settings.document($0) }
        return refs.isEmpty ? [hsStateDocumentRef(organizationId: organizationId, project: project)] : refs
    }

    // Row maps a save sends. Nil optionals are left out, so `healthSafetyDocumentWriteFields` keeps the stored value.
    private func hsTalkMap(_ talk: HSToolboxTalk) -> [String: Any] {
        var map: [String: Any] = [
            "id": talk.id,
            "title": talk.title,
            "category": talk.category.rawValue,
            "isGeneral": talk.isGeneral,
            "trades": talk.trades,
            "purpose": talk.purpose,
            "keyPoints": talk.keyPoints,
            "source": talk.source.rawValue,
            "ownerOrganizationId": talk.ownerOrganizationId ?? "",
            "status": talk.status.rawValue,
            "version": talk.version,
            "updatedAt": Timestamp(date: talk.updatedAt),
        ]
        if let fileURL = talk.fileURL { map["fileURL"] = fileURL }
        return map
    }

    private func hsIssueMap(_ issue: HSToolboxIssue, jobId: String) -> [String: Any] {
        var map: [String: Any] = [
            "id": issue.id,
            "projectId": jobId,
            "talkId": issue.talkId,
            "weekCommencing": Timestamp(date: issue.weekCommencing),
            "issuedByUserId": issue.issuedByUserId,
            "issuedAt": Timestamp(date: issue.issuedAt),
            "recipientUserIds": issue.recipientUserIds,
            "status": issue.status.rawValue,
        ]
        if let publishAt = issue.publishAt { map["publishAt"] = Timestamp(date: publishAt) }
        if let ramsDocumentId = issue.ramsDocumentId { map["ramsDocumentId"] = ramsDocumentId }
        return map
    }

    private func hsSignatureMap(_ signature: HSToolboxSignature) -> [String: Any] {
        var map: [String: Any] = [
            "id": signature.id,
            "issueId": signature.issueId,
            "userId": signature.userId,
            "status": signature.status.rawValue,
            "readConfirmed": signature.readConfirmed,
        ]
        if let image = signature.signatureImageBase64 { map["signatureImageBase64"] = image }
        if let signedAt = signature.signedAt { map["signedAt"] = Timestamp(date: signedAt) }
        if let reminderSentAt = signature.reminderSentAt { map["reminderSentAt"] = Timestamp(date: reminderSentAt) }
        return map
    }

    private func hsRamsMap(_ doc: HSRamsDocument) -> [String: Any] {
        var map: [String: Any] = [
            "id": doc.id,
            "title": doc.title,
            "trade": doc.trade,
            "version": doc.version,
            "status": doc.status,
            "uploadedAt": Timestamp(date: doc.uploadedAt),
            "attachedDocTitles": doc.attachedDocTitles,
        ]
        if let fileURL = doc.fileURL { map["fileURL"] = fileURL }
        if let fileName = doc.fileName { map["fileName"] = fileName }
        if let reviewDate = doc.reviewDate { map["reviewDate"] = Timestamp(date: reviewDate) }
        return map
    }

    private func hsOtherDocMap(_ doc: HSOtherDocument) -> [String: Any] {
        var map: [String: Any] = [
            "id": doc.id,
            "title": doc.title,
            "category": doc.category,
            "uploadedAt": Timestamp(date: doc.uploadedAt),
            "issuableToClient": doc.issuableToClient,
        ]
        if let trade = doc.trade { map["trade"] = trade }
        if let fileURL = doc.fileURL { map["fileURL"] = fileURL }
        if let fileName = doc.fileName { map["fileName"] = fileName }
        return map
    }

    /// One `parseHealthSafetyDocument` talk row.
    static func hsTalk(_ row: CanonicalDocumentRow) -> HSToolboxTalk {
        HSToolboxTalk(
            id: row.id,
            title: row.text("title"),
            category: HSToolboxTalkCategory(rawValue: row.text("category")) ?? .general,
            isGeneral: row.bool("isGeneral"),
            trades: row.strings("trades"),
            purpose: row.text("purpose"),
            keyPoints: row.strings("keyPoints"),
            source: HSToolboxTalkSource(rawValue: row.text("source")) ?? .library,
            ownerOrganizationId: row.optionalText("ownerOrganizationId"),
            status: HSToolboxTalkStatus(rawValue: row.text("status")) ?? .approved,
            version: Int(row.number("version") ?? 1),
            updatedAt: row.date("updatedAtMs") ?? Date(timeIntervalSince1970: 0),
            fileURL: row.optionalText("fileURL")
        )
    }

    /// RULEBOOK 1.8.0 §1: a job's health & safety data through `parseHealthSafetyDocument` (issue status `complete`
    /// / `completed` / `scheduled` understood; signatures from the `signatures` array and the per-signer
    /// `signatureRecords` map, folded to one per issue and person, a signed copy winning).
    static func healthSafetyData(fromStored data: [String: Any], jobId: String, fallbackProjectId: UUID) -> HSProjectSafetyData? {
        guard let parsed = CanonicalBusinessEngine.parseHealthSafetyDocument(data, projectId: jobId) else { return nil }
        let issues = parsed.rows("issues").map { row in
            HSToolboxIssue(
                id: row.id,
                projectId: row.optionalText("projectId").map { JobKeys.inAppId($0) } ?? fallbackProjectId,
                talkId: row.text("talkId"),
                weekCommencing: row.optionalText("weekCommencingDayKey").flatMap { OrganizationRulebookContext.date(fromDayKey: $0) }
                    ?? row.date("weekCommencingMs") ?? Date(timeIntervalSince1970: 0),
                issuedByUserId: row.text("issuedByUserId"),
                issuedAt: row.date("issuedAtMs") ?? Date(timeIntervalSince1970: 0),
                publishAt: row.date("publishAtMs"),
                recipientUserIds: row.strings("recipientUserIds"),
                status: HSToolboxIssueStatus.fromRulebook(row.text("status")),
                ramsDocumentId: row.optionalText("ramsDocumentId")
            )
        }
        let signatures = parsed.rows("signatures").map { row in
            HSToolboxSignature(
                id: row.id,
                issueId: row.text("issueId"),
                userId: row.text("userId"),
                status: HSToolboxSignatureStatus(rawValue: row.text("status")) ?? .pending,
                readConfirmed: row.bool("readConfirmed"),
                signatureImageBase64: row.optionalText("signatureImageBase64"),
                signedAt: row.date("signedAtMs"),
                reminderSentAt: row.date("reminderSentAtMs")
            )
        }
        let rams = parsed.rows("ramsDocuments").map { row in
            HSRamsDocument(
                id: row.id,
                title: row.text("title"),
                trade: row.text("trade"),
                version: Int(row.number("version") ?? 1),
                status: row.text("status"),
                uploadedAt: row.date("uploadedAtMs") ?? Date(timeIntervalSince1970: 0),
                fileURL: row.optionalText("fileURL"),
                fileName: row.optionalText("fileName"),
                reviewDate: row.date("reviewDateMs"),
                attachedDocTitles: row.strings("attachedDocTitles")
            )
        }
        let others = parsed.rows("otherDocuments").map { row in
            HSOtherDocument(
                id: row.id,
                title: row.text("title"),
                trade: row.optionalText("trade"),
                category: row.text("category"),
                uploadedAt: row.date("uploadedAtMs") ?? Date(timeIntervalSince1970: 0),
                fileURL: row.optionalText("fileURL"),
                fileName: row.optionalText("fileName"),
                issuableToClient: row.bool("issuableToClient")
            )
        }
        return HSProjectSafetyData(
            talks: parsed.rows("talks").map(hsTalk),
            issues: issues,
            signatures: signatures,
            ramsDocuments: rams,
            otherDocuments: others,
            updatedAt: parsed.date("updatedAtMs") ?? Date()
        )
    }

    /// Two copies of a job's settings document (the shared id and an older web id) as one stored map for the reader:
    /// the first copy's rows, then rows of the second whose id the first lacks; every signature row and
    /// `signatureRecords` entry of both (the reader folds them).
    nonisolated static func mergedHealthSafetyDocuments(_ documents: [[String: Any]]) -> [String: Any] {
        guard var merged = documents.first else { return [:] }
        for other in documents.dropFirst() {
            for field in ["talks", "issues", "ramsDocuments", "otherDocuments"] {
                var rows = merged[field] as? [Any] ?? []
                let ids = Set(rows.compactMap { (($0 as? [String: Any])?["id"] as? String)?.lowercased() })
                for row in other[field] as? [Any] ?? [] {
                    let id = ((row as? [String: Any])?["id"] as? String)?.lowercased() ?? ""
                    if !id.isEmpty, !ids.contains(id) { rows.append(row) }
                }
                merged[field] = rows
            }
            merged["signatures"] = (merged["signatures"] as? [Any] ?? []) + (other["signatures"] as? [Any] ?? [])
            var records = merged["signatureRecords"] as? [String: Any] ?? [:]
            for (key, value) in other["signatureRecords"] as? [String: Any] ?? [:] where records[key] == nil {
                records[key] = value
            }
            merged["signatureRecords"] = records
        }
        return merged
    }

    func loadHealthSafetyData(project: Project, organizationId: String) async throws -> HSProjectSafetyData {
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else { return .empty }
        let orgId = try await ensureReadableOrganization(resolved)

        var stored: [[String: Any]] = []
        for (index, ref) in hsStateDocumentRefs(organizationId: orgId, project: project).enumerated() {
            let doc: DocumentSnapshot
            do {
                doc = try await ref.getDocument(source: .server)
            } catch {
                do {
                    doc = try await ref.getDocument(source: .cache)
                } catch {
                    // The shared document must be readable; an older copy that cannot be read is skipped.
                    if index == 0 { throw error }
                    continue
                }
            }
            if let data = doc.data() { stored.append(data) }
        }
        guard !stored.isEmpty else { return .empty }
        guard let output = Self.healthSafetyData(
            fromStored: Self.mergedHealthSafetyDocuments(stored),
            jobId: project.documentId,
            fallbackProjectId: project.id
        ) else {
            throw CanonicalWriteUnavailableError(function: "parseHealthSafetyDocument")
        }
        return output
    }

    func loadPlatformToolboxLibrary() async throws -> [HSToolboxTalk] {
        let docIds = ["toolboxTalkLibrary", "toolboxLibrary", "healthSafetyLibrary"]
        for docId in docIds {
            let snapshot: DocumentSnapshot
            do {
                snapshot = try await db.collection("platformConfig").document(docId).getDocument(source: .server)
            } catch {
                do {
                    snapshot = try await db.collection("platformConfig").document(docId).getDocument(source: .cache)
                } catch {
                    continue
                }
            }
            guard let data = snapshot.data() else { continue }
            let raw = (data["talks"] as? [[String: Any]])
                ?? (data["toolboxTalks"] as? [[String: Any]])
                ?? (data["items"] as? [[String: Any]])
                ?? []
            // RULEBOOK 1.8.0: library talks read with the same reader (`parseHealthSafetyDocument` talks).
            let talks = CanonicalBusinessEngine.parseHealthSafetyDocument(["talks": raw], projectId: "")?
                .rows("talks").map(Self.hsTalk) ?? []
            if !talks.isEmpty {
                return talks
            }
        }
        return []
    }

    func saveHealthSafetyData(
        _ safetyData: HSProjectSafetyData,
        project: Project,
        organizationId: String,
        fields: Set<String> = ["talks", "issues", "signatures", "ramsDocuments", "otherDocuments"]
    ) async throws {
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save health and safety data."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings -> Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [saveHealthSafetyData] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)
        try await validateDataIntegrity(organizationId: orgId)

        // RULEBOOK 1.8.0 §1: `healthSafetyDocumentWriteFields` — only the arrays named in `fields`, each row laid over
        // its stored row by id (the other app's fields kept), issue status written `completed`, an empty list never
        // replacing a stored one, unchanged arrays not written, `signatureRecords` never touched (signing is
        // `saveHealthSafetySignature`).
        let ref = hsStateDocumentRef(organizationId: orgId, project: project)
        let snapshot = try await ref.getDocument(source: .server)
        let stored = snapshot.exists ? snapshot.data() : nil
        let jobId = project.documentId
        var next: [String: [[String: Any]]] = [:]
        if fields.contains("talks") { next["talks"] = safetyData.talks.map(hsTalkMap) }
        if fields.contains("issues") { next["issues"] = safetyData.issues.map { hsIssueMap($0, jobId: jobId) } }
        if fields.contains("signatures") { next["signatures"] = safetyData.signatures.map(hsSignatureMap) }
        if fields.contains("ramsDocuments") { next["ramsDocuments"] = safetyData.ramsDocuments.map(hsRamsMap) }
        if fields.contains("otherDocuments") { next["otherDocuments"] = safetyData.otherDocuments.map(hsOtherDocMap) }
        guard let write = CanonicalBusinessEngine.healthSafetyDocumentWriteFields(stored: stored, next: next) else {
            throw CanonicalWriteUnavailableError(function: "healthSafetyDocumentWriteFields")
        }
        var changes: [String: Any] = [:]
        for (key, value) in write.set { changes[key] = ScriptFirestoreValue.native(value) }
        for key in write.remove { changes[key] = FieldValue.delete() }
        guard !changes.isEmpty else { return }
        let stamped = WriteMetadata.stamped(changes, userId: currentUser?.uid)
        if snapshot.exists {
            try await ref.updateData(stamped)
        } else {
            try await ref.setData(stamped.filter { !($0.value is FieldValue) || $0.key == "updatedAt" }, merge: true)
        }
    }

    /// RULEBOOK 1.8.0 §1: one person signing (or being reminded on) one issue — `healthSafetySignatureWriteFields`, a
    /// field-path update of `signatureRecords.{key}` plus an `arrayUnion` of the row onto `signatures` (older builds
    /// read the array), in one `update`. Two signers write different keys, so neither signature is lost.
    func saveHealthSafetySignature(_ signature: HSToolboxSignature, project: Project, organizationId: String) async throws {
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        let orgId = try await ensureReadableOrganization(resolved)
        guard let write = CanonicalBusinessEngine.healthSafetySignatureWriteFields(
            issueId: signature.issueId,
            userId: signature.userId,
            signatureId: signature.id,
            status: signature.status.rawValue,
            readConfirmed: signature.readConfirmed,
            signatureImageBase64: signature.signatureImageBase64,
            signedAt: signature.signedAt,
            reminderSentAt: signature.reminderSentAt
        ) else {
            throw CanonicalWriteUnavailableError(function: "healthSafetySignatureWriteFields")
        }
        let update = Self.healthSafetySignatureUpdate(write, userId: currentUser?.uid)
        let ref = hsStateDocumentRef(organizationId: orgId, project: project)
        do {
            try await ref.updateData(update)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 5 else { throw error }
            // Missing document: create it with the signer's entry as a nested map (never a dotted key).
            let row = (ScriptFirestoreValue.native(write.value) as? [String: Any]) ?? write.value
            let arrayRow = (ScriptFirestoreValue.native(write.arrayRow) as? [String: Any]) ?? write.arrayRow
            try await ref.setData(WriteMetadata.stamped([
                write.fieldPath[0]: [write.fieldPath[1]: row],
                "signatures": FieldValue.arrayUnion([arrayRow]),
            ], userId: currentUser?.uid), merge: true)
        }
    }

    /// The `updateData` map for a signature write: the entry at its field path, the array row unioned, metadata.
    /// Instants the script passed through as epoch ms are written as Timestamps.
    nonisolated static func healthSafetySignatureUpdate(_ write: CanonicalHealthSafetySignatureWrite, userId: String?) -> [AnyHashable: Any] {
        func native(_ row: [String: Any]) -> [String: Any] {
            var out = row
            for key in ["signedAt", "reminderSentAt"] {
                if let stamp = ScriptFirestoreValue.timestamp(ms: row[key]) { out[key] = stamp }
            }
            return out
        }
        var update: [AnyHashable: Any] = [
            FieldPath(write.fieldPath): native(write.value),
            "signatures": FieldValue.arrayUnion([native(write.arrayRow)]),
        ]
        for (key, value) in WriteMetadata.fields(userId: userId) { update[key] = value }
        return update
    }

    // MARK: - Deadlines (Project / Small Works)

    private func deadlinesStateDocumentRef(organizationId: String, project: Project) -> DocumentReference {
        deadlinesStateDocumentRef(organizationId: organizationId, projectKey: project.documentId, isSmallWorks: project.jobType == .smallWorks)
    }

    /// `settings/deadlinesDocumentId(projectId, isSmallWorks)` (RULEBOOK 1.7.0): `deadlines_{collection}_{KEY}` with
    /// the job key from `deadlineProjectKey` (upper case, the key both apps have always written).
    private func deadlinesStateDocumentRef(organizationId: String, projectKey: String, isSmallWorks: Bool) -> DocumentReference {
        let collection = isSmallWorks ? "smallWorks" : "projects"
        let docId = CanonicalBusinessEngine.deadlinesDocumentId(projectId: projectKey, isSmallWorks: isSmallWorks)
            ?? "deadlines_\(collection)_\(projectKey.uppercased())"
        return db.collection("organizations")
            .document(organizationId)
            .collection("settings")
            .document(docId)
    }

    private func deadlineAssignmentsDocumentRef(organizationId: String) -> DocumentReference {
        db.collection("organizations")
            .document(organizationId)
            .collection("settings")
            .document("deadlineAssignments")
    }

    private func deadlineChangeMap(_ change: DLChange) -> [String: Any] {
        var map: [String: Any] = [
            "id": WorkDocumentKeys.storedId(for: change.id),
            "at": Timestamp(date: change.at),
            "author": change.author
        ]
        switch change.kind {
        case .created(let due):
            map["type"] = "created"
            map["due"] = Timestamp(date: due)
        case .rescheduled(let from, let to, let reason):
            map["type"] = "rescheduled"
            map["from"] = Timestamp(date: from)
            map["to"] = Timestamp(date: to)
            map["reason"] = reason
        case .progress(let pct):
            map["type"] = "progress"
            map["progress"] = pct
        case .status(let status):
            map["type"] = "status"
            map["status"] = status.rawValue
        case .note(let text):
            map["type"] = "note"
            map["note"] = text
        case .completed(let on):
            map["type"] = "completed"
            map["completedOn"] = Timestamp(date: on)
        case .assigned(let who):
            map["type"] = "assigned"
            map["assignedTo"] = who
        case .fileAttached(let name):
            map["type"] = "fileAttached"
            map["name"] = name
        case .siteAuditAttached(let name):
            map["type"] = "siteAuditAttached"
            map["name"] = name
        }
        return map
    }

    /// One `parseDeadlineItem` history row (RULEBOOK 1.7.0): the stored change id is kept (UUID or not); an
    /// unknown type reads as a note carrying the stored type.
    private static func deadlineChange(fromCanonical row: CanonicalDocumentRow) -> DLChange? {
        guard !row.id.isEmpty else { return nil }
        let kind: DLChange.Kind
        switch row.text("type") {
        case "created":
            kind = .created(due: row.date("dueMs") ?? Date())
        case "rescheduled":
            kind = .rescheduled(from: row.date("fromMs") ?? Date(), to: row.date("toMs") ?? Date(), reason: row.text("reason"))
        case "progress":
            kind = .progress(to: Int(row.number("progress") ?? 0))
        case "status":
            kind = .status(to: DLStatus(rawValue: row.text("status")) ?? .notStarted)
        case "completed":
            kind = .completed(on: row.date("completedOnMs") ?? Date())
        case "assigned":
            kind = .assigned(to: row.text("assignedTo"))
        case "fileAttached":
            kind = .fileAttached(name: row.optionalText("name") ?? "File")
        case "siteAuditAttached":
            kind = .siteAuditAttached(name: row.optionalText("name") ?? "Site audit")
        default:
            kind = .note(row.text("note"))
        }
        return DLChange(id: WorkDocumentKeys.inAppId(for: row.id), at: row.date("atMs") ?? Date(), author: row.text("author"), kind: kind)
    }

    private func deadlineMap(_ item: DLDeadline) -> [String: Any] {
        [
            "id": WorkDocumentKeys.storedId(for: item.id),
            "title": item.title,
            "location": item.location ?? "",
            "trade": item.trade ?? "",
            "detail": item.detail ?? "",
            "start": item.start.map(Timestamp.init(date:)) as Any,
            "due": Timestamp(date: item.due),
            "completedAt": item.completedAt.map(Timestamp.init(date:)) as Any,
            "assignees": item.assignees,
            "assigneeUserIds": item.assigneeUserIds,
            "company": item.company ?? "",
            "status": item.status.rawValue,
            "progress": item.progress,
            "isCritical": item.isCritical,
            "dependsOn": item.dependsOn.map { WorkDocumentKeys.storedId(for: $0) },
            "blockedReason": item.blockedReason ?? "",
            "reminderDaysBefore": item.reminderDaysBefore as Any,
            "originalDue": item.originalDue.map(Timestamp.init(date:)) as Any,
            "history": item.history.map(deadlineChangeMap),
            "contextKind": item.contextKind,
            "projectId": item.projectId.map { WorkDocumentKeys.storedId(for: $0) } ?? "",
            "createdByUserId": item.createdByUserId,
            "fileURL": item.fileURL ?? "",
            "fileName": item.fileName ?? "",
            "siteAuditId": item.siteAuditId.map { WorkDocumentKeys.storedId(for: $0) } ?? "",
            "siteAuditTitle": item.siteAuditTitle ?? ""
        ]
    }

    /// RULEBOOK 1.7.0 §1 "Document readers": a deadlines document is read only through `parseDeadlineDocument`
    /// (items keep their stored ids, UUID or not; an item without an id is skipped; ordered by due day). Tests call
    /// this with a raw document.
    static func deadlines(fromDocument documentId: String, data: [String: Any], projectKey: String) -> [DLDeadline]? {
        guard let document = CanonicalBusinessEngine.parseDeadlineDocument(documentId: documentId, data: data, projectId: projectKey) else {
            return nil
        }
        return document.rows("items").map(deadline(fromCanonical:))
    }

    /// One `parseDeadlineItem` row as a `DLDeadline`. Ids get stable in-app UUIDs and are written back as stored.
    static func deadline(fromCanonical row: CanonicalDocumentRow) -> DLDeadline {
        DLDeadline(
            id: WorkDocumentKeys.inAppId(for: row.id),
            title: row.optionalText("title") ?? "Untitled deadline",
            location: row.optionalText("location"),
            trade: row.optionalText("trade"),
            detail: row.optionalText("detail"),
            start: row.date("startMs"),
            due: row.date("dueMs") ?? Date(),
            completedAt: row.date("completedAtMs"),
            assignees: row.strings("assignees"),
            assigneeUserIds: row.strings("assigneeUserIds"),
            company: row.optionalText("company"),
            status: DLStatus(rawValue: row.text("status")) ?? .notStarted,
            progress: row.number("progress") ?? 0,
            isCritical: row.bool("isCritical"),
            dependsOn: row.strings("dependsOn").map { WorkDocumentKeys.inAppId(for: $0) },
            blockedReason: row.optionalText("blockedReason"),
            reminderDaysBefore: row.number("reminderDaysBefore").map { Int($0) },
            originalDue: row.date("originalDueMs"),
            history: row.rows("history").compactMap(deadlineChange(fromCanonical:)),
            contextKind: row.optionalText("contextKind") ?? "Project",
            projectId: row.optionalText("projectId").map { WorkDocumentKeys.inAppId(for: $0) },
            createdByUserId: row.text("createdByUserId"),
            fileURL: row.optionalText("fileURL"),
            fileName: row.optionalText("fileName"),
            siteAuditId: row.optionalText("siteAuditId").map { WorkDocumentKeys.inAppId(for: $0) },
            siteAuditTitle: row.optionalText("siteAuditTitle")
        )
    }

    func loadDeadlines(project: Project, organizationId: String) async throws -> [DLDeadline] {
        try await loadDeadlinesState(project: project, organizationId: organizationId).items
    }

    func loadDeadlinesState(project: Project, organizationId: String) async throws -> (items: [DLDeadline], updatedAt: Date?) {
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else { return ([], nil) }
        let orgId = try await ensureReadableOrganization(resolved)
        let ref = deadlinesStateDocumentRef(organizationId: orgId, project: project)
        let doc: DocumentSnapshot
        do {
            doc = try await ref.getDocument(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) || isOfflineNetworkError(error) {
                doc = try await ref.getDocument(source: .cache)
            } else {
                throw error
            }
        }
        guard let data = doc.data() else { return ([], nil) }
        guard let items = Self.deadlines(fromDocument: ref.documentID, data: data, projectKey: project.documentId) else {
            throw CanonicalWriteUnavailableError(function: "parseDeadlineDocument")
        }
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
        return (items, updatedAt)
    }

    @discardableResult
    func saveDeadlines(
        _ items: [DLDeadline],
        project: Project,
        organizationId: String,
        baseUpdatedAt: Date? = nil
    ) async throws -> [DLDeadline] {
        try await saveDeadlines(
            items,
            projectId: project.id,
            projectKey: project.documentId,
            isSmallWorks: project.jobType == .smallWorks,
            organizationId: organizationId,
            baseUpdatedAt: baseUpdatedAt
        )
    }

    @discardableResult
    func saveDeadlines(
        _ items: [DLDeadline],
        projectId: UUID,
        projectKey: String? = nil,
        isSmallWorks: Bool,
        organizationId: String,
        baseUpdatedAt: Date? = nil
    ) async throws -> [DLDeadline] {
        // The job id as stored (RULEBOOK 1.7.0): the caller's, else the remembered stored id, else the UUID.
        let jobKey = projectKey ?? WorkDocumentKeys.storedId(for: projectId)
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save deadlines."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings -> Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: [saveDeadlines] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)
        try await validateDataIntegrity(organizationId: orgId)

        let ref = deadlinesStateDocumentRef(organizationId: orgId, projectKey: jobKey, isSmallWorks: isSmallWorks)
        var itemsToWrite = items
        if let baseUpdatedAt {
            do {
                let remoteDoc = try await ref.getDocument(source: .server)
                if let data = remoteDoc.data(),
                   let remoteUpdatedAt = (data["updatedAt"] as? Timestamp)?.dateValue(),
                   remoteUpdatedAt > baseUpdatedAt.addingTimeInterval(0.4) {
                    let remoteItems = Self.deadlines(fromDocument: ref.documentID, data: data, projectKey: jobKey) ?? []
                    itemsToWrite = mergeDeadlinesFirstWriterWins(remote: remoteItems, local: items)
                    print("🔥🔥🔥 DEBUG: [saveDeadlines] First writer already synced — merging local creates only")
                }
            } catch {
                if !isOfflineNetworkError(error) && !isFirestorePermissionDenied(error) {
                    print("🔥🔥🔥 DEBUG: [saveDeadlines] FWW remote read failed: \(error.localizedDescription)")
                }
            }
        }

        let payload: [String: Any] = [
            "items": itemsToWrite.map(deadlineMap),
            "updatedAt": Timestamp(date: Date()),
            "projectId": jobKey
        ]
        try await ref.setData(payload, merge: true)

        try await writeDeadlineAssignments(
            projectKey: jobKey,
            assigneeUserIds: itemsToWrite.flatMap(\.assigneeUserIds),
            organizationId: orgId
        )
        return itemsToWrite
    }

    /// RULEBOOK 1.7.0 §1 "Partial writes only": one job's assignees in `settings/deadlineAssignments` are written
    /// with `deadlineAssignmentWriteFields` as a field-path update (`['projects', KEY]`). The document is created
    /// from `createFields` only when it is missing. Never a merge-set with a dotted key, which stored a literal
    /// field named `projects.{KEY}` that nothing read back.
    private func writeDeadlineAssignments(projectKey: String, assigneeUserIds: [String], organizationId orgId: String) async throws {
        guard let write = CanonicalBusinessEngine.deadlineAssignmentWriteFields(projectId: projectKey, assigneeUserIds: assigneeUserIds) else {
            throw CanonicalWriteUnavailableError(function: "deadlineAssignmentWriteFields")
        }
        let ref = deadlineAssignmentsDocumentRef(organizationId: orgId)
        let update: [AnyHashable: Any] = [
            FieldPath(write.fieldPath): write.value,
            "updatedAt": Timestamp(date: Date())
        ]
        do {
            try await ref.updateData(update)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 5 else { throw error }
            // Missing: create it. A nested map (never a dotted key); merge keeps any other job's entry a racing
            // device wrote first.
            var create = write.createFields
            create["updatedAt"] = Timestamp(date: Date())
            try await ref.setData(create, merge: true)
        }
    }

    private func mergeDeadlinesFirstWriterWins(remote: [DLDeadline], local: [DLDeadline]) -> [DLDeadline] {
        var byId = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for item in local where byId[item.id] == nil {
            byId[item.id] = item
        }
        return byId.values.sorted { $0.due < $1.due }
    }

    /// `jobIds`: the job list's stored document ids. With them each assignment key is mapped back to the job's stored
    /// id (`deadlineAssignedProjectIds` with `jobIds`, `storedJobIdForKey`, 1.8.0) and keys naming no job are left out.
    func loadDeadlineAssignedProjectIds(userId: String, organizationId: String, jobIds: [String]? = nil) async -> Set<UUID> {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else { return [] }
        do {
            let orgId = try await ensureReadableOrganization(resolved)
            let snap = try await deadlineAssignmentsDocumentRef(organizationId: orgId).getDocument()
            guard let data = snap.data() else { return [] }
            // `deadlineAssignedProjectIds`: the nested map and older literal `projects.{KEY}` fields, ids compared
            // without case. Keys are upper case (`deadlineProjectKey`); a UUID key is the job's in-app id.
            if let jobIds, !jobIds.isEmpty {
                let stored = CanonicalBusinessEngine.deadlineAssignedProjectIds(data, personIds: [trimmed], jobIds: jobIds) ?? []
                return Set(stored.map { WorkDocumentKeys.inAppId(for: $0) })
            }
            let keys = CanonicalBusinessEngine.deadlineAssignedProjectIds(data, personIds: [trimmed]) ?? []
            return Set(keys.map { UUID(uuidString: $0) ?? WorkDocumentKeys.inAppId(for: $0) })
        } catch {
            print("🔥🔥🔥 DEBUG: [loadDeadlineAssignedProjectIds] \(error.localizedDescription)")
            return []
        }
    }

}

// MARK: - Firebase Configuration

class FirebaseConfig {
    static func configure() {
        // Firebase is configured in AppDelegate or App struct
        // This class can be used for additional configuration
    }
}
