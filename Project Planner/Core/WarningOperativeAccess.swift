import Foundation

/// Who may open Edit User from a staff warning. Hidden when this is false.
/// Managers need the Operatives toggle. Admins who can manage users do not.
enum WarningOperativeAccess {
    enum Destination: Equatable {
        case editUser(userId: String)
    }

    static func canOpen(actor: AppUser, target: AppUser) -> Bool {
        if actor.permissions.operativeMode { return false }
        if target.isSuperAdmin && !actor.isSuperAdmin { return false }
        let canManageUsers = actor.isSuperAdmin || actor.permissions.adminAccess || actor.role == .admin
        if canManageUsers { return true }
        // RULEBOOK §11 `canManageOperatives`: above operative level with the Operatives toggle in effect.
        if CanonicalBusinessEngine.canManageOperatives(actor.permissionSubject) {
            return target.permissions.operativeMode || target.role == .operative
        }
        return false
    }

    /// Login accounts open Edit User. No destination means the control stays hidden.
    static func destination(actor: AppUser, target: AppUser) -> Destination? {
        guard target.isStoredUserDocument, canOpen(actor: actor, target: target) else { return nil }
        return .editUser(userId: target.id)
    }
}
