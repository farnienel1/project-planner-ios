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
        didSet { OrganizationDocumentAbbreviation.update(from: currentOrganization) }
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
    /// Lower bound of the launch booking and manager-site listeners. Nil with `scheduleHistoryIsFull` means every date.
    var scheduleHistoryStart: Date?
    private var scheduleHistoryIsFull = false
    /// Inbox ids already accepted for an only-if-missing write. A token refresh must not write the same row twice.
    private var acceptedMissingNotificationIds = Set<String>()
    /// Push tokens a send has already reported as dead. The full token is never logged.
    private var failedPushTokens = Set<String>()
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
                    guard organizationIdsMatch(self.currentOrganization?.firestoreDocumentId, orgId) else { return }
                    self.applyOrganizationDocumentMyScheduleOptions(from: data)
                    self.applyOrganizationDocumentMaterialCutOff(from: data)
                    self.applyOrganizationDocumentBilling(from: data, organizationId: orgId)
                }
            }
    }

    @MainActor
    private func applyOrganizationDocumentMyScheduleOptions(from data: [String: Any]) {
        guard var org = currentOrganization else { return }
        guard let settingsDict = data["settings"] as? [String: Any],
              let raw = settingsDict["myScheduleOptions"] as? [String: Any] else {
            return
        }
        let options = MyScheduleOptions.fromFirestore(raw)
        let previous = org.settings.myScheduleOptions
        guard previous != options else { return }
        org.settings.myScheduleOptions = options
        organizationHasFirestoreMyScheduleOptions = true
        currentOrganization = org
        storeOrganizationLocally(org)
        NotificationCenter.default.post(name: .organizationMyScheduleOptionsDidChange, object: nil)
    }

    /// Live `settings.materialCutOff`. A web save of 15:30 must replace the in-memory 16:00 clock.
    @MainActor
    private func applyOrganizationDocumentMaterialCutOff(from data: [String: Any]) {
        guard var org = currentOrganization else { return }
        guard let settingsDict = data["settings"] as? [String: Any],
              let raw = settingsDict["materialCutOff"] as? [String: Any] else { return }
        guard let cutOff = OrgMaterialCutOff.fromFirestore(raw) else { return }
        guard org.settings.materialCutOff != cutOff else { return }
        org.settings.materialCutOff = cutOff
        currentOrganization = org
        storeOrganizationLocally(org)
        NotificationCenter.default.post(name: .organizationMaterialCutOffDidChange, object: nil)
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
                id: UUID(uuidString: organizationId) ?? UUID(),
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
                try? auth.signOut()
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
            id: UUID(uuidString: trimmed) ?? UUID(),
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
        if let parsed = CanonicalBusinessEngine.parseWarningDetection(warningRaw),
           let detection = OrgWarningDetectionSettings(canonical: parsed) {
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
        if let settingsDict = data["settings"] as? [String: Any],
           let regionId = (settingsDict["bankHolidayRegionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !regionId.isEmpty {
            settings.bankHolidayRegionId = regionId
        } else if let regionId = (data["bankHolidayRegionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !regionId.isEmpty {
            settings.bankHolidayRegionId = regionId
        }
        if let settingsDict = data["settings"] as? [String: Any],
           let currency = (settingsDict["currencyCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currency.isEmpty {
            settings.currencyCode = currency.uppercased()
        } else if let currency = (data["currencyCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !currency.isEmpty {
            settings.currencyCode = currency.uppercased()
        }
        return settings
    }

    /// Reads current/prior/scheduled payroll policy fields and promotes due scheduled changes.
    static func applyPayrollPolicyFields(from data: [String: Any], to organization: inout Organization) {
        let current = organization.settings.payrollTimePolicy
        var prior: OrgPayrollTimePolicy?
        if let priorDict = data["payrollTimePolicyPrior"] as? [String: Any] {
            prior = OrgPayrollTimePolicy.fromFirestore(priorDict)
        }
        var effectiveFrom = Calendar.current.startOfDay(for: Date())
        if let key = data["payrollTimePolicyEffectiveFrom"] as? String,
           let d = PayrollTimePolicyCatalog.date(fromDayKey: key) {
            effectiveFrom = d
        }
        var scheduled: OrgPayrollTimePolicyScheduledChange?
        if let schedDict = data["payrollTimePolicyScheduled"] as? [String: Any] {
            scheduled = OrgPayrollTimePolicyScheduledChange.fromFirestore(schedDict)
        }
        let applied = PayrollTimePolicyCatalog.appliedPolicyState(
            current: current,
            prior: prior,
            effectiveFrom: effectiveFrom,
            scheduled: scheduled
        )
        organization.settings.payrollTimePolicy = applied.current
        organization.payrollTimePolicyPrior = applied.prior
        organization.payrollTimePolicyEffectiveFrom = applied.effectiveFrom
        organization.payrollTimePolicyScheduled = applied.scheduled
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
                try? auth.signOut()
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
                        id: UUID(uuidString: organizationId) ?? UUID(),
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
    
    private func parseJobType(from rawValue: Any?, defaultValue: JobType) -> JobType {
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
    
    private func parseManagerLegacy(from rawValue: Any?) -> ManagerLegacy {
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

    func saveProject(_ project: Project, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: [SAVE] ========== SAVING PROJECT ==========")
        print("🔥🔥🔥 DEBUG: [SAVE] Project: \(project.siteName)")
        print("🔥🔥🔥 DEBUG: [SAVE] Project ID: \(project.id.uuidString)")
        print("🔥🔥🔥 DEBUG: [SAVE] Organization ID: \(organizationId)")
        
        // CRITICAL: Ensure user document is linked before validation
        // This prevents "user is not linked to organization" errors
        do {
            try await ensureUserDocumentLinked(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: [SAVE] ✅ User document verified/updated")
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE] ⚠️ Could not ensure user document is linked: \(error.localizedDescription)")
            // Continue anyway - validation might still pass if user is in organization members
        }
        
        // Validate data integrity before saving
        do {
            try await validateDataIntegrity(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: [SAVE] ✅ Data integrity validation passed")
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE] ❌ Data integrity validation failed: \(error.localizedDescription)")
            throw error
        }
        
        var data: [String: Any] = [
            "jobNumber": project.jobNumber,
            "siteName": project.siteName,
            "addressLine1": project.addressLine1,
            "addressLine2": project.addressLine2 ?? "",
            "townCity": project.townCity,
            "postcode": project.postcode,
            // Keep siteAddress for backward compatibility
            "siteAddress": project.siteAddress,
            "client": [
                "id": project.client.id.uuidString,
                "name": project.client.name,
                "email": project.client.email ?? "",
                "phone": project.client.phone ?? ""
            ],
            "startDate": Timestamp(date: project.startDate),
            "endDate": Timestamp(date: project.endDate),
            "jobType": project.jobType.rawValue,
            "manager": project.manager.rawValue,
            "isLive": project.isLive,
            "description": project.description ?? "",
            "organizationId": organizationId,
            "createdAt": Timestamp(date: project.createdAt),
            "updatedAt": Timestamp(date: project.updatedAt)
        ]
        data["hiddenManagerUserIds"] = Array(project.hiddenManagerUserIds)
        data["hiddenOperativeUserIds"] = Array(project.hiddenOperativeUserIds)
        data["usesMapPinForLocation"] = project.usesMapPinForLocation
        if let lat = project.latitude { data["latitude"] = lat }
        if let lon = project.longitude { data["longitude"] = lon }
        
        // Save primary managerId if available
        if let managerId = project.managerId ?? project.allAssignedManagerIds.first {
            data["managerId"] = managerId.uuidString
        }
        let managerIdsToSave = project.allAssignedManagerIds.map(\.uuidString)
        if !managerIdsToSave.isEmpty {
            data["managerIds"] = managerIdsToSave
        }
        
        // Save customJobType if available
        if let customJobType = project.customJobType {
            data["customJobType"] = customJobType
        }
        
        let documentPath = "organizations/\(organizationId)/projects/\(project.id.uuidString)"
        print("🔥🔥🔥 DEBUG: [SAVE] Saving to: \(documentPath)")
        print("🔥🔥🔥 DEBUG: [SAVE] Data keys: \(data.keys.joined(separator: ", "))")
        
        // Save to organizations/{orgId}/projects/{projectId}
        do {
            try await db.collection("organizations").document(organizationId).collection("projects").document(project.id.uuidString).setData(data)
            print("🔥🔥🔥 DEBUG: [SAVE] ✅✅✅ Project saved successfully to Firebase!")
            
            // Verify save by reading it back immediately
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds for propagation
            let verifyDoc = try await db.collection("organizations").document(organizationId).collection("projects").document(project.id.uuidString).getDocument()
            if verifyDoc.exists {
                print("🔥🔥🔥 DEBUG: [SAVE] ✅ Verification: Document exists in Firebase")
                if let verifyData = verifyDoc.data() {
                    print("🔥🔥🔥 DEBUG: [SAVE] ✅ Verification: Document has data with \(verifyData.keys.count) fields")
                }
            } else {
                print("🔥🔥🔥 DEBUG: [SAVE] ❌❌❌ WARNING: Document does NOT exist after save!")
                print("🔥🔥🔥 DEBUG: [SAVE] This indicates a permission or data issue!")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE] ❌❌❌ ERROR saving project: \(error.localizedDescription)")
            print("🔥🔥🔥 DEBUG: [SAVE] Error type: \(type(of: error))")
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: [SAVE] Error domain: \(nsError.domain), code: \(nsError.code)")
            if nsError.domain == "FIRFirestoreErrorDomain" {
                if nsError.code == 7 {
                    print("🔥🔥🔥 DEBUG: [SAVE] ❌ PERMISSION DENIED - Security rules are blocking this save!")
                    print("🔥🔥🔥 DEBUG: [SAVE] Check that user belongs to organization and organizationId matches")
                }
            }
            throw error
        }
    }

    /// Restores map-pin location fields from Firestore (handles `NSNumber` from Firestore).
    private static func applyMapPinFields(from data: [String: Any], to project: inout Project) {
        project.usesMapPinForLocation = data["usesMapPinForLocation"] as? Bool ?? false
        if let n = data["latitude"] as? NSNumber {
            project.latitude = n.doubleValue
        } else if let d = data["latitude"] as? Double {
            project.latitude = d
        } else {
            project.latitude = nil
        }
        if let n = data["longitude"] as? NSNumber {
            project.longitude = n.doubleValue
        } else if let d = data["longitude"] as? Double {
            project.longitude = d
        } else {
            project.longitude = nil
        }
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
        print("🔥🔥🔥 DEBUG: [LOAD] Starting to load projects for organization: \(orgId)")
        let snapshot = try await getDocumentsPreferringServer(
            db.collection("organizations").document(orgId).collection("projects")
        )
        print("🔥🔥🔥 DEBUG: [LOAD] Found \(snapshot.documents.count) project documents in Firebase")
        
        var loadedProjects: [Project] = []
        var skippedCount = 0
        
        for doc in snapshot.documents {
            let data = doc.data()
            let docId = doc.documentID
            if loadedProjects.count % 40 == 0 {
                await Task.yield()
            }

            // Skip placeholder documents
            if docId == "INITIAL-PLACEHOLDER" {
                print("🔥🔥🔥 DEBUG: [LOAD] Skipping placeholder document")
                skippedCount += 1
                continue
            }
            
            // More forgiving parsing - use defaults for missing fields
            let clientData = data["client"] as? [String: Any] ?? [:]
            let clientName = clientData["name"] as? String ?? "Unknown Client"
            let clientEmail = clientData["email"] as? String ?? ""
            let clientPhone = clientData["phone"] as? String ?? ""
            let clientIdString = clientData["id"] as? String ?? UUID().uuidString
            
            let startDate = (data["startDate"] as? Timestamp)?.dateValue()
                ?? (data["createdAt"] as? Timestamp)?.dateValue()
                ?? Date()
            let endDate = (data["endDate"] as? Timestamp)?.dateValue() ?? startDate
            let jobType = parseJobType(from: data["jobType"], defaultValue: .catA)
            let manager = parseManagerLegacy(from: data["manager"])
            
            // Load managerId if available
            let managerId: UUID? = {
                if let managerIdString = data["managerId"] as? String {
                    return UUID(uuidString: managerIdString)
                }
                return nil
            }()
            let managerIds: [UUID] = {
                let raw = data["managerIds"] as? [String] ?? []
                let parsed = raw.compactMap(UUID.init(uuidString:))
                if !parsed.isEmpty { return parsed }
                if let managerId { return [managerId] }
                return []
            }()
            
            // Load customJobType if available
            let customJobType: String? = data["customJobType"] as? String
            let hiddenManagerUserIds = Set((data["hiddenManagerUserIds"] as? [String]) ?? [])
            let hiddenOperativeUserIds = Set((data["hiddenOperativeUserIds"] as? [String]) ?? [])
            
            let client = Client(
                id: UUID(uuidString: clientIdString) ?? UUID(),
                name: clientName,
                email: clientEmail.isEmpty ? nil : clientEmail,
                phone: clientPhone.isEmpty ? nil : clientPhone
            )
            
            // Handle both new format (addressLine1, etc.) and old format (siteAddress)
            let project: Project
            if let addressLine1 = data["addressLine1"] as? String,
               let townCity = data["townCity"] as? String,
               let postcode = data["postcode"] as? String {
                // New format
                var decodedProject = Project(
                    id: UUID(uuidString: docId) ?? UUID(),
                    jobNumber: data["jobNumber"] as? String ?? "",
                    siteName: data["siteName"] as? String ?? "Unnamed Project",
                    addressLine1: addressLine1,
                    addressLine2: data["addressLine2"] as? String,
                    townCity: townCity,
                    postcode: postcode,
                    client: client,
                    startDate: startDate,
                    endDate: endDate,
                    jobType: jobType,
                    customJobType: customJobType,
                    manager: manager,
                    managerId: managerId,
                    managerIds: managerIds,
                    isLive: data["isLive"] as? Bool ?? true,
                    description: data["description"] as? String,
                    hiddenManagerUserIds: hiddenManagerUserIds,
                    hiddenOperativeUserIds: hiddenOperativeUserIds
                )
                Self.applyMapPinFields(from: data, to: &decodedProject)
                project = decodedProject
            } else {
                // Legacy format - use old initializer
                var legacyProject = Project(
                    id: UUID(uuidString: docId) ?? UUID(),
                    jobNumber: data["jobNumber"] as? String ?? "",
                    siteName: data["siteName"] as? String ?? "Unnamed Project",
                    siteAddress: data["siteAddress"] as? String ?? "",
                    client: client,
                    startDate: startDate,
                    endDate: endDate,
                    jobType: jobType,
                    manager: manager,
                    isLive: data["isLive"] as? Bool ?? true,
                    description: data["description"] as? String,
                    hiddenManagerUserIds: hiddenManagerUserIds,
                    hiddenOperativeUserIds: hiddenOperativeUserIds
                )
                // Set managerId and customJobType after initialization since legacy initializer doesn't accept them
                legacyProject.managerId = managerId
                legacyProject.managerIds = managerIds
                legacyProject.customJobType = customJobType
                var legacyVar = legacyProject
                Self.applyMapPinFields(from: data, to: &legacyVar)
                project = legacyVar
            }
            
            loadedProjects.append(project)
        }
        
        print("🔥🔥🔥 DEBUG: [LOAD] ✅ Loaded \(loadedProjects.count) projects, skipped \(skippedCount) documents")
        return loadedProjects
    }
    
    func saveClient(_ client: Client, organizationId: String) async throws {
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
        
        let data: [String: Any] = [
            "id": client.id.uuidString,
            "name": client.name,
            "contactPerson": client.contactPerson ?? "",
            "email": client.email ?? "",
            "phone": client.phone ?? "",
            "address": client.address ?? "",
            "organizationId": orgId,
            "createdAt": Timestamp(date: client.createdAt),
            "updatedAt": Timestamp(date: client.updatedAt)
        ]
        
        print("🔥🔥🔥 DEBUG: Saving client to organizations/\(orgId)/clients/\(client.id.uuidString)")
        
        try await db.collection("organizations").document(orgId).collection("clients").document(client.id.uuidString).setData(data)
        
        print("🔥🔥🔥 DEBUG: Client saved successfully to Firebase")
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
        
        let clients = snapshot.documents.compactMap { doc -> Client? in
            let data = doc.data()
            let idString = (data["id"] as? String) ?? doc.documentID
            guard let id = UUID(uuidString: idString),
                  let name = data["name"] as? String else {
                return nil
            }
            
            var client = Client(
                id: id,
                name: name,
                contactPerson: data["contactPerson"] as? String,
                email: data["email"] as? String,
                phone: data["phone"] as? String,
                address: data["address"] as? String
            )
            // Preserve dates from Firebase if available
            if let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() {
                client.createdAt = createdAt
            }
            if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                client.updatedAt = updatedAt
            }
            return client
        }
        
        print("🔥🔥🔥 DEBUG: Loaded \(clients.count) clients from Firebase")
        return clients
    }
    
    func deleteClient(_ client: Client, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteClient called for client: \(client.name), organization: \(organizationId)")
        try await db.collection("organizations").document(organizationId).collection("clients").document(client.id.uuidString).delete()
        print("🔥🔥🔥 DEBUG: Client deleted successfully from Firebase")
    }
    
    func deleteProject(_ project: Project, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteProject called for project: \(project.siteName), organization: \(organizationId)")
        try await db.collection("organizations").document(organizationId).collection("projects").document(project.id.uuidString).delete()
        print("🔥🔥🔥 DEBUG: Project deleted successfully from Firebase")
    }
    
    // MARK: - Small Works Management (Separate Collection)
    
    func saveSmallWorks(_ smallWork: Project, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ========== SAVING SMALL WORKS ==========")
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Small Work: \(smallWork.siteName)")
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Small Work ID: \(smallWork.id.uuidString)")
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Organization ID: \(organizationId)")
        
        // CRITICAL: Ensure user document is linked before validation
        // This prevents "user is not linked to organization" errors
        do {
            try await ensureUserDocumentLinked(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ✅ User document verified/updated")
            // Wait a moment for the update to propagate
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ⚠️ Could not ensure user document is linked: \(error.localizedDescription)")
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Will continue - validation will check organization members as fallback")
        }
        
        // Validate data integrity before saving
        // This now checks organization members as fallback if user document doesn't have organizationId
        do {
            try await validateDataIntegrity(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ✅ Data integrity validation passed")
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ❌ Data integrity validation failed: \(error.localizedDescription)")
            throw error
        }
        
        var data: [String: Any] = [
            "jobNumber": smallWork.jobNumber,
            "siteName": smallWork.siteName,
            "addressLine1": smallWork.addressLine1,
            "addressLine2": smallWork.addressLine2 ?? "",
            "townCity": smallWork.townCity,
            "postcode": smallWork.postcode,
            // Keep siteAddress for backward compatibility
            "siteAddress": smallWork.siteAddress,
            "client": [
                "id": smallWork.client.id.uuidString,
                "name": smallWork.client.name,
                "email": smallWork.client.email ?? "",
                "phone": smallWork.client.phone ?? ""
            ],
            "startDate": Timestamp(date: smallWork.startDate),
            "endDate": Timestamp(date: smallWork.endDate),
            "jobType": smallWork.jobType.rawValue,
            "manager": smallWork.manager.rawValue,
            "isLive": smallWork.isLive,
            "description": smallWork.description ?? "",
            "organizationId": organizationId,
            "createdAt": Timestamp(date: smallWork.createdAt),
            "updatedAt": Timestamp(date: smallWork.updatedAt)
        ]
        data["hiddenManagerUserIds"] = Array(smallWork.hiddenManagerUserIds)
        data["hiddenOperativeUserIds"] = Array(smallWork.hiddenOperativeUserIds)
        data["usesMapPinForLocation"] = smallWork.usesMapPinForLocation
        if let lat = smallWork.latitude { data["latitude"] = lat }
        if let lon = smallWork.longitude { data["longitude"] = lon }
        
        // Save primary managerId if available
        if let managerId = smallWork.managerId ?? smallWork.allAssignedManagerIds.first {
            data["managerId"] = managerId.uuidString
        }
        let managerIdsToSave = smallWork.allAssignedManagerIds.map(\.uuidString)
        if !managerIdsToSave.isEmpty {
            data["managerIds"] = managerIdsToSave
        }
        
        // Save customJobType if available
        if let customJobType = smallWork.customJobType {
            data["customJobType"] = customJobType
        }
        
        let documentPath = "organizations/\(organizationId)/smallWorks/\(smallWork.id.uuidString)"
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Saving to: \(documentPath)")
        print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Data keys: \(data.keys.joined(separator: ", "))")
        
        // Save to organizations/{orgId}/smallWorks/{smallWorkId}
        do {
            try await db.collection("organizations").document(organizationId).collection("smallWorks").document(smallWork.id.uuidString).setData(data)
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ✅✅✅ Small Works saved successfully to Firebase!")
            
            // Verify save by reading it back immediately
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds for propagation
            let verifyDoc = try await db.collection("organizations").document(organizationId).collection("smallWorks").document(smallWork.id.uuidString).getDocument()
            if verifyDoc.exists {
                print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ✅ Verification: Document exists in Firebase")
                if let verifyData = verifyDoc.data() {
                    print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ✅ Verification: Document has data with \(verifyData.keys.count) fields")
                }
            } else {
                print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ❌❌❌ WARNING: Document does NOT exist after save!")
                print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] This indicates a permission or data issue!")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ❌❌❌ ERROR saving small works: \(error.localizedDescription)")
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Error type: \(type(of: error))")
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Error domain: \(nsError.domain), code: \(nsError.code)")
            if nsError.domain == "FIRFirestoreErrorDomain" {
                if nsError.code == 7 {
                    print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] ❌ PERMISSION DENIED - Security rules are blocking this save!")
                    print("🔥🔥🔥 DEBUG: [SAVE SMALL WORKS] Check that user belongs to organization and organizationId matches")
                }
            }
            throw error
        }
    }
    
    func loadSmallWorks(organizationId: String) async throws -> [Project] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Starting to load small works for organization: \(orgId)")
        let snapshot = try await getDocumentsPreferringServer(
            db.collection("organizations").document(orgId).collection("smallWorks")
        )
        print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Found \(snapshot.documents.count) small works documents in Firebase")
        
        var loadedSmallWorks: [Project] = []
        var skippedCount = 0
        
        for doc in snapshot.documents {
            let data = doc.data()
            let docId = doc.documentID
            if loadedSmallWorks.count % 40 == 0 {
                await Task.yield()
            }

            // Skip placeholder documents
            if docId == "INITIAL-PLACEHOLDER" {
                print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Skipping placeholder document")
                skippedCount += 1
                continue
            }
            
            // More forgiving parsing - use defaults for missing fields
            let clientData = data["client"] as? [String: Any] ?? [:]
            let clientName = clientData["name"] as? String ?? "Unknown Client"
            let clientEmail = clientData["email"] as? String ?? ""
            let clientPhone = clientData["phone"] as? String ?? ""
            let clientIdString = clientData["id"] as? String ?? UUID().uuidString
            
            let startDate = (data["startDate"] as? Timestamp)?.dateValue()
                ?? (data["createdAt"] as? Timestamp)?.dateValue()
                ?? Date()
            let endDate = (data["endDate"] as? Timestamp)?.dateValue() ?? startDate
            let jobType = parseJobType(from: data["jobType"], defaultValue: .smallWorks)
            let manager = parseManagerLegacy(from: data["manager"])
            
            // Load managerId if available
            let managerId: UUID? = {
                if let managerIdString = data["managerId"] as? String {
                    return UUID(uuidString: managerIdString)
                }
                return nil
            }()
            let managerIds: [UUID] = {
                let raw = data["managerIds"] as? [String] ?? []
                let parsed = raw.compactMap(UUID.init(uuidString:))
                if !parsed.isEmpty { return parsed }
                if let managerId { return [managerId] }
                return []
            }()
            
            // Load customJobType if available
            let customJobType: String? = data["customJobType"] as? String
            let hiddenManagerUserIds = Set((data["hiddenManagerUserIds"] as? [String]) ?? [])
            let hiddenOperativeUserIds = Set((data["hiddenOperativeUserIds"] as? [String]) ?? [])
            
            let client = Client(
                id: UUID(uuidString: clientIdString) ?? UUID(),
                name: clientName,
                email: clientEmail.isEmpty ? nil : clientEmail,
                phone: clientPhone.isEmpty ? nil : clientPhone
            )
            
            // Handle both new format (addressLine1, etc.) and old format (siteAddress)
            let smallWork: Project
            if let addressLine1 = data["addressLine1"] as? String,
               let townCity = data["townCity"] as? String,
               let postcode = data["postcode"] as? String {
                // New format
                var decodedSmallWork = Project(
                    id: UUID(uuidString: docId) ?? UUID(),
                    jobNumber: data["jobNumber"] as? String ?? "",
                    siteName: data["siteName"] as? String ?? "Unnamed Small Works",
                    addressLine1: addressLine1,
                    addressLine2: data["addressLine2"] as? String,
                    townCity: townCity,
                    postcode: postcode,
                    client: client,
                    startDate: startDate,
                    endDate: endDate,
                    jobType: jobType,
                    customJobType: customJobType,
                    manager: manager,
                    managerId: managerId,
                    managerIds: managerIds,
                    isLive: data["isLive"] as? Bool ?? true,
                    description: data["description"] as? String,
                    hiddenManagerUserIds: hiddenManagerUserIds,
                    hiddenOperativeUserIds: hiddenOperativeUserIds
                )
                Self.applyMapPinFields(from: data, to: &decodedSmallWork)
                smallWork = decodedSmallWork
            } else {
                // Legacy format - use old initializer
                var legacySmallWork = Project(
                    id: UUID(uuidString: docId) ?? UUID(),
                    jobNumber: data["jobNumber"] as? String ?? "",
                    siteName: data["siteName"] as? String ?? "Unnamed Small Works",
                    siteAddress: data["siteAddress"] as? String ?? "",
                    client: client,
                    startDate: startDate,
                    endDate: endDate,
                    jobType: jobType,
                    manager: manager,
                    isLive: data["isLive"] as? Bool ?? true,
                    description: data["description"] as? String,
                    hiddenManagerUserIds: hiddenManagerUserIds,
                    hiddenOperativeUserIds: hiddenOperativeUserIds
                )
                // Set managerId and customJobType after initialization since legacy initializer doesn't accept them
                legacySmallWork.managerId = managerId
                legacySmallWork.managerIds = managerIds
                legacySmallWork.customJobType = customJobType
                var legacySmallVar = legacySmallWork
                Self.applyMapPinFields(from: data, to: &legacySmallVar)
                smallWork = legacySmallVar
            }
            
            loadedSmallWorks.append(smallWork)
        }
        
        print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] ✅ Loaded \(loadedSmallWorks.count) small works, skipped \(skippedCount) documents")
        return loadedSmallWorks
    }
    
    func deleteSmallWorks(_ smallWork: Project, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteSmallWorks called for small works: \(smallWork.siteName), organization: \(organizationId)")
        try await db.collection("organizations").document(organizationId).collection("smallWorks").document(smallWork.id.uuidString).delete()
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
        let data: [String: Any] = [
            "jobTypes": Array(jobTypes),
            "organizationId": orgId,
            "updatedAt": Timestamp(date: Date())
        ]
        try await db.collection("organizations").document(orgId).collection("settings").document("jobTypes").setData(data)
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
            let parsed = parseJobTypeList(data["jobTypes"])
            if !parsed.isEmpty {
                print("🔥🔥🔥 DEBUG: Loaded \(parsed.count) job types from Firebase")
                return parsed
            }
        }
        print("🔥🔥🔥 DEBUG: No job types found in Firebase, returning empty set")
        return []
    }

    private func parseJobTypeList(_ raw: Any?) -> Set<String> {
        var names: [String] = []
        if let array = raw as? [String] {
            names = array
        } else if let array = raw as? [Any] {
            names = array.compactMap { item in
                if let s = item as? String { return s }
                if let map = item as? [String: Any] {
                    return (map["name"] as? String) ?? (map["rawValue"] as? String)
                }
                return nil
            }
        } else if let s = raw as? String {
            names = s.split(separator: ",").map(String.init)
        }
        return Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
    
    // MARK: - Project Task Management
    
    func loadProjectTasks(organizationId: String) async throws -> [ProjectTask] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: Loading tasks from Firebase for organization: \(orgId)")
        let tasksRef = db.collection("organizations").document(orgId).collection("tasks")
        let snapshot = try await getDocumentsPreferringServer(tasksRef)
        print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) task documents in Firebase")
        
        return snapshot.documents.compactMap { doc in
            let data = doc.data()
            guard let projectIdString = data["projectId"] as? String,
                  let projectId = UUID(uuidString: projectIdString),
                  let title = data["title"] as? String,
                  let createdBy = data["createdBy"] as? String,
                  let statusRaw = data["status"] as? String,
                  let status = ProjectTask.Status(rawValue: statusRaw),
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
            else {
                return nil
            }
            
            let assignedOperativeId: UUID?
            if let operativeIdString = data["assignedOperativeId"] as? String {
                assignedOperativeId = UUID(uuidString: operativeIdString)
            } else {
                assignedOperativeId = nil
            }
            
            let assignedManagerId: UUID?
            if let managerIdString = data["assignedManagerId"] as? String {
                assignedManagerId = UUID(uuidString: managerIdString)
            } else {
                assignedManagerId = nil
            }
            
            let dueDate = (data["dueDate"] as? Timestamp)?.dateValue()
            let details = data["details"] as? String
            let priorityRaw = data["priority"] as? String
            let priority = priorityRaw.flatMap { ProjectTask.Priority(rawValue: $0) } ?? .normal

            // Load multiple assignments
            var assignedOperativeIds: [UUID] = []
            if let operativeIdsArray = data["assignedOperativeIds"] as? [String] {
                assignedOperativeIds = operativeIdsArray.compactMap { UUID(uuidString: $0) }
            }
            
            var assignedManagerIds: [UUID] = []
            if let managerIdsArray = data["assignedManagerIds"] as? [String] {
                assignedManagerIds = managerIdsArray.compactMap { UUID(uuidString: $0) }
            }
            
            // Load completion info
            let completedBy = data["completedBy"] as? String
            let completedAt = (data["completedAt"] as? Timestamp)?.dateValue()
            let completionImages = data["completionImages"] as? [String] ?? []
            let completionFiles = data["completionFiles"] as? [String] ?? []
            let completionNotes = data["completionNotes"] as? String
            
            // Load attached files/images
            let attachedFileURL = data["attachedFileURL"] as? String
            let attachedFileName = data["attachedFileName"] as? String
            let attachedImageURLs = data["attachedImageURLs"] as? [String] ?? []
            let attachedSiteAuditId = (data["attachedSiteAuditId"] as? String).flatMap(UUID.init(uuidString:))
            let attachedSiteAuditTitle = data["attachedSiteAuditTitle"] as? String
            
            // Load items (multi-item tasks)
            var items: [ProjectTaskItem] = []
            if let itemsArray = data["items"] as? [[String: Any]] {
                for itemDict in itemsArray {
                    guard let idStr = itemDict["id"] as? String,
                          let itemId = UUID(uuidString: idStr),
                          let itemTitle = itemDict["title"] as? String else { continue }
                    let itemDesc = itemDict["description"] as? String
                    items.append(ProjectTaskItem(id: itemId, title: itemTitle, description: itemDesc))
                }
            }
            let completedItemIds: [UUID] = (data["completedItemIds"] as? [String])?.compactMap { UUID(uuidString: $0) } ?? []
            
            return ProjectTask(
                id: UUID(uuidString: doc.documentID) ?? UUID(),
                projectId: projectId,
                title: title,
                details: details,
                createdBy: createdBy,
                assignedOperativeId: assignedOperativeId,
                assignedManagerId: assignedManagerId,
                assignedOperativeIds: assignedOperativeIds,
                assignedManagerIds: assignedManagerIds,
                dueDate: dueDate,
                priority: priority,
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt,
                attachedFileURL: attachedFileURL,
                attachedFileName: attachedFileName,
                attachedImageURLs: attachedImageURLs,
                attachedSiteAuditId: attachedSiteAuditId,
                attachedSiteAuditTitle: attachedSiteAuditTitle,
                completedBy: completedBy,
                completedAt: completedAt,
                completionImages: completionImages,
                completionFiles: completionFiles,
                completionNotes: completionNotes,
                items: items,
                completedItemIds: completedItemIds
            )
        }
    }
    
    func saveProjectTask(_ task: ProjectTask, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: Saving task '\(task.title)' to Firebase for organization: \(organizationId)")
        var data: [String: Any] = [
            "organizationId": organizationId,
            "projectId": task.projectId.uuidString,
            "title": task.title,
            "details": task.details ?? "",
            "createdBy": task.createdBy,
            "status": task.status.rawValue,
            "priority": task.priority.rawValue,
            "createdAt": Timestamp(date: task.createdAt),
            "updatedAt": Timestamp(date: task.updatedAt)
        ]
        
        if let operativeId = task.assignedOperativeId {
            data["assignedOperativeId"] = operativeId.uuidString
        }
        
        if let managerId = task.assignedManagerId {
            data["assignedManagerId"] = managerId.uuidString
        }
        
        // Add multiple assignments
        if !task.assignedOperativeIds.isEmpty {
            data["assignedOperativeIds"] = task.assignedOperativeIds.map { $0.uuidString }
        }
        
        if !task.assignedManagerIds.isEmpty {
            data["assignedManagerIds"] = task.assignedManagerIds.map { $0.uuidString }
        }
        
        if let dueDate = task.dueDate {
            data["dueDate"] = Timestamp(date: dueDate)
        }
        
        // Add completion info
        if let completedBy = task.completedBy {
            data["completedBy"] = completedBy
        }
        
        if let completedAt = task.completedAt {
            data["completedAt"] = Timestamp(date: completedAt)
        }
        
        if !task.completionImages.isEmpty {
            data["completionImages"] = task.completionImages
        }
        
        if !task.completionFiles.isEmpty {
            data["completionFiles"] = task.completionFiles
        }
        
        if let notes = task.completionNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            data["completionNotes"] = notes
        }
        
        // Add attached images
        if !task.attachedImageURLs.isEmpty {
            data["attachedImageURLs"] = task.attachedImageURLs
        }
        if let fileURL = task.attachedFileURL, !fileURL.isEmpty {
            data["attachedFileURL"] = fileURL
        }
        if let fileName = task.attachedFileName, !fileName.isEmpty {
            data["attachedFileName"] = fileName
        }
        if let auditId = task.attachedSiteAuditId {
            data["attachedSiteAuditId"] = auditId.uuidString
        }
        if let auditTitle = task.attachedSiteAuditTitle, !auditTitle.isEmpty {
            data["attachedSiteAuditTitle"] = auditTitle
        }
        
        // Add items and completedItemIds (multi-item tasks)
        if !task.items.isEmpty {
            data["items"] = task.items.map { item in
                [
                    "id": item.id.uuidString,
                    "title": item.title,
                    "description": item.description ?? ""
                ]
            }
        }
        if !task.completedItemIds.isEmpty {
            data["completedItemIds"] = task.completedItemIds.map { $0.uuidString }
        }
        
        try await db.collection("organizations").document(organizationId).collection("tasks").document(task.id.uuidString).setData(data)
        print("🔥🔥🔥 DEBUG: Task '\(task.title)' saved successfully to Firebase")
    }
    
    func deleteProjectTask(taskId: UUID, organizationId: String) async throws {
        try await db.collection("organizations").document(organizationId).collection("tasks").document(taskId.uuidString).delete()
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
        operativeId: UUID,
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
            operativeId: operativeId.uuidString,
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
        try await db.collection("organizations").document(orgId).updateData(payload)
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
        operativeId: UUID,
        qualificationId: String,
        fileName: String,
        contentType: String
    ) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }
    #endif
    
    // MARK: - Operative Management
    
    func saveOperative(_ operative: Operative, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: saveOperative called with organizationId: \(organizationId)")
        print("🔥🔥🔥 DEBUG: Operative details - Name: \(operative.name), ID: \(operative.id.uuidString)")
        print("🔥🔥🔥 DEBUG: Operative email: \(operative.email), phone: \(operative.phone ?? "nil")")
        print("🔥🔥🔥 DEBUG: Operative skills: \(Array(operative.skills))")
        
            let data: [String: Any] = [
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
                "hourlyRate": operative.hourlyRate ?? 0,
                "currencySymbol": operative.currencySymbol ?? "£",
            "notes": operative.notes ?? "",
            "dayRate": operative.dayRate ?? 0,
            "tradeTypePreset": operative.tradeTypePreset ?? "",
            "tradeTypeCustom": operative.tradeTypeCustom ?? "",
            "qualificationExpiryDates": Dictionary(uniqueKeysWithValues: operative.qualificationExpiryDates.map { ($0.key, Timestamp(date: $0.value)) }),
            "qualificationCertificateURLs": Dictionary(uniqueKeysWithValues: operative.qualificationCertificateURLs.map { ($0.key, $0.value) }),
            "organizationId": organizationId,
            "createdAt": Timestamp(date: operative.createdAt),
            "updatedAt": Timestamp(date: operative.updatedAt)
        ]
        
        print("🔥🔥🔥 DEBUG: Data to save: \(data)")
        print("🔥🔥🔥 DEBUG: Saving operative to organizations/\(organizationId)/operatives/\(operative.id.uuidString)")
        
        do {
            try await db.collection("organizations").document(organizationId).collection("operatives").document(operative.id.uuidString).setData(data)
            print("🔥🔥🔥 DEBUG: Operative saved successfully to Firebase")
        } catch {
            print("🔥🔥🔥 DEBUG: ERROR saving operative: \(error.localizedDescription)")
            throw error
        }
    }

    /// Merges qualification maps onto the operative document. Other fields stay.
    func patchOperativeQualificationMaps(
        operativeId: UUID,
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
        try await db.collection("organizations").document(orgId).collection("operatives").document(operativeId.uuidString).setData(payload, merge: true)
    }
    
    func deleteOperative(operativeId: UUID, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: deleteOperative called for operative: \(operativeId.uuidString), organization: \(organizationId)")
        
        // Delete all bookings for this operative
        let bookingsSnapshot = try await db.collection("organizations").document(organizationId).collection("bookings")
            .whereField("operativeId", isEqualTo: operativeId.uuidString)
            .getDocuments()
        
        print("🔥🔥🔥 DEBUG: Found \(bookingsSnapshot.documents.count) bookings to delete for operative")
        
        // Delete each booking
        for bookingDoc in bookingsSnapshot.documents {
            try await bookingDoc.reference.delete()
            print("🔥🔥🔥 DEBUG: Deleted booking: \(bookingDoc.documentID)")
        }
        
        // Delete the operative
        try await db.collection("organizations").document(organizationId).collection("operatives").document(operativeId.uuidString).delete()
        print("🔥🔥🔥 DEBUG: Operative and \(bookingsSnapshot.documents.count) bookings deleted successfully from Firebase")
    }
    
    func loadOperatives(organizationId: String) async throws -> [Operative] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Starting load for organization: \(orgId)")
        let operativesRef = db.collection("organizations").document(orgId).collection("operatives")
        let snapshot = try await getDocumentsPreferringServer(operativesRef)
        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Found \(snapshot.documents.count) operative documents")
        
        // Filter out legacy INITIAL-PLACEHOLDER documents and junk seed rows
        let loaded = snapshot.documents.compactMap { (doc: QueryDocumentSnapshot) -> Operative? in
            // Skip legacy placeholder documents
            if doc.documentID == "INITIAL-PLACEHOLDER" {
                return nil
            }
            let data = doc.data()
            let nameLower = (data["name"] as? String ?? "").lowercased()
            let emailLower = (data["email"] as? String ?? "").lowercased()
            if nameLower.contains("placeholder")
                || emailLower.contains("placeholder")
                || nameLower.contains("initial operative") {
                return nil
            }
            
            // A missing start date or skills list used to drop the whole person, which then hid their bookings.
            let startDate = (data["startDate"] as? Timestamp)?.dateValue()
                ?? (data["createdAt"] as? Timestamp)?.dateValue()
                ?? Date()
            let skills = Set(data["skills"] as? [String] ?? [])
            
            // Parse qualifications
            var qualifications: Set<Qualification> = []
            if let qualificationsArray = data["qualifications"] as? [[String: Any]] {
                for qualificationData in qualificationsArray {
                    if let idString = qualificationData["id"] as? String,
                       !idString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let name = qualificationData["name"] as? String,
                       let hasEndDate = qualificationData["hasEndDate"] as? Bool,
                       let createdAt = (qualificationData["createdAt"] as? Timestamp)?.dateValue(),
                       let updatedAt = (qualificationData["updatedAt"] as? Timestamp)?.dateValue() {

                        let endDate = (qualificationData["endDate"] as? Timestamp)?.dateValue()

                        let qualification = Qualification(
                            id: idString,
                            name: name,
                            hasEndDate: hasEndDate,
                            endDate: endDate,
                            createdAt: createdAt,
                            updatedAt: updatedAt
                        )
                        
                        qualifications.insert(qualification)
                    }
                }
            }
            
            var qualificationExpiryDates: [String: Date] = [:]
            if let expiryMap = data["qualificationExpiryDates"] as? [String: Any] {
                for (key, rawDate) in expiryMap {
                    let qualificationId = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !qualificationId.isEmpty else { continue }
                    if let ts = rawDate as? Timestamp {
                        qualificationExpiryDates[qualificationId] = ts.dateValue()
                    } else if let date = rawDate as? Date {
                        qualificationExpiryDates[qualificationId] = date
                    }
                }
            }

            var qualificationCertificateURLs: [String: String] = [:]
            if let certificateMap = data["qualificationCertificateURLs"] as? [String: String] {
                for (key, url) in certificateMap {
                    let qualificationId = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !qualificationId.isEmpty else { continue }
                    qualificationCertificateURLs[qualificationId] = url
                }
            } else if let certificateMapAny = data["qualificationCertificateURLs"] as? [String: Any] {
                for (key, rawURL) in certificateMapAny {
                    let qualificationId = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !qualificationId.isEmpty, let url = rawURL as? String else { continue }
                    qualificationCertificateURLs[qualificationId] = url
                }
            }
            
                // Load firstName and lastName if available, otherwise parse from name (backward compatibility)
                let firstName: String
                let lastName: String
                if let loadedFirstName = data["firstName"] as? String,
                   let loadedLastName = data["lastName"] as? String {
                    firstName = loadedFirstName
                    lastName = loadedLastName
                } else if let name = data["name"] as? String {
                    // Legacy format - parse name into firstName and lastName
                    let nameParts = name.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                    firstName = nameParts.count > 0 ? String(nameParts[0]) : name
                    lastName = nameParts.count > 1 ? String(nameParts[1]) : ""
                } else {
                    firstName = ""
                    lastName = ""
                }
                
                let loadedHourly = data["hourlyRate"] as? Double
                let loadedDay = data["dayRate"] as? Double
                let tp = (data["tradeTypePreset"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let tc = (data["tradeTypeCustom"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let operative = Operative(
                    id: UUID(uuidString: doc.documentID) ?? UUID(),
                    firstName: firstName,
                    lastName: lastName,
                    email: data["email"] as? String ?? "",
                    phone: data["phone"] as? String ?? "",
                    startDate: startDate,
                    skills: skills,
                    qualifications: Array(qualifications),
                    qualificationExpiryDates: qualificationExpiryDates,
                    qualificationCertificateURLs: qualificationCertificateURLs,
                    isActive: firestoreBool(data["isActive"]) ?? true,
                    hourlyRate: loadedHourly,
                    dayRate: loadedDay ?? loadedHourly,
                    currencySymbol: data["currencySymbol"] as? String,
                    notes: data["notes"] as? String,
                    tradeTypePreset: (tp?.isEmpty == false) ? tp : nil,
                    tradeTypeCustom: (tc?.isEmpty == false) ? tc : nil,
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                    updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
                )
                return operative
            }

        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Keeping \(loaded.count) real operatives (placeholders skipped)")
        return loaded
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
            try await saveProject(testProject, organizationId: organizationId)
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
            try await saveProject(testProject, organizationId: organizationId)
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
        
        func saveManager(_ manager: Manager, organizationId: String) async throws {
            print("🔥🔥🔥 DEBUG: saveManager called with organizationId: \(organizationId)")
            
            let data: [String: Any] = [
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
                "createdAt": Timestamp(date: manager.createdAt),
                "updatedAt": Timestamp(date: Date())
            ]
            
            let documentId = manager.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines)
            let storageId = documentId.isEmpty ? manager.id.uuidString : documentId
            print("🔥🔥🔥 DEBUG: Saving manager to organizations/\(organizationId)/managers/\(storageId)")
            
            try await db.collection("organizations").document(organizationId).collection("managers").document(storageId).setData(data)
            
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
            
            var managers: [Manager] = []
            
            for doc in snapshot.documents {
                let data = doc.data()
                
                guard let firstName = data["firstName"] as? String,
                      let lastName = data["lastName"] as? String,
                      let email = data["email"] as? String else {
                    print("🔥🔥🔥 DEBUG: Failed to parse manager data for document: \(doc.documentID)")
                    continue
                }
                let isActive = firestoreBool(data["isActive"]) ?? true
                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
                let mobileNumber = (data["mobileNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                let documentId = doc.documentID.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = Manager.stableId(forFirestoreDocumentId: documentId)
                let department = data["department"] as? String
                let notes = data["notes"] as? String
                
                let mtp = (data["tradeTypePreset"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let mtc = (data["tradeTypeCustom"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                var manager = Manager(
                    id: id,
                    firstName: firstName,
                    lastName: lastName,
                    email: email,
                    mobileNumber: mobileNumber,
                    department: department,
                    isActive: isActive,
                    notes: notes,
                    tradeTypePreset: (mtp?.isEmpty == false) ? mtp : nil,
                    tradeTypeCustom: (mtc?.isEmpty == false) ? mtc : nil,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    firestoreDocumentId: documentId
                )
                
                // Set the actual dates from Firebase
                manager.createdAt = createdAt
                manager.updatedAt = updatedAt
                
                managers.append(manager)
            }
            
            // Exclude legacy/placeholder managers (e.g. "Initial manager placeholder system") so only real users appear in the app
            return managers.filter { manager in
                let name = manager.fullName.lowercased()
                let email = manager.email.lowercased()
                return !name.contains("placeholder") && !email.contains("placeholder")
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
    
    func saveSkills(organizationId: String, skills: [OrganizationSkill]) async throws {
        let skillsRef = db.collection("organizations").document(organizationId).collection("skills")
        let existingSnapshot = try await skillsRef.getDocuments()
        let newIds = Set(skills.map(\.id))
        let batch = db.batch()
        for document in existingSnapshot.documents where !newIds.contains(document.documentID) {
            batch.deleteDocument(document.reference)
        }
        let now = Date()
        for skill in skills {
            let docRef = skillsRef.document(skill.id)
            let data: [String: Any] = [
                "name": skill.name,
                "trade": skill.trade,
                "createdAt": Timestamp(date: skill.createdAt),
                "updatedAt": Timestamp(date: now)
            ]
            batch.setData(data, forDocument: docRef, merge: true)
        }
        try await batch.commit()
        print("🔥🔥🔥 DEBUG: Successfully saved \(skills.count) organisation skills to Firebase")
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
        
        return qualifications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func loadSkills(organizationId: String) async throws -> [OrganizationSkill] {
        let orgId = try await ensureReadableOrganization(organizationId)
        let snapshot = try await db.collection("organizations").document(orgId).collection("skills").getDocuments(source: .server)
        
        var skills: [OrganizationSkill] = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            guard let skillName = data["name"] as? String else { continue }
            let tradeRaw = (data["trade"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trade = tradeRaw.isEmpty ? OrganizationSkill.defaultTrade : tradeRaw
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt
            skills.append(OrganizationSkill(id: doc.documentID, name: skillName, trade: trade, createdAt: createdAt, updatedAt: updatedAt))
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
            try await db.collection("organizations").document(organizationId).collection("operatives").document(operativeId.uuidString).delete()
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
    
    static func parseAppUserDocument(userId: String, data: [String: Any]) -> AppUser {
        let email = data["email"] as? String ?? ""
        let organizationId = organizationIdFromFirestore(data["organizationId"]) ?? ""
        let role = Self.roleFromStoredToken(data["role"] as? String)
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let nestedPermissions = data["permissions"] as? [String: Any] ?? [:]

        // Top-level flag wins when it is actually stored. Nested `permissions` covers website / older writes.
        // `as? Bool` is not used: Firestore may return 0/1 or "true", and that used to zero every flag.
        // Role text and operative/manager records do not invent these flags.
        func flag(_ key: String, default defaultValue: Bool) -> Bool {
            if let top = firestoreBool(data[key]) { return top }
            if let nested = firestoreBool(nestedPermissions[key]) { return nested }
            return defaultValue
        }

        let operativeMode = flag("operativeMode", default: false)
        let adminAccess = flag("adminAccess", default: false)
        let manager = flag("manager", default: false)
        let isSuperAdmin = flag("isSuperAdmin", default: false)

        let permissions = UserPermissions(
            adminAccess: adminAccess,
            manager: manager,
            operatives: operativeMode ? false : flag("operatives", default: false),
            skills: false,
            qualifications: operativeMode ? false : flag("qualifications", default: false),
            materials: operativeMode ? flag("materials", default: false) : flag("materials", default: true),
            projects: operativeMode ? true : flag("projects", default: false),
            smallWorks: operativeMode ? true : flag("smallWorks", default: false),
            operativeMode: operativeMode,
            annualLeaveSelfBook: flag("annualLeaveSelfBook", default: false),
            weeklyReports: flag("weeklyReports", default: false),
            dailyOverview: flag("dailyOverview", default: true),
            subContractors: flag("subContractors", default: false),
            siteAudit: flag("siteAudit", default: true),
            wholesalersOrderHistory: flag("wholesalersOrderHistory", default: true)
        )
        let policyAccepted = flag("policyAccepted", default: false)
        let policyAcceptedAt = (data["policyAcceptedAt"] as? Timestamp)?.dateValue()
        let resolvedRole = role
        
        let assignedManagerUserId = data["assignedManagerUserId"] as? String
        let assignedManagerUserIdsRaw = data["assignedManagerUserIds"] as? [String] ?? []
        let assignedManagerUserIds: [String] = {
            var ids = assignedManagerUserIdsRaw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if ids.isEmpty,
               let legacy = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !legacy.isEmpty {
                ids = [legacy]
            }
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }()
        let dayRate = data["dayRate"] as? Double
        let hourlyRate = data["hourlyRate"] as? Double
        let utp = (data["tradeTypePreset"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let utc = (data["tradeTypeCustom"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profilePhotoRaw = (data["profilePhotoURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastSeenAt = (data["lastSeenAt"] as? Timestamp)?.dateValue()
        let employmentTypeRaw = (data["employmentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let employmentType = EmploymentType.fromCanonical(employmentTypeRaw)
        let transitionFromRaw = (data["employmentTypeTransitionFrom"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let employmentTypeTransitionFrom = transitionFromRaw.flatMap { raw -> EmploymentType? in
            guard !raw.isEmpty else { return nil }
            return EmploymentType.fromCanonical(raw)
        }
        let employmentTypeEffectiveAt = (data["employmentTypeEffectiveAt"] as? Timestamp)?.dateValue()
        let alDays = (data["annualLeaveDaysPerYear"] as? NSNumber)?.doubleValue
            ?? (data["annualLeaveDaysPerYear"] as? Double)
            ?? AnnualLeavePolicy.defaultDaysPerYear
        let alStart = (data["annualLeaveYearStartMonth"] as? NSNumber)?.intValue
            ?? (data["annualLeaveYearStartMonth"] as? Int)
            ?? AnnualLeavePolicy.defaultStartMonth
        let alEnd = (data["annualLeaveYearEndMonth"] as? NSNumber)?.intValue
            ?? (data["annualLeaveYearEndMonth"] as? Int)
            ?? AnnualLeavePolicy.defaultEndMonth
        let alCarry = flag("annualLeaveCarriesOver", default: AnnualLeavePolicy.defaultCarriesOver)
        let yearAllowance = (data["annualLeaveYearAllowance"] as? NSNumber)?.doubleValue
            ?? (data["annualLeaveYearAllowance"] as? Double)
        let yearAllowanceKey = (data["annualLeaveYearAllowanceKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alEnabled = flag("annualLeaveEnabled", default: true)
        let hasNoLineManager = flag("hasNoLineManager", default: false)
        let timesheetsEnabledRaw = firestoreBool(data["timesheetsEnabled"]) ?? firestoreBool(nestedPermissions["timesheetsEnabled"])
        let timesheetsEnabled = timesheetsEnabledRaw ?? AppUser.defaultTimesheetsEnabled(for: permissions, employmentType: employmentType)
        let vatRaw = (data["vatNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let utrRaw = (data["utrNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let parsedName = Self.personName(from: data)
        var parsed = AppUser(
            id: userId,
            email: email,
            organizationId: organizationId,
            role: resolvedRole,
            createdAt: createdAt,
            firstName: parsedName.first,
            surname: parsedName.surname,
            mobileNumber: data["mobileNumber"] as? String,
            isActive: firestoreUserIsActive(from: data),
            passwordSet: {
                // Invites write `passwordSet: false`. A missing field is an existing account.
                // Treating missing as false moved every legacy manager and operative onto Pending,
                // and the screens open on Active, so the lists looked empty.
                let stored = firestoreBool(data["passwordSet"]) ?? firestoreBool(nestedPermissions["passwordSet"])
                return stored ?? true
            }(),
            permissions: permissions,
            isSuperAdmin: isSuperAdmin,
            policyAccepted: policyAccepted,
            policyAcceptedAt: policyAcceptedAt,
            legalPackVersion: data["legalPackVersion"] as? String,
            assignedManagerUserId: assignedManagerUserIds.first ?? assignedManagerUserId,
            assignedManagerUserIds: assignedManagerUserIds,
            hasNoLineManager: hasNoLineManager,
            dayRate: dayRate,
            hourlyRate: hourlyRate,
            tradeTypePreset: (utp?.isEmpty == false) ? utp : nil,
            tradeTypeCustom: (utc?.isEmpty == false) ? utc : nil,
            profilePhotoURL: (profilePhotoRaw?.isEmpty == false) ? profilePhotoRaw : nil,
            lastSeenAt: lastSeenAt,
            employmentType: employmentType,
            employmentTypeTransitionFrom: employmentTypeTransitionFrom,
            employmentTypeEffectiveAt: employmentTypeEffectiveAt,
            annualLeaveEnabled: alEnabled,
            annualLeaveDaysPerYear: alDays,
            annualLeaveYearStartMonth: alStart,
            annualLeaveYearEndMonth: alEnd,
            annualLeaveCarriesOver: alCarry,
            annualLeaveYearAllowance: yearAllowance,
            annualLeaveYearAllowanceKey: (yearAllowanceKey?.isEmpty == false) ? yearAllowanceKey : nil,
            timesheetsEnabled: timesheetsEnabled,
            vatNumber: (vatRaw?.isEmpty == false) ? vatRaw : nil,
            utrNumber: (utrRaw?.isEmpty == false) ? utrRaw : nil
        )
        parsed.documentName = data["name"] as? String ?? ""
        parsed.documentDisplayName = data["displayName"] as? String ?? ""
        parsed.formerUserIds = CanonicalBusinessEngine.parseFormerUserIds(data["formerUserIds"]) ?? []
        return parsed
    }
    
    /// Reads the name the list shows. Website rows sometimes store `lastName` or a single `name`.
    private static func personName(from data: [String: Any]) -> (first: String, surname: String) {
        func text(_ key: String) -> String {
            (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var first = text("firstName")
        var surname = text("surname")
        if surname.isEmpty { surname = text("lastName") }
        if first.isEmpty && surname.isEmpty {
            let combined = text("displayName").isEmpty ? text("name") : text("displayName")
            let parts = combined.split(separator: " ", maxSplits: 1).map(String.init)
            if let given = parts.first, !given.isEmpty { first = given }
            if parts.count > 1 { surname = parts[1] }
        }
        return (first, surname)
    }

    /// "Manager", "managers", "administrator", and the org members-map token all count.
    /// A strict `UserRole(rawValue:)` miss used to leave the person on no list.
    private static func roleFromStoredToken(_ raw: String?) -> UserRole {
        let token = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if token.contains("operat") { return .operative }
        if token.contains("admin") { return .admin }
        if token.contains("manag") { return .manager }
        return UserRole(rawValue: token) ?? .viewer
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

        // Same email, two documents: keep the account they actually sign in with.
        // An empty email must not collapse every nameless document into one row.
        var byKey: [String: AppUser] = [:]
        for user in users {
            let emailKey = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let key = emailKey.isEmpty ? "id:\(user.id)" : emailKey
            if let existing = byKey[key] {
                let chosen = Self.collapsedRosterUser(existing, user)
                if chosen.id != existing.id {
                    print("🔥🔥🔥 DEBUG: Preferring user doc \(chosen.id) over \(existing.id) for \(key)")
                }
                byKey[key] = chosen
            } else {
                byKey[key] = user
            }
        }
        let uniqueUsers = Array(byKey.values)

        print("🔥🔥🔥 DEBUG: Returning \(uniqueUsers.count) unique users")
        let claimedEmails: Set<String>? = memberIndex.emailClaimsLoaded ? Set(memberIndex.userIdByEmail.keys) : nil
        return OrganizationUserRoster(users: uniqueUsers, claimedEmails: claimedEmails)
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
        var payload: [String: Any] = ["updatedAt": Timestamp(date: Date())]
        for (key, value) in Self.warningDetectionFirestoreMap(settings) {
            payload["warningDetection.\(key)"] = value
        }
        let orgRef = db.collection("organizations").document(orgId)
        do {
            try await orgRef.updateData(payload)
        } catch {
            try await orgRef.setData(
                [
                    "warningDetection": Self.warningDetectionFirestoreMap(settings),
                    "updatedAt": Timestamp(date: Date()),
                ],
                merge: true
            )
        }
        guard var org = currentOrganization else { return }
        org.settings.warningDetection = settings
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Keep a saved look-ahead when a later read is the factory default.
    /// Payment runs are not decided here — they always come from the live document.
    static func detectionForWarningScan(
        current: OrgWarningDetectionSettings,
        loaded: OrgWarningDetectionSettings
    ) -> OrgWarningDetectionSettings {
        if loaded == .default, current != .default {
            return current
        }
        return loaded
    }

    /// Re-reads the organisation document. Payment runs always come from this live read.
    /// A factory-default detection payload does not replace a saved look-ahead mode.
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

    /// Admin: apply working-hours changes immediately (today onward).
    func applyOrganizationPayrollTimePolicyImmediately(_ policy: OrgPayrollTimePolicy) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        let today = Calendar.current.startOfDay(for: Date())
        let prior = currentOrganization?.settings.payrollTimePolicy
        var payload: [String: Any] = [
            "payrollTimePolicy": policy.asFirestoreDictionary(),
            "payrollTimePolicyEffectiveFrom": PayrollTimePolicyCatalog.dayKey(today),
            "payrollTimePolicyScheduled": NSNull(),
            "updatedAt": Timestamp(date: Date()),
        ]
        if let prior {
            payload["payrollTimePolicyPrior"] = prior.asFirestoreDictionary()
        }
        try await db.collection("organizations").document(orgId).setData(payload, merge: true)
        guard var org = currentOrganization else { return }
        org.payrollTimePolicyPrior = prior
        org.payrollTimePolicyEffectiveFrom = today
        org.payrollTimePolicyScheduled = nil
        org.settings.payrollTimePolicy = policy
        org.settings.workingHours.startTime = policy.standardDayStart
        org.settings.workingHours.endTime = policy.standardDayEnd
        org.settings.workingHours.lunchBreak = policy.unpaidBreakMinutes
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }

    /// Admin: queue a future working-hours change (replaces any pending schedule).
    func scheduleOrganizationPayrollTimePolicyChange(_ policy: OrgPayrollTimePolicy, effectiveFrom: Date) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        let day = Calendar.current.startOfDay(for: effectiveFrom)
        let scheduled = OrgPayrollTimePolicyScheduledChange(policy: policy, effectiveFrom: day)
        try await db.collection("organizations").document(orgId).setData(
            [
                "payrollTimePolicyScheduled": scheduled.asFirestoreDictionary(),
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
        )
        guard var org = currentOrganization else { return }
        org.payrollTimePolicyScheduled = scheduled
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
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
        let previous = currentOrganization?.settings.invoicing ?? settings
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
        let snap = try await db.collection("organizations").document(orgId).getDocument()
        var merged = (snap.data()?["invoicing"] as? [String: Any]) ?? [:]
        for (key, value) in written {
            merged[key] = value
        }
        try await db.collection("organizations").document(orgId).setData(
            [
                "invoicing": merged,
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
        )
        guard var org = currentOrganization else { return }
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
        try await db.collection("organizations").document(orgId).setData(
            [
                "annualLeaveDefaults": payload,
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
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
        try await db.collection("organizations").document(orgId).setData(
            [
                "bankHolidayRegionId": trimmed,
                "settings.bankHolidayRegionId": trimmed,
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
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
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Select an annual leave / bank holiday region."]
            )
        }
        let payload: [String: Any] = [
            "daysPerYear": defaults.daysPerYear,
            "startMonth": defaults.startMonth,
            "endMonth": defaults.endMonth,
            "carriesOver": defaults.carriesOver,
        ]
        try await db.collection("organizations").document(orgId).setData(
            [
                "annualLeaveDefaults": payload,
                "bankHolidayRegionId": trimmed,
                "settings.bankHolidayRegionId": trimmed,
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
        )
        guard var org = currentOrganization else { return }
        org.settings.annualLeaveDefaults = defaults
        org.settings.bankHolidayRegionId = trimmed
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
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard OrganizationCurrencyCatalog.all.contains(where: { $0.code == trimmed }) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Select a supported currency."]
            )
        }
        try await db.collection("organizations").document(orgId).setData(
            [
                "currencyCode": trimmed,
                "settings.currencyCode": trimmed,
                "updatedAt": Timestamp(date: Date()),
            ],
            merge: true
        )
        guard var org = currentOrganization else { return }
        org.settings.currencyCode = trimmed
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
            [
                "settings.materialCutOff": payload,
                "updatedAt": Timestamp(date: Date()),
            ]
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
        try await db.collection("organizations").document(orgId).updateData(
            [
                "settings.myScheduleOptions": options.asFirestoreDictionary(),
                "updatedAt": Timestamp(date: Date()),
            ]
        )
        guard var org = currentOrganization else { return }
        org.settings.myScheduleOptions = options
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
        officeCity: String?,
        officePostcode: String?,
        countryCode: String,
        defaultLatitude: Double?,
        defaultLongitude: Double?,
        documentAbbreviation: String?
    ) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        let existingName = CanonicalBusinessEngine.coalesceOrganizationName([currentOrganization?.name]) ?? ""
        guard let nameFields = CanonicalBusinessEngine.organizationNameWriteFields(name, existingName: existingName) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Could not save the organisation name."]
            )
        }
        var payload: [String: Any] = nameFields
        payload["countryCode"] = countryCode.uppercased()
        payload["updatedAt"] = Timestamp(date: Date())
        if hasOfficeAddress {
            let line1 = officeAddressLine1?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let city = officeCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            payload["officeAddressLine1"] = line1
            payload["officeCity"] = city
            let pc = officePostcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pc.isEmpty {
                payload["officePostcode"] = FieldValue.delete()
            } else {
                payload["officePostcode"] = pc
            }
        } else {
            payload["officeAddressLine1"] = FieldValue.delete()
            payload["officeCity"] = FieldValue.delete()
            payload["officePostcode"] = FieldValue.delete()
        }
        if let defaultLatitude, let defaultLongitude {
            payload["defaultLatitude"] = defaultLatitude
            payload["defaultLongitude"] = defaultLongitude
        }
        let abbreviation = OrganizationDocumentAbbreviation.normalized(documentAbbreviation)
        if let abbreviation {
            payload["documentAbbreviation"] = abbreviation
        } else {
            payload["documentAbbreviation"] = FieldValue.delete()
        }
        try await db.collection("organizations").document(orgId).updateData(payload)
        
        guard var org = currentOrganization else { return }
        if let writtenName = nameFields["name"] as? String, !writtenName.isEmpty {
            org.name = writtenName
        } else if let kept = CanonicalBusinessEngine.coalesceOrganizationName([existingName, org.name]) {
            org.name = kept
        }
        org.countryCode = countryCode.uppercased()
        org.documentAbbreviation = abbreviation
        if hasOfficeAddress {
            let line1 = officeAddressLine1?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let city = officeCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pc = officePostcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            org.officeAddressLine1 = line1.isEmpty ? nil : line1
            org.officeCity = city.isEmpty ? nil : city
            org.officePostcode = pc.isEmpty ? nil : pc
        } else {
            org.officeAddressLine1 = nil
            org.officeCity = nil
            org.officePostcode = nil
        }
        org.defaultLatitude = defaultLatitude
        org.defaultLongitude = defaultLongitude
        org.updatedAt = Date()
        currentOrganization = org
        storeOrganizationLocally(org)
    }
    
    func saveUser(_ user: AppUser) async throws {
        // Operative mode does not demote an admin. Tab order is admin, then operativeMode, then manager.
        let keepAdmin = user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin
        let operativeOnly = user.permissions.operativeMode && !keepAdmin
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
            "operativeMode": user.permissions.operativeMode,
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
                "operativeMode": user.permissions.operativeMode,
                "siteAudit": operativeOnly ? user.permissions.siteAudit : true,
                "subContractors": user.permissions.subContractors,
                "wholesalersOrderHistory": user.permissions.wholesalersOrderHistory,
                "annualLeaveSelfBook": user.permissions.annualLeaveSelfBook,
                "weeklyReports": user.permissions.weeklyReports,
                "dailyOverview": user.permissions.dailyOverview,
            ] as [String: Bool],
            "isSuperAdmin": isSuperAdminToSave,
            "policyAccepted": user.policyAccepted,
            "employmentType": user.employmentType.rawValue,
            "updatedAt": Timestamp(date: Date())
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
        
        if let dr = user.dayRate {
            userData["dayRate"] = dr
        }
        if let hr = user.hourlyRate {
            userData["hourlyRate"] = hr
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
        
        userData["annualLeaveDaysPerYear"] = AnnualLeavePolicy.clampDaysPerYear(user.annualLeaveDaysPerYear)
        userData["annualLeaveYearStartMonth"] = AnnualLeavePolicy.clampMonth(user.annualLeaveYearStartMonth)
        userData["annualLeaveYearEndMonth"] = AnnualLeavePolicy.clampMonth(user.annualLeaveYearEndMonth)
        userData["annualLeaveCarriesOver"] = user.annualLeaveCarriesOver
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

        if sessionsAreSeparate(for: user) {
            try await saveSeparateDeviceSession(user, payload: userData)
            return
        }
        // Merge keeps `notificationPreferences`, `pushTokens`, and `pushTokenUpdatedAt`.
        // Those keys are on USER_DOCUMENT_FIELDS and are not part of this profile payload.
        try await db.collection("users").document(user.id).setData(userData, merge: true)
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
    
    func updateUserProfilePhotoURL(userId: String, url: String?) async throws {
        var payload: [String: Any] = ["updatedAt": Timestamp(date: Date())]
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            payload["profilePhotoURL"] = url
        } else {
            payload["profilePhotoURL"] = FieldValue.delete()
        }
        try await db.collection("users").document(userId).updateData(payload)
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

    /// Patch-only update for operative profile metadata managed from Manage Users.
    /// Writes only targeted fields to avoid rules rejecting unrelated user fields.
    func updateOperativeProfileMetadata(
        userId: String,
        assignedManagerUserId: String?,
        assignedManagerUserIds: [String]? = nil,
        hasNoLineManager: Bool? = nil,
        dayRate: Double?,
        updateDayRate: Bool = true
    ) async throws {
        var payload: [String: Any] = [
            "updatedAt": Timestamp(date: Date())
        ]
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
            if let dayRate {
                payload["dayRate"] = dayRate
            } else {
                payload["dayRate"] = FieldValue.delete()
            }
        }
        try await db.collection("users").document(userId).updateData(payload)
    }

    func updateUserDayRateMetadata(userId: String, dayRate: Double?) async throws {
        var payload: [String: Any] = [
            "updatedAt": Timestamp(date: Date())
        ]
        if let dayRate {
            payload["dayRate"] = dayRate
        } else {
            payload["dayRate"] = FieldValue.delete()
        }
        try await db.collection("users").document(userId).updateData(payload)
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

    /// Cloud fallback for operative metadata when direct users/{userId} updates are denied by rules.
    /// Stored at organizations/{orgId}/operativeProfiles/{userId} and merged on user load.
    func saveOperativeProfileMetadataFallback(
        organizationId: String,
        userId: String,
        assignedManagerUserId: String?,
        dayRate: Double?
    ) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let ref = db.collection("organizations")
            .document(orgId)
            .collection("operativeProfiles")
            .document(userId)

        var payload: [String: Any] = [
            "userId": userId,
            "updatedAt": Timestamp(date: Date())
        ]
        if let managerId = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !managerId.isEmpty {
            payload["assignedManagerUserId"] = managerId
        } else {
            payload["assignedManagerUserId"] = FieldValue.delete()
        }
        if let dayRate {
            payload["dayRate"] = dayRate
        } else {
            payload["dayRate"] = FieldValue.delete()
        }

        do {
            try await ref.updateData(payload)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 5 {
                var createPayload: [String: Any] = [
                    "userId": userId,
                    "updatedAt": Timestamp(date: Date())
                ]
                if let managerId = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !managerId.isEmpty {
                    createPayload["assignedManagerUserId"] = managerId
                }
                if let dayRate {
                    createPayload["dayRate"] = dayRate
                }
                try await ref.setData(createPayload, merge: true)
            } else {
                throw error
            }
        }
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
        for doc in snapshot.documents {
            let data = doc.data()
            let userId = (data["userId"] as? String) ?? doc.documentID
            mapped[userId] = OperativeProfileMetadata(
                userId: userId,
                assignedManagerUserId: data["assignedManagerUserId"] as? String,
                dayRate: data["dayRate"] as? Double
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

    func registerPushToken(_ token: String) async {
        guard let authUser = currentUser else { return }
        let uid = authUser.uid
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await writePushTokens(userId: uid, currentDeviceToken: trimmed)
            // Backward compatibility: invitations may still reference legacy users/{placeholderId}.
            // Mirror this token into same-email docs so targeted push still works during id convergence.
            let normalizedEmail = authUser.email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedEmail.isEmpty,
               let orgId = currentOrganization?.firestoreDocumentId,
               !orgId.isEmpty {
                // Same company only. With no open company this mirror is skipped, and users are not listed by email.
                let orgUsers = try await db.collection("users")
                    .whereField("organizationId", isEqualTo: orgId)
                    .limit(to: 250)
                    .getDocuments(source: .server)
                let candidateDocs = orgUsers.documents.filter { doc in
                    let email = (doc.data()["email"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() ?? ""
                    return !email.isEmpty && email == normalizedEmail
                }
                for doc in candidateDocs where doc.documentID != uid {
                    try await writePushTokens(userId: doc.documentID, currentDeviceToken: trimmed)
                    print("🔥🔥🔥 DEBUG: Mirrored push token from \(uid) to legacy user doc \(doc.documentID)")
                }
            }
            print("🔥🔥🔥 DEBUG: Registered push token for user \(uid)")
        } catch {
            print("🔥🔥🔥 DEBUG: Failed to register push token: \(error.localizedDescription)")
        }
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
        onlyIfMissing: Bool = false
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
        let ref = db.collection("organizations").document(organizationId).collection("notifications").document(notification.id.uuidString)
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
            relatedIdValue = notification.relatedId?.uuidString ?? NSNull()
        }
        var data: [String: Any] = [
            "organizationId": notification.organizationId,
            "type": notification.type.rawValue,
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
        // Equality on userId only. The script sorts; an orderBy here needs a composite index.
        let boundedQuery = notificationsRef.limit(to: max(1, limit))
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
        
        var notifications: [AppNotification] = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            
            guard let typeString = data["type"] as? String,
                  let type = AppNotification.NotificationType(rawValue: typeString),
                  let title = data["title"] as? String,
                  let message = data["message"] as? String,
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let isRead = data["isRead"] as? Bool,
                  let orgId = data["organizationId"] as? String else {
                continue
            }
            
            let id = UUID(uuidString: doc.documentID) ?? UUID()
            let userId = data["userId"] as? String
            let relatedIdString = data["relatedId"] as? String
            let relatedId = relatedIdString.flatMap(UUID.init(uuidString:))
            let requiresPermission = data["requiresPermission"] as? String
            let deepLinkUserId = data["deepLinkUserId"] as? String
            let deepLinkWeekStart = (data["deepLinkWeekStart"] as? Timestamp)?.dateValue()
            
            let notification = AppNotification(
                id: id,
                organizationId: orgId,
                type: type,
                title: title,
                message: message,
                userId: userId,
                relatedId: relatedId,
                isRead: isRead,
                createdAt: createdAt,
                requiresPermission: requiresPermission,
                deepLinkUserId: deepLinkUserId,
                deepLinkWeekStart: deepLinkWeekStart,
                dayKey: AppNotification.inboxDayKey(storedDayKey: data["dayKey"] as? String, relatedId: relatedIdString),
                catalogue: data["catalogue"] as? String
            )
            
            notifications.append(notification)
        }

        return notifications
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
    
    func saveBooking(_ booking: Booking, organizationId: String) async throws {
        print("🔥🔥🔥 DEBUG: saveBooking called with organizationId: \(organizationId), bookingId: \(booking.id.uuidString)")
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        
        var bookingData: [String: Any] = [
            "id": booking.documentKey,
            // A Firebase Auth uid stays a uid (web #189). Writing the in-app UUID would book nobody.
            "operativeId": booking.storedOperativeId,
            "projectId": booking.projectId.uuidString,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "bookedBy": booking.bookedBy,
            "notes": booking.notes ?? "",
            "status": booking.status.rawValue,
            "createdAt": Timestamp(date: booking.createdAt),
            "updatedAt": Timestamp(date: booking.updatedAt)
        ]
        if let ws = booking.workStartTime, !ws.isEmpty {
            bookingData["workStartTime"] = ws
        } else {
            bookingData["workStartTime"] = FieldValue.delete()
        }
        if let we = booking.workEndTime, !we.isEmpty {
            bookingData["workEndTime"] = we
        } else {
            bookingData["workEndTime"] = FieldValue.delete()
        }
        bookingData["isBreakRemoved"] = booking.isBreakRemoved
        if let otm = booking.otMultiplierOverride {
            bookingData["otMultiplierOverride"] = otm
        } else {
            bookingData["otMultiplierOverride"] = FieldValue.delete()
        }
        if let gid = booking.bookingGroupId, !gid.isEmpty {
            bookingData["bookingGroupId"] = gid
        } else {
            bookingData["bookingGroupId"] = FieldValue.delete()
        }

        print("🔥🔥🔥 DEBUG: Saving booking to organizations/\(orgId)/bookings/\(booking.id.uuidString)")
        
        try await db.collection("organizations").document(orgId).collection("bookings").document(booking.documentKey).setData(bookingData, merge: true)
        
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
        guard let projectId = UUID(uuidString: row.projectId),
              let timeSlot = TimeSlot.fromStored(row.timeSlot),
              let status = BookingStatus(rawValue: row.status) else {
            NSLog("BOOKING_UNREADABLE_ON_IOS id=%@ project=%@ slot=%@ status=%@", row.id, row.projectId, row.timeSlot, row.status)
            return nil
        }
        var booking = Booking(
            // A document id that is not a UUID keeps one stable in-app id instead of a new random one per read.
            id: UUID(uuidString: row.id) ?? OperativeKeyRegistry.derivedUUID(for: "booking.\(row.id)"),
            operativeId: Booking.internalOperativeId(for: row.operativeId),
            projectId: projectId,
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
            return ManagerSiteBooking(
                id: UUID(uuidString: row.id) ?? OperativeKeyRegistry.derivedUUID(for: "managerBooking.\(row.id)"),
                userId: row.userId,
                date: Date(timeIntervalSince1970: row.dateMs / 1000),
                timeSlot: timeSlot,
                locationType: locationType,
                locationId: row.locationId.flatMap { UUID(uuidString: $0) },
                customLocationName: row.customLocationName,
                workStartTime: row.workStartTime,
                workEndTime: row.workEndTime,
                isBreakRemoved: row.isBreakRemoved,
                bookingGroupId: row.bookingGroupId,
                createdAt: row.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                updatedAt: row.updatedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            )
        }
    }

    func bookingFromFirestoreDocument(_ doc: QueryDocumentSnapshot) -> Booking? {
        let data = doc.data()
            
            // operativeId may be a Firebase Auth uid, not a UUID (web #189). Keep the booking and its stored id.
            guard let operativeIdString = (data["operativeId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !operativeIdString.isEmpty,
                  let projectIdString = data["projectId"] as? String,
                  let projectId = UUID(uuidString: projectIdString),
                  let date = (data["date"] as? Timestamp)?.dateValue(),
                  let timeSlotString = data["timeSlot"] as? String,
                  let timeSlot = TimeSlot.fromStored(timeSlotString),
                  let bookedBy = data["bookedBy"] as? String,
                  let statusString = data["status"] as? String,
                  let status = BookingStatus(rawValue: statusString) else {
                return nil
            }
            
            let id = UUID(uuidString: doc.documentID) ?? UUID()
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
                projectId: projectId,
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
        try await db.collection("organizations").document(orgId).collection("bookings").document(booking.documentKey).delete()
    }

    // MARK: - Manager / Admin site bookings (where I'm working – AM, PM, Full Day, Office)

    func saveManagerSiteBooking(_ booking: ManagerSiteBooking, organizationId: String) async throws {
        var data: [String: Any] = [
            "id": booking.id.uuidString,
            "organizationId": organizationId,
            "userId": booking.userId,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "locationType": booking.locationType.rawValue,
            "createdAt": Timestamp(date: booking.createdAt),
            "updatedAt": Timestamp(date: booking.updatedAt)
        ]
        if let lid = booking.locationId {
            data["locationId"] = lid.uuidString
        }
        if let customLocationName = booking.customLocationName, !customLocationName.isEmpty {
            data["customLocationName"] = customLocationName
        }
        if let ws = booking.workStartTime, !ws.isEmpty {
            data["workStartTime"] = ws
        } else {
            data["workStartTime"] = FieldValue.delete()
        }
        if let we = booking.workEndTime, !we.isEmpty {
            data["workEndTime"] = we
        } else {
            data["workEndTime"] = FieldValue.delete()
        }
        data["isBreakRemoved"] = booking.isBreakRemoved
        if let gid = booking.bookingGroupId, !gid.isEmpty {
            data["bookingGroupId"] = gid
        } else {
            data["bookingGroupId"] = FieldValue.delete()
        }
        try await db.collection("organizations").document(organizationId).collection("managerSiteBookings").document(booking.id.uuidString).setData(data, merge: true)
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
        let id = UUID(uuidString: doc.documentID) ?? UUID()
        let locationId = (data["locationId"] as? String).flatMap { UUID(uuidString: $0) }
        let customLocationName = data["customLocationName"] as? String
        let workStartTime = data["workStartTime"] as? String
        let workEndTime = data["workEndTime"] as? String
        let isBreakRemoved = (data["isBreakRemoved"] as? Bool) ?? false
        let bookingGroupId = data["bookingGroupId"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        return ManagerSiteBooking(
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
        try await db.collection("organizations").document(organizationId).collection("managerSiteBookings").document(booking.id.uuidString).delete()
    }

    // MARK: - Holiday Bookings

    func saveHolidayBooking(_ booking: HolidayBooking, organizationId: String) async throws {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        var data: [String: Any] = [
            "id": booking.id.uuidString,
            "organizationId": orgId,
            "startDate": Timestamp(date: booking.startDate),
            "endDate": Timestamp(date: booking.endDate),
            "status": booking.status.rawValue,
            "timeSlot": booking.timeSlot.rawValue,
            "createdAt": Timestamp(date: booking.createdAt),
            "updatedAt": Timestamp(date: booking.updatedAt)
        ]
        if let uid = booking.userId { data["userId"] = uid }
        if let oid = booking.operativeId { data["operativeId"] = oid.uuidString }
        if let approvedBy = booking.approvedByUserId { data["approvedByUserId"] = approvedBy }
        if let approvedAt = booking.approvedAt { data["approvedAt"] = Timestamp(date: approvedAt) }
        if let cancellationRequestedAt = booking.cancellationRequestedAt {
            data["cancellationRequestedAt"] = Timestamp(date: cancellationRequestedAt)
        } else {
            data["cancellationRequestedAt"] = NSNull()
        }
        if let cancellationRequestedByUserId = booking.cancellationRequestedByUserId {
            data["cancellationRequestedByUserId"] = cancellationRequestedByUserId
        } else {
            data["cancellationRequestedByUserId"] = NSNull()
        }
        if let note = booking.decisionNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            data["decisionNote"] = note
        } else {
            data["decisionNote"] = NSNull()
        }
        try await db.collection("organizations").document(orgId).collection("holidayBookings").document(booking.id.uuidString).setData(data, merge: true)
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
        var parsed: [HolidayBooking] = []
        var skipped = 0
        for doc in snapshot.documents {
            if let booking = holidayBookingFromFirestore(doc, organizationId: orgId) {
                parsed.append(booking)
            } else {
                skipped += 1
            }
        }
        print("🔥🔥🔥 DEBUG: [HOLIDAY LOAD] docs=\(snapshot.documents.count) parsed=\(parsed.count) skipped=\(skipped)")
        return parsed
    }

    private func holidayBookingFromFirestore(_ doc: QueryDocumentSnapshot, organizationId orgId: String) -> HolidayBooking? {
        let data = doc.data()
        let startDate = firstFirestoreDate(in: data, keys: ["startDate", "start_date", "start", "from", "dateFrom", "holidayStart", "date"])
        let endDate = firstFirestoreDate(in: data, keys: ["endDate", "end_date", "end", "to", "dateTo", "holidayEnd"]) ?? startDate
        guard let startDate, let endDate else {
            print("🔥🔥🔥 DEBUG: [HOLIDAY LOAD] skip \(doc.documentID) — no start/end date")
            return nil
        }
        let status = holidayStatus(from: data) ?? .approved
        let bookingOrgId = firstFirestoreString(in: data, keys: ["organizationId"]) ?? orgId
        let id = Manager.stableId(forFirestoreDocumentId: doc.documentID)
        let userId = holidayUserId(from: data)
        let operativeId = firstFirestoreString(in: data, keys: ["operativeId", "operative_id", "operativeID"]).flatMap { UUID(uuidString: $0) }
        let approvedByUserId = firstFirestoreString(in: data, keys: ["approvedByUserId", "approvedBy"])
        let approvedAt = firstFirestoreDate(in: data, keys: ["approvedAt"])
        let timeSlot = holidayTimeSlot(from: firstFirestoreString(in: data, keys: ["timeSlot", "slot", "halfDay"]))
        let cancellationRequestedAt = firstFirestoreDate(in: data, keys: ["cancellationRequestedAt"])
        let cancellationRequestedByUserId = firstFirestoreString(in: data, keys: ["cancellationRequestedByUserId"])
        let decisionNote = firstFirestoreString(in: data, keys: ["decisionNote", "note"])
        let createdAt = firstFirestoreDate(in: data, keys: ["createdAt"]) ?? Date()
        let updatedAt = firstFirestoreDate(in: data, keys: ["updatedAt"]) ?? createdAt
        return HolidayBooking(
            id: id,
            organizationId: bookingOrgId,
            userId: userId,
            operativeId: operativeId,
            startDate: min(startDate, endDate),
            endDate: max(startDate, endDate),
            status: status,
            timeSlot: timeSlot,
            approvedByUserId: approvedByUserId,
            approvedAt: approvedAt,
            cancellationRequestedAt: cancellationRequestedAt,
            cancellationRequestedByUserId: cancellationRequestedByUserId,
            decisionNote: decisionNote,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func firstFirestoreDate(in data: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let date = firestoreDate(data[key]) { return date }
        }
        return nil
    }

    private func firstFirestoreString(in data: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = data[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func holidayUserId(from data: [String: Any]) -> String? {
        if let direct = firstFirestoreString(in: data, keys: ["userId", "user_id", "uid", "userID", "linkedUserId", "employeeUserId"]) {
            return direct
        }
        if let user = data["user"] as? [String: Any] {
            return firstFirestoreString(in: user, keys: ["id", "uid", "userId", "userID"])
        }
        return nil
    }

    private func holidayStatus(from data: [String: Any]) -> HolidayStatus? {
        let raw = firstFirestoreString(in: data, keys: ["status", "holidayStatus", "approvalStatus"])?
            .lowercased()
        switch raw {
        case nil, "":
            return nil
        case "pending", "requested", "awaiting", "awaiting approval", "submitted":
            return .pending
        case "approved", "approve", "accepted", "confirmed":
            return .approved
        case "rejected", "declined", "denied", "cancelled", "canceled":
            return .rejected
        default:
            return nil
        }
    }

    private func holidayTimeSlot(from raw: String?) -> HolidayTimeSlot {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "am", "morning", "a.m.":
            return .morning
        case "pm", "afternoon", "p.m.":
            return .afternoon
        default:
            return .fullDay
        }
    }

    func deleteHolidayBooking(_ booking: HolidayBooking, organizationId: String) async throws {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        try await db.collection("organizations").document(orgId).collection("holidayBookings").document(booking.id.uuidString).delete()
    }

    func recordOperativeDayRateChange(
        organizationId: String,
        userId: String?,
        operativeId: UUID?,
        dayRate: Double,
        effectiveAt: Date
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
        var payload: [String: Any] = [
            "dayRate": dayRate,
            "effectiveAt": Timestamp(date: effectiveAt),
            "createdAt": Timestamp(date: Date())
        ]
        if let uid { payload["userId"] = uid }
        if let operativeId { payload["operativeId"] = operativeId.uuidString }
        try await db.collection("organizations")
            .document(organizationId)
            .collection("operativeDayRateHistory")
            .document(UUID().uuidString)
            .setData(payload, merge: true)
    }

    func loadOperativeDayRateHistory(organizationId: String) async throws -> OperativeDayRateHistoryCollection {
        let snapshot = try await db.collection("organizations")
            .document(organizationId)
            .collection("operativeDayRateHistory")
            .getDocuments()
        var byUserId: [String: [OperativeDayRateHistoryEntry]] = [:]
        var byOperativeId: [String: [OperativeDayRateHistoryEntry]] = [:]
        for doc in snapshot.documents {
            let data = doc.data()
            guard let dayRate = data["dayRate"] as? Double,
                  let effectiveAt = (data["effectiveAt"] as? Timestamp)?.dateValue() else { continue }
            let rawUser = data["userId"] as? String
            let userId: String? = (rawUser?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let operativeId = (data["operativeId"] as? String).flatMap(UUID.init(uuidString:))
            guard userId != nil || operativeId != nil else { continue }
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let entry = OperativeDayRateHistoryEntry(
                id: UUID(uuidString: doc.documentID) ?? UUID(),
                userId: userId,
                operativeId: operativeId,
                dayRate: dayRate,
                effectiveAt: effectiveAt,
                createdAt: createdAt
            )
            if let userId {
                byUserId[userId, default: []].append(entry)
            }
            if let operativeId {
                byOperativeId[operativeId.uuidString, default: []].append(entry)
            }
        }
        for key in byUserId.keys {
            byUserId[key] = byUserId[key]?.sorted(by: { $0.effectiveAt < $1.effectiveAt })
        }
        for key in byOperativeId.keys {
            byOperativeId[key] = byOperativeId[key]?.sorted(by: { $0.effectiveAt < $1.effectiveAt })
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
        
        // Save project
        try await saveProject(project, organizationId: organizationId)
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

    /// Firestore often returns numeric fields as `Int64` / `NSNumber`; plain `as? Int` drops valid rows.
    private func materialQuantityFromFirestore(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Int8: return Int(v)
        case let v as Int16: return Int(v)
        case let v as Int32: return Int(v)
        case let v as Int64: return Int(exactly: v)
        case let v as UInt: return Int(exactly: v)
        case let v as Double: return Int(exactly: v)
        case let v as Float: return Int(v)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    /// Parses a materials subcollection document for ownership checks and delete. Returns nil if required fields are missing.
    private func materialItemFromFirestoreDocumentData(_ data: [String: Any]) -> MaterialItem? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let quantity = materialQuantityFromFirestore(data["quantity"]),
              let unitString = data["unit"] as? String,
              let unit = MaterialUnit(rawValue: unitString),
              let materialName = data["material"] as? String,
              let addedBy = data["addedBy"] as? String,
              let addedAt = (data["addedAt"] as? Timestamp)?.dateValue(),
              let projectIdString = data["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdString),
              let date = (data["date"] as? Timestamp)?.dateValue() else {
            return nil
        }
        let status = materialWorkflowStatusFromFirestore(data["status"])
        let catalogueId = (data["catalogueItemId"] as? String).flatMap(UUID.init(uuidString:))
        let lastSentTypeRaw = data["lastSentRequestType"] as? String
        let lastSentType = lastSentTypeRaw.flatMap { MaterialOrderRequest.RequestType(rawValue: $0) }

        return MaterialItem(
            id: id,
            quantity: quantity,
            unit: unit,
            material: materialName,
            addedBy: addedBy,
            addedByUserId: data["addedByUserId"] as? String,
            addedAt: addedAt,
            editedBy: data["editedBy"] as? String,
            editedByUserId: data["editedByUserId"] as? String,
            editedAt: (data["editedAt"] as? Timestamp)?.dateValue(),
            projectId: projectId,
            date: Calendar.current.startOfDay(for: date),
            status: status,
            catalogueItemId: catalogueId,
            brand: data["brand"] as? String,
            productCode: data["productCode"] as? String,
            size: data["size"] as? String,
            length: (data["length"] as? String)
                ?? (data["sizeOrLength"] as? String)
                ?? (data["packSize"] as? Int).map(String.init),
            lengthUnit: (data["lengthUnit"] as? String).flatMap(MaterialLengthUnit.init(rawValue:)),
            category: data["category"] as? String,
            websiteURL: data["websiteURL"] as? String,
            notes: data["notes"] as? String,
            lastSentAt: (data["lastSentAt"] as? Timestamp)?.dateValue(),
            lastSentRequestType: lastSentType
        )
    }

    private func materialWorkflowStatusFromFirestore(_ value: Any?) -> MaterialWorkflowStatus {
        guard let raw = value as? String,
              let status = MaterialWorkflowStatus(rawValue: raw) else {
            return .draft
        }
        return status
    }

    private func legacyLengthMigrationPayload(_ data: [String: Any]) -> [String: Any]? {
        let hasLength = (data["length"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard !hasLength else { return nil }
        let legacyValue = (data["sizeOrLength"] as? String)
            ?? (data["packSize"] as? Int).map(String.init)
        let trimmed = legacyValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return [
            "length": trimmed,
            // Keep legacy field in sync while older app builds still read it.
            "sizeOrLength": trimmed
        ]
    }

    private func materialItemFirestorePayload(_ material: MaterialItem, addedByUserId: String?) -> [String: Any] {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: material.date)
        var data: [String: Any] = [
            "id": material.id.uuidString,
            "quantity": material.quantity,
            "unit": material.unit.rawValue,
            "material": material.material,
            "addedBy": material.addedBy,
            "addedByUserId": addedByUserId as Any,
            "addedAt": Timestamp(date: material.addedAt),
            "editedBy": material.editedBy as Any,
            "editedByUserId": material.editedByUserId as Any,
            "editedAt": material.editedAt.map { Timestamp(date: $0) } as Any,
            "projectId": material.projectId.uuidString,
            "date": Timestamp(date: normalizedDate),
            "status": material.status.rawValue
        ]
        if let catalogueItemId = material.catalogueItemId {
            data["catalogueItemId"] = catalogueItemId.uuidString
        }
        if let brand = material.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            data["brand"] = brand
        }
        if let code = material.productCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            data["productCode"] = code
        }
        if let size = material.size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            data["size"] = size
        }
        if let length = material.length?.trimmingCharacters(in: .whitespacesAndNewlines), !length.isEmpty {
            data["length"] = length
            // Backward compatibility for older app versions.
            data["sizeOrLength"] = length
        }
        if let lengthUnit = material.lengthUnit {
            data["lengthUnit"] = lengthUnit.rawValue
        }
        if let category = material.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
            data["category"] = category
        }
        if let websiteURL = material.websiteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !websiteURL.isEmpty {
            data["websiteURL"] = websiteURL
        }
        if let notes = material.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            data["notes"] = notes
        }
        if let lastSentAt = material.lastSentAt {
            data["lastSentAt"] = Timestamp(date: lastSentAt)
        }
        if let lastSentRequestType = material.lastSentRequestType {
            data["lastSentRequestType"] = lastSentRequestType.rawValue
        }
        return data
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

        // Ensure date is normalized to start of day
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: material.date)
        let docRef = db.collection("organizations").document(orgId)
            .collection("materials")
            .document(material.id.uuidString)

        let serverSnapshot = try await docRef.getDocument(source: .server)
        if serverSnapshot.exists,
           let serverData = serverSnapshot.data(),
           let serverMaterial = materialItemFromFirestoreDocumentData(serverData) {
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
        
        let data = materialItemFirestorePayload(material, addedByUserId: effectiveAddedByUserId)
        
        print("💾 [FirebaseBackend] Saving material:")
        print("   ID: \(material.id.uuidString)")
        print("   Material: \(material.material)")
        print("   Project ID: \(material.projectId.uuidString)")
        print("   Date: \(normalizedDate)")
        print("   Organization ID: \(orgId)")
        
        try await docRef.setData(data)

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
            guard let material = materialItemFromFirestoreDocumentData(doc.data()) else { continue }
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
        print("🔍 [FirebaseBackend] Loading materials for projectId: \(projectId.uuidString) org: \(orgId)")
        let materialsQuery = db.collection("organizations").document(orgId)
            .collection("materials")
            .whereField("projectId", isEqualTo: projectId.uuidString)
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
            let data = doc.data()
            if let migration = legacyLengthMigrationPayload(data) {
                try? await doc.reference.setData(migration, merge: true)
            }
            guard let materialItem = materialItemFromFirestoreDocumentData(data) else {
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
            let data = doc.data()
            if let migration = legacyLengthMigrationPayload(data) {
                try? await doc.reference.setData(migration, merge: true)
            }
            guard let item = materialItemFromFirestoreDocumentData(data) else { continue }
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
            .whereField("projectId", isEqualTo: projectId.uuidString)
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
                    let data = doc.data()
                    if let migration = self.legacyLengthMigrationPayload(data) {
                        Task {
                            try? await doc.reference.setData(migration, merge: true)
                        }
                    }
                    guard let item = self.materialItemFromFirestoreDocumentData(data) else { continue }
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
            .document(materialId.uuidString)
        let snapshot = try await docRef.getDocument(source: .server)
        guard let data = snapshot.data(),
              let material = materialItemFromFirestoreDocumentData(data) else {
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
        let calendar = Calendar.current
        let today = Date()
        let cutoffDay = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -keepDays, to: today) ?? today
        )
        
        let snapshot = try await db.collection("organizations").document(orgId)
            .collection("materials")
            .whereField("projectId", isEqualTo: projectId.uuidString)
            .getDocuments()
        
        let toDelete = snapshot.documents.filter { doc in
            guard let ts = doc.data()["date"] as? Timestamp else { return false }
            let neededDay = calendar.startOfDay(for: ts.dateValue())
            return neededDay < cutoffDay
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

        let data: [String: Any] = [
            "id": audit.id.uuidString,
            "organizationId": orgId,
            "projectId": audit.projectId.uuidString,
            "projectJobNumber": audit.projectJobNumber,
            "projectName": audit.projectName,
            "type": audit.type.rawValue,
            "customTitle": audit.customTitle,
            "authorName": audit.authorName,
            "date": Timestamp(date: audit.date),
            "createdAt": Timestamp(date: audit.createdAt),
            "createdByUserId": audit.createdByUserId,
            "visibleToOperatives": audit.visibleToOperatives,
            "items": audit.items.map { item in
                var row: [String: Any] = [
                    "id": item.id.uuidString,
                    "title": item.title,
                    "location": item.location,
                    "assignee": item.assignee,
                    "comments": item.comments,
                    "annotations": item.annotations,
                    "createdAt": Timestamp(date: item.createdAt)
                ]
                if let imageURL = item.imageURL {
                    row["imageURL"] = imageURL
                }
                if let capturedAt = item.imageCapturedAt {
                    row["imageCapturedAt"] = Timestamp(date: capturedAt)
                }
                return row
            }
        ]

        try await db.collection("organizations").document(orgId)
            .collection("siteAudits")
            .document(audit.id.uuidString)
            .setData(data)
    }

    func loadSiteAudits(organizationId: String, projectId: UUID? = nil, createdByUserId: String? = nil) async throws -> [SiteAudit] {
        var query: Query = db.collection("organizations").document(organizationId)
            .collection("siteAudits")

        if let projectId {
            query = query.whereField("projectId", isEqualTo: projectId.uuidString)
        }
        if let createdByUserId {
            query = query.whereField("createdByUserId", isEqualTo: createdByUserId)
        }

        let snapshot = try await query.getDocuments()
        var audits: [SiteAudit] = []

        for doc in snapshot.documents {
            let data = doc.data()
            guard let idString = data["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let projectIdString = data["projectId"] as? String,
                  let parsedProjectId = UUID(uuidString: projectIdString),
                  let projectJobNumber = data["projectJobNumber"] as? String,
                  let projectName = data["projectName"] as? String,
                  let typeRaw = data["type"] as? String,
                  let type = SiteAuditType(rawValue: typeRaw),
                  let authorName = data["authorName"] as? String,
                  let date = (data["date"] as? Timestamp)?.dateValue(),
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let createdByUserId = data["createdByUserId"] as? String else {
                continue
            }
            let customTitle = (data["customTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let visibleToOperatives = data["visibleToOperatives"] as? Bool ?? true

            let itemRows = data["items"] as? [[String: Any]] ?? []
            let items: [SiteAuditItem] = itemRows.compactMap { row in
                guard let itemIdString = row["id"] as? String,
                      let itemId = UUID(uuidString: itemIdString),
                      let title = row["title"] as? String,
                      let location = row["location"] as? String,
                      let assignee = row["assignee"] as? String,
                      let comments = row["comments"] as? String,
                      let createdAt = (row["createdAt"] as? Timestamp)?.dateValue() else {
                    return nil
                }
                return SiteAuditItem(
                    id: itemId,
                    title: title,
                    location: location,
                    assignee: assignee,
                    comments: comments,
                    annotations: row["annotations"] as? String ?? "",
                    imageURL: row["imageURL"] as? String,
                    imageCapturedAt: (row["imageCapturedAt"] as? Timestamp)?.dateValue(),
                    createdAt: createdAt
                )
            }

            audits.append(SiteAudit(
                id: id,
                projectId: parsedProjectId,
                projectJobNumber: projectJobNumber,
                projectName: projectName,
                type: type,
                customTitle: customTitle,
                authorName: authorName,
                date: date,
                items: items,
                createdAt: createdAt,
                createdByUserId: createdByUserId,
                visibleToOperatives: visibleToOperatives
            ))
        }

        return audits.sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - Wholesalers
    
    func saveWholesaler(_ wholesaler: Wholesaler, organizationId: String) async throws {
        let contactsData = wholesaler.contacts.map { contact in
            wholesalerContactFirestoreRow(contact)
        }
        
        var data: [String: Any] = [
            "id": wholesaler.id.uuidString,
            "name": wholesaler.name,
            "contacts": contactsData,
            "createdAt": Timestamp(date: wholesaler.createdAt),
            "updatedAt": Timestamp(date: wholesaler.updatedAt)
        ]
        if let address = wholesaler.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            data["address"] = address
        }
        if let trade = wholesaler.trade?.trimmingCharacters(in: .whitespacesAndNewlines), !trade.isEmpty {
            data["trade"] = trade
        }
        if let accountNumber = wholesaler.accountNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !accountNumber.isEmpty {
            data["accountNumber"] = accountNumber
        }
        if let primaryContactId = wholesaler.primaryContactId {
            data["primaryContactId"] = primaryContactId.uuidString
        }
        
        try await db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(wholesaler.id.uuidString)
            .setData(data, merge: true)
    }

    /// One `contacts[]` row, the shape web `wholesalerPayload` writes. `phone` is null when no mobile is saved.
    private func wholesalerContactFirestoreRow(_ contact: WholesalerContact) -> [String: Any] {
        let phone = contact.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            "id": contact.id.uuidString,
            "name": contact.name,
            "email": contact.email,
            "createdAt": Timestamp(date: contact.createdAt),
            "isPrimary": contact.isPrimary,
            "phone": phone.isEmpty ? NSNull() : phone
        ]
    }

    func deleteWholesaler(wholesalerId: UUID, organizationId: String) async throws {
        try await db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(wholesalerId.uuidString)
            .delete()
    }
    
    func loadWholesalers(organizationId: String) async throws -> [Wholesaler] {
        let snapshot = try await db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .getDocuments()
        
        var wholesalers: [Wholesaler] = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            
            guard let idString = data["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let name = data["name"] as? String,
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue(),
                  let contactsArray = data["contacts"] as? [[String: Any]] else {
                continue
            }
            
            var contacts: [WholesalerContact] = []
            for contactData in contactsArray {
                if let contactIdString = contactData["id"] as? String,
                   let contactId = UUID(uuidString: contactIdString),
                   let contactName = contactData["name"] as? String,
                   let contactEmail = contactData["email"] as? String,
                   let contactCreatedAt = (contactData["createdAt"] as? Timestamp)?.dateValue() {
                    let phone = (contactData["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let contact = WholesalerContact(
                        id: contactId,
                        name: contactName,
                        email: contactEmail,
                        isPrimary: contactData["isPrimary"] as? Bool ?? false,
                        createdAt: contactCreatedAt,
                        phone: phone?.isEmpty == false ? phone : nil
                    )
                    contacts.append(contact)
                }
            }
            let primaryId = (data["primaryContactId"] as? String).flatMap(UUID.init(uuidString:))
            var normalizedContacts = contacts
            if let primaryId,
               let idx = normalizedContacts.firstIndex(where: { $0.id == primaryId }) {
                for i in normalizedContacts.indices {
                    normalizedContacts[i].isPrimary = i == idx
                }
            } else if !normalizedContacts.isEmpty, !normalizedContacts.contains(where: \.isPrimary) {
                normalizedContacts[0].isPrimary = true
            }
            
            let wholesaler = Wholesaler(
                id: id,
                name: name,
                address: data["address"] as? String,
                trade: data["trade"] as? String,
                accountNumber: data["accountNumber"] as? String,
                primaryContactId: primaryId ?? normalizedContacts.first(where: \.isPrimary)?.id,
                contacts: normalizedContacts,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            
            wholesalers.append(wholesaler)
        }
        
        return wholesalers
    }
    
    func addContactToWholesaler(_ contact: WholesalerContact, wholesalerId: UUID, organizationId: String) async throws {
        let wholesalerRef = db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(wholesalerId.uuidString)
        
        // First, get the current wholesaler to ensure it exists and get current contacts
        let doc = try await wholesalerRef.getDocument()
        
        guard doc.exists else {
            throw NSError(domain: "WholesalerNotFound", code: 404, userInfo: [NSLocalizedDescriptionKey: "Wholesaler not found"])
        }
        
        let data = doc.data() ?? [:]
        var contactsArray = data["contacts"] as? [[String: Any]] ?? []
        
        // Check if contact already exists (by ID)
        let contactIdString = contact.id.uuidString
        if contactsArray.contains(where: { ($0["id"] as? String) == contactIdString }) {
            // Contact already exists, update it instead
            if let index = contactsArray.firstIndex(where: { ($0["id"] as? String) == contactIdString }) {
                var row = wholesalerContactFirestoreRow(contact)
                // Keep a mobile saved on web when this edit did not carry one.
                if contact.phone == nil, let stored = contactsArray[index]["phone"] {
                    row["phone"] = stored
                }
                contactsArray[index] = row
            }
        } else {
            // Add new contact
            contactsArray.append(wholesalerContactFirestoreRow(contact))
        }
        
        // Update the wholesaler with the new contacts array
        try await wholesalerRef.updateData([
            "contacts": contactsArray,
            "updatedAt": Timestamp(date: Date())
        ])
    }
    
    // MARK: - Subcontractors
    
    func saveSubcontractor(_ subcontractor: Subcontractor, organizationId: String) async throws {
        let contactsData = subcontractor.contacts.map { contact in
            [
                "id": contact.id.uuidString,
                "name": contact.name,
                "email": contact.email,
                "contactNumber": contact.contactNumber,
                "position": contact.position.rawValue,
                "tradeType": contact.displayTrade,
                "createdAt": Timestamp(date: contact.createdAt)
            ] as [String : Any]
        }
        
        let data: [String: Any] = [
            "id": subcontractor.id.uuidString,
            "name": subcontractor.name,
            "subcontractorType": subcontractor.subcontractorType,
            "website": subcontractor.website ?? NSNull(),
            "address": subcontractor.address ?? NSNull(),
            "contacts": contactsData,
            "createdAt": Timestamp(date: subcontractor.createdAt),
            "updatedAt": Timestamp(date: subcontractor.updatedAt)
        ]
        
        try await db.collection("organizations").document(organizationId)
            .collection("subcontractors")
            .document(subcontractor.id.uuidString)
            .setData(data)

        let extraTrades = subcontractor.contacts.map(\.displayTrade) + [subcontractor.subcontractorType]
        try? await mergeOrganizationTradeTypes(extraTrades, organizationId: organizationId)
    }

    func loadOrganizationTradeTypes(organizationId: String) async -> [String] {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else { return [] }
        do {
            let snap = try await db.collection("organizations").document(orgId)
                .collection("settings")
                .document("tradeTypeInventory")
                .getDocument()
            return (snap.data()?["trades"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    func mergeOrganizationTradeTypes(_ trades: [String], organizationId: String) async throws {
        let orgId = try await ensureReadableOrganization(organizationId)
        let incoming = trades
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }
        let ref = db.collection("organizations").document(orgId)
            .collection("settings")
            .document("tradeTypeInventory")
        let existing = await loadOrganizationTradeTypes(organizationId: orgId)
        var seen = Set(existing.map { $0.lowercased() })
        var merged = existing
        for trade in incoming where seen.insert(trade.lowercased()).inserted {
            merged.append(trade)
        }
        try await ref.setData([
            "trades": merged,
            "updatedAt": Timestamp(date: Date())
        ], merge: true)
    }
    
    func loadSubcontractors(organizationId: String) async throws -> [Subcontractor] {
        let snapshot = try await db.collection("organizations").document(organizationId)
            .collection("subcontractors")
            .getDocuments()
        
        var loaded: [Subcontractor] = []
        for doc in snapshot.documents {
            let data = doc.data()
            guard let idString = data["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let name = data["name"] as? String,
                  let subcontractorType = data["subcontractorType"] as? String,
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { continue }
            let website = data["website"] as? String
            let address = data["address"] as? String
            
            let contactsArray = data["contacts"] as? [[String: Any]] ?? []
            let contacts: [SubcontractorContact] = contactsArray.compactMap { row in
                guard let cidString = row["id"] as? String,
                      let cid = UUID(uuidString: cidString),
                      let cname = row["name"] as? String,
                      let cemail = row["email"] as? String,
                      let number = row["contactNumber"] as? String,
                      let positionRaw = row["position"] as? String,
                      let cCreatedAt = (row["createdAt"] as? Timestamp)?.dateValue() else { return nil }
                let position = SubcontractorContactPosition(rawValue: positionRaw) ?? .installer
                let storedTrade = (row["tradeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return SubcontractorContact(
                    id: cid,
                    name: cname,
                    email: cemail,
                    contactNumber: number,
                    position: position,
                    tradeType: storedTrade.isEmpty ? positionRaw : storedTrade,
                    createdAt: cCreatedAt
                )
            }
            
            loaded.append(
                Subcontractor(
                    id: id,
                    name: name,
                    subcontractorType: subcontractorType,
                    website: website,
                    address: address,
                    contacts: contacts,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return loaded.sorted { $0.name < $1.name }
    }
    
    func saveSubcontractorBooking(_ booking: SubcontractorBooking, organizationId: String) async throws {
        var data: [String: Any] = [
            "id": booking.id.uuidString,
            "subcontractorId": booking.subcontractorId.uuidString,
            "projectId": booking.projectId.uuidString,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "isBreakRemoved": booking.isBreakRemoved,
            "bookedBy": booking.bookedBy,
            "status": booking.status.rawValue,
            "createdAt": Timestamp(date: booking.createdAt),
            "updatedAt": Timestamp(date: booking.updatedAt)
        ]
        if let workStartTime = booking.workStartTime, !workStartTime.isEmpty {
            data["workStartTime"] = workStartTime
        }
        if let workEndTime = booking.workEndTime, !workEndTime.isEmpty {
            data["workEndTime"] = workEndTime
        }
        if !booking.bookedContactIds.isEmpty {
            data["bookedContactIds"] = booking.bookedContactIds.map(\.uuidString)
        }
        
        try await db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .document(booking.id.uuidString)
            .setData(data)
    }

    func deleteSubcontractorBooking(_ booking: SubcontractorBooking, organizationId: String) async throws {
        try await db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .document(booking.id.uuidString)
            .delete()
    }
    
    func loadSubcontractorBookings(organizationId: String) async throws -> [SubcontractorBooking] {
        let snapshot = try await db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .getDocuments()
        
        var loaded: [SubcontractorBooking] = []
        for doc in snapshot.documents {
            let data = doc.data()
            guard let idString = data["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let subcontractorIdString = data["subcontractorId"] as? String,
                  let subcontractorId = UUID(uuidString: subcontractorIdString),
                  let projectIdString = data["projectId"] as? String,
                  let projectId = UUID(uuidString: projectIdString),
                  let date = (data["date"] as? Timestamp)?.dateValue(),
                  let timeSlotRaw = data["timeSlot"] as? String,
                  let timeSlot = TimeSlot.fromStored(timeSlotRaw),
                  let bookedBy = data["bookedBy"] as? String,
                  let statusRaw = data["status"] as? String,
                  let status = BookingStatus(rawValue: statusRaw),
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { continue }
            let workStartTime = data["workStartTime"] as? String
            let workEndTime = data["workEndTime"] as? String
            let isBreakRemoved = data["isBreakRemoved"] as? Bool ?? false
            let bookedContactIds = (data["bookedContactIds"] as? [String])?
                .compactMap(UUID.init(uuidString:)) ?? []
            
            loaded.append(
                SubcontractorBooking(
                    id: id,
                    subcontractorId: subcontractorId,
                    projectId: projectId,
                    date: date,
                    timeSlot: timeSlot,
                    workStartTime: workStartTime,
                    workEndTime: workEndTime,
                    isBreakRemoved: isBreakRemoved,
                    bookedBy: bookedBy,
                    status: status,
                    bookedContactIds: bookedContactIds,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return loaded.sorted { $0.date < $1.date }
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
        var loaded: [MaterialCatalogItem] = []
        for doc in snapshot.documents {
            let data = doc.data()
            if let migration = legacyLengthMigrationPayload(data) {
                try? await doc.reference.setData(migration, merge: true)
            }
            if let item = materialCatalogItemFromFirestore(data, documentId: doc.documentID) {
                loaded.append(item)
            }
        }
        return loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func saveMaterialCatalogueItem(_ item: MaterialCatalogItem, organizationId: String) async throws {
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        try await db.collection("organizations").document(orgId)
            .collection("materialCatalogue")
            .document(item.id.uuidString)
            .setData(materialCatalogueFirestorePayload(item))
    }

    func deleteMaterialCatalogueItem(_ itemId: UUID, organizationId: String) async throws {
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        try await db.collection("organizations").document(orgId)
            .collection("materialCatalogue")
            .document(itemId.uuidString)
            .delete()
    }

    /// Batched catalogue writes. `onProgress` reports how many items in this call have been committed.
    func saveMaterialCatalogueItems(
        _ items: [MaterialCatalogItem],
        organizationId: String,
        onProgress: ((Int) -> Void)? = nil
    ) async throws {
        guard !items.isEmpty else { return }
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        let collection = db.collection("organizations").document(orgId).collection("materialCatalogue")
        var index = 0
        var completed = 0
        while index < items.count {
            let batch = db.batch()
            let end = min(index + Self.materialCatalogueBatchSize, items.count)
            for item in items[index..<end] {
                batch.setData(
                    materialCatalogueFirestorePayload(item),
                    forDocument: collection.document(item.id.uuidString)
                )
            }
            try await batch.commit()
            completed = end
            index = end
            let progressValue = completed
            await MainActor.run {
                onProgress?(progressValue)
            }
        }
    }

    /// Batched catalogue deletes. `onProgress` reports how many IDs in this call have been committed.
    func deleteMaterialCatalogueItems(
        _ itemIds: [UUID],
        organizationId: String,
        onProgress: ((Int) -> Void)? = nil
    ) async throws {
        guard !itemIds.isEmpty else { return }
        let orgId = try await resolvedOrganizationIdForMaterialCatalogueWrite(organizationId)
        let collection = db.collection("organizations").document(orgId).collection("materialCatalogue")
        var index = 0
        var completed = 0
        while index < itemIds.count {
            let batch = db.batch()
            let end = min(index + Self.materialCatalogueBatchSize, itemIds.count)
            for itemId in itemIds[index..<end] {
                batch.deleteDocument(collection.document(itemId.uuidString))
            }
            try await batch.commit()
            completed = end
            index = end
            let progressValue = completed
            await MainActor.run {
                onProgress?(progressValue)
            }
        }
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
                .document(id.uuidString)
            let snap = try await docRef.getDocument(source: .server)
            guard snap.exists,
                  let data = snap.data(),
                  let item = materialItemFromFirestoreDocumentData(data) else { continue }
            // Never downgrade an already ordered item back to quote-requested.
            let nextStatus: MaterialWorkflowStatus = (item.status == .ordered && status == .sentForQuote)
                ? .ordered
                : status
            try await docRef.updateData([
                "status": nextStatus.rawValue,
                "lastSentAt": Timestamp(date: now),
                "lastSentRequestType": requestType.rawValue,
                "updatedAt": Timestamp(date: now)
            ])
        }
    }

    private func materialCatalogueFirestorePayload(_ item: MaterialCatalogItem) -> [String: Any] {
        var data: [String: Any] = [
            "id": item.id.uuidString,
            "name": item.name,
            "brand": item.brand,
            "defaultUnit": item.defaultUnit.rawValue,
            "createdAt": Timestamp(date: item.createdAt),
            "createdByUserId": item.createdByUserId,
            "createdByName": item.createdByName
        ]
        if let code = item.productCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            data["productCode"] = code
        }
        if let size = item.size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            data["size"] = size
        }
        if let length = item.length?.trimmingCharacters(in: .whitespacesAndNewlines), !length.isEmpty {
            data["length"] = length
            // Backward compatibility for older app versions.
            data["sizeOrLength"] = length
        }
        if let lengthUnit = item.lengthUnit {
            data["lengthUnit"] = lengthUnit.rawValue
        }
        data["category"] = normalizedMaterialCategory(item.category)
        return data
    }

    private func materialCatalogItemFromFirestore(_ data: [String: Any], documentId: String) -> MaterialCatalogItem? {
        let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let id = UUID(uuidString: (data["id"] as? String) ?? "") ?? UUID(uuidString: documentId)
        guard let id else { return nil }
        let brand = (data["brand"] as? String) ?? ""
        let unit = MaterialUnit(rawValue: (data["defaultUnit"] as? String) ?? "") ?? .number
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let createdByUserId = (data["createdByUserId"] as? String) ?? ""
        let createdByName = (data["createdByName"] as? String) ?? ""
        return MaterialCatalogItem(
            id: id,
            name: name,
            brand: brand,
            productCode: data["productCode"] as? String,
            defaultUnit: unit,
            size: data["size"] as? String,
            length: (data["length"] as? String)
                ?? (data["sizeOrLength"] as? String)
                ?? (data["packSize"] as? Int).map(String.init),
            lengthUnit: (data["lengthUnit"] as? String).flatMap(MaterialLengthUnit.init(rawValue:)),
            category: normalizedMaterialCategory(data["category"] as? String),
            createdAt: createdAt,
            createdByUserId: createdByUserId,
            createdByName: createdByName
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
        var data: [String: Any] = [
            "id": record.id.uuidString,
            "projectId": record.projectId.uuidString,
            "requestType": record.requestType.rawValue,
            "sentAt": Timestamp(date: record.sentAt),
            "sentBy": record.sentBy,
            "recipients": record.recipients.map {
                var row: [String: Any] = [
                    "name": $0.name,
                    "email": $0.email
                ]
                if let wholesalerName = $0.wholesalerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !wholesalerName.isEmpty {
                    row["wholesalerName"] = wholesalerName
                }
                return row
            },
            "lines": record.lines.map { line in
                var row: [String: Any] = [
                    "materialId": line.materialId.uuidString,
                    "name": line.name,
                    "quantity": line.quantity,
                    "unit": line.unit.rawValue
                ]
                if let brand = line.brand { row["brand"] = brand }
                if let code = line.productCode { row["productCode"] = code }
                if let lengthDisplay = line.lengthDisplay { row["lengthDisplay"] = lengthDisplay }
                return row
            }
        ]
        if let materialsDate = record.materialsDate {
            data["materialsDate"] = Timestamp(date: materialsDate)
        }
        if let deliveryRequiredAt = record.deliveryRequiredAt,
           CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired(record.requestType.rawValue) == true {
            data["deliveryRequiredAt"] = Timestamp(date: deliveryRequiredAt)
        }
        try await db.collection("organizations").document(orgId)
            .collection("materialSendRecords")
            .document(record.id.uuidString)
            .setData(data)
    }

    func loadAllMaterialSendRecords(organizationId: String) async throws -> [MaterialSendRecord] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let snapshot = try await db.collection("organizations").document(orgId)
            .collection("materialSendRecords")
            .getDocuments(source: .server)
        return snapshot.documents.compactMap { materialSendRecordFromFirestore($0.data()) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    func loadMaterialSendRecords(organizationId: String, projectId: UUID) async throws -> [MaterialSendRecord] {
        let orgId = try await resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId)
        let snapshot = try await db.collection("organizations").document(orgId)
            .collection("materialSendRecords")
            .whereField("projectId", isEqualTo: projectId.uuidString)
            .getDocuments(source: .server)
        return snapshot.documents.compactMap { materialSendRecordFromFirestore($0.data()) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    private func materialSendRecordFromFirestore(_ data: [String: Any]) -> MaterialSendRecord? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let projectIdString = data["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdString),
              let requestTypeRaw = data["requestType"] as? String,
              let requestType = MaterialOrderRequest.RequestType(rawValue: requestTypeRaw),
              let sentAt = (data["sentAt"] as? Timestamp)?.dateValue(),
              let sentBy = data["sentBy"] as? String else {
            return nil
        }
        let materialsDate = (data["materialsDate"] as? Timestamp)?.dateValue()
        let deliveryRequiredAt = (data["deliveryRequiredAt"] as? Timestamp)?.dateValue()
        let recipientsRaw = data["recipients"] as? [[String: Any]] ?? []
        let recipients = recipientsRaw.compactMap { row -> MaterialSendRecipientSnapshot? in
            guard let name = row["name"] as? String,
                  let email = row["email"] as? String else { return nil }
            return MaterialSendRecipientSnapshot(
                name: name,
                email: email,
                wholesalerName: row["wholesalerName"] as? String
            )
        }
        let linesRaw = data["lines"] as? [[String: Any]] ?? []
        let lines = linesRaw.compactMap { row -> MaterialSendLineSnapshot? in
            guard let materialIdString = row["materialId"] as? String,
                  let materialId = UUID(uuidString: materialIdString),
                  let name = row["name"] as? String,
                  let quantity = materialQuantityFromFirestore(row["quantity"]),
                  let unitRaw = row["unit"] as? String,
                  let unit = MaterialUnit(rawValue: unitRaw) else { return nil }
            return MaterialSendLineSnapshot(
                materialId: materialId,
                name: name,
                quantity: quantity,
                unit: unit,
                brand: row["brand"] as? String,
                productCode: row["productCode"] as? String,
                lengthDisplay: row["lengthDisplay"] as? String
            )
        }
        let storedDelivery = CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired(requestType.rawValue) == true
            ? deliveryRequiredAt
            : nil
        return MaterialSendRecord(
            id: id,
            projectId: projectId,
            requestType: requestType,
            sentAt: sentAt,
            materialsDate: materialsDate,
            deliveryRequiredAt: storedDelivery,
            sentBy: sentBy,
            recipients: recipients,
            lines: lines.isEmpty ? [] : lines
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
        return snapshot.data()
    }

    func saveTimesheetState(
        organizationId: String,
        userId: String,
        weekStart: Date,
        weekEnd: Date,
        payload: [String: Any]
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
        var data = payload
        data["userId"] = periodFields.userId
        data["weekStartKey"] = periodFields.weekStartKey
        data["weekEndKey"] = periodFields.weekEndKey
        data["weekStart"] = Timestamp(date: startInstant)
        data["weekEnd"] = Timestamp(date: endInstant)
        data["updatedAt"] = Timestamp(date: Date())
        try await timesheetStateDocumentRef(
            organizationId: organizationId,
            userId: userId,
            weekStart: weekStart
        ).setData(data, merge: true)
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

    private func hsStateDocumentRef(organizationId: String, project: Project) -> DocumentReference {
        // Use org settings document path so H&S works even before dedicated rules are deployed.
        // Key includes work type + project id to keep project/small works data isolated.
        let docId = "healthSafety_\(hsCollectionName(for: project))_\(project.id.uuidString)"
        return db.collection("organizations")
            .document(organizationId)
            .collection("settings")
            .document(docId)
    }

    private func hsTalkMap(_ talk: HSToolboxTalk) -> [String: Any] {
        [
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
            "fileURL": talk.fileURL ?? ""
        ]
    }

    private func hsIssueMap(_ issue: HSToolboxIssue) -> [String: Any] {
        [
            "id": issue.id,
            "projectId": issue.projectId.uuidString,
            "talkId": issue.talkId,
            "weekCommencing": Timestamp(date: issue.weekCommencing),
            "issuedByUserId": issue.issuedByUserId,
            "issuedAt": Timestamp(date: issue.issuedAt),
            "publishAt": issue.publishAt.map(Timestamp.init(date:)) as Any,
            "recipientUserIds": issue.recipientUserIds,
            "status": issue.status.rawValue,
            "ramsDocumentId": issue.ramsDocumentId ?? ""
        ]
    }

    private func hsSignatureMap(_ signature: HSToolboxSignature) -> [String: Any] {
        [
            "id": signature.id,
            "issueId": signature.issueId,
            "userId": signature.userId,
            "status": signature.status.rawValue,
            "readConfirmed": signature.readConfirmed,
            "signatureImageBase64": signature.signatureImageBase64 ?? "",
            "signedAt": signature.signedAt.map(Timestamp.init(date:)) as Any,
            "reminderSentAt": signature.reminderSentAt.map(Timestamp.init(date:)) as Any
        ]
    }

    private func hsRamsMap(_ doc: HSRamsDocument) -> [String: Any] {
        [
            "id": doc.id,
            "title": doc.title,
            "trade": doc.trade,
            "version": doc.version,
            "status": doc.status,
            "uploadedAt": Timestamp(date: doc.uploadedAt),
            "fileURL": doc.fileURL ?? "",
            "fileName": doc.fileName ?? "",
            "reviewDate": doc.reviewDate.map(Timestamp.init(date:)) as Any,
            "attachedDocTitles": doc.attachedDocTitles
        ]
    }

    private func hsOtherDocMap(_ doc: HSOtherDocument) -> [String: Any] {
        [
            "id": doc.id,
            "title": doc.title,
            "trade": doc.trade ?? "",
            "category": doc.category,
            "uploadedAt": Timestamp(date: doc.uploadedAt),
            "fileURL": doc.fileURL ?? "",
            "fileName": doc.fileName ?? "",
            "issuableToClient": doc.issuableToClient
        ]
    }

    private func parseHSTalk(_ map: [String: Any]) -> HSToolboxTalk? {
        guard let id = map["id"] as? String, !id.isEmpty else { return nil }
        let categoryRaw = (map["category"] as? String) ?? HSToolboxTalkCategory.general.rawValue
        let sourceRaw = (map["source"] as? String) ?? HSToolboxTalkSource.library.rawValue
        let statusRaw = (map["status"] as? String) ?? HSToolboxTalkStatus.approved.rawValue
        let updatedAt = (map["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        let ownerId = (map["ownerOrganizationId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = (map["fileURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HSToolboxTalk(
            id: id,
            title: (map["title"] as? String) ?? "",
            category: HSToolboxTalkCategory(rawValue: categoryRaw) ?? .general,
            isGeneral: map["isGeneral"] as? Bool ?? false,
            trades: map["trades"] as? [String] ?? [],
            purpose: (map["purpose"] as? String) ?? "",
            keyPoints: map["keyPoints"] as? [String] ?? [],
            source: HSToolboxTalkSource(rawValue: sourceRaw) ?? .library,
            ownerOrganizationId: ownerId?.isEmpty == false ? ownerId : nil,
            status: HSToolboxTalkStatus(rawValue: statusRaw) ?? .approved,
            version: map["version"] as? Int ?? 1,
            updatedAt: updatedAt,
            fileURL: fileURL?.isEmpty == false ? fileURL : nil
        )
    }

    private func parseHSIssue(_ map: [String: Any], fallbackProjectId: UUID) -> HSToolboxIssue? {
        guard let id = map["id"] as? String, !id.isEmpty else { return nil }
        let projectId = ((map["projectId"] as? String).flatMap(UUID.init(uuidString:))) ?? fallbackProjectId
        let statusRaw = (map["status"] as? String) ?? HSToolboxIssueStatus.awaiting.rawValue
        let ramsId = (map["ramsDocumentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HSToolboxIssue(
            id: id,
            projectId: projectId,
            talkId: (map["talkId"] as? String) ?? "",
            weekCommencing: (map["weekCommencing"] as? Timestamp)?.dateValue() ?? Date(),
            issuedByUserId: (map["issuedByUserId"] as? String) ?? "",
            issuedAt: (map["issuedAt"] as? Timestamp)?.dateValue() ?? Date(),
            publishAt: (map["publishAt"] as? Timestamp)?.dateValue(),
            recipientUserIds: map["recipientUserIds"] as? [String] ?? [],
            status: HSToolboxIssueStatus(rawValue: statusRaw) ?? .awaiting,
            ramsDocumentId: (ramsId?.isEmpty == false) ? ramsId : nil
        )
    }

    private func parseHSSignature(_ map: [String: Any]) -> HSToolboxSignature? {
        guard let id = map["id"] as? String, !id.isEmpty else { return nil }
        let statusRaw = (map["status"] as? String) ?? HSToolboxSignatureStatus.pending.rawValue
        let signatureBase64 = (map["signatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HSToolboxSignature(
            id: id,
            issueId: (map["issueId"] as? String) ?? "",
            userId: (map["userId"] as? String) ?? "",
            status: HSToolboxSignatureStatus(rawValue: statusRaw) ?? .pending,
            readConfirmed: map["readConfirmed"] as? Bool ?? false,
            signatureImageBase64: signatureBase64?.isEmpty == false ? signatureBase64 : nil,
            signedAt: (map["signedAt"] as? Timestamp)?.dateValue(),
            reminderSentAt: (map["reminderSentAt"] as? Timestamp)?.dateValue()
        )
    }

    private func parseHSRams(_ map: [String: Any]) -> HSRamsDocument? {
        guard let id = map["id"] as? String, !id.isEmpty else { return nil }
        let fileURL = (map["fileURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (map["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HSRamsDocument(
            id: id,
            title: (map["title"] as? String) ?? "Untitled RAMS",
            trade: (map["trade"] as? String) ?? "General",
            version: map["version"] as? Int ?? 1,
            status: (map["status"] as? String) ?? "live",
            uploadedAt: (map["uploadedAt"] as? Timestamp)?.dateValue() ?? Date(),
            fileURL: fileURL?.isEmpty == false ? fileURL : nil,
            fileName: fileName?.isEmpty == false ? fileName : nil,
            reviewDate: (map["reviewDate"] as? Timestamp)?.dateValue(),
            attachedDocTitles: map["attachedDocTitles"] as? [String] ?? []
        )
    }

    private func parseHSOtherDoc(_ map: [String: Any]) -> HSOtherDocument? {
        guard let id = map["id"] as? String, !id.isEmpty else { return nil }
        let trade = (map["trade"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = (map["fileURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (map["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HSOtherDocument(
            id: id,
            title: (map["title"] as? String) ?? "Untitled H&S doc",
            trade: trade?.isEmpty == false ? trade : nil,
            category: (map["category"] as? String) ?? "trade",
            uploadedAt: (map["uploadedAt"] as? Timestamp)?.dateValue() ?? Date(),
            fileURL: fileURL?.isEmpty == false ? fileURL : nil,
            fileName: fileName?.isEmpty == false ? fileName : nil,
            issuableToClient: map["issuableToClient"] as? Bool ?? false
        )
    }

    func loadHealthSafetyData(project: Project, organizationId: String) async throws -> HSProjectSafetyData {
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else { return .empty }
        let orgId = try await ensureReadableOrganization(resolved)

        let ref = hsStateDocumentRef(organizationId: orgId, project: project)
        let doc: DocumentSnapshot
        do {
            doc = try await ref.getDocument(source: .server)
        } catch {
            do {
                doc = try await ref.getDocument(source: .cache)
            } catch {
                throw error
            }
        }

        guard let data = doc.data() else { return .empty }

        let talksRaw = data["talks"] as? [[String: Any]] ?? []
        let issuesRaw = data["issues"] as? [[String: Any]] ?? []
        let signaturesRaw = data["signatures"] as? [[String: Any]] ?? []
        let ramsRaw = data["ramsDocuments"] as? [[String: Any]] ?? []
        let otherRaw = data["otherDocuments"] as? [[String: Any]] ?? []
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()

        var output = HSProjectSafetyData(
            talks: talksRaw.compactMap(parseHSTalk),
            issues: issuesRaw.compactMap { parseHSIssue($0, fallbackProjectId: project.id) },
            signatures: signaturesRaw.compactMap(parseHSSignature),
            ramsDocuments: ramsRaw.compactMap(parseHSRams),
            otherDocuments: otherRaw.compactMap(parseHSOtherDoc),
            updatedAt: updatedAt
        )
        output.issues.sort { $0.issuedAt > $1.issuedAt }
        output.signatures.sort { ($0.signedAt ?? .distantPast) > ($1.signedAt ?? .distantPast) }
        output.ramsDocuments.sort { $0.uploadedAt > $1.uploadedAt }
        output.otherDocuments.sort { $0.uploadedAt > $1.uploadedAt }
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
            let talks = raw.compactMap(parseHSTalk)
            if !talks.isEmpty {
                return talks
            }
        }
        return []
    }

    func saveHealthSafetyData(_ safetyData: HSProjectSafetyData, project: Project, organizationId: String) async throws {
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

        let existing: HSProjectSafetyData
        do {
            existing = try await loadHealthSafetyData(project: project, organizationId: orgId)
        } catch {
            existing = .empty
        }

        // Never clobber a populated catalogue with an empty in-memory snapshot.
        // An empty talks seed or a failed load used to wipe issued TBTs from Tracking.
        let talks = safetyData.talks.isEmpty && !existing.talks.isEmpty ? existing.talks : safetyData.talks
        let issues = safetyData.issues.isEmpty && !existing.issues.isEmpty ? existing.issues : safetyData.issues
        let signatures = safetyData.signatures.isEmpty && !existing.signatures.isEmpty ? existing.signatures : safetyData.signatures
        let ramsDocuments = safetyData.ramsDocuments.isEmpty && !existing.ramsDocuments.isEmpty ? existing.ramsDocuments : safetyData.ramsDocuments
        let otherDocuments = safetyData.otherDocuments.isEmpty && !existing.otherDocuments.isEmpty ? existing.otherDocuments : safetyData.otherDocuments

        let payload: [String: Any] = [
            "talks": talks.map(hsTalkMap),
            "issues": issues.map(hsIssueMap),
            "signatures": signatures.map(hsSignatureMap),
            "ramsDocuments": ramsDocuments.map(hsRamsMap),
            "otherDocuments": otherDocuments.map(hsOtherDocMap),
            "updatedAt": Timestamp(date: Date())
        ]
        let ref = hsStateDocumentRef(organizationId: orgId, project: project)
        try await ref.setData(payload, merge: true)
    }

    // MARK: - Deadlines (Project / Small Works)

    private func deadlinesStateDocumentRef(organizationId: String, project: Project) -> DocumentReference {
        deadlinesStateDocumentRef(organizationId: organizationId, projectId: project.id, isSmallWorks: project.jobType == .smallWorks)
    }

    private func deadlinesStateDocumentRef(organizationId: String, projectId: UUID, isSmallWorks: Bool) -> DocumentReference {
        let collection = isSmallWorks ? "smallWorks" : "projects"
        let docId = "deadlines_\(collection)_\(projectId.uuidString)"
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
            "id": change.id.uuidString,
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

    private func parseDeadlineChange(_ map: [String: Any]) -> DLChange? {
        let id = (map["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let at = (map["at"] as? Timestamp)?.dateValue() ?? Date()
        let author = (map["author"] as? String) ?? ""
        let type = (map["type"] as? String) ?? "note"
        let kind: DLChange.Kind
        switch type {
        case "created":
            kind = .created(due: (map["due"] as? Timestamp)?.dateValue() ?? Date())
        case "rescheduled":
            kind = .rescheduled(
                from: (map["from"] as? Timestamp)?.dateValue() ?? Date(),
                to: (map["to"] as? Timestamp)?.dateValue() ?? Date(),
                reason: (map["reason"] as? String) ?? ""
            )
        case "progress":
            kind = .progress(to: map["progress"] as? Int ?? 0)
        case "status":
            kind = .status(to: DLStatus(rawValue: (map["status"] as? String) ?? "") ?? .notStarted)
        case "note":
            kind = .note((map["note"] as? String) ?? "")
        case "completed":
            kind = .completed(on: (map["completedOn"] as? Timestamp)?.dateValue() ?? Date())
        case "assigned":
            kind = .assigned(to: (map["assignedTo"] as? String) ?? "")
        case "fileAttached":
            kind = .fileAttached(name: (map["name"] as? String) ?? "File")
        case "siteAuditAttached":
            kind = .siteAuditAttached(name: (map["name"] as? String) ?? "Site audit")
        default:
            kind = .note(type)
        }
        return DLChange(id: id, at: at, author: author, kind: kind)
    }

    private func deadlineMap(_ item: DLDeadline) -> [String: Any] {
        [
            "id": item.id.uuidString,
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
            "dependsOn": item.dependsOn.map(\.uuidString),
            "blockedReason": item.blockedReason ?? "",
            "reminderDaysBefore": item.reminderDaysBefore as Any,
            "originalDue": item.originalDue.map(Timestamp.init(date:)) as Any,
            "history": item.history.map(deadlineChangeMap),
            "contextKind": item.contextKind,
            "projectId": item.projectId?.uuidString ?? "",
            "createdByUserId": item.createdByUserId,
            "fileURL": item.fileURL ?? "",
            "fileName": item.fileName ?? "",
            "siteAuditId": item.siteAuditId?.uuidString ?? "",
            "siteAuditTitle": item.siteAuditTitle ?? ""
        ]
    }

    private func parseDeadline(_ map: [String: Any], fallbackProjectId: UUID) -> DLDeadline? {
        guard let idString = map["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
        let status = DLStatus(rawValue: (map["status"] as? String) ?? "") ?? .notStarted
        let due = (map["due"] as? Timestamp)?.dateValue() ?? Date()
        let location = (map["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trade = (map["trade"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (map["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = (map["company"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = (map["blockedReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = (map["fileURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (map["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteTitle = (map["siteAuditTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = (map["projectId"] as? String).flatMap(UUID.init(uuidString:)) ?? fallbackProjectId
        let siteAuditId = (map["siteAuditId"] as? String).flatMap(UUID.init(uuidString:))
        let reminder: Int?
        if let n = map["reminderDaysBefore"] as? Int {
            reminder = n
        } else if let n = map["reminderDaysBefore"] as? NSNumber {
            reminder = n.intValue
        } else {
            reminder = nil
        }
        let historyRaw = map["history"] as? [[String: Any]] ?? []
        let item = DLDeadline(
            id: id,
            title: (map["title"] as? String) ?? "Untitled deadline",
            location: location?.isEmpty == false ? location : nil,
            trade: trade?.isEmpty == false ? trade : nil,
            detail: detail?.isEmpty == false ? detail : nil,
            start: (map["start"] as? Timestamp)?.dateValue(),
            due: due,
            completedAt: (map["completedAt"] as? Timestamp)?.dateValue(),
            assignees: map["assignees"] as? [String] ?? [],
            assigneeUserIds: map["assigneeUserIds"] as? [String] ?? [],
            company: company?.isEmpty == false ? company : nil,
            status: status,
            progress: map["progress"] as? Double ?? 0,
            isCritical: map["isCritical"] as? Bool ?? false,
            dependsOn: (map["dependsOn"] as? [String] ?? []).compactMap(UUID.init(uuidString:)),
            blockedReason: blocked?.isEmpty == false ? blocked : nil,
            reminderDaysBefore: reminder,
            originalDue: (map["originalDue"] as? Timestamp)?.dateValue(),
            history: historyRaw.compactMap(parseDeadlineChange),
            contextKind: (map["contextKind"] as? String) ?? "Project",
            projectId: projectId,
            createdByUserId: (map["createdByUserId"] as? String) ?? "",
            fileURL: fileURL?.isEmpty == false ? fileURL : nil,
            fileName: fileName?.isEmpty == false ? fileName : nil,
            siteAuditId: siteAuditId,
            siteAuditTitle: siteTitle?.isEmpty == false ? siteTitle : nil
        )
        return item
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
        let raw = data["items"] as? [[String: Any]] ?? []
        let items = raw.compactMap { parseDeadline($0, fallbackProjectId: project.id) }
            .sorted { $0.due < $1.due }
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
            isSmallWorks: project.jobType == .smallWorks,
            organizationId: organizationId,
            baseUpdatedAt: baseUpdatedAt
        )
    }

    @discardableResult
    func saveDeadlines(
        _ items: [DLDeadline],
        projectId: UUID,
        isSmallWorks: Bool,
        organizationId: String,
        baseUpdatedAt: Date? = nil
    ) async throws -> [DLDeadline] {
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

        let ref = deadlinesStateDocumentRef(organizationId: orgId, projectId: projectId, isSmallWorks: isSmallWorks)
        var itemsToWrite = items
        if let baseUpdatedAt {
            do {
                let remoteDoc = try await ref.getDocument(source: .server)
                if let data = remoteDoc.data(),
                   let remoteUpdatedAt = (data["updatedAt"] as? Timestamp)?.dateValue(),
                   remoteUpdatedAt > baseUpdatedAt.addingTimeInterval(0.4) {
                    let raw = data["items"] as? [[String: Any]] ?? []
                    let remoteItems = raw.compactMap { parseDeadline($0, fallbackProjectId: projectId) }
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
            "projectId": projectId.uuidString
        ]
        try await ref.setData(payload, merge: true)

        let assigneeIds = Array(Set(itemsToWrite.flatMap(\.assigneeUserIds))).sorted()
        try await deadlineAssignmentsDocumentRef(organizationId: orgId).setData([
            "projects.\(projectId.uuidString)": assigneeIds,
            "updatedAt": Timestamp(date: Date())
        ], merge: true)
        return itemsToWrite
    }

    private func mergeDeadlinesFirstWriterWins(remote: [DLDeadline], local: [DLDeadline]) -> [DLDeadline] {
        var byId = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for item in local where byId[item.id] == nil {
            byId[item.id] = item
        }
        return byId.values.sorted { $0.due < $1.due }
    }

    func loadDeadlineAssignedProjectIds(userId: String, organizationId: String) async -> Set<UUID> {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else { return [] }
        do {
            let orgId = try await ensureReadableOrganization(resolved)
            let snap = try await deadlineAssignmentsDocumentRef(organizationId: orgId).getDocument()
            guard let projects = snap.data()?["projects"] as? [String: [String]] else { return [] }
            return Set(projects.compactMap { key, ids in
                ids.contains(trimmed) ? UUID(uuidString: key) : nil
            })
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
