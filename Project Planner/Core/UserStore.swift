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
    @Published var currentUser: AppUser?
    /// When set, tab visibility and `can*` helpers use a simulated role. Identity and Firestore still use `currentUser`.
    @Published var roleTestingPreset: RoleTestingPreset?
    @Published var organizationUsers: [AppUser] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    @Published var isOffline: Bool = false
    private let operativeProfileOverridesKey = "operative_profile_overrides_v1"

    private struct OperativeProfileOverride: Codable {
        var assignedManagerUserId: String?
        var dayRate: Double?
        var updatedAt: Date
    }
    
    init() {
        // Initialize with empty state
    }
    
    func setFirebaseBackend(_ firebaseBackend: FirebaseBackend) {
        self.firebaseBackend = firebaseBackend
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
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
                skills: true,
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
                skills: true,
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
                skills: true,
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
                if userData == nil {
                    // User doesn't exist, create as super admin (organization creator)
                    if let organization = firebaseBackend.currentOrganization {
                        let superAdminPermissions = UserPermissions(
                            adminAccess: true,
                            operatives: true,
                            skills: true,
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
                } else {
                    // Existing user - ensure passwordSet is true if they're authenticated
                    // (If they can sign in, they have a password set)
                    var updatedUser = userData!
                    var needsUpdate = false
                    
                    // If passwordSet is false but user is authenticated, they must have set a password
                    if !updatedUser.passwordSet {
                        updatedUser.passwordSet = true
                        needsUpdate = true
                        print("🔥🔥🔥 DEBUG: Fixing passwordSet for existing user: \(updatedUser.email)")
                    }
                    
                    // Legacy: role .operative without operativeMode flag — align so permission helpers match.
                    if updatedUser.role == .operative && !updatedUser.permissions.operativeMode {
                        updatedUser.permissions.operativeMode = true
                        needsUpdate = true
                    }
                    
                    // CRITICAL: Operative-first hierarchy – if operativeMode is true, clear admin/manager flags so UI never shows full access
                    // Run this FIRST so we never elevate an operative to super admin in later steps.
                    if updatedUser.permissions.operativeMode {
                        if updatedUser.permissions.adminAccess || updatedUser.permissions.manager || updatedUser.permissions.operatives || updatedUser.permissions.skills || updatedUser.permissions.qualifications || updatedUser.isSuperAdmin {
                            print("🔥🔥🔥 DEBUG: ⚠️ User has operativeMode but other permissions set – enforcing operative-only")
                            updatedUser.isSuperAdmin = false
                            updatedUser.permissions.adminAccess = false
                            updatedUser.permissions.manager = false
                            updatedUser.permissions.operatives = false
                            updatedUser.permissions.skills = false
                            updatedUser.permissions.qualifications = false
                            updatedUser.permissions.materials = false
                            updatedUser.permissions.projects = true
                            updatedUser.permissions.smallWorks = true
                            updatedUser.role = .operative
                            needsUpdate = true
                        }
                    }
                    
                    // Only the organization creator (stored on the org) may be super admin. Never elevate based on adminAccess or "only user" count.
                    if let organization = firebaseBackend.currentOrganization,
                       updatedUser.organizationId == organization.firestoreDocumentId,
                       !updatedUser.permissions.operativeMode,
                       let creatorUserId = organization.creatorUserId,
                       creatorUserId == firebaseUser.uid,
                       !updatedUser.isSuperAdmin {
                        print("🔥🔥🔥 DEBUG: User is organization creator – ensuring super admin and adminAccess")
                        updatedUser.isSuperAdmin = true
                        updatedUser.permissions.adminAccess = true
                        updatedUser.role = .admin
                        needsUpdate = true
                    }
                    
                    // Ensure isSuperAdmin users have adminAccess (no elevation – only syncing existing super admin)
                    if updatedUser.isSuperAdmin && !updatedUser.permissions.adminAccess {
                        updatedUser.permissions.adminAccess = true
                        updatedUser.role = .admin
                        needsUpdate = true
                    }
                    
                    if needsUpdate {
                        try await firebaseBackend.saveUser(updatedUser)
                        userData = updatedUser
                        print("🔥🔥🔥 DEBUG: ✅ Updated user document with correct permissions")
                    }
                }
                
                self.currentUser = userData
                
                // Load org roster in the background so a slow / stuck org query cannot block the main shell.
                Task { await self.loadOrganizationUsers() }
            }
        } catch {
            errorMessage = "Failed to load user data: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error loading current user: \(error)")
        }
        
        isLoading = false
    }
    
    func loadOrganizationUsers() async {
        guard let firebaseBackend = firebaseBackend,
              let currentUser = currentUser else {
            print("🔥🔥🔥 DEBUG: Cannot load users - missing firebaseBackend or currentUser")
            return
        }
        
        print("🔥🔥🔥 DEBUG: loadOrganizationUsers called for organizationId: \(currentUser.organizationId)")
        
        do {
            let users = try await firebaseBackend.getOrganizationUsers(organizationId: currentUser.organizationId)
            let cloudOverrides = (try? await firebaseBackend.loadOperativeProfileMetadataFallback(
                organizationId: currentUser.organizationId
            )) ?? [:]
            print("🔥🔥🔥 DEBUG: Loaded \(users.count) users from Firebase")
            for user in users {
                print("🔥🔥🔥 DEBUG: - \(user.email) (\(user.firstName) \(user.surname)) - Active: \(user.isActive), PasswordSet: \(user.passwordSet)")
            }
            
            await MainActor.run {
                // Sort users: super admin first, then by email
                let usersWithCloudOverrides = applyCloudOperativeProfileOverrides(users, overrides: cloudOverrides)
                let usersWithOverrides = applyOperativeProfileOverrides(to: usersWithCloudOverrides)
                let sortedUsers = usersWithOverrides.sorted { user1, user2 in
                    if user1.isSuperAdmin != user2.isSuperAdmin {
                        return user1.isSuperAdmin // Super admin first
                    }
                    return user1.email < user2.email // Then alphabetically by email
                }
                
                self.organizationUsers = sortedUsers
                print("🔥🔥🔥 DEBUG: Updated organizationUsers array with \(sortedUsers.count) users")
                for (index, user) in sortedUsers.enumerated() {
                    print("🔥🔥🔥 DEBUG: [\(index)] \(user.email) - SuperAdmin: \(user.isSuperAdmin), Active: \(user.isActive)")
                }
            }
            
            await enforceSingleSuperAdminInFirestoreIfNeeded()
            
            // Cache the data
            if smartCache != nil {
                // We'll add user caching to SmartCacheService later
            }
        } catch {
            errorMessage = "Failed to load organization users: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error loading organization users: \(error)")
        }
    }
    
    /// Call when the user signs out so deleted/other-org users don't persist in the UI.
    func clearOnSignOut() {
        organizationUsers = []
        currentUser = nil
        roleTestingPreset = nil
        errorMessage = nil
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
    
    // MARK: - Operative-first hierarchy
    // If the user has operativeMode, they are treated as operative only: no admin/manager features, regardless of other flags in Firestore.
    
    // Helper to check if user has admin-level access (super admin or adminAccess permission).
    // Operatives are never considered admins.
    func hasAdminAccess() -> Bool {
        guard let currentUser = displayUser else { return false }
        if currentUser.permissions.operativeMode { return false }
        return currentUser.isSuperAdmin
            || currentUser.permissions.adminAccess
            || currentUser.role == .admin
    }
    
    // Simplified permission checks using user.permissions. Operatives get restricted access.
    func canManageUsers() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess() || hasPermission { $0.permissions.adminAccess }
    }
    
    func canViewOperatives() -> Bool {
        if isOperativeMode() { return false }
        return (hasAdminAccess() || hasPermission { $0.permissions.manager }) &&
               (hasAdminAccess() || hasPermission { $0.permissions.operatives })
    }
    
    func canManageSkills() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess() || hasPermission { $0.permissions.skills }
    }
    
    func canManageQualifications() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess() || hasPermission { $0.permissions.qualifications }
    }
    
    func canViewProjects() -> Bool {
        return true
    }

    func canViewMaterials() -> Bool {
        if isOperativeMode() {
            return displayUser?.permissions.materials == true
        }
        return true
    }
    
    func canEditProjects() -> Bool {
        guard let currentUser = displayUser else { return false }
        if currentUser.permissions.operativeMode { return false }
        if currentUser.isSuperAdmin || currentUser.permissions.adminAccess { return true }
        guard currentUser.permissions.manager else { return false }
        return currentUser.permissions.projects || currentUser.permissions.smallWorks
    }
    
    func canViewSiteAudit() -> Bool {
        guard let currentUser = displayUser else { return false }
        if currentUser.permissions.operativeMode {
            return currentUser.permissions.siteAudit
        }
        return true
    }
    
    func canEditOperatives() -> Bool {
        return canViewOperatives()
    }
    
    func canViewManagers() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess() || hasPermission { $0.permissions.manager }
    }
    
    func canEditManagers() -> Bool {
        if isOperativeMode() { return false }
        return hasAdminAccess() || hasPermission { $0.permissions.manager }
    }
    
    func canViewSkills() -> Bool {
        return canManageSkills()
    }
    
    func canEditSkills() -> Bool {
        return canManageSkills()
    }
    
    func canViewQualifications() -> Bool {
        if isOperativeMode() { return true }
        return canManageQualifications()
    }
    
    func canEditQualifications() -> Bool {
        if isOperativeMode() { return false }
        return canManageQualifications()
    }
    
    func canBookWork() -> Bool {
        if isOperativeMode() { return false }
        return true
    }
    
    func canManageSubcontractors() -> Bool {
        if isOperativeMode() { return false }
        guard let currentUser = displayUser else { return false }
        if currentUser.isSuperAdmin || currentUser.permissions.adminAccess || currentUser.role == .admin {
            return true
        }
        return currentUser.permissions.manager && currentUser.permissions.subContractors
    }
    
    /// Super admins, admins, and managers may set whether a site audit is visible to operative-mode users.
    func canManageSiteAuditOperativeVisibility() -> Bool {
        guard let u = displayUser else { return false }
        if isOperativeMode() { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.permissions.manager
    }
    
    /// Manager account with operative management only (no admin / super admin).
    func isActingManagerOperativeManagementOnly() -> Bool {
        guard let u = displayUser else { return false }
        if u.permissions.operativeMode { return false }
        if u.isSuperAdmin || u.permissions.adminAccess { return false }
        return u.permissions.manager && u.permissions.operatives
    }
    
    /// Whether the signed-in user may change permissions for `target` in **Manage / edit user**.
    func canEditTargetUserPermissions(_ target: AppUser) -> Bool {
        guard let acting = currentUser else { return false }
        if isOrganizationCreator(userId: target.id) { return false }
        if acting.permissions.operativeMode { return false }
        if hasAdminAccess() { return true }
        if isActingManagerOperativeManagementOnly() {
            return target.permissions.operativeMode || target.role == .operative
        }
        return false
    }
    
    /// Demotes mistaken `isSuperAdmin` flags so only the organisation creator remains super admin.
    private func enforceSingleSuperAdminInFirestoreIfNeeded() async {
        guard let firebaseBackend,
              let creatorId = firebaseBackend.currentOrganization?.creatorUserId,
              hasAdminAccess() else { return }
        var demoted = false
        for var user in organizationUsers where user.isSuperAdmin && user.id != creatorId {
            user.isSuperAdmin = false
            do {
                try await firebaseBackend.saveUser(user)
                demoted = true
                print("🔥🔥🔥 DEBUG: Demoted mistaken super admin for \(user.email)")
            } catch {
                print("🔥🔥🔥 DEBUG: Failed to demote super admin for \(user.email): \(error.localizedDescription)")
            }
        }
        if demoted {
            await loadOrganizationUsers()
        }
    }
    
    func canViewReports() -> Bool {
        if isOperativeMode() { return false }
        return true
    }
    
    /// True if `actingUser` may delete `targetUser` under org policy:
    /// - Super Admin: can delete any non-creator user (including admins)
    /// - Admin (non-super): can delete only non-admin/non-super users
    private func canDeleteUser(targetUser: AppUser, actingUser: AppUser) -> Bool {
        let creatorUserId = firebaseBackend?.currentOrganization?.creatorUserId
        let isCreatorTarget = creatorUserId != nil && creatorUserId == targetUser.id
        if isCreatorTarget { return false }

        if actingUser.isSuperAdmin {
            return actingUser.id != targetUser.id
        }

        if actingUser.permissions.adminAccess {
            let targetIsAdminLike = targetUser.isSuperAdmin || targetUser.permissions.adminAccess || targetUser.role == .admin
            return !targetIsAdminLike
        }

        return false
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
    
    /// Summary of what the current user can and cannot see (for debugging / Settings).
    func currentUserAccessSummary() -> String {
        guard let u = displayUser else { return "Not signed in." }
        let previewNote = roleTestingPreset.map { "(Preview: \($0.title)) " } ?? ""
        if u.permissions.operativeMode {
            return """
            \(previewNote)Role: Operative (limited view)
            Can see: Home, Projects (assigned only), Small Works (assigned only), My Schedule (view only), Settings
            Cannot see: Managers, Operatives list, Manage Users, Add User, Skills, Qualifications, Wholesalers, Help tab, Create project/small works, Book work, Reports, Daily/Weekly overview
            """
        }
        var lines: [String] = [previewNote + "Role: " + (u.isSuperAdmin ? "Super Admin" : (u.permissions.adminAccess ? "Admin" : (u.permissions.manager ? "Manager" : "User")))]
        if hasAdminAccess() { lines.append("Can: Manage users, view all projects/small works, managers, operatives, skills, qualifications, create projects/small works, book work, reports") }
        else if canViewManagers() { lines.append("Can: View managers, operatives, projects, small works, book work") }
        else { lines.append("Can: View projects, small works (as permitted)") }
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
    func inviteUser(firstName: String, surname: String, email: String, mobileNumber: String?, permissions: UserPermissions, assignedManagerUserId: String? = nil, invitedOperativeDayRate: Double? = nil, invitedManagerDayRate: Double? = nil, invitedTradeTypePreset: String? = nil, invitedTradeTypeCustom: String? = nil) async -> Bool {
        print("🔥🔥🔥 DEBUG: inviteUser called with firstName: \(firstName), surname: \(surname), email: \(email)")
        
        errorMessage = nil
        
        if permissions.operativeMode && (assignedManagerUserId == nil || assignedManagerUserId?.isEmpty == true) {
            errorMessage = "Every operative must be assigned a line manager."
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
        
        // Check for duplicate email in the organization BEFORE attempting to create.
        // Use server source so we don't treat a deleted user as still existing due to cache.
        print("🔥🔥🔥 DEBUG: Checking for duplicate email: \(email) in organization: \(organizationId)")
        do {
            let db = Firestore.firestore()
            let duplicateCheck = try await db.collection("users")
                .whereField("email", isEqualTo: email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
                .whereField("organizationId", isEqualTo: organizationId)
                .getDocuments(source: .server)
            
            if !duplicateCheck.documents.isEmpty {
                print("🔥🔥🔥 DEBUG: ❌ DUPLICATE EMAIL DETECTED: \(email) already exists in this organization")
                for doc in duplicateCheck.documents {
                    let data = doc.data()
                    let existingEmail = data["email"] as? String ?? ""
                    let existingFirstName = data["firstName"] as? String ?? ""
                    let existingSurname = data["surname"] as? String ?? ""
                    print("🔥🔥🔥 DEBUG: Found existing user: \(doc.documentID) - \(existingFirstName) \(existingSurname) (\(existingEmail))")
                }
                errorMessage = "A user with the email address '\(email)' already exists in this organization. Each email address can only be used once per organization."
                return false
            }
            print("🔥🔥🔥 DEBUG: ✅ No duplicate email found - email is available")
        } catch {
            print("🔥🔥🔥 DEBUG: ⚠️ Error checking for duplicate email: \(error.localizedDescription)")
            // Continue anyway - the createUserInvitation will also check
        }
        
        // CRITICAL: Before creating a user, ensure the current user has admin permissions
        // Check the ACTUAL Firebase document (not just in-memory object) and fix if needed
        guard let currentUserId = firebaseBackend.currentUser?.uid else {
            print("🔥🔥🔥 DEBUG: ⚠️ No current user ID available")
            errorMessage = "Unable to identify current user. Please sign in again."
            return false
        }
        
        // Load the actual user document from Firebase to check permissions
        if let firebaseUserData = try? await firebaseBackend.getUserData(userId: currentUserId) {
            print("🔥🔥🔥 DEBUG: Current user (inviter) Firebase document data:")
            print("🔥🔥🔥 DEBUG: - isSuperAdmin: \(firebaseUserData.isSuperAdmin)")
            print("🔥🔥🔥 DEBUG: - adminAccess: \(firebaseUserData.permissions.adminAccess)")
            print("🔥🔥🔥 DEBUG: - role: \(firebaseUserData.role.rawValue)")
            
            // Check if user has admin permissions in Firebase
            let hasAdmin = firebaseUserData.isSuperAdmin || firebaseUserData.permissions.adminAccess || firebaseUserData.role == .admin
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
                assignedManagerUserId: assignedManagerUserId,
                invitedOperativeDayRate: invitedOperativeDayRate,
                invitedManagerDayRate: invitedManagerDayRate,
                invitedTradeTypePreset: invitedTradeTypePreset,
                invitedTradeTypeCustom: invitedTradeTypeCustom
            )
            print("🔥🔥🔥 DEBUG: createUserInvitation succeeded")
            
            // Reload organization users to show the newly added user
            await loadOrganizationUsers()
            print("🔥🔥🔥 DEBUG: Organization users reloaded")
            
            return true
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

    /// Transfers organization ownership (Super Admin) to another admin user.
    /// Updates `organizations/{orgId}.creatorUserId` and flips `isSuperAdmin` flags accordingly.
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
        if newOwnerUserId == currentUser.id {
            errorMessage = "You are already the Super Admin."
            return false
        }
        guard let newOwner = organizationUsers.first(where: { $0.id == newOwnerUserId }) else {
            errorMessage = "User not found."
            return false
        }
        guard !newOwner.permissions.operativeMode else {
            errorMessage = "Cannot make an operative the Super Admin."
            return false
        }
        guard newOwner.permissions.adminAccess || newOwner.isSuperAdmin || newOwner.role == .admin else {
            errorMessage = "Only an Admin can be made Super Admin."
            return false
        }

        do {
            try await firebaseBackend.transferOrganizationOwnership(
                organizationId: organizationId,
                newCreatorUserId: newOwnerUserId
            )
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
             
             func deactivateUser(userId: String) async {
                 guard let firebaseBackend = firebaseBackend else { return }
                 
                 do {
                     // Update user in Firebase to set isActive to false
                     var updatedUser = organizationUsers.first { $0.id == userId }
                     updatedUser?.isActive = false
                     
                     if let user = updatedUser {
                         try await firebaseBackend.saveUser(user)
                         
                         // Update local array
                         if let index = organizationUsers.firstIndex(where: { $0.id == userId }) {
                             organizationUsers[index] = user
                         }
                     }
                 } catch {
                     print("🔥🔥🔥 DEBUG: Error deactivating user: \(error)")
                 }
             }
             
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
                 
                guard canDeleteUser(targetUser: user, actingUser: currentUser) else {
                    print("🔥🔥🔥 DEBUG: ❌ Delete blocked by role policy")
                     await MainActor.run {
                        if user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin {
                            errorMessage = "Only the Super Admin can delete admin users."
                        } else {
                            errorMessage = "You do not have permission to delete this user."
                        }
                     }
                     return
                 }
                 
                 let isManager = user.permissions.manager || user.permissions.adminAccess || user.isSuperAdmin
                 let isOperative = user.permissions.operativeMode
                 
                 // If this is a manager, update all bookings' bookedBy to super admin
                 if isManager, let bookingStore = bookingStore {
                     // Find super admin
                     let superAdmin = organizationUsers.first { $0.isSuperAdmin }
                     let superAdminName = superAdmin?.fullName ?? "Super Admin"
                     
                     // Update all bookings where this manager is the booker
                     let bookingsToUpdate = bookingStore.bookings.filter { $0.bookedBy == userName }
                     print("🔥🔥🔥 DEBUG: Updating \(bookingsToUpdate.count) bookings from manager \(userName) to super admin \(superAdminName)")
                     
                     for booking in bookingsToUpdate {
                         var updatedBooking = booking
                         updatedBooking.bookedBy = superAdminName
                         await bookingStore.updateBooking(updatedBooking)
                     }
                     
                     if !bookingsToUpdate.isEmpty {
                         print("🔥🔥🔥 DEBUG: ✅ Updated \(bookingsToUpdate.count) bookings to super admin")
                     }
                 }
                 
                 // If this is an operative, delete all bookings and remove from OperativeStore
                 if isOperative {
                     print("🔥🔥🔥 DEBUG: User is an operative - deleting bookings and operative record")
                     
                     // Find the operative in OperativeStore by email
                     if let operativeStore = operativeStore {
                         let matchingOperative = await MainActor.run {
                             operativeStore.operatives.first { $0.email.lowercased() == userEmail }
                         }
                         
                         if let operative = matchingOperative {
                             print("🔥🔥🔥 DEBUG: Found operative record: \(operative.name) (ID: \(operative.id))")
                             
                             // Delete all bookings for this operative
                             if let bookingStore = bookingStore {
                                 let bookingsToDelete = await MainActor.run {
                                     bookingStore.bookings.filter { $0.operativeId == operative.id }
                                 }
                                 print("🔥🔥🔥 DEBUG: Deleting \(bookingsToDelete.count) bookings for operative \(operative.name)")
                                 
                                 for booking in bookingsToDelete {
                                     await bookingStore.deleteBooking(booking)
                                 }
                                 
                                 if !bookingsToDelete.isEmpty {
                                     print("🔥🔥🔥 DEBUG: ✅ Deleted \(bookingsToDelete.count) bookings for operative")
                                 }
                             }
                             
                             // Delete the operative from OperativeStore
                             await operativeStore.deleteOperative(operative, bookingStore: bookingStore)
                             print("🔥🔥🔥 DEBUG: ✅ Deleted operative record from OperativeStore")
                         } else {
                             print("🔥🔥🔥 DEBUG: ⚠️ No matching operative record found in OperativeStore (may not exist)")
                             
                             // Still delete bookings that might reference this user by email or name
                             if let bookingStore = bookingStore {
                                 // Try to find bookings by matching operative name or email
                                 let bookingsToDelete = await MainActor.run {
                                     bookingStore.bookings.filter { booking in
                                         // Check if any operative matches this booking's operativeId
                                         if let operative = operativeStore.operatives.first(where: { $0.id == booking.operativeId }) {
                                             return operative.email.lowercased() == userEmail || operative.name == userName
                                         }
                                         return false
                                     }
                                 }
                                 
                                 if !bookingsToDelete.isEmpty {
                                     print("🔥🔥🔥 DEBUG: Deleting \(bookingsToDelete.count) additional bookings found by email/name match")
                                     for booking in bookingsToDelete {
                                         await bookingStore.deleteBooking(booking)
                                     }
                                 }
                             }
                         }
                     } else {
                         print("🔥🔥🔥 DEBUG: ⚠️ OperativeStore not provided - cannot delete operative record")
                     }
                 }
                 
                // Delete from Firebase: remove ALL user documents for this email in this org
                // (invited users: users/{randomUUID}; after signup may also have users/{authUid} — delete every match)
                guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                    await MainActor.run { errorMessage = "Organization not loaded." }
                    return
                }
                do {
                    let db = Firestore.firestore()
                    let emailNormalized = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let emailRaw = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    var docIdsToDelete = Set<String>()
                    docIdsToDelete.insert(userId)
                    
                    func collectDocs(_ snap: QuerySnapshot) {
                        for doc in snap.documents { docIdsToDelete.insert(doc.documentID) }
                    }
                    
                    let snapLower = try await db.collection("users")
                        .whereField("organizationId", isEqualTo: organizationId)
                        .whereField("email", isEqualTo: emailNormalized)
                        .getDocuments(source: .server)
                    collectDocs(snapLower)
                    
                    if emailRaw != emailNormalized {
                        let snapRaw = try await db.collection("users")
                            .whereField("organizationId", isEqualTo: organizationId)
                            .whereField("email", isEqualTo: emailRaw)
                            .getDocuments(source: .server)
                        collectDocs(snapRaw)
                    }
                    
                    print("🔥🔥🔥 DEBUG: Deleting \(docIdsToDelete.count) user document id(s) for \(userEmail)")
                    
                    var deletedAny = false
                    for docId in docIdsToDelete {
                        let ref = db.collection("users").document(docId)
                        let doc = try await ref.getDocument(source: .server)
                        guard doc.exists, let data = doc.data() else {
                            continue
                        }
                        guard (data["organizationId"] as? String) == organizationId else {
                            print("🔥🔥🔥 DEBUG: ⚠️ Skip users/\(docId) — organizationId mismatch")
                            continue
                        }
                        let docEmailNorm = ((data["email"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        let sameRowAsUI = (docId == userId)
                        guard docEmailNorm == emailNormalized || sameRowAsUI else {
                            print("🔥🔥🔥 DEBUG: ⚠️ Skip users/\(docId) — email mismatch (doc=\(docEmailNorm) vs \(emailNormalized))")
                            continue
                        }
                        print("🔥🔥🔥 DEBUG: Deleting user document: users/\(docId)")
                        try await ref.delete()
                        deletedAny = true
                        print("🔥🔥🔥 DEBUG: ✅ Deleted users/\(docId)")
                        do {
                            try await db.collection("organizations").document(organizationId).updateData([
                                "members.\(docId)": FieldValue.delete()
                            ])
                            print("🔥🔥🔥 DEBUG: ✅ Removed \(docId) from organization members")
                        } catch {
                            print("🔥🔥🔥 DEBUG: ⚠️ Could not remove \(docId) from members: \(error.localizedDescription)")
                        }
                    }
                    
                    if !deletedAny {
                        print("🔥🔥🔥 DEBUG: No matching user documents deleted for \(userEmail) (may already be gone)")
                    }
                    
                    // Clear email claim so this email can be re-invited (Firestore duplicate-prevention)
                    try await db.collection("organizations").document(organizationId)
                        .collection("userEmails").document(emailNormalized).delete()
                    print("🔥🔥🔥 DEBUG: ✅ Cleared userEmails/\(emailNormalized) if present")
                    
                    // Remove pending invitations so stale links and resend state don't linger
                    let emailVariants = Array(Set([emailNormalized, emailRaw].filter { !$0.isEmpty }))
                    for variant in emailVariants {
                        let invSnap = try await db.collection("invitations")
                            .whereField("organizationId", isEqualTo: organizationId)
                            .whereField("email", isEqualTo: variant)
                            .getDocuments(source: .server)
                        for invDoc in invSnap.documents {
                            try await invDoc.reference.delete()
                            print("🔥🔥🔥 DEBUG: ✅ Deleted invitation \(invDoc.documentID) for \(variant)")
                        }
                    }
                } catch {
                    print("🔥🔥🔥 DEBUG: ❌ Failed to delete user \(userName) from Firebase: \(error.localizedDescription)")
                    await MainActor.run { errorMessage = "Failed to delete user: \(error.localizedDescription)" }
                    return
                }
                
                // Remove from local array and reload so UI matches Firebase (if owner deleted someone in console, they disappear)
                organizationUsers.removeAll { $0.email.lowercased() == userEmail }
                print("🔥🔥🔥 DEBUG: ✅ User removed from local array")
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
        guard let index = organizationUsers.firstIndex(where: { $0.id == userId }) else { return false }
        if isOrganizationCreator(userId: userId) { return false }

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

        updated.firstName = trimmedFirst
        updated.surname = trimmedSurname
        updated.email = trimmedEmail
        updated.mobileNumber = mobileOut

        let emailChanged = oldEmailNorm != trimmedEmail
        let orgId = updated.organizationId

        do {
            try await firebaseBackend.saveUser(updated)
            if emailChanged {
                try await firebaseBackend.reconcileUserEmailIndex(
                    organizationId: orgId,
                    userId: userId,
                    oldEmailNormalized: oldEmailNorm,
                    newEmail: trimmedEmail
                )
            }

            if let opStore = operativeStore {
                if let oi = opStore.operatives.firstIndex(where: {
                    $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == oldEmailNorm
                }) {
                    var op = opStore.operatives[oi]
                    op.firstName = trimmedFirst
                    op.lastName = trimmedSurname
                    op.email = trimmedEmail
                    op.phone = mobileOut
                    op.updatedAt = Date()
                    await opStore.updateOperative(op)
                }
                if let mi = opStore.managers.firstIndex(where: {
                    $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == oldEmailNorm
                }) {
                    var mgr = opStore.managers[mi]
                    mgr.email = trimmedEmail
                    mgr.firstName = trimmedFirst
                    mgr.lastName = trimmedSurname
                    mgr.mobileNumber = mobileOut ?? ""
                    mgr.updatedAt = Date()
                    try await firebaseBackend.saveManager(mgr, organizationId: orgId)
                    opStore.managers[mi] = mgr
                }
            }

            organizationUsers[index] = updated
            if var cu = currentUser, cu.id == userId {
                cu = updated
                currentUser = cu
            }

            if emailChanged, Auth.auth().currentUser?.uid == userId {
                do {
                    try await firebaseBackend.sendVerifyBeforeUpdateEmail(to: trimmedEmail)
                } catch {
                    errorMessage = "Profile saved. Could not send sign-in email verification: \(error.localizedDescription). You can try again later or update the address in Firebase Authentication."
                    print("🔥🔥🔥 DEBUG: verifyBeforeUpdateEmail failed: \(error)")
                }
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
                 linkedOperativeUUID: UUID? = nil
             ) async -> Bool {
                 guard let firebaseBackend = firebaseBackend else { return false }

                 do {
                     if let index = organizationUsers.firstIndex(where: { $0.id == userId }) {
                         var updatedUser = organizationUsers[index]
                         let previousPermissions = updatedUser.permissions

                         if updatedUser.isSuperAdmin && isOrganizationCreator(userId: updatedUser.id) {
                             print("🔥🔥🔥 DEBUG: Cannot update permissions for organization creator super admin")
                             return false
                         }

                        updatedUser.permissions = permissions

                        if permissions.adminAccess {
                            updatedUser.role = .admin
                        } else if permissions.manager {
                            updatedUser.role = .manager
                        } else if permissions.operativeMode {
                            updatedUser.role = .operative
                        } else {
                            updatedUser.role = .viewer
                        }

                        try await firebaseBackend.saveUser(updatedUser)
                         organizationUsers[index] = updatedUser

                         if let holidayStore,
                            UserRoleTransitionPolicy.shouldClearPendingAnnualLeave(
                                old: previousPermissions,
                                new: permissions
                            ) {
                             await holidayStore.deletePendingHolidayRequestsFor(
                                 userId: userId,
                                 operativeId: linkedOperativeUUID
                             )
                         }

                         return true
                     }
                     return false
                 } catch {
                     print("🔥🔥🔥 DEBUG: Error updating user permissions: \(error)")
                     return false
                 }
             }

             /// Updates operative-specific profile fields on the user account and synchronizes linked operative day rate.
             func updateOperativeProfileFields(
                for user: AppUser,
                assignedManagerUserId: String?,
                dayRate: Double?,
                operativeStore: OperativeStore?
             ) async -> Bool {
                guard let firebaseBackend = firebaseBackend else { return false }
                guard let index = organizationUsers.firstIndex(where: { $0.id == user.id }) else { return false }
                var updatedUser = organizationUsers[index]
                guard updatedUser.permissions.operativeMode || updatedUser.role == .operative else { return false }

                updatedUser.assignedManagerUserId = assignedManagerUserId
                updatedUser.dayRate = dayRate

                do {
                    let previousDayRate = organizationUsers[index].dayRate
                    let dayRateChanged = previousDayRate != dayRate
                    try await firebaseBackend.updateOperativeProfileMetadata(
                        userId: updatedUser.id,
                        assignedManagerUserId: assignedManagerUserId,
                        dayRate: dayRate
                    )
                    if dayRateChanged,
                       let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                        if let previousDayRate {
                            let history = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? [:]
                            if history[updatedUser.id]?.isEmpty ?? true {
                                try? await firebaseBackend.recordOperativeDayRateChange(
                                    organizationId: orgId,
                                    userId: updatedUser.id,
                                    dayRate: previousDayRate,
                                    effectiveAt: updatedUser.createdAt
                                )
                            }
                        }
                        if let newRate = dayRate {
                            try? await firebaseBackend.recordOperativeDayRateChange(
                                organizationId: orgId,
                                userId: updatedUser.id,
                                dayRate: newRate,
                                effectiveAt: Date()
                            )
                        }
                    }
                    clearOperativeProfileOverride(for: updatedUser.id)
                    organizationUsers[index] = updatedUser
                    if let operativeStore {
                        await syncActiveOperativesWithUserAccounts(operativeStore: operativeStore)
                    }
                    await loadOrganizationUsers()
                    return true
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                        do {
                            try await firebaseBackend.saveOperativeProfileMetadataFallback(
                                organizationId: updatedUser.organizationId,
                                userId: updatedUser.id,
                                assignedManagerUserId: assignedManagerUserId,
                                dayRate: dayRate
                            )
                            clearOperativeProfileOverride(for: updatedUser.id)
                            organizationUsers[index] = updatedUser
                            errorMessage = "Primary user profile write was blocked, but saved to cloud fallback."
                            if let operativeStore {
                                await syncActiveOperativesWithUserAccounts(operativeStore: operativeStore)
                            }
                            await loadOrganizationUsers()
                            return true
                        } catch {
                            // Last fallback: keep operations unblocked by persisting an on-device override.
                            saveOperativeProfileOverride(
                                for: updatedUser.id,
                                assignedManagerUserId: assignedManagerUserId,
                                dayRate: dayRate
                            )
                            organizationUsers[index] = updatedUser
                            errorMessage = "Cloud permissions blocked this update. Saved locally on this device."
                            if let operativeStore {
                                await syncActiveOperativesWithUserAccounts(operativeStore: operativeStore)
                            }
                            return true
                        }
                    } else {
                        errorMessage = "Failed to update operative profile fields: \(error.localizedDescription)"
                        print("🔥🔥🔥 DEBUG: Error updating operative profile fields: \(error)")
                        return false
                    }
                }
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
            if let idx = organizationUsers.firstIndex(where: { $0.id == user.id }) {
                organizationUsers[idx].profilePhotoURL = url
            }
            if var cu = currentUser, cu.id == user.id {
                cu.profilePhotoURL = url
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
        guard user.permissions.operativeMode || user.role == .operative || user.permissions.manager || user.role == .manager else {
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

    func updateManagerDayRate(for user: AppUser, dayRate: Double?) async -> Bool {
        guard let firebaseBackend = firebaseBackend else { return false }
        guard let index = organizationUsers.firstIndex(where: { $0.id == user.id }) else { return false }
        guard organizationUsers[index].permissions.manager || organizationUsers[index].role == .manager else { return false }
        
        var updatedUser = organizationUsers[index]
        updatedUser.dayRate = dayRate
        
        do {
            try await firebaseBackend.updateUserDayRateMetadata(userId: updatedUser.id, dayRate: dayRate)
            organizationUsers[index] = updatedUser
            await loadOrganizationUsers()
            return true
        } catch {
            errorMessage = "Failed to update manager day rate: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error updating manager day rate: \(error)")
            return false
        }
    }
             
             // MARK: - User Active Status
             
             /// Sets `isActive` on **every** `users/*` document for this person in the org (same email),
             /// so duplicates (invite UUID + Auth uid) do not leave one doc stuck `true`.
             func updateUserActiveStatus(for user: AppUser, isActive: Bool) async -> Bool {
                 guard firebaseBackend != nil else {
                     errorMessage = "Unable to connect."
                     return false
                 }
                 guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else {
                     errorMessage = "Organization not loaded."
                     return false
                 }
                 
                 let db = Firestore.firestore()
                 let emailNormalized = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                 let emailRaw = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
                 
                 var docIds = Set<String>()
                 docIds.insert(user.id)
                 
                 do {
                     let snapLower = try await db.collection("users")
                         .whereField("organizationId", isEqualTo: organizationId)
                         .whereField("email", isEqualTo: emailNormalized)
                         .getDocuments(source: .server)
                     for d in snapLower.documents { docIds.insert(d.documentID) }
                     
                     if emailRaw != emailNormalized {
                         let snapRaw = try await db.collection("users")
                             .whereField("organizationId", isEqualTo: organizationId)
                             .whereField("email", isEqualTo: emailRaw)
                             .getDocuments(source: .server)
                         for d in snapRaw.documents { docIds.insert(d.documentID) }
                     }
                     
                     var updatedCount = 0
                     for docId in docIds {
                         let ref = db.collection("users").document(docId)
                         let doc = try await ref.getDocument(source: .server)
                         guard doc.exists, let data = doc.data() else { continue }
                         guard (data["organizationId"] as? String) == organizationId else { continue }
                         let docEmailNorm = ((data["email"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                         let sameRowAsUI = (docId == user.id)
                         guard docEmailNorm == emailNormalized || sameRowAsUI else { continue }
                         
                         try await ref.updateData([
                             "isActive": isActive,
                             "updatedAt": Timestamp(date: Date())
                         ])
                         updatedCount += 1
                         print("🔥🔥🔥 DEBUG: ✅ isActive=\(isActive) on users/\(docId)")
                     }
                     
                     if updatedCount == 0 {
                         errorMessage = "Could not update this user in Firestore (no matching documents)."
                         print("🔥🔥🔥 DEBUG: ❌ updateUserActiveStatus: 0 documents updated for \(emailNormalized)")
                         return false
                     }
                     
                     for i in organizationUsers.indices {
                         if organizationUsers[i].email.lowercased() == emailNormalized {
                             organizationUsers[i].isActive = isActive
                         }
                     }
                     await loadOrganizationUsers()
                     errorMessage = nil
                     return true
                 } catch {
                     errorMessage = "Failed to update active status: \(error.localizedDescription)"
                     print("🔥🔥🔥 DEBUG: ❌ Error updating user active status: \(error)")
                     return false
                 }
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
            if let dr = user.dayRate, op.dayRate != dr {
                op.dayRate = dr
                changed = true
            }
            if op.tradeTypePreset != user.tradeTypePreset || op.tradeTypeCustom != user.tradeTypeCustom {
                op.tradeTypePreset = user.tradeTypePreset
                op.tradeTypeCustom = user.tradeTypeCustom
                changed = true
            }
            if changed {
                op.updatedAt = Date()
                await operativeStore.updateOperative(op)
                print("🔥🔥🔥 DEBUG: ✅ Synced operative roster for linked user \(em)")
            }
        }
    }

    private func loadOperativeProfileOverrides() -> [String: OperativeProfileOverride] {
        guard let data = UserDefaults.standard.data(forKey: operativeProfileOverridesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: OperativeProfileOverride].self, from: data)) ?? [:]
    }

    private func saveOperativeProfileOverrides(_ overrides: [String: OperativeProfileOverride]) {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: operativeProfileOverridesKey)
        }
    }

    private func saveOperativeProfileOverride(for userId: String, assignedManagerUserId: String?, dayRate: Double?) {
        var overrides = loadOperativeProfileOverrides()
        overrides[userId] = OperativeProfileOverride(
            assignedManagerUserId: assignedManagerUserId,
            dayRate: dayRate,
            updatedAt: Date()
        )
        saveOperativeProfileOverrides(overrides)
    }

    private func clearOperativeProfileOverride(for userId: String) {
        var overrides = loadOperativeProfileOverrides()
        overrides.removeValue(forKey: userId)
        saveOperativeProfileOverrides(overrides)
    }

    private func applyOperativeProfileOverrides(to users: [AppUser]) -> [AppUser] {
        let overrides = loadOperativeProfileOverrides()
        guard !overrides.isEmpty else { return users }
        return users.map { user in
            guard let override = overrides[user.id] else { return user }
            var updated = user
            updated.assignedManagerUserId = override.assignedManagerUserId
            updated.dayRate = override.dayRate
            return updated
        }
    }

    private func applyCloudOperativeProfileOverrides(
        _ users: [AppUser],
        overrides: [String: FirebaseBackend.OperativeProfileMetadata]
    ) -> [AppUser] {
        guard !overrides.isEmpty else { return users }
        return users.map { user in
            guard let override = overrides[user.id] else { return user }
            var updated = user
            updated.assignedManagerUserId = override.assignedManagerUserId
            updated.dayRate = override.dayRate
            return updated
        }
    }
}