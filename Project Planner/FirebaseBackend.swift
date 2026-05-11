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
private func organizationIdFromFirestore(_ value: Any?) -> String? {
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

private func organizationIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !left.isEmpty,
          !right.isEmpty else {
        return false
    }
    return left == right
}

private func normalizedOrganizationId(_ organizationId: String) -> String {
    organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isOfflineNetworkError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
        return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        return underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorNotConnectedToInternet
    }
    return false
}

// MARK: - Firebase Backend Manager

@MainActor
class FirebaseBackend: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: FirebaseAuth.User?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentOrganization: Organization?
    @Published var userRole: UserRole = .basic
    @Published var shouldShowSetupFlow = false
    var isNewOrganization = false
    
    /// Lazy so `FirebaseBackend` can be constructed before `application(_:didFinishLaunchingWithOptions:)` calls `FirebaseApp.configure()`.
    private lazy var auth: Auth = Auth.auth()
    private lazy var db: Firestore = Firestore.firestore()
    #if canImport(FirebaseStorage)
    private lazy var storage: Storage = Storage.storage()
    #endif
    private var authHandle: AuthStateDidChangeListenerHandle?
    /// Single-flight attach: `await` yields MainActor, so a second caller must wait instead of starting a parallel `perform` (duplicate listeners / races).
    private var authAttachInProgress = false
    
    // Local storage keys
    private let organizationIdKey = "cached_organizationId"
    private let organizationNameKey = "cached_organizationName"

    struct OperativeProfileMetadata {
        let userId: String
        let assignedManagerUserId: String?
        let dayRate: Double?
    }
    
    /// Breaks recover → loadUserOrganization → org read fails → recover again loops (see firestore org self-read rules).
    private var suppressOrganizationReadPermissionRecovery = false
    /// Prevents parallel org load/recovery storms from multiple stores/views.
    private var organizationLoadInProgress = false

    /// Ensures org id is non-empty and org document is readable before subcollection reads.
    private func ensureReadableOrganization(_ organizationId: String) async throws -> String {
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
            _ = try await db.collection("organizations").document(trimmedOrgId).getDocument(source: .server)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                // Some deployments deny org root read while allowing subcollection access.
                // Do not block projects/smallWorks/clients/operatives reads in that case.
                print("🔥🔥🔥 DEBUG: ⚠️ Org root read denied for \(trimmedOrgId), continuing with subcollection reads")
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
    private func setCurrentOrganizationFromRecovery(orgId: String, orgData: [String: Any], fallbackRole: String = "member") {
        let resolvedName = (orgData["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = Organization(
            id: UUID(uuidString: orgId) ?? UUID(),
            firestoreDocumentId: orgId,
            name: (resolvedName?.isEmpty == false) ? resolvedName! : "Recovered Organization",
            settings: OrganizationSettings(),
            officeAddressLine1: orgData["officeAddressLine1"] as? String,
            officeCity: orgData["officeCity"] as? String,
            officePostcode: orgData["officePostcode"] as? String,
            countryCode: (orgData["countryCode"] as? String)?.uppercased() ?? "GB",
            defaultLatitude: orgData["defaultLatitude"] as? Double,
            defaultLongitude: orgData["defaultLongitude"] as? Double,
            companyLogoURL: orgData["companyLogoURL"] as? String,
            creatorUserId: orgData["creatorUserId"] as? String
        )
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

        let sessionUser = auth.currentUser
        currentUser = sessionUser
        isAuthenticated = sessionUser != nil

        authHandle = auth.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentUser = user
                self.isAuthenticated = user != nil
                if let user = user {
                    print("🔥🔥🔥 Firebase user signed in: \(user.email ?? "N/A")")

                    let shouldPreserveSetupFlow = self.shouldShowSetupFlow && self.isNewOrganization

                    if self.currentOrganization != nil {
                        print("🔥🔥🔥 DEBUG: Organization already set, skipping reload from auth listener")
                        NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
                    } else {
                        Task { [weak self] in
                            await self?.loadUserOrganizationWithRecovery(userId: user.uid)
                        }
                    }

                    if shouldPreserveSetupFlow {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard let self else { return }
                            self.shouldShowSetupFlow = true
                            self.isNewOrganization = true
                            print("🔥🔥🔥 DEBUG: Auth state changed - preserved shouldShowSetupFlow for new sign-up")
                        }
                    }

                    NotificationCenter.default.post(name: .userDidSignIn, object: user.email)
                } else {
                    print("Firebase user signed out.")
                    self.currentOrganization = nil
                    self.userRole = .basic
                    self.shouldShowSetupFlow = false
                    self.isNewOrganization = false
                    self.clearLocalOrganizationCache()
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

    /// Pushes `Auth.auth().currentUser` into `@Published` immediately (no listener required). Use so UI gates don’t spin forever while attach runs.
    func syncPublishedAuthFromAuthSession() {
        ensureFirebaseAppConfigured()
        guard FirebaseApp.app() != nil else { return }
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
            let organizationData: [String: Any] = [
                "name": organizationName,
                "members": [result.user.uid: "admin"],
                "creatorUserId": result.user.uid,
                "countryCode": "GB",
                "settings": [:],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
            
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
                "skills": true,
                "qualifications": true,
                "isSuperAdmin": true, // Organization creator is super admin
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
            
            print("🔥🔥🔥 DEBUG: Creating user document for: \(result.user.uid)")
            print("🔥🔥🔥 DEBUG: User document data: \(userData)")
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
            
            // Store organization locally immediately
            storeOrganizationLocally(organization)
            
            // Set organization immediately on main thread
            await MainActor.run {
                self.currentOrganization = organization
                self.userRole = .admin
                self.isNewOrganization = true // Mark this as a new organization
                self.shouldShowSetupFlow = true // ALWAYS show setup flow for new sign-ups
                self.errorMessage = nil // Clear any errors
                print("🔥🔥🔥 DEBUG: Sign-up completed - shouldShowSetupFlow set to TRUE for new organization")
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
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    func signOut() throws {
        try auth.signOut()
    }
    
    func completeSetupFlow() {
        shouldShowSetupFlow = false
        isNewOrganization = false
        print("🔥🔥🔥 DEBUG: Setup flow completed, flags reset")
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
        // Find the user in our organization so we can create a new invitation (verification code) for them.
        // Use server source so we don't use stale cache (e.g. after a user was deleted).
        var usersSnapshot = try await db.collection("users").whereField("email", isEqualTo: email).limit(to: 1).getDocuments(source: .server)
        if usersSnapshot.documents.isEmpty, email != email.lowercased() {
            usersSnapshot = try await db.collection("users").whereField("email", isEqualTo: email.lowercased()).limit(to: 1).getDocuments(source: .server)
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
        let permissions = UserPermissions(
            adminAccess: permissionsMap["adminAccess"] as? Bool ?? false,
            manager: permissionsMap["manager"] as? Bool ?? false,
            operatives: permissionsMap["operatives"] as? Bool ?? false,
            skills: permissionsMap["skills"] as? Bool ?? false,
            qualifications: permissionsMap["qualifications"] as? Bool ?? false,
            materials: permissionsMap["materials"] as? Bool ?? false,
            projects: permissionsMap["projects"] as? Bool ?? true,
            smallWorks: permissionsMap["smallWorks"] as? Bool ?? true,
            operativeMode: permissionsMap["operativeMode"] as? Bool ?? false,
            annualLeaveSelfBook: permissionsMap["annualLeaveSelfBook"] as? Bool ?? false,
            weeklyReports: permissionsMap["weeklyReports"] as? Bool ?? false,
            subContractors: permissionsMap["subContractors"] as? Bool ?? false,
            siteAudit: permissionsMap["siteAudit"] as? Bool ?? true
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
                "skills": permissions.skills,
                "qualifications": permissions.qualifications,
                "materials": permissions.materials,
                "projects": permissions.projects,
                "smallWorks": permissions.smallWorks,
                "operativeMode": permissions.operativeMode,
                "annualLeaveSelfBook": permissions.annualLeaveSelfBook,
                "weeklyReports": permissions.weeklyReports,
                "subContractors": permissions.subContractors,
                "siteAudit": permissions.siteAudit
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
    private func clearLocalOrganizationCache() {
        UserDefaults.standard.removeObject(forKey: organizationIdKey)
        UserDefaults.standard.removeObject(forKey: organizationNameKey)
        print("🔥🔥🔥 DEBUG: ✅ Cleared local organization cache (sign-out or recovery)")
    }
    
    /// Store organizationId locally for offline access
    @MainActor
    private func storeOrganizationIdLocally(_ organizationId: String) {
        UserDefaults.standard.set(organizationId, forKey: organizationIdKey)
        print("🔥🔥🔥 DEBUG: ✅ Stored organizationId locally: \(organizationId)")
    }
    
    /// Load organizationId from local storage
    @MainActor
    private func loadOrganizationIdLocally() -> String? {
        return UserDefaults.standard.string(forKey: organizationIdKey)
    }
    
    /// Load organization from local storage (for offline access)
    @MainActor
    private func loadOrganizationFromLocalStorage() -> Organization? {
        guard let organizationId = loadOrganizationIdLocally(),
              let organizationName = UserDefaults.standard.string(forKey: organizationNameKey) else {
            return nil
        }
        
        if let uuid = UUID(uuidString: organizationId) {
            return Organization(
                id: uuid,
                firestoreDocumentId: organizationId,
                name: organizationName,
                settings: OrganizationSettings()
            )
        }
        return nil
    }
    
    /// Store organization locally
    @MainActor
    private func storeOrganizationLocally(_ organization: Organization) {
        storeOrganizationIdLocally(organization.firestoreDocumentId)
        UserDefaults.standard.set(organization.name, forKey: organizationNameKey)
        print("🔥🔥🔥 DEBUG: ✅ Stored organization locally: \(organization.name)")
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
        
        // Do not return early when currentOrganization is set — it can be stale (wrong org id → Firestore permission denied on projects).
        // Optionally hydrate name from cache while Firebase loads; Firebase result always wins.
        if let cachedOrganization = loadOrganizationFromLocalStorage() {
            print("🔥🔥🔥 DEBUG: ✅ Found organization in local storage: \(cachedOrganization.name) (will verify against users/\(userId) in Firebase)")
            if currentOrganization == nil {
                self.currentOrganization = cachedOrganization
            }
        }
        
        await loadUserOrganizationFromFirebase(userId: userId)
    }

    private func getDocumentWithServerTimeoutAndCacheFallback(
        _ ref: DocumentReference,
        timeoutSeconds: Double = 8.0
    ) async throws -> DocumentSnapshot {
        enum ReadTimeoutError: Error { case timedOut }

        func withTimeout<T>(_ seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw ReadTimeoutError.timedOut
                }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }
        }

        do {
            return try await withTimeout(timeoutSeconds) {
                try await ref.getDocument(source: .server)
            }
        } catch {
            if error is ReadTimeoutError {
                print("🔥🔥🔥 DEBUG: ⏱️ Firestore server read timed out for \(ref.path) - trying cache")
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: 🌐 Offline while reading \(ref.path) from server - trying cache")
            } else {
                let nsError = error as NSError
                print("🔥🔥🔥 DEBUG: ⚠️ Server read failed for \(ref.path) [\(nsError.domain):\(nsError.code)] - trying cache")
            }

            return try await ref.getDocument(source: .cache)
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
            
            guard userDoc.exists else {
                print("🔥🔥🔥 DEBUG: ❌ User document does not exist at users/\(userId) — attempting recovery (invited users / merge)")
                errorMessage = "User document not found. Attempting recovery..."
                self.currentOrganization = nil
                clearLocalOrganizationCache()
                if let userEmail = currentUser?.email {
                    let recovered = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                    if recovered, currentOrganization != nil {
                        print("🔥🔥🔥 DEBUG: ✅ Organization recovered after missing user doc")
                        NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
                        return
                    }
                }
                return
            }
            
            guard let userData = userDoc.data() else {
                print("🔥🔥🔥 DEBUG: ❌ User document exists but has no data!")
                errorMessage = "User data is empty. Please contact support."
                self.currentOrganization = nil
                clearLocalOrganizationCache()
                return
            }
            
            print("🔥🔥🔥 DEBUG: User data keys: \(userData.keys.joined(separator: ", "))")
            if let rawOrg = userData["organizationId"] {
                print("🔥🔥🔥 DEBUG: Raw organizationId field type: \(type(of: rawOrg)), value: \(rawOrg)")
            }
            
            guard let organizationId = organizationIdFromFirestore(userData["organizationId"]) else {
                print("🔥🔥🔥 DEBUG: ❌ No organizationId found in user document!")
                print("🔥🔥🔥 DEBUG: User data keys: \(userData.keys.joined(separator: ", "))")
                print("🔥🔥🔥 DEBUG: User data: \(userData)")
                print("🔥🔥🔥 DEBUG: This account may need to be linked to an organization.")
                errorMessage = "Organization not linked. Attempting recovery..."
                
                // Try to find or create organization
                self.currentOrganization = nil
                clearLocalOrganizationCache()
                await attemptToFixMissingOrganization(userId: userId, userData: userData)
                return
            }
            discoveredOrganizationId = organizationId
            discoveredUserRoleRaw = userData["role"] as? String
            
            print("🔥🔥🔥 DEBUG: ✅ Found organizationId in user document: \(organizationId)")
            
            // If organizationId is stored as DocumentReference, Firestore rules often deny org/subcollection access.
            // Migrate to plain string on load so `userOrgIdMatchesPath` succeeds on the next read.
            if !(userData["organizationId"] is String) {
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
            
            guard orgDoc.exists else {
                print("🔥🔥🔥 DEBUG: ❌ Organization document does not exist!")
                print("🔥🔥🔥 DEBUG: Organization ID: \(organizationId)")
                print("🔥🔥🔥 DEBUG: This organization may have been deleted or never created.")
                errorMessage = "Organization not found. Please contact support."
                self.currentOrganization = nil
                clearLocalOrganizationCache()
                return
            }
            
            guard let data = orgDoc.data() else {
                print("🔥🔥🔥 DEBUG: ❌ Organization document exists but has no data!")
                errorMessage = "Organization data is empty. Please contact support."
                self.currentOrganization = nil
                clearLocalOrganizationCache()
                return
            }
            
            let organizationName = data["name"] as? String ?? "Unknown Organization"
            let creatorUserId = data["creatorUserId"] as? String
            let officeAddressLine1 = data["officeAddressLine1"] as? String
            let officeCity = data["officeCity"] as? String
            let officePostcode = data["officePostcode"] as? String
            let countryCode = (data["countryCode"] as? String)?.uppercased() ?? "GB"
            let defaultLatitude = data["defaultLatitude"] as? Double
            let defaultLongitude = data["defaultLongitude"] as? Double
            print("🔥🔥🔥 DEBUG: ✅ Organization name: \(organizationName), creatorUserId: \(creatorUserId ?? "nil")")
            
            let organization = Organization(
                id: UUID(uuidString: organizationId) ?? UUID(),
                firestoreDocumentId: organizationId,
                name: organizationName,
                settings: OrganizationSettings(),
                officeAddressLine1: officeAddressLine1,
                officeCity: officeCity,
                officePostcode: officePostcode,
                countryCode: countryCode,
                defaultLatitude: defaultLatitude,
                defaultLongitude: defaultLongitude,
                companyLogoURL: data["companyLogoURL"] as? String,
                creatorUserId: creatorUserId
            )
            
            self.currentOrganization = organization
            self.userRole = UserRole(rawValue: userData["role"] as? String ?? UserRole.basic.rawValue) ?? .basic
            self.errorMessage = nil // Clear any previous errors
            
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
        print("🔥🔥🔥 DEBUG: Attempting to fix missing organization...")
        
        // Check if there are any organizations that this user might belong to
        // by checking if user email matches any organization members
        do {
            let orgsSnapshot = try await db.collection("organizations").getDocuments()
            print("🔥🔥🔥 DEBUG: Found \(orgsSnapshot.documents.count) organizations in Firestore")
            
            // For now, we can't automatically fix this without more context
            // User would need to contact support or recreate account
            print("🔥🔥🔥 DEBUG: Cannot automatically fix - user needs to contact support or recreate account")
        } catch {
            print("🔥🔥🔥 DEBUG: Error checking organizations: \(error.localizedDescription)")
        }
    }
    
    func getOrganizationData(organizationId: String) async throws -> OrganizationData? {
        let doc = try await db.collection("organizations").document(organizationId).getDocument()
        guard doc.exists else { return nil }
        
        let data = doc.data()!
        return OrganizationData(
            id: organizationId,
            name: data["name"] as? String ?? "",
            members: data["members"] as? [String: String] ?? [:],
            settings: data["settings"] as? [String: Any] ?? [:],
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }
    
    func updateOrganizationData(_ orgData: OrganizationData) async throws {
        let data: [String: Any] = [
            "name": orgData.name,
            "members": orgData.members,
            "settings": orgData.settings,
            "updatedAt": Timestamp(date: Date())
        ]
        
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
        guard let user = currentUser else { return }
        let orgIdStr = normalizedOrganizationId(organizationId)
        var shouldReloadOrganization = false
        // Store a plain string: Firestore security rules match `users/{uid}.organizationId` reliably as string;
        // DocumentReference often fails `userOrgIdMatchesPath` in rules (type not treated as path).
        do {
            try await db.collection("users").document(user.uid).setData([
                "organizationId": orgIdStr,
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            shouldReloadOrganization = true
        } catch {
            print("🔥🔥🔥 DEBUG: repairCurrentUserOrganizationAccess - failed user doc patch: \(error.localizedDescription)")
        }

        do {
            // Write member entry directly without requiring organization read permission.
            try await db.collection("organizations").document(orgIdStr).updateData([
                "members.\(user.uid)": "admin",
                "updatedAt": Timestamp(date: Date())
            ])
            shouldReloadOrganization = true
        } catch {
            print("🔥🔥🔥 DEBUG: repairCurrentUserOrganizationAccess - failed org membership patch: \(error.localizedDescription)")
        }

        // Avoid a permission-denied loop when both patches fail.
        if shouldReloadOrganization {
            await loadUserOrganization(userId: user.uid)
        }
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
        
        // Save managerId if available
        if let managerId = project.managerId {
            data["managerId"] = managerId.uuidString
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
    
    func loadProjects(organizationId: String) async throws -> [Project] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: [LOAD] Starting to load projects for organization: \(orgId)")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection("organizations").document(orgId).collection("projects").getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [LOAD] Server denied projects read for \(orgId) - trying cache fallback")
                snapshot = try await db.collection("organizations").document(orgId).collection("projects").getDocuments(source: .cache)
            } else {
                throw error
            }
        }
        print("🔥🔥🔥 DEBUG: [LOAD] Found \(snapshot.documents.count) project documents in Firebase")
        
        var loadedProjects: [Project] = []
        var skippedCount = 0
        
        for doc in snapshot.documents {
            let data = doc.data()
            let docId = doc.documentID
            print("🔥🔥🔥 DEBUG: [LOAD] Processing project document: \(docId)")
            print("🔥🔥🔥 DEBUG: [LOAD] Document data keys: \(data.keys.joined(separator: ", "))")
            
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
                project = Project(
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
                    isLive: data["isLive"] as? Bool ?? true,
                    description: data["description"] as? String,
                    hiddenManagerUserIds: hiddenManagerUserIds,
                    hiddenOperativeUserIds: hiddenOperativeUserIds
                )
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
                legacyProject.customJobType = customJobType
                project = legacyProject
            }
            
            loadedProjects.append(project)
            print("🔥🔥🔥 DEBUG: [LOAD] ✅ Successfully loaded project: \(project.siteName) (ID: \(project.id.uuidString))")
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
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [LOAD CLIENTS] Server denied clients read for \(orgId) - trying cache fallback")
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
        
        // Save managerId if available
        if let managerId = smallWork.managerId {
            data["managerId"] = managerId.uuidString
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
        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection("organizations").document(orgId).collection("smallWorks").getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Server denied smallWorks read for \(orgId) - trying cache fallback")
                snapshot = try await db.collection("organizations").document(orgId).collection("smallWorks").getDocuments(source: .cache)
            } else {
                throw error
            }
        }
        print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Found \(snapshot.documents.count) small works documents in Firebase")
        
        var loadedSmallWorks: [Project] = []
        var skippedCount = 0
        
        for doc in snapshot.documents {
            let data = doc.data()
            let docId = doc.documentID
            print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Processing small works document: \(docId)")
            print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] Document data keys: \(data.keys.joined(separator: ", "))")
            
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
                smallWork = Project(
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
                    isLive: data["isLive"] as? Bool ?? true,
                    description: data["description"] as? String,
                    hiddenManagerUserIds: hiddenManagerUserIds,
                    hiddenOperativeUserIds: hiddenOperativeUserIds
                )
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
                legacySmallWork.customJobType = customJobType
                smallWork = legacySmallWork
            }
            
            loadedSmallWorks.append(smallWork)
            print("🔥🔥🔥 DEBUG: [LOAD SMALL WORKS] ✅ Successfully loaded small works: \(smallWork.siteName) (ID: \(smallWork.id.uuidString))")
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
        if doc.exists, let data = doc.data(), let jobTypesArray = data["jobTypes"] as? [String] {
            let jobTypes = Set(jobTypesArray)
            print("🔥🔥🔥 DEBUG: Loaded \(jobTypes.count) job types from Firebase")
            return jobTypes
        }
        print("🔥🔥🔥 DEBUG: No job types found in Firebase, returning empty set")
        return []
    }
    
    // MARK: - Project Task Management
    
    func loadProjectTasks(organizationId: String) async throws -> [ProjectTask] {
        let orgId = try await ensureReadableOrganization(organizationId)
        print("🔥🔥🔥 DEBUG: Loading tasks from Firebase for organization: \(orgId)")
        let tasksRef = db.collection("organizations").document(orgId).collection("tasks")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await tasksRef.getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [TASK LOAD] Server denied tasks read for \(orgId) - trying cache fallback")
                snapshot = try await tasksRef.getDocuments(source: .cache)
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: [TASK LOAD] Offline while loading tasks for \(orgId) - trying cache fallback")
                snapshot = try await tasksRef.getDocuments(source: .cache)
            } else {
                throw error
            }
        }
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
            
            // Load attached files/images
            let attachedFileURL = data["attachedFileURL"] as? String
            let attachedFileName = data["attachedFileName"] as? String
            let attachedImageURLs = data["attachedImageURLs"] as? [String] ?? []
            
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
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt,
                attachedFileURL: attachedFileURL,
                attachedFileName: attachedFileName,
                attachedImageURLs: attachedImageURLs,
                completedBy: completedBy,
                completedAt: completedAt,
                completionImages: completionImages,
                completionFiles: completionFiles,
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
        
        // Add attached images
        if !task.attachedImageURLs.isEmpty {
            data["attachedImageURLs"] = task.attachedImageURLs
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
        
        // Create secure path: organizations/{orgId}/tasks/{taskId}/files/{userId}_{timestamp}_{fileName}
        let timestamp = Int(Date().timeIntervalSince1970)
        let sanitizedFileName = fileName.replacingOccurrences(of: " ", with: "_")
        let filePath = "organizations/\(organizationId)/tasks/\(taskId.uuidString)/files/\(userId)_\(timestamp)_\(sanitizedFileName)"
        
        let storageRef = storage.reference().child(filePath)
        
        // Upload file using async/await wrapper
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putFile(from: fileURL, metadata: nil) { metadata, error in
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
    
    func uploadTaskImage(_ image: UIImage, taskId: UUID, organizationId: String, imageName: String) async throws -> String {
        guard let userId = currentUser?.uid,
              let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
        }
        
        // Create secure path: organizations/{orgId}/tasks/{taskId}/images/{userId}_{timestamp}_{imageName}
        let timestamp = Int(Date().timeIntervalSince1970)
        let sanitizedImageName = imageName.replacingOccurrences(of: " ", with: "_")
        let imagePath = "organizations/\(organizationId)/tasks/\(taskId.uuidString)/images/\(userId)_\(timestamp)_\(sanitizedImageName).jpg"
        
        let storageRef = storage.reference().child(imagePath)
        
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
    func uploadSiteAuditImage(_ image: UIImage, auditId: UUID, organizationId: String, imageName: String) async throws -> String {
        guard let userId = currentUser?.uid,
              let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let sanitizedImageName = imageName.replacingOccurrences(of: " ", with: "_")
        let imagePath = "organizations/\(organizationId)/siteAudits/\(auditId.uuidString)/images/\(userId)_\(timestamp)_\(sanitizedImageName).jpg"
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
        guard let imageData = image.jpegData(compressionQuality: 0.82) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
        }
        let path = "organizations/\(organizationId)/userProfiles/\(userId)/profile.jpg"
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

    func uploadOrganizationLogo(_ image: UIImage, organizationId: String) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        guard let imageData = image.jpegData(compressionQuality: 0.75) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to process logo image"])
        }
        let path = "organizations/\(organizationId)/branding/company_logo/\(userId)_\(Int(Date().timeIntervalSince1970)).jpg"
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
        qualificationId: UUID,
        fileName: String,
        contentType: String
    ) async throws -> String {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        if data.isEmpty {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "File is empty"])
        }
        // Conservative guardrail to avoid excessively large uploads from mobile.
        if data.count > 10 * 1024 * 1024 {
            throw NSError(domain: "FirebaseBackend", code: 413, userInfo: [NSLocalizedDescriptionKey: "File is too large. Please upload a file smaller than 10MB."])
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let sanitizedName = fileName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let path = "organizations/\(organizationId)/operatives/\(operativeId.uuidString)/qualifications/\(qualificationId.uuidString)/certificates/\(userId)_\(timestamp)_\(sanitizedName)"
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType
        
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(data, metadata: metadata) { metadata, error in
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
    #else
    func uploadTaskFile(_ fileURL: URL, taskId: UUID, organizationId: String, fileName: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available. Please add FirebaseStorage to your project dependencies via Xcode: File > Add Package Dependencies > https://github.com/firebase/firebase-ios-sdk"])
    }
    
    func uploadTaskImage(_ image: UIImage, taskId: UUID, organizationId: String, imageName: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available. Please add FirebaseStorage to your project dependencies via Xcode: File > Add Package Dependencies > https://github.com/firebase/firebase-ios-sdk"])
    }

    func uploadSiteAuditImage(_ image: UIImage, auditId: UUID, organizationId: String, imageName: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }

    func uploadUserProfilePhoto(_ image: UIImage, userId: String, organizationId: String) async throws -> String {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }
    
    func uploadQualificationDocument(
        data: Data,
        organizationId: String,
        operativeId: UUID,
        qualificationId: UUID,
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
                        "id": qualification.id.uuidString,
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
            "qualificationExpiryDates": Dictionary(uniqueKeysWithValues: operative.qualificationExpiryDates.map { ($0.key.uuidString, Timestamp(date: $0.value)) }),
            "qualificationCertificateURLs": Dictionary(uniqueKeysWithValues: operative.qualificationCertificateURLs.map { ($0.key.uuidString, $0.value) }),
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
        let snapshot: QuerySnapshot
        do {
            snapshot = try await operativesRef.getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Server denied operatives read for \(orgId) - trying cache fallback")
                snapshot = try await operativesRef.getDocuments(source: .cache)
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Offline while loading operatives for \(orgId) - trying cache fallback")
                snapshot = try await operativesRef.getDocuments(source: .cache)
            } else {
                throw error
            }
        }
        print("🔥🔥🔥 DEBUG: [LOAD OPERATIVES] Found \(snapshot.documents.count) operative documents")
        
        // Filter out legacy INITIAL-PLACEHOLDER documents
        return snapshot.documents.compactMap { (doc: QueryDocumentSnapshot) -> Operative? in
            // Skip legacy placeholder documents
            if doc.documentID == "INITIAL-PLACEHOLDER" {
                return nil
            }
            let data = doc.data()
            
            guard let startDate = (data["startDate"] as? Timestamp)?.dateValue(),
                  let skillsArray = data["skills"] as? [String] else {
                return nil
            }
            
            let skills = Set(skillsArray)
            
            // Parse qualifications
            var qualifications: Set<Qualification> = []
            if let qualificationsArray = data["qualifications"] as? [[String: Any]] {
                for qualificationData in qualificationsArray {
                    if let idString = qualificationData["id"] as? String,
                       let id = UUID(uuidString: idString),
                       let name = qualificationData["name"] as? String,
                       let hasEndDate = qualificationData["hasEndDate"] as? Bool,
                       let createdAt = (qualificationData["createdAt"] as? Timestamp)?.dateValue(),
                       let updatedAt = (qualificationData["updatedAt"] as? Timestamp)?.dateValue() {
                        
                        let endDate = (qualificationData["endDate"] as? Timestamp)?.dateValue()
                        
                        let qualification = Qualification(
                            id: id,
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
            
            var qualificationExpiryDates: [UUID: Date] = [:]
            if let expiryMap = data["qualificationExpiryDates"] as? [String: Any] {
                for (key, rawDate) in expiryMap {
                    guard let qualificationId = UUID(uuidString: key) else { continue }
                    if let ts = rawDate as? Timestamp {
                        qualificationExpiryDates[qualificationId] = ts.dateValue()
                    } else if let date = rawDate as? Date {
                        qualificationExpiryDates[qualificationId] = date
                    }
                }
            }
            
            var qualificationCertificateURLs: [UUID: String] = [:]
            if let certificateMap = data["qualificationCertificateURLs"] as? [String: String] {
                for (key, url) in certificateMap {
                    guard let qualificationId = UUID(uuidString: key) else { continue }
                    qualificationCertificateURLs[qualificationId] = url
                }
            } else if let certificateMapAny = data["qualificationCertificateURLs"] as? [String: Any] {
                for (key, rawURL) in certificateMapAny {
                    guard let qualificationId = UUID(uuidString: key),
                          let url = rawURL as? String else { continue }
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
                    isActive: data["isActive"] as? Bool ?? true,
                    hourlyRate: loadedHourly,
                    dayRate: loadedDay ?? loadedHourly,
                    currencySymbol: data["currencySymbol"] as? String,
                    notes: data["notes"] as? String,
                    tradeTypePreset: (tp?.isEmpty == false) ? tp : nil,
                    tradeTypeCustom: (tc?.isEmpty == false) ? tc : nil,
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                    updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
                )
                
                print("🔥🔥🔥 DEBUG: Loaded operative: \(operative.name), skills: \(Array(operative.skills))")
                return operative
        }
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
        print("🔥🔥🔥 DEBUG: === Listing All Organizations ===")
        print("🔥🔥🔥 DEBUG: Function called successfully!")
        
        do {
            print("🔥🔥🔥 DEBUG: Attempting to fetch organizations...")
            let snapshot = try await db.collection("organizations").getDocuments()
            print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) organizations")
            
            for document in snapshot.documents {
                let data = document.data()
                print("🔥🔥🔥 DEBUG: Organization ID: \(document.documentID)")
                print("🔥🔥🔥 DEBUG: Organization Name: \(data["name"] ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Members: \(data["members"] ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Created At: \(data["createdAt"] ?? "N/A")")
                print("---")
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error fetching organizations: \(error.localizedDescription)")
        }
        
        print("🔥🔥🔥 DEBUG: === End Organizations List ===")
    }
    
    func debugUsers() async {
        print("🔥🔥🔥 DEBUG: === Listing All Users ===")
        print("🔥🔥🔥 DEBUG: Function called successfully!")
        
        do {
            print("🔥🔥🔥 DEBUG: Attempting to fetch users...")
            let snapshot = try await db.collection("users").getDocuments()
            print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) users")
            
            for document in snapshot.documents {
                let data = document.data()
                print("🔥🔥🔥 DEBUG: User ID: \(document.documentID)")
                print("🔥🔥🔥 DEBUG: Email: \(data["email"] ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Organization ID: \(data["organizationId"] ?? "N/A")")
                print("🔥🔥🔥 DEBUG: Role: \(data["role"] ?? "N/A")")
                print("---")
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
            
            print("🔥🔥🔥 DEBUG: Saving manager to organizations/\(organizationId)/managers/\(manager.id.uuidString)")
            
            try await db.collection("organizations").document(organizationId).collection("managers").document(manager.id.uuidString).setData(data)
            
            print("🔥🔥🔥 DEBUG: Manager saved successfully to Firebase")
        }
        
        func loadManagers(organizationId: String) async throws -> [Manager] {
            let orgId = try await ensureReadableOrganization(organizationId)
            print("🔥🔥🔥 DEBUG: [LOAD MANAGERS] Starting load for organization: \(orgId)")
            let snapshot = try await db.collection("organizations").document(orgId).collection("managers").getDocuments(source: .server)
            print("🔥🔥🔥 DEBUG: [LOAD MANAGERS] Found \(snapshot.documents.count) manager documents")
            
            var managers: [Manager] = []
            
            for doc in snapshot.documents {
                let data = doc.data()
                
                guard let firstName = data["firstName"] as? String,
                      let lastName = data["lastName"] as? String,
                      let email = data["email"] as? String,
                      let mobileNumber = data["mobileNumber"] as? String,
                      let isActive = data["isActive"] as? Bool,
                      let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                      let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
                    print("🔥🔥🔥 DEBUG: Failed to parse manager data for document: \(doc.documentID)")
                    continue
                }
                
                let id = UUID(uuidString: doc.documentID) ?? UUID()
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
                    tradeTypeCustom: (mtc?.isEmpty == false) ? mtc : nil
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
        try await db.collection("organizations").document(organizationId).collection("managers").document(manager.id.uuidString).delete()
        print("🔥🔥🔥 DEBUG: Manager deleted successfully from Firebase")
    }
    
    // Check if organization needs setup (has no clients, projects, or managers)
    private func checkIfSetupNeeded(organizationId: String) async {
        do {
            // Check if organization has any clients, projects, or managers
            let clientsSnapshot = try await db.collection("organizations").document(organizationId).collection("clients").limit(to: 1).getDocuments()
            let projectsSnapshot = try await db.collection("organizations").document(organizationId).collection("projects").limit(to: 1).getDocuments()
            let managersSnapshot = try await db.collection("organizations").document(organizationId).collection("managers").limit(to: 1).getDocuments()
            
            let hasClients = !clientsSnapshot.documents.isEmpty
            let hasProjects = !projectsSnapshot.documents.isEmpty
            let hasManagers = !managersSnapshot.documents.isEmpty
            
            // If no data exists, show setup flow
            if !hasClients && !hasProjects && !hasManagers {
                await MainActor.run {
                    self.shouldShowSetupFlow = true
                    print("🔥🔥🔥 DEBUG: Organization has no data, showing setup flow")
                }
            } else {
                await MainActor.run {
                    self.shouldShowSetupFlow = false
                    self.isNewOrganization = false
                    print("🔥🔥🔥 DEBUG: Organization has data, setup flow not needed")
                }
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error checking setup status: \(error.localizedDescription)")
            // On error, assume setup is not needed
            await MainActor.run {
                self.shouldShowSetupFlow = false
                self.isNewOrganization = false
            }
        }
    }
    
    func saveQualifications(organizationId: String, qualifications: [Qualification]) async throws {
        let batch = db.batch()
        
        // Clear existing qualifications
        let existingSnapshot = try await db.collection("organizations").document(organizationId).collection("qualifications").getDocuments()
        for document in existingSnapshot.documents {
            batch.deleteDocument(document.reference)
        }
        
        // Add new qualifications
        for qualification in qualifications {
            let docRef = db.collection("organizations").document(organizationId).collection("qualifications").document(qualification.id.uuidString)
            var data: [String: Any] = [
                "name": qualification.name,
                "hasEndDate": qualification.hasEndDate,
                "createdAt": Timestamp(date: qualification.createdAt),
                "updatedAt": Timestamp(date: qualification.updatedAt)
            ]
            
            if let endDate = qualification.endDate {
                data["endDate"] = Timestamp(date: endDate)
            }
            
            batch.setData(data, forDocument: docRef)
        }
        
        try await batch.commit()
        print("🔥🔥🔥 DEBUG: Successfully saved \(qualifications.count) qualifications to Firebase")
    }
    
    func saveSkills(organizationId: String, skills: Set<String>) async throws {
        let batch = db.batch()
        
        // Clear existing skills
        let existingSnapshot = try await db.collection("organizations").document(organizationId).collection("skills").getDocuments()
        for document in existingSnapshot.documents {
            batch.deleteDocument(document.reference)
        }
        
        // Add new skills
        for skill in skills {
            let docRef = db.collection("organizations").document(organizationId).collection("skills").document()
            let data: [String: Any] = [
                "name": skill,
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
            
            batch.setData(data, forDocument: docRef)
        }
        
        try await batch.commit()
        print("🔥🔥🔥 DEBUG: Successfully saved \(skills.count) skills to Firebase")
    }
    
    func loadQualifications(organizationId: String) async throws -> [Qualification] {
        let orgId = try await ensureReadableOrganization(organizationId)
        let snapshot = try await db.collection("organizations").document(orgId).collection("qualifications").getDocuments(source: .server)
        
        var qualifications: [Qualification] = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            
            guard let name = data["name"] as? String,
                  let hasEndDate = data["hasEndDate"] as? Bool,
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
                print("🔥🔥🔥 DEBUG: Failed to parse qualification data for document: \(doc.documentID)")
                continue
            }
            
            let id = UUID(uuidString: doc.documentID) ?? UUID()
            let endDate = (data["endDate"] as? Timestamp)?.dateValue()
            
            let qualification = Qualification(
                id: id,
                name: name,
                hasEndDate: hasEndDate,
                endDate: endDate,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            
            qualifications.append(qualification)
        }
        
        return qualifications
    }
    
    func loadSkills(organizationId: String) async throws -> Set<String> {
        let orgId = try await ensureReadableOrganization(organizationId)
        let snapshot = try await db.collection("organizations").document(orgId).collection("skills").getDocuments(source: .server)
        
        var skills: Set<String> = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            
            if let skillName = data["name"] as? String {
                skills.insert(skillName)
            }
        }
        
        print("🔥🔥🔥 DEBUG: Loaded \(skills.count) skills from Firebase")
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
        let doc = try await db.collection("users").document(userId).getDocument(source: .server)
        
        if !doc.exists {
            // Invited users often have users/{randomUUID} until first sign-in; merge onto Auth UID.
            if let auth = Auth.auth().currentUser, auth.uid == userId, let authEmail = auth.email, !authEmail.isEmpty {
                try await mergePlaceholderUserDocOntoAuthUidIfNeeded(authUid: userId, email: authEmail)
                let retry = try await db.collection("users").document(userId).getDocument(source: .server)
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
    
    /// Copies Firestore fields from an older `users/*` row (same email, different document id) to `users/{authUid}`.
    private func mergePlaceholderUserDocOntoAuthUidIfNeeded(authUid: String, email rawEmail: String) async throws {
        let variants = Array(Set([
            rawEmail,
            rawEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }))
        
        for variant in variants {
            let snap = try await db.collection("users")
                .whereField("email", isEqualTo: variant)
                .limit(to: 8)
                .getDocuments(source: .server)
            
            for placeholder in snap.documents where placeholder.documentID != authUid {
                guard let orgId = organizationIdFromFirestore(placeholder.data()["organizationId"]) else { continue }
                print("🔥🔥🔥 DEBUG: Merging invited user doc \(placeholder.documentID) → \(authUid) for email \(variant)")
                var merged = placeholder.data()
                merged["email"] = rawEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                merged["organizationId"] = orgId
                merged["updatedAt"] = Timestamp(date: Date())
                merged["passwordSet"] = true
                try await db.collection("users").document(authUid).setData(merged, merge: true)
                let norm = rawEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                try await db.collection("organizations").document(orgId)
                    .collection("userEmails").document(norm)
                    .setData(["userId": authUid], merge: true)
                return
            }
        }
    }
    
    private static func parseAppUserDocument(userId: String, data: [String: Any]) -> AppUser {
        let email = data["email"] as? String ?? ""
        let organizationId = organizationIdFromFirestore(data["organizationId"]) ?? ""
        let roleString = data["role"] as? String ?? "viewer"
        let role = UserRole(rawValue: roleString) ?? .viewer
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        
        let operativeMode = data["operativeMode"] as? Bool ?? false
        let permissions = UserPermissions(
            adminAccess: operativeMode ? false : (data["adminAccess"] as? Bool ?? false),
            manager: operativeMode ? false : (data["manager"] as? Bool ?? false),
            operatives: operativeMode ? false : (data["operatives"] as? Bool ?? false),
            skills: operativeMode ? false : (data["skills"] as? Bool ?? false),
            qualifications: operativeMode ? false : (data["qualifications"] as? Bool ?? false),
            materials: operativeMode ? (data["materials"] as? Bool ?? false) : (data["materials"] as? Bool ?? true),
            projects: operativeMode ? true : (data["projects"] as? Bool ?? false),
            smallWorks: operativeMode ? true : (data["smallWorks"] as? Bool ?? false),
            operativeMode: operativeMode,
            annualLeaveSelfBook: data["annualLeaveSelfBook"] as? Bool ?? false,
            weeklyReports: data["weeklyReports"] as? Bool ?? false,
            subContractors: data["subContractors"] as? Bool ?? false,
            siteAudit: data["siteAudit"] as? Bool ?? true
        )
        let policyAccepted = data["policyAccepted"] as? Bool ?? false
        let policyAcceptedAt = (data["policyAcceptedAt"] as? Timestamp)?.dateValue()
        let rawIsSuperAdmin = data["isSuperAdmin"] as? Bool ?? false
        let isSuperAdmin = operativeMode ? false : rawIsSuperAdmin
        let resolvedRole: UserRole = operativeMode ? .operative : role
        
        let assignedManagerUserId = data["assignedManagerUserId"] as? String
        let dayRate = data["dayRate"] as? Double
        let utp = (data["tradeTypePreset"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let utc = (data["tradeTypeCustom"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profilePhotoRaw = (data["profilePhotoURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return AppUser(
            id: userId,
            email: email,
            organizationId: organizationId,
            role: resolvedRole,
            createdAt: createdAt,
            firstName: data["firstName"] as? String ?? "",
            surname: data["surname"] as? String ?? "",
            mobileNumber: data["mobileNumber"] as? String,
            isActive: data["isActive"] as? Bool ?? true,
            passwordSet: data["passwordSet"] as? Bool ?? false,
            permissions: permissions,
            isSuperAdmin: isSuperAdmin,
            policyAccepted: policyAccepted,
            policyAcceptedAt: policyAcceptedAt,
            assignedManagerUserId: assignedManagerUserId,
            dayRate: dayRate,
            tradeTypePreset: (utp?.isEmpty == false) ? utp : nil,
            tradeTypeCustom: (utc?.isEmpty == false) ? utc : nil,
            profilePhotoURL: (profilePhotoRaw?.isEmpty == false) ? profilePhotoRaw : nil
        )
    }
    
    func getOrganizationUsers(organizationId: String) async throws -> [AppUser] {
        print("🔥🔥🔥 DEBUG: getOrganizationUsers called with organizationId: \(organizationId)")
        
        let query = db.collection("users")
            .whereField("organizationId", isEqualTo: organizationId)
        let snapshot: QuerySnapshot
        do {
            snapshot = try await query.getDocuments(source: .server)
        } catch {
            // Offline: fall back to cache so the app still works; when back online we'll get fresh data
            snapshot = try await query.getDocuments()
        }
        
        print("🔥🔥🔥 DEBUG: Found \(snapshot.documents.count) user documents")
        
        var users: [AppUser] = []
        
        for doc in snapshot.documents {
            let data = doc.data()
            let userId = doc.documentID
            let email = data["email"] as? String ?? ""
            let docOrganizationId = organizationIdFromFirestore(data["organizationId"]) ?? ""
            
            print("🔥🔥🔥 DEBUG: Processing user - DocumentID: \(userId), Email: \(email), DocOrgId: \(docOrganizationId), RequestedOrgId: \(organizationId)")
            
            guard organizationIdsMatch(docOrganizationId, organizationId) else {
                print("🔥🔥🔥 DEBUG: Skipping user \(email) - organizationId mismatch")
                continue
            }
            
            var user = Self.parseAppUserDocument(userId: userId, data: data)
            user.organizationId = organizationId
            
            users.append(user)
            print("🔥🔥🔥 DEBUG: Added user to list: \(user.email) (\(user.firstName) \(user.surname))")
        }
        
        // Deduplicate by email: prefer the document that has passwordSet: true (the one they use to log in)
        // so we don't show "Pending" for someone who has already signed up and logged in.
        var byEmail: [String: AppUser] = [:]
        for user in users {
            let key = user.email.lowercased()
            if let existing = byEmail[key] {
                let preferNew = user.passwordSet && !existing.passwordSet
                let preferExisting = existing.passwordSet && !user.passwordSet
                if preferNew {
                    byEmail[key] = user
                    print("🔥🔥🔥 DEBUG: Preferring user doc \(user.id) (passwordSet: true) over \(existing.id) for \(user.email)")
                } else if !preferExisting {
                    byEmail[key] = user
                }
            } else {
                byEmail[key] = user
            }
        }
        let uniqueUsers = Array(byEmail.values)
        
        print("🔥🔥🔥 DEBUG: Returning \(uniqueUsers.count) unique users (deduplicated by email, preferring passwordSet: true)")
        return uniqueUsers
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
        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "adminUserId": adminUserId,
            "creatorUserId": adminUserId,
            "countryCode": countryCode.uppercased(),
            "createdAt": Timestamp(date: Date()),
            "updatedAt": Timestamp(date: Date())
        ]
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
        try await db.collection("organizations").document(id).setData(payload, merge: true)
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
        defaultLongitude: Double?
    ) async throws {
        guard let orgId = currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No organization loaded"]
            )
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Organisation name is required"]
            )
        }
        var payload: [String: Any] = [
            "name": trimmedName,
            "countryCode": countryCode.uppercased(),
            "updatedAt": Timestamp(date: Date())
        ]
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
        try await db.collection("organizations").document(orgId).updateData(payload)
        
        guard var org = currentOrganization else { return }
        org.name = trimmedName
        org.countryCode = countryCode.uppercased()
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
        // CRITICAL: Operative mode is the single source of truth – never persist admin/super-admin for operatives
        let isSuperAdminToSave = user.permissions.operativeMode ? false : user.isSuperAdmin
        let roleToSave: UserRole = user.permissions.operativeMode ? .operative : user.role
        var userData: [String: Any] = [
            "email": user.email,
            "organizationId": user.organizationId,
            "role": roleToSave.rawValue,
            "createdAt": Timestamp(date: user.createdAt),
            "firstName": user.firstName,
            "surname": user.surname,
            "isActive": user.isActive,
            "passwordSet": user.passwordSet,
            "adminAccess": user.permissions.operativeMode ? false : user.permissions.adminAccess,
            "manager": user.permissions.operativeMode ? false : user.permissions.manager,
            "operatives": user.permissions.operativeMode ? false : user.permissions.operatives,
            "skills": user.permissions.operativeMode ? false : user.permissions.skills,
            "qualifications": user.permissions.operativeMode ? false : user.permissions.qualifications,
            "materials": user.permissions.operativeMode ? user.permissions.materials : true,
            "projects": user.permissions.projects,
            "smallWorks": user.permissions.smallWorks,
            "operativeMode": user.permissions.operativeMode,
            "annualLeaveSelfBook": user.permissions.annualLeaveSelfBook,
            "weeklyReports": user.permissions.weeklyReports,
            "subContractors": user.permissions.subContractors,
            "siteAudit": user.permissions.siteAudit,
            "isSuperAdmin": isSuperAdminToSave,
            "policyAccepted": user.policyAccepted,
            "updatedAt": Timestamp(date: Date())
        ]
        
        if let mobileNumber = user.mobileNumber {
            userData["mobileNumber"] = mobileNumber
        }
        
        if let policyAcceptedAt = user.policyAcceptedAt {
            userData["policyAcceptedAt"] = Timestamp(date: policyAcceptedAt)
        }
        
        if user.permissions.operativeMode,
           let mid = user.assignedManagerUserId,
           !mid.isEmpty {
            userData["assignedManagerUserId"] = mid
        }
        
        if (user.permissions.operativeMode || user.permissions.manager), let dr = user.dayRate {
            userData["dayRate"] = dr
        }
        
        if user.permissions.operativeMode || user.permissions.manager {
            if let p = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                userData["tradeTypePreset"] = p
            }
            if let c = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                userData["tradeTypeCustom"] = c
            }
        }
        
        if let photo = user.profilePhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !photo.isEmpty {
            userData["profilePhotoURL"] = photo
        } else {
            userData["profilePhotoURL"] = FieldValue.delete()
        }
        
        try await db.collection("users").document(user.id).setData(userData)
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
    func updateOperativeProfileMetadata(userId: String, assignedManagerUserId: String?, dayRate: Double?) async throws {
        var payload: [String: Any] = [
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

    /// Transfers organization ownership by updating `creatorUserId` and flipping `isSuperAdmin` between old and new owners.
    /// - Important: Callers must ensure `newCreatorUserId` is an admin and not an operative.
    func transferOrganizationOwnership(organizationId: String, newCreatorUserId: String) async throws {
        // Determine current owner
        let oldCreatorUserId = currentOrganization?.creatorUserId ?? currentUser?.uid

        // Update org ownership
        try await db.collection("organizations").document(organizationId).updateData([
            "creatorUserId": newCreatorUserId,
            "updatedAt": Timestamp(date: Date())
        ])

        // Flip super admin flags
        if let oldId = oldCreatorUserId, oldId != newCreatorUserId {
            try? await db.collection("users").document(oldId).updateData([
                "isSuperAdmin": false,
                "updatedAt": Timestamp(date: Date())
            ])
        }

        try await db.collection("users").document(newCreatorUserId).updateData([
            "isSuperAdmin": true,
            "adminAccess": true,
            "role": UserRole.admin.rawValue,
            "updatedAt": Timestamp(date: Date())
        ])

        // Update in-memory org cache
        if currentOrganization?.firestoreDocumentId == organizationId {
            currentOrganization?.creatorUserId = newCreatorUserId
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
            try await db.collection("users").document(uid).setData([
                "pushTokens": FieldValue.arrayUnion([trimmed]),
                "pushTokenUpdatedAt": Timestamp(date: Date())
            ], merge: true)
            // Backward compatibility: invitations may still reference legacy users/{placeholderId}.
            // Mirror this token into same-email docs so targeted push still works during id convergence.
            let normalizedEmail = authUser.email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedEmail.isEmpty {
                var candidateDocs: [QueryDocumentSnapshot] = []
                if let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
                    // Case-insensitive email matching within org to catch legacy mixed-case rows.
                    let orgUsers = try await db.collection("users")
                        .whereField("organizationId", isEqualTo: orgId)
                        .limit(to: 250)
                        .getDocuments(source: .server)
                    candidateDocs = orgUsers.documents.filter { doc in
                        let email = (doc.data()["email"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased() ?? ""
                        return !email.isEmpty && email == normalizedEmail
                    }
                } else {
                    let sameEmail = try await db.collection("users")
                        .whereField("email", isEqualTo: normalizedEmail)
                        .limit(to: 12)
                        .getDocuments(source: .server)
                    candidateDocs = sameEmail.documents
                }
                for doc in candidateDocs where doc.documentID != uid {
                    try await db.collection("users").document(doc.documentID).setData([
                        "pushTokens": FieldValue.arrayUnion([trimmed]),
                        "pushTokenUpdatedAt": Timestamp(date: Date())
                    ], merge: true)
                    print("🔥🔥🔥 DEBUG: Mirrored push token from \(uid) to legacy user doc \(doc.documentID)")
                }
            }
            print("🔥🔥🔥 DEBUG: Registered push token for user \(uid)")
        } catch {
            print("🔥🔥🔥 DEBUG: Failed to register push token: \(error.localizedDescription)")
        }
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
    
    func saveNotification(_ notification: AppNotification, organizationId: String) async throws {
        let data: [String: Any] = [
            "organizationId": notification.organizationId,
            "type": notification.type.rawValue,
            "title": notification.title,
            "message": notification.message,
            "userId": notification.userId ?? NSNull(),
            "relatedId": notification.relatedId?.uuidString ?? NSNull(),
            "isRead": notification.isRead,
            "createdAt": Timestamp(date: notification.createdAt),
            "requiresPermission": notification.requiresPermission ?? NSNull()
        ]
        
        try await db.collection("organizations").document(organizationId).collection("notifications").document(notification.id.uuidString).setData(data)
        print("🔥🔥🔥 DEBUG: [FIREBASE SAVE NOTIFICATION OK] org=\(organizationId) id=\(notification.id.uuidString) type=\(notification.type.rawValue) target=\(notification.userId ?? "broadcast")")
    }
    
    func loadNotifications(organizationId: String) async throws -> [AppNotification] {
        let notificationsRef = db.collection("organizations").document(organizationId).collection("notifications")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await notificationsRef.getDocuments(source: .server)
        } catch {
            let nsError = error as NSError
            if (nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7) || isOfflineNetworkError(error) {
                snapshot = try await notificationsRef.getDocuments(source: .cache)
            } else {
                throw error
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
            let relatedId = relatedIdString != nil ? UUID(uuidString: relatedIdString!) : nil
            let requiresPermission = data["requiresPermission"] as? String
            
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
                requiresPermission: requiresPermission
            )
            
            notifications.append(notification)
        }
        
        return notifications.sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - User Invitation
    
    func createUserInvitation(email: String, organizationId: String, invitedBy: String, firstName: String, surname: String, mobileNumber: String?, permissions: UserPermissions, assignedManagerUserId: String? = nil, invitedOperativeDayRate: Double? = nil, invitedManagerDayRate: Double? = nil, invitedTradeTypePreset: String? = nil, invitedTradeTypeCustom: String? = nil) async throws {
        print("🔥🔥🔥 DEBUG: createUserInvitation called with email: \(email), organizationId: \(organizationId), invitedBy: \(invitedBy)")
        
        let emailLower = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Check if user already exists in this organization (case-insensitive).
        // Use server source so we don't treat a deleted user as still existing due to cache.
        let existingUsersQuery = try await db.collection("users")
            .whereField("email", isEqualTo: emailLower)
            .whereField("organizationId", isEqualTo: organizationId)
            .getDocuments(source: .server)
        
        if !existingUsersQuery.documents.isEmpty {
            print("🔥🔥🔥 DEBUG: ❌ ERROR: User with email \(email) already exists in this organization")
            // Check if it's the same user or a duplicate
            for doc in existingUsersQuery.documents {
                let data = doc.data()
                let existingEmail = data["email"] as? String ?? ""
                let existingFirstName = data["firstName"] as? String ?? ""
                let existingSurname = data["surname"] as? String ?? ""
                print("🔥🔥🔥 DEBUG: Found existing user document: \(doc.documentID), name: \(existingFirstName) \(existingSurname), email: \(existingEmail)")
            }
            // Throw error to prevent duplicate creation
            throw NSError(
                domain: "UserCreationError",
                code: 409, // Conflict
                userInfo: [
                    NSLocalizedDescriptionKey: "A user with the email address '\(email)' already exists in this organization. Each email address can only be used once per organization."
                ]
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
            "permissions": [
                "adminAccess": permissions.adminAccess,
                "manager": permissions.manager,
                "operatives": permissions.operatives,
                "skills": permissions.skills,
                "qualifications": permissions.qualifications,
                    "materials": permissions.materials,
                "projects": permissions.projects,
                "smallWorks": permissions.smallWorks,
                "operativeMode": permissions.operativeMode,
                "annualLeaveSelfBook": permissions.annualLeaveSelfBook,
                "weeklyReports": permissions.weeklyReports,
                "subContractors": permissions.subContractors,
                "siteAudit": permissions.siteAudit
            ],
            "createdAt": Timestamp(date: Date()),
            "isUsed": false
        ]
        
        if permissions.operativeMode, let mid = assignedManagerUserId, !mid.isEmpty {
            invitationData["assignedManagerUserId"] = mid
        }
        if permissions.operativeMode, let dr = invitedOperativeDayRate {
            invitationData["dayRate"] = dr
        }
        if permissions.manager, let dr = invitedManagerDayRate {
            invitationData["dayRate"] = dr
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
        
        print("🔥🔥🔥 DEBUG: Invitation data: \(invitationData)")
        
        try await db.collection("invitations").document(invitationId).setData(invitationData)
        
        print("🔥🔥🔥 DEBUG: Invitation document created successfully")
        
        // Only create user document if they don't already exist
        if existingUsersQuery.documents.isEmpty {
            // Create user document immediately so they appear in manage users list
            // User will have passwordSet: false until they accept invitation
            let userId = UUID().uuidString
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
                guard permissions.operativeMode, let m = assignedManagerUserId, !m.isEmpty else { return nil }
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
                isActive: true,
                passwordSet: false, // Will be set to true when they accept invitation and set password
                permissions: permissions, // Use the permissions from the invitation
                isSuperAdmin: false,
                assignedManagerUserId: operativeManagerId,
                dayRate: permissions.operativeMode ? invitedOperativeDayRate : (permissions.manager ? invitedManagerDayRate : nil),
                tradeTypePreset: (permissions.operativeMode || permissions.manager) && inviteTp?.isEmpty == false ? inviteTp : nil,
                tradeTypeCustom: (permissions.operativeMode || permissions.manager) && inviteTc?.isEmpty == false ? inviteTc : nil
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
                    "skills": newUser.permissions.skills,
                    "qualifications": newUser.permissions.qualifications,
                    "materials": newUser.permissions.materials,
                    "operativeMode": newUser.permissions.operativeMode,
                    "annualLeaveSelfBook": newUser.permissions.annualLeaveSelfBook,
                    "weeklyReports": newUser.permissions.weeklyReports,
                    "subContractors": newUser.permissions.subContractors,
                    "siteAudit": newUser.permissions.siteAudit,
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
        } else {
            print("🔥🔥🔥 DEBUG: User already exists - updating existing user with new invitation info if needed")
            // Optionally update the existing user's permissions if they changed
            if let existingDoc = existingUsersQuery.documents.first {
                let existingUserId = existingDoc.documentID
                
                // Update user with latest invitation info (permissions, etc.)
                var updateData: [String: Any] = [
                    "firstName": firstName,
                    "surname": surname,
                    "adminAccess": permissions.adminAccess,
                    "manager": permissions.manager,
                    "operatives": permissions.operatives,
                    "skills": permissions.skills,
                    "qualifications": permissions.qualifications,
                    "materials": permissions.materials,
                    "projects": permissions.projects,
                    "smallWorks": permissions.smallWorks,
                    "operativeMode": permissions.operativeMode,
                    "annualLeaveSelfBook": permissions.annualLeaveSelfBook,
                    "weeklyReports": permissions.weeklyReports,
                    "subContractors": permissions.subContractors,
                    "siteAudit": permissions.siteAudit
                ]
                
                if permissions.operativeMode, let mid = assignedManagerUserId, !mid.isEmpty {
                    updateData["assignedManagerUserId"] = mid
                } else {
                    updateData["assignedManagerUserId"] = FieldValue.delete()
                }
                
                if let mobileNumber = mobileNumber, !mobileNumber.isEmpty {
                    updateData["mobileNumber"] = mobileNumber
                }
                
                try await db.collection("users").document(existingUserId).updateData(updateData)
                print("🔥🔥🔥 DEBUG: ✅ Updated existing user with new invitation data")
            }
        }
        
        // Send invitation email
        await sendInvitationEmail(email: email, firstName: firstName, surname: surname, invitationId: invitationId)
    }
    
    func sendInvitationEmail(email: String, firstName: String, surname: String, invitationId: String) async {
        print("🔥🔥🔥 DEBUG: Sending invitation email to: \(email)")
        
        let fromName = currentOrganization?.name
        let resendService = ResendEmailService()
        let success = await resendService.sendPasswordSetupEmail(
            to: email,
            firstName: firstName,
            surname: surname,
            invitationCode: invitationId,
            fromName: fromName
        )
        
        if success {
            print("🔥🔥🔥 DEBUG: ✅ Invitation email sent successfully to: \(email)")
        } else {
            print("🔥🔥🔥 DEBUG: ❌ Failed to send invitation email to: \(email)")
            // Fallback to plain text email via EmailService
            let subject = "Welcome to Project Planner - Set Up Your Account"
            let body = """
            Hello \(firstName) \(surname),
            
            You have been invited to join the Project Planner system.
            
            To set up your account and create your password, please visit:
            https://project-planner-f986c.web.app/setup-password.html?token=\(invitationId)
            
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
        let snapshot = try await db.collection("users").getDocuments()
        
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
        
        let bookingData: [String: Any] = [
            "id": booking.id.uuidString,
            "operativeId": booking.operativeId.uuidString,
            "projectId": booking.projectId.uuidString,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "bookedBy": booking.bookedBy,
            "notes": booking.notes ?? "",
            "status": booking.status.rawValue,
            "createdAt": Timestamp(date: booking.createdAt),
            "updatedAt": Timestamp(date: booking.updatedAt)
        ]
        
        print("🔥🔥🔥 DEBUG: Saving booking to organizations/\(orgId)/bookings/\(booking.id.uuidString)")
        
        try await db.collection("organizations").document(orgId).collection("bookings").document(booking.id.uuidString).setData(bookingData, merge: true)
        
        print("🔥🔥🔥 DEBUG: Booking saved successfully to Firebase")
    }
    
    func loadBookings(organizationId: String) async throws -> [Booking] {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        let bookingsRef = db.collection("organizations").document(orgId).collection("bookings")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await bookingsRef.getDocuments(source: .server)
        } catch {
            if isFirestorePermissionDenied(error) {
                print("🔥🔥🔥 DEBUG: [BOOKING LOAD] Server denied bookings read for \(orgId) - trying cache fallback")
                snapshot = try await bookingsRef.getDocuments(source: .cache)
            } else if isOfflineNetworkError(error) {
                print("🔥🔥🔥 DEBUG: [BOOKING LOAD] Offline while loading bookings for \(orgId) - trying cache fallback")
                snapshot = try await bookingsRef.getDocuments(source: .cache)
            } else {
                throw error
            }
        }
        
        return snapshot.documents.compactMap { doc in
            let data = doc.data()
            
            guard let operativeIdString = data["operativeId"] as? String,
                  let operativeId = UUID(uuidString: operativeIdString),
                  let projectIdString = data["projectId"] as? String,
                  let projectId = UUID(uuidString: projectIdString),
                  let date = (data["date"] as? Timestamp)?.dateValue(),
                  let timeSlotString = data["timeSlot"] as? String,
                  let timeSlot = TimeSlot(rawValue: timeSlotString),
                  let bookedBy = data["bookedBy"] as? String,
                  let statusString = data["status"] as? String,
                  let status = BookingStatus(rawValue: statusString) else {
                return nil
            }
            
            let id = UUID(uuidString: doc.documentID) ?? UUID()
            let notes = data["notes"] as? String
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
            
            return Booking(
                id: id,
                operativeId: operativeId,
                projectId: projectId,
                date: date,
                timeSlot: timeSlot,
                bookedBy: bookedBy,
                notes: notes,
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }
    
    func deleteBooking(_ booking: Booking, organizationId: String) async throws {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        try await db.collection("organizations").document(orgId).collection("bookings").document(booking.id.uuidString).delete()
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
        try await db.collection("organizations").document(organizationId).collection("managerSiteBookings").document(booking.id.uuidString).setData(data, merge: true)
    }

    func loadManagerSiteBookings(organizationId: String) async throws -> [ManagerSiteBooking] {
        let snapshot = try await db.collection("organizations").document(organizationId).collection("managerSiteBookings").getDocuments()
        return snapshot.documents.compactMap { doc -> ManagerSiteBooking? in
            let data = doc.data()
            guard let userId = data["userId"] as? String,
                  let date = (data["date"] as? Timestamp)?.dateValue(),
                  let timeSlotRaw = data["timeSlot"] as? String,
                  let timeSlot = ManagerTimeSlot(rawValue: timeSlotRaw),
                  let locationTypeRaw = data["locationType"] as? String,
                  let locationType = ManagerLocationType(rawValue: locationTypeRaw) else { return nil }
            let id = UUID(uuidString: doc.documentID) ?? UUID()
            let locationId = (data["locationId"] as? String).flatMap { UUID(uuidString: $0) }
            let customLocationName = data["customLocationName"] as? String
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
            return ManagerSiteBooking(id: id, userId: userId, date: date, timeSlot: timeSlot, locationType: locationType, locationId: locationId, customLocationName: customLocationName, createdAt: createdAt, updatedAt: updatedAt)
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
        try await db.collection("organizations").document(orgId).collection("holidayBookings").document(booking.id.uuidString).setData(data, merge: true)
    }

    func loadHolidayBookings(organizationId: String) async throws -> [HolidayBooking] {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
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
        return snapshot.documents.compactMap { doc -> HolidayBooking? in
            let data = doc.data()
            guard let startDate = (data["startDate"] as? Timestamp)?.dateValue(),
                  let endDate = (data["endDate"] as? Timestamp)?.dateValue(),
                  let statusRaw = data["status"] as? String,
                  let status = HolidayStatus(rawValue: statusRaw) else { return nil }
            let bookingOrgId = (data["organizationId"] as? String) ?? orgId
            let id = UUID(uuidString: doc.documentID) ?? UUID()
            let userId = data["userId"] as? String
            let operativeId = (data["operativeId"] as? String).flatMap { UUID(uuidString: $0) }
            let approvedByUserId = data["approvedByUserId"] as? String
            let approvedAt = (data["approvedAt"] as? Timestamp)?.dateValue()
            let timeSlotRaw = data["timeSlot"] as? String
            let timeSlot = HolidayTimeSlot(rawValue: timeSlotRaw ?? "") ?? .fullDay
            let cancellationRequestedAt = (data["cancellationRequestedAt"] as? Timestamp)?.dateValue()
            let cancellationRequestedByUserId = data["cancellationRequestedByUserId"] as? String
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
            return HolidayBooking(
                id: id,
                organizationId: bookingOrgId,
                userId: userId,
                operativeId: operativeId,
                startDate: startDate,
                endDate: endDate,
                status: status,
                timeSlot: timeSlot,
                approvedByUserId: approvedByUserId,
                approvedAt: approvedAt,
                cancellationRequestedAt: cancellationRequestedAt,
                cancellationRequestedByUserId: cancellationRequestedByUserId,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    func deleteHolidayBooking(_ booking: HolidayBooking, organizationId: String) async throws {
        let orgId = try await resolveWritableOrganizationId(preferred: organizationId)
        try await db.collection("organizations").document(orgId).collection("holidayBookings").document(booking.id.uuidString).delete()
    }

    func recordOperativeDayRateChange(
        organizationId: String,
        userId: String,
        dayRate: Double,
        effectiveAt: Date
    ) async throws {
        let payload: [String: Any] = [
            "userId": userId,
            "dayRate": dayRate,
            "effectiveAt": Timestamp(date: effectiveAt),
            "createdAt": Timestamp(date: Date())
        ]
        try await db.collection("organizations")
            .document(organizationId)
            .collection("operativeDayRateHistory")
            .document(UUID().uuidString)
            .setData(payload, merge: true)
    }

    func loadOperativeDayRateHistory(organizationId: String) async throws -> [String: [OperativeDayRateHistoryEntry]] {
        let snapshot = try await db.collection("organizations")
            .document(organizationId)
            .collection("operativeDayRateHistory")
            .getDocuments()
        var mapped: [String: [OperativeDayRateHistoryEntry]] = [:]
        for doc in snapshot.documents {
            let data = doc.data()
            guard let userId = data["userId"] as? String,
                  let dayRate = data["dayRate"] as? Double,
                  let effectiveAt = (data["effectiveAt"] as? Timestamp)?.dateValue() else { continue }
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let entry = OperativeDayRateHistoryEntry(
                id: UUID(uuidString: doc.documentID) ?? UUID(),
                userId: userId,
                dayRate: dayRate,
                effectiveAt: effectiveAt,
                createdAt: createdAt
            )
            mapped[userId, default: []].append(entry)
        }
        for key in mapped.keys {
            mapped[key] = mapped[key]?.sorted(by: { $0.effectiveAt < $1.effectiveAt })
        }
        return mapped
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
    
    /// Automatic recovery: Attempts to fix missing organization link
    @MainActor
    /// Ensures the user document has the correct organizationId set
    /// This is called before saves to prevent "user not linked to organization" errors
    func ensureUserDocumentLinked(organizationId: String) async throws {
        guard let userId = currentUser?.uid,
              let userEmail = currentUser?.email else {
            print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ❌ User not authenticated")
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        
        print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] Starting for user: \(userId), org: \(organizationId)")
        
        let userDocRef = db.collection("users").document(userId)
        
        do {
            let userDoc = try await userDocRef.getDocument(source: .server)
            
            if userDoc.exists {
                let userData = userDoc.data() ?? [:]
                let currentOrgId = organizationIdFromFirestore(userData["organizationId"])
                let orgIdStr = normalizedOrganizationId(organizationId)
                // Migrate DocumentReference (or any non-string) to string so Firestore rules `userOrgIdMatchesPath` succeeds.
                let storedAsPlainString = userData["organizationId"] is String
                let needsOrgStringMigration = organizationIdsMatch(currentOrgId, organizationId) && !storedAsPlainString
                
                if !organizationIdsMatch(currentOrgId, organizationId) || needsOrgStringMigration {
                    if needsOrgStringMigration {
                        print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] Migrating organizationId to string for rules compatibility (was ref/other type)")
                    } else {
                        print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] Current orgId: \(currentOrgId ?? "nil"), updating to: \(organizationId)")
                    }
                    try await userDocRef.updateData([
                        "organizationId": orgIdStr,
                        "updatedAt": Timestamp(date: Date())
                    ])
                    print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ✅ User document updated successfully")
                    
                    // Verify the update
                    let verifyDoc = try await userDocRef.getDocument(source: .server)
                    if let verifyData = verifyDoc.data(),
                       let verifiedOrgId = organizationIdFromFirestore(verifyData["organizationId"]),
                       organizationIdsMatch(verifiedOrgId, organizationId) {
                        print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ✅ Verification passed - organizationId is now: \(verifiedOrgId)")
                    } else {
                        print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ⚠️ Verification failed - update may not have propagated")
                    }
                } else {
                    print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ✅ User document already has correct organizationId: \(organizationId)")
                }
            } else {
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] User document doesn't exist - creating it...")
                let orgIdStr = normalizedOrganizationId(organizationId)
                try await userDocRef.setData([
                    "email": userEmail,
                    "organizationId": orgIdStr,
                    "role": "basic",
                    "isActive": true,
                    "createdAt": Timestamp(date: Date()),
                    "updatedAt": Timestamp(date: Date())
                ])
                print("🔥🔥🔥 DEBUG: [ensureUserDocumentLinked] ✅ User document created successfully")
                
                // Verify the creation
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
    
    /// Find an existing user in the same organization with the same email (e.g. pre-created by invitation).
    /// Returns permission/role data to use when creating users/{authUid} so operativeMode/manager etc. are preserved.
    private func existingOrgUserDataByEmail(organizationId: String, userEmail: String) async -> [String: Any]? {
        let q = db.collection("users")
            .whereField("organizationId", isEqualTo: organizationId)
            .whereField("email", isEqualTo: userEmail)
            .limit(to: 1)
        let snapshot = try? await q.getDocuments(source: .server)
        guard let doc = snapshot?.documents.first else { return nil }
        let data = doc.data()
        var out: [String: Any] = [
            "email": data["email"] ?? userEmail,
            "organizationId": organizationId,
            "role": data["role"] ?? "basic",
            "isActive": data["isActive"] as? Bool ?? true,
            "adminAccess": data["adminAccess"] as? Bool ?? false,
            "manager": data["manager"] as? Bool ?? false,
            "operatives": data["operatives"] as? Bool ?? false,
            "skills": data["skills"] as? Bool ?? false,
            "qualifications": data["qualifications"] as? Bool ?? false,
            "materials": data["materials"] as? Bool ?? false,
            "operativeMode": data["operativeMode"] as? Bool ?? false,
            "annualLeaveSelfBook": data["annualLeaveSelfBook"] as? Bool ?? false,
            "weeklyReports": data["weeklyReports"] as? Bool ?? false,
            "subContractors": data["subContractors"] as? Bool ?? false,
            "siteAudit": data["siteAudit"] as? Bool ?? true,
            "projects": data["projects"] as? Bool ?? true,
            "smallWorks": data["smallWorks"] as? Bool ?? false,
            "isSuperAdmin": data["isSuperAdmin"] as? Bool ?? false,
        ]
        if let firstName = data["firstName"] { out["firstName"] = firstName }
        if let surname = data["surname"] { out["surname"] = surname }
        if let mobileNumber = data["mobileNumber"] { out["mobileNumber"] = mobileNumber }
        if let createdAt = data["createdAt"] { out["createdAt"] = createdAt }
        return out
    }
    
    func recoverMissingOrganizationLink(userId: String, userEmail: String) async -> Bool {
        print("🔥🔥🔥 DEBUG: 🔧 Attempting to recover missing organization link for user: \(userId), email: \(userEmail)")
        
        do {
            // Strategy 1: Check if user is admin of any organization
            let orgsSnapshot = try await db.collection("organizations").getDocuments()
            print("🔥🔥🔥 DEBUG: Found \(orgsSnapshot.documents.count) organizations to check")
            
            for orgDoc in orgsSnapshot.documents {
                let orgData = orgDoc.data()
                if let members = orgData["members"] as? [String: String] {
                    // Check if user is admin
                    if members[userId] == "admin" {
                        let organizationId = orgDoc.documentID
                        print("🔥🔥🔥 DEBUG: ✅ Found organization where user is admin: \(organizationId)")
                        
                        // Check if user document exists, if not CREATE it, otherwise UPDATE it
                        let userDocRef = db.collection("users").document(userId)
                        let userDoc = try await userDocRef.getDocument()
                        
                        if userDoc.exists {
                            // Document exists - update it
                            print("🔥🔥🔥 DEBUG: User document exists - updating organizationId")
                            try await userDocRef.updateData([
                                "organizationId": organizationId,
                                "updatedAt": Timestamp(date: Date())
                            ])
                        } else {
                            // Document doesn't exist - create it
                            print("🔥🔥🔥 DEBUG: User document does NOT exist - creating it with organizationId")
                            try await userDocRef.setData([
                                "email": userEmail,
                                "organizationId": organizationId,
                                "role": "admin",
                                "isSuperAdmin": true,
                                "isActive": true,
                                "createdAt": Timestamp(date: Date()),
                                "updatedAt": Timestamp(date: Date())
                            ])
                        }
                        
                        // Store organizationId locally for offline access
                        storeOrganizationIdLocally(organizationId)
                        
                        // Reload organization (rules may deny org root read; fall back to snapshot data).
                        await loadUserOrganization(userId: userId)
                        if currentOrganization == nil {
                            setCurrentOrganizationFromRecovery(orgId: organizationId, orgData: orgDoc.data(), fallbackRole: "admin")
                        }
                        return currentOrganization != nil
                    }
                    
                    // Strategy 2: Check if user is a member (any role)
                    if members[userId] != nil {
                        let organizationId = orgDoc.documentID
                        let userRole = members[userId] ?? "member"
                        print("🔥🔥🔥 DEBUG: ✅ Found organization where user is a member: \(organizationId) (role: \(userRole))")
                        
                        // Check if user document exists, if not CREATE it, otherwise UPDATE it
                        let userDocRef = db.collection("users").document(userId)
                        let userDoc = try await userDocRef.getDocument()
                        
                        if userDoc.exists {
                            // Document exists - update it
                            print("🔥🔥🔥 DEBUG: User document exists - updating organizationId")
                            try await userDocRef.updateData([
                                "organizationId": organizationId,
                                "role": userRole,
                                "updatedAt": Timestamp(date: Date())
                            ])
                        } else {
                            // Document doesn't exist - create it, preserving permissions from existing org user (e.g. invited operative)
                            print("🔥🔥🔥 DEBUG: User document does NOT exist - creating it with organizationId")
                            var newUserData: [String: Any] = [
                                "email": userEmail,
                                "organizationId": organizationId,
                                "role": userRole,
                                "isActive": true,
                                "createdAt": Timestamp(date: Date()),
                                "updatedAt": Timestamp(date: Date())
                            ]
                            if let existing = await existingOrgUserDataByEmail(organizationId: organizationId, userEmail: userEmail) {
                                newUserData["role"] = existing["role"] ?? userRole
                                newUserData["adminAccess"] = existing["adminAccess"] ?? false
                                newUserData["manager"] = existing["manager"] ?? false
                                newUserData["operatives"] = existing["operatives"] ?? false
                                newUserData["skills"] = existing["skills"] ?? false
                                newUserData["qualifications"] = existing["qualifications"] ?? false
                                newUserData["materials"] = existing["materials"] ?? false
                                newUserData["operativeMode"] = existing["operativeMode"] ?? false
                                newUserData["annualLeaveSelfBook"] = existing["annualLeaveSelfBook"] ?? false
                                newUserData["weeklyReports"] = existing["weeklyReports"] ?? false
                                newUserData["subContractors"] = existing["subContractors"] ?? false
                                newUserData["projects"] = existing["projects"] ?? true
                                newUserData["smallWorks"] = existing["smallWorks"] ?? false
                                newUserData["isSuperAdmin"] = existing["isSuperAdmin"] ?? false
                                if let fn = existing["firstName"] { newUserData["firstName"] = fn }
                                if let sn = existing["surname"] { newUserData["surname"] = sn }
                                if let mobile = existing["mobileNumber"] { newUserData["mobileNumber"] = mobile }
                                print("🔥🔥🔥 DEBUG: Preserved permissions from existing org user (e.g. operativeMode)")
                            }
                            try await userDocRef.setData(newUserData)
                        }
                        
                        // Store organizationId locally for offline access
                        storeOrganizationIdLocally(organizationId)
                        
                        // Reload organization (rules may deny org root read; fall back to snapshot data).
                        await loadUserOrganization(userId: userId)
                        if currentOrganization == nil {
                            setCurrentOrganizationFromRecovery(orgId: organizationId, orgData: orgDoc.data(), fallbackRole: userRole)
                        }
                        return currentOrganization != nil
                    }
                }
            }
            
            // Strategy 3: Check user document for any organizationId that might exist
            let userDoc = try await db.collection("users").document(userId).getDocument(source: .server)
            if userDoc.exists, let userData = userDoc.data(),
               let orgId = organizationIdFromFirestore(userData["organizationId"]) {
                print("🔥🔥🔥 DEBUG: ✅ Found organizationId in user document: \(orgId)")
                // Verify organization exists
                let orgDoc = try await db.collection("organizations").document(orgId).getDocument(source: .server)
                if orgDoc.exists {
                    // Store organizationId locally for offline access
                    storeOrganizationIdLocally(orgId)
                    // Reload organization
                    await loadUserOrganization(userId: userId)
                    return currentOrganization != nil
                }
            }
            
            // Strategy 3b: Invited user – find org by existing user with same email (e.g. users/{randomUUID} from invite).
            let emailVariants = Array(Set([
                userEmail,
                userEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }))
            
            variantLoop: for emailVariant in emailVariants {
                let sameEmailQuery = try await db.collection("users")
                    .whereField("email", isEqualTo: emailVariant)
                    .limit(to: 8)
                    .getDocuments(source: .server)
                for doc in sameEmailQuery.documents where doc.documentID != userId {
                    let data = doc.data()
                    guard let orgId = organizationIdFromFirestore(data["organizationId"]) else { continue }
                    let orgDoc = try await db.collection("organizations").document(orgId).getDocument()
                    guard orgDoc.exists else { continue }
                    print("🔥🔥🔥 DEBUG: ✅ Found organization via same-email user (invited): \(orgId)")
                    let userDocRef = db.collection("users").document(userId)
                    let emailNorm = userEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    var newUserData: [String: Any] = [
                        "email": emailNorm,
                        "organizationId": orgId,
                        "role": data["role"] ?? "basic",
                        "isActive": data["isActive"] as? Bool ?? true,
                        "createdAt": Timestamp(date: Date()),
                        "updatedAt": Timestamp(date: Date()),
                        "adminAccess": data["adminAccess"] as? Bool ?? false,
                        "manager": data["manager"] as? Bool ?? false,
                        "operatives": data["operatives"] as? Bool ?? false,
                        "skills": data["skills"] as? Bool ?? false,
                        "qualifications": data["qualifications"] as? Bool ?? false,
                        "operativeMode": data["operativeMode"] as? Bool ?? false,
                        "annualLeaveSelfBook": data["annualLeaveSelfBook"] as? Bool ?? false,
                        "weeklyReports": data["weeklyReports"] as? Bool ?? false,
                        "subContractors": data["subContractors"] as? Bool ?? false,
                        "siteAudit": data["siteAudit"] as? Bool ?? true,
                        "projects": data["projects"] as? Bool ?? true,
                        "smallWorks": data["smallWorks"] as? Bool ?? false,
                        "isSuperAdmin": data["isSuperAdmin"] as? Bool ?? false,
                    ]
                    if let fn = data["firstName"] { newUserData["firstName"] = fn }
                    if let sn = data["surname"] { newUserData["surname"] = sn }
                    if let mobile = data["mobileNumber"] { newUserData["mobileNumber"] = mobile }
                    if let am = data["assignedManagerUserId"] as? String, !am.isEmpty {
                        newUserData["assignedManagerUserId"] = am
                    }
                    try await userDocRef.setData(newUserData, merge: true)
                    try await db.collection("organizations").document(orgId)
                        .collection("userEmails").document(emailNorm)
                        .setData(["userId": userId], merge: true)
                    storeOrganizationIdLocally(orgId)
                    await loadUserOrganization(userId: userId)
                    if currentOrganization == nil {
                        setCurrentOrganizationFromRecovery(
                            orgId: orgId,
                            orgData: orgDoc.data() ?? [:],
                            fallbackRole: data["role"] as? String ?? "basic"
                        )
                    }
                    break variantLoop
                }
            }
            if currentOrganization != nil {
                return true
            }
            
            // Strategy 4: Check if any organization has data for this user (projects, operatives, etc.)
            // This is a last resort - find organization by data ownership
            print("🔥🔥🔥 DEBUG: ⚠️ Trying to find organization by data ownership...")
            for orgDoc in orgsSnapshot.documents {
                let organizationId = orgDoc.documentID
                // Check if user has projects in this organization
                let projectsSnapshot = try await db.collection("organizations")
                    .document(organizationId)
                    .collection("projects")
                    .whereField("createdBy", isEqualTo: userId)
                    .limit(to: 1)
                    .getDocuments()
                
                if !projectsSnapshot.isEmpty {
                    print("🔥🔥🔥 DEBUG: ✅ Found organization with user's projects: \(organizationId)")
                    // Check if user document exists, if not CREATE it, otherwise UPDATE it
                    let userDocRef = db.collection("users").document(userId)
                    let userDoc = try await userDocRef.getDocument()
                    
                    if userDoc.exists {
                        try await userDocRef.updateData([
                            "organizationId": organizationId,
                            "updatedAt": Timestamp(date: Date())
                        ])
                    } else {
                        var newUserData: [String: Any] = [
                            "email": userEmail,
                            "organizationId": organizationId,
                            "role": "member",
                            "isActive": true,
                            "createdAt": Timestamp(date: Date()),
                            "updatedAt": Timestamp(date: Date())
                        ]
                        if let existing = await existingOrgUserDataByEmail(organizationId: organizationId, userEmail: userEmail) {
                            newUserData["role"] = existing["role"] ?? "member"
                            newUserData["adminAccess"] = existing["adminAccess"] ?? false
                            newUserData["manager"] = existing["manager"] ?? false
                            newUserData["operatives"] = existing["operatives"] ?? false
                            newUserData["skills"] = existing["skills"] ?? false
                            newUserData["qualifications"] = existing["qualifications"] ?? false
                            newUserData["materials"] = existing["materials"] ?? false
                            newUserData["operativeMode"] = existing["operativeMode"] ?? false
                            newUserData["annualLeaveSelfBook"] = existing["annualLeaveSelfBook"] ?? false
                            newUserData["weeklyReports"] = existing["weeklyReports"] ?? false
                            newUserData["subContractors"] = existing["subContractors"] ?? false
                            newUserData["projects"] = existing["projects"] ?? true
                            newUserData["smallWorks"] = existing["smallWorks"] ?? false
                            newUserData["isSuperAdmin"] = existing["isSuperAdmin"] ?? false
                            if let fn = existing["firstName"] { newUserData["firstName"] = fn }
                            if let sn = existing["surname"] { newUserData["surname"] = sn }
                            if let mobile = existing["mobileNumber"] { newUserData["mobileNumber"] = mobile }
                            print("🔥🔥🔥 DEBUG: Preserved permissions from existing org user (e.g. operativeMode)")
                        }
                        try await userDocRef.setData(newUserData)
                    }
                    
                    // Store organizationId locally for offline access
                    storeOrganizationIdLocally(organizationId)
                    
                    // Reload organization (rules may deny org root read; fall back to snapshot data).
                    await loadUserOrganization(userId: userId)
                    if currentOrganization == nil {
                        setCurrentOrganizationFromRecovery(orgId: organizationId, orgData: orgDoc.data(), fallbackRole: "member")
                    }
                    return currentOrganization != nil
                }
            }
            
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
                NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
            } else {
                // Try one more time with a delay
                print("🔥🔥🔥 DEBUG: ⚠️ First recovery attempt failed, retrying in 2 seconds...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let retryRecovered = await recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                if retryRecovered, currentOrganization != nil {
                    print("🔥🔥🔥 DEBUG: ✅ Retry recovery successful!")
                    NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
                } else {
                    errorMessage = "Organization not found. Tap 'Force Reload' in Settings to try again."
                }
            }
        } else if currentOrganization != nil {
            // Organization loaded successfully - notify stores to reload data
            print("🔥🔥🔥 DEBUG: ✅ Organization loaded successfully: \(currentOrganization?.name ?? "N/A")")
            NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
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
        
        // Clear current organization to force fresh load
        currentOrganization = nil
        clearLocalOrganizationCache()
        
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
        NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
        
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
        guard let userId = currentUser?.uid,
              let userEmail = currentUser?.email else {
            print("🔥🔥🔥 DEBUG: ❌ Cannot link - user not authenticated")
            errorMessage = "User not authenticated"
            return false
        }
        
        print("🔥🔥🔥 DEBUG: 🔧 Manually linking user to organization: \(organizationId)")
        
        do {
            // First, verify the organization exists
            let orgDoc = try await db.collection("organizations").document(organizationId).getDocument()
            guard orgDoc.exists, let orgData = orgDoc.data() else {
                print("🔥🔥🔥 DEBUG: ❌ Organization does not exist: \(organizationId)")
                errorMessage = "Organization not found"
                return false
            }
            
            let orgName = orgData["name"] as? String ?? "Unknown Organization"
            print("🔥🔥🔥 DEBUG: ✅ Organization exists: \(orgName)")
            
            // Check if user document exists
            let userDocRef = db.collection("users").document(userId)
            let userDoc = try await userDocRef.getDocument()
            
            if userDoc.exists {
                // Update existing user document
                print("🔥🔥🔥 DEBUG: User document exists - updating organizationId")
                try await userDocRef.updateData([
                    "organizationId": organizationId,
                    "updatedAt": Timestamp(date: Date())
                ])
            } else {
                // Create user document
                print("🔥🔥🔥 DEBUG: User document does NOT exist - creating it with organizationId")
                try await userDocRef.setData([
                    "email": userEmail,
                    "organizationId": organizationId,
                    "role": "admin",
                    "isSuperAdmin": true,
                    "isActive": true,
                    "createdAt": Timestamp(date: Date()),
                    "updatedAt": Timestamp(date: Date())
                ])
            }
            
            // Also ensure user is in organization's members field
            let orgRef = db.collection("organizations").document(organizationId)
            let orgDocData = try await orgRef.getDocument().data() ?? [:]
            var members = orgDocData["members"] as? [String: String] ?? [:]
            members[userId] = "admin"
            
            try await orgRef.updateData([
                "members": members,
                "updatedAt": Timestamp(date: Date())
            ])
            
            print("🔥🔥🔥 DEBUG: ✅ Successfully linked user to organization")
            
            // Store organization locally
            let organization = Organization(
                id: UUID(uuidString: organizationId) ?? UUID(),
                firestoreDocumentId: organizationId,
                name: orgName,
                settings: OrganizationSettings(),
                officeAddressLine1: orgDocData["officeAddressLine1"] as? String,
                officeCity: orgDocData["officeCity"] as? String,
                officePostcode: orgDocData["officePostcode"] as? String,
                countryCode: (orgDocData["countryCode"] as? String)?.uppercased() ?? "GB",
                defaultLatitude: orgDocData["defaultLatitude"] as? Double,
                defaultLongitude: orgDocData["defaultLongitude"] as? Double
            )
            storeOrganizationLocally(organization)
            
            // Load organization
            self.currentOrganization = organization
            self.userRole = .admin
            self.errorMessage = nil
            
            // Post notification to reload all data
            NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
            
            print("🔥🔥🔥 DEBUG: ✅✅✅ Organization loaded: \(orgName)")
            return true
            
        } catch {
            print("🔥🔥🔥 DEBUG: ❌ Error linking to organization: \(error.localizedDescription)")
            errorMessage = "Failed to link to organization: \(error.localizedDescription)"
            return false
        }
    }

    /// Finds a better organization for this user when current org has no projects/small works.
    /// Returns true if the app switched `currentOrganization` and persisted the new org locally.
    @MainActor
    func autoSwitchToOrganizationWithWorkData(userId: String, currentOrganizationId: String) async -> Bool {
        do {
            print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Scanning organizations for user work data...")
            let orgsSnapshot = try await db.collection("organizations").getDocuments(source: .server)

            var bestOrganization: Organization?
            var bestScore = -1
            let normalizedCurrentOrgId = currentOrganizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            for orgDoc in orgsSnapshot.documents {
                let orgId = orgDoc.documentID
                let orgData = orgDoc.data()
                let members = orgData["members"] as? [String: String] ?? [:]
                let creatorUserId = orgData["creatorUserId"] as? String
                let isUserInOrg = members[userId] != nil || creatorUserId == userId
                if !isUserInOrg { continue }

                let orgRef = db.collection("organizations").document(orgId)
                let projectsCount: Int
                let smallWorksCount: Int
                let clientsCount: Int
                do {
                    projectsCount = try await orgRef.collection("projects").limit(to: 200).getDocuments(source: .server).documents.count
                    smallWorksCount = try await orgRef.collection("smallWorks").limit(to: 200).getDocuments(source: .server).documents.count
                    clientsCount = try await orgRef.collection("clients").limit(to: 200).getDocuments(source: .server).documents.count
                } catch {
                    if isFirestorePermissionDenied(error) {
                        print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Skipping org \(orgId) due to permission denial while counting")
                        continue
                    }
                    throw error
                }

                // Prefer orgs with actual work data first, then use clients as tie-breaker.
                let score = (projectsCount * 1000) + (smallWorksCount * 100) + clientsCount
                print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Org \(orgId) counts — projects: \(projectsCount), smallWorks: \(smallWorksCount), clients: \(clientsCount), score: \(score)")

                if score > bestScore {
                    bestScore = score
                    bestOrganization = Organization(
                        id: UUID(uuidString: orgId) ?? UUID(),
                        firestoreDocumentId: orgId,
                        name: orgData["name"] as? String ?? "Unknown Organization",
                        settings: OrganizationSettings(),
                        officeAddressLine1: orgData["officeAddressLine1"] as? String,
                        officeCity: orgData["officeCity"] as? String,
                        officePostcode: orgData["officePostcode"] as? String,
                        countryCode: (orgData["countryCode"] as? String)?.uppercased() ?? "GB",
                        defaultLatitude: orgData["defaultLatitude"] as? Double,
                        defaultLongitude: orgData["defaultLongitude"] as? Double,
                        creatorUserId: creatorUserId
                    )
                }
            }

            guard let targetOrg = bestOrganization else {
                print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] No accessible organizations found for user")
                return false
            }

            let normalizedTarget = targetOrg.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let targetHasWorkData = bestScore >= 100 // at least one project/small work
            guard targetHasWorkData, normalizedTarget != normalizedCurrentOrgId else {
                print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] No better org with work data found")
                return false
            }

            print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Switching organization to \(targetOrg.name) (\(targetOrg.firestoreDocumentId))")
            currentOrganization = targetOrg
            storeOrganizationLocally(targetOrg)
            do {
                try await ensureUserDocumentLinked(organizationId: targetOrg.firestoreDocumentId)
            } catch {
                print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Could not update user org link immediately: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: .organizationDidLoad, object: nil)
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: [OrgAutoSwitch] Failed: \(error.localizedDescription)")
            return false
        }
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
            date: Calendar.current.startOfDay(for: date)
        )
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
        
        let data: [String: Any] = [
            "id": material.id.uuidString,
            "quantity": material.quantity,
            "unit": material.unit.rawValue,
            "material": material.material,
            "addedBy": material.addedBy,
            "addedByUserId": effectiveAddedByUserId as Any,
            "addedAt": Timestamp(date: material.addedAt),
            "editedBy": material.editedBy as Any,
            "editedByUserId": material.editedByUserId as Any,
            "editedAt": material.editedAt.map { Timestamp(date: $0) } as Any,
            "projectId": material.projectId.uuidString,
            "date": Timestamp(date: normalizedDate)
        ]
        
        print("💾 [FirebaseBackend] Saving material:")
        print("   ID: \(material.id.uuidString)")
        print("   Material: \(material.material)")
        print("   Project ID: \(material.projectId.uuidString)")
        print("   Date: \(normalizedDate)")
        print("   Organization ID: \(orgId)")
        
        try await docRef.setData(data)
        
        print("✅ [FirebaseBackend] Material saved successfully to Firebase")
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
            
            guard let idString = data["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let quantity = materialQuantityFromFirestore(data["quantity"]),
                  let unitString = data["unit"] as? String,
                  let unit = MaterialUnit(rawValue: unitString),
                  let material = data["material"] as? String,
                  let addedBy = data["addedBy"] as? String,
                  let addedAt = (data["addedAt"] as? Timestamp)?.dateValue(),
                  let projectIdString = data["projectId"] as? String,
                  let projectId = UUID(uuidString: projectIdString),
                  let date = (data["date"] as? Timestamp)?.dateValue() else {
                print("⚠️ [FirebaseBackend] Skipping material document - missing required fields")
                continue
            }
            
            // Normalize date to start of day when loading
            let calendar = Calendar.current
            let normalizedDate = calendar.startOfDay(for: date)
            
            let materialItem = MaterialItem(
                id: id,
                quantity: quantity,
                unit: unit,
                material: material,
                addedBy: addedBy,
                addedByUserId: data["addedByUserId"] as? String,
                addedAt: addedAt,
                editedBy: data["editedBy"] as? String,
                editedByUserId: data["editedByUserId"] as? String,
                editedAt: (data["editedAt"] as? Timestamp)?.dateValue(),
                projectId: projectId,
                date: normalizedDate
            )
            
            materials.append(materialItem)
            print("   ✅ Loaded: \(material) for date \(normalizedDate)")
        }
        
        print("✅ [FirebaseBackend] Returning \(materials.count) materials")
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
                let calendar = Calendar.current

                for doc in docs {
                    let data = doc.data()
                    guard let idString = data["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let quantity = self.materialQuantityFromFirestore(data["quantity"]),
                          let unitString = data["unit"] as? String,
                          let unit = MaterialUnit(rawValue: unitString),
                          let material = data["material"] as? String,
                          let addedBy = data["addedBy"] as? String,
                          let addedAt = (data["addedAt"] as? Timestamp)?.dateValue(),
                          let projectIdString = data["projectId"] as? String,
                          let parsedProjectId = UUID(uuidString: projectIdString),
                          let date = (data["date"] as? Timestamp)?.dateValue() else {
                        continue
                    }

                    loaded.append(MaterialItem(
                        id: id,
                        quantity: quantity,
                        unit: unit,
                        material: material,
                        addedBy: addedBy,
                        addedByUserId: data["addedByUserId"] as? String,
                        addedAt: addedAt,
                        editedBy: data["editedBy"] as? String,
                        editedByUserId: data["editedByUserId"] as? String,
                        editedAt: (data["editedAt"] as? Timestamp)?.dateValue(),
                        projectId: parsedProjectId,
                        date: calendar.startOfDay(for: date)
                    ))
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
            "authorName": audit.authorName,
            "date": Timestamp(date: audit.date),
            "createdAt": Timestamp(date: audit.createdAt),
            "createdByUserId": audit.createdByUserId,
            "visibleToOperatives": audit.visibleToOperatives,
            "items": audit.items.map { item in
                var row: [String: Any] = [
                    "id": item.id.uuidString,
                    "title": item.title,
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

    func loadSiteAudits(organizationId: String, projectId: UUID? = nil) async throws -> [SiteAudit] {
        var query: Query = db.collection("organizations").document(organizationId)
            .collection("siteAudits")

        if let projectId {
            query = query.whereField("projectId", isEqualTo: projectId.uuidString)
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
            let visibleToOperatives = data["visibleToOperatives"] as? Bool ?? true

            let itemRows = data["items"] as? [[String: Any]] ?? []
            let items: [SiteAuditItem] = itemRows.compactMap { row in
                guard let itemIdString = row["id"] as? String,
                      let itemId = UUID(uuidString: itemIdString),
                      let title = row["title"] as? String,
                      let assignee = row["assignee"] as? String,
                      let comments = row["comments"] as? String,
                      let createdAt = (row["createdAt"] as? Timestamp)?.dateValue() else {
                    return nil
                }
                return SiteAuditItem(
                    id: itemId,
                    title: title,
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
            [
                "id": contact.id.uuidString,
                "name": contact.name,
                "email": contact.email,
                "createdAt": Timestamp(date: contact.createdAt)
            ]
        }
        
        let data: [String: Any] = [
            "id": wholesaler.id.uuidString,
            "name": wholesaler.name,
            "contacts": contactsData,
            "createdAt": Timestamp(date: wholesaler.createdAt),
            "updatedAt": Timestamp(date: wholesaler.updatedAt)
        ]
        
        try await db.collection("organizations").document(organizationId)
            .collection("wholesalers")
            .document(wholesaler.id.uuidString)
            .setData(data)
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
                    let contact = WholesalerContact(
                        id: contactId,
                        name: contactName,
                        email: contactEmail,
                        createdAt: contactCreatedAt
                    )
                    contacts.append(contact)
                }
            }
            
            let wholesaler = Wholesaler(
                id: id,
                name: name,
                contacts: contacts,
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
                contactsArray[index] = [
                    "id": contact.id.uuidString,
                    "name": contact.name,
                    "email": contact.email,
                    "createdAt": Timestamp(date: contact.createdAt)
                ]
            }
        } else {
            // Add new contact
            contactsArray.append([
                "id": contact.id.uuidString,
                "name": contact.name,
                "email": contact.email,
                "createdAt": Timestamp(date: contact.createdAt)
            ])
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
                      let position = SubcontractorContactPosition(rawValue: positionRaw),
                      let cCreatedAt = (row["createdAt"] as? Timestamp)?.dateValue() else { return nil }
                return SubcontractorContact(
                    id: cid,
                    name: cname,
                    email: cemail,
                    contactNumber: number,
                    position: position,
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
        let data: [String: Any] = [
            "id": booking.id.uuidString,
            "subcontractorId": booking.subcontractorId.uuidString,
            "projectId": booking.projectId.uuidString,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "bookedBy": booking.bookedBy,
            "status": booking.status.rawValue,
            "createdAt": Timestamp(date: booking.createdAt),
            "updatedAt": Timestamp(date: booking.updatedAt)
        ]
        
        try await db.collection("organizations").document(organizationId)
            .collection("subcontractorBookings")
            .document(booking.id.uuidString)
            .setData(data)
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
                  let timeSlot = TimeSlot(rawValue: timeSlotRaw),
                  let bookedBy = data["bookedBy"] as? String,
                  let statusRaw = data["status"] as? String,
                  let status = BookingStatus(rawValue: statusRaw),
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
                  let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { continue }
            
            loaded.append(
                SubcontractorBooking(
                    id: id,
                    subcontractorId: subcontractorId,
                    projectId: projectId,
                    date: date,
                    timeSlot: timeSlot,
                    bookedBy: bookedBy,
                    status: status,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return loaded.sorted { $0.date < $1.date }
    }
    
    // MARK: - Email Service
    
    func sendMaterialRequest(_ request: MaterialOrderRequest, organizationId: String) async throws {
        // Build email content
        let requestTypeText = request.requestType == .quote ? "quote" : "order"
        let isQuote = request.requestType == .quote
        
        // Reply-To and CC use sender's email; signature is already in request.sentBy (Name, phone, email, company)
        let senderEmail = currentUser?.email ?? "info@projectplanner.us"
        let senderName = request.sentBy.split(separator: "\n").first.map(String.init) ?? "Project Planner"
        
        for contact in request.recipientContacts {
            let emailBody = buildMaterialRequestEmail(
                contactName: contact.name,
                isQuote: isQuote,
                projectNumber: request.projectNumber,
                projectName: request.projectName,
                siteAddress: request.siteAddress,
                materials: request.materials,
                sentBy: request.sentBy
            )
            
            let subject = "Material \(requestTypeText) Request - \(request.projectNumber)"
            
            let emailService = ResendEmailService()
            let success = await emailService.sendEmail(
                to: contact.email,
                subject: subject,
                htmlContent: emailBody,
                cc: senderEmail,
                replyTo: senderEmail,
                fromName: senderName
            )
            
            if success {
                print("✅ Email sent successfully to \(contact.email)")
            } else {
                print("❌ Failed to send email to \(contact.email)")
                // Still continue with other contacts even if one fails
            }
        }
    }
    
    private func buildMaterialRequestEmail(
        contactName: String,
        isQuote: Bool,
        projectNumber: String,
        projectName: String,
        siteAddress: String,
        materials: [MaterialItem],
        sentBy: String
    ) -> String {
        let firstName = contactName.split(separator: " ").first.map(String.init) ?? contactName
        let jobNumberSection = "<p><strong>Job Number:</strong> \(projectNumber)</p>"
        
        let introParagraph: String
        let middleSection: String
        if isQuote {
            introParagraph = "<p>Hi \(firstName), please can I have a quote for the below items.</p>"
            middleSection = jobNumberSection
        } else {
            introParagraph = "<p>Hi \(firstName), please can I place an order for the below items to the following address.</p>"
            middleSection = """
            \(jobNumberSection)
            
            <p><strong>Address:</strong><br>
            \(siteAddress)</p>
            """
        }
        
        var emailHTML = """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="line-height: 1.6; color: #333;">
                \(introParagraph)
                
                \(middleSection)
                
                <p><strong>Material List:</strong></p>
                <ol style="padding-left: 20px;">
        """
        
        for material in materials {
            emailHTML += "<li>\(material.material) - \(material.quantity) \(material.unit.rawValue)</li>\n"
        }
        
        let formattedSignature = sentBy.replacingOccurrences(of: "\n", with: "<br>")
        
        emailHTML += """
                </ol>
                
                <p>Kind Regards,<br>
                \(formattedSignature)</p>
            </div>
        </body>
        </html>
        """
        
        return emailHTML
    }
}

// MARK: - Firebase Configuration

class FirebaseConfig {
    static func configure() {
        // Firebase is configured in AppDelegate or App struct
        // This class can be used for additional configuration
    }
}
