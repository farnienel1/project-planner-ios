import XCTest
@testable import Project_Planner

/// RULEBOOK §13 (forced sign-out removes this phone's push token) and §11 (Add User saves the toggles shown).
@MainActor
final class SignOutAndAddUserPermissionTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Sign-out: one path, clean-up first, bounded

    func testSignOutRunsAfterTheCleanupFinishes() async {
        var events: [String] = []
        let finished = await SignOutSequence.run(
            timeoutSeconds: 2,
            cleanup: { events.append("cleanup") },
            signOut: { events.append("signOut") }
        )
        XCTAssertTrue(finished)
        XCTAssertEqual(events, ["cleanup", "signOut"])
    }

    func testSignOutStillHappensWhenTheCleanupNeverReturns() async {
        var signOuts = 0
        let started = Date()
        let finished = await SignOutSequence.run(
            timeoutSeconds: 0.3,
            cleanup: {
                // A hung network call: never finishes inside the timeout.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            },
            signOut: { signOuts += 1 }
        )
        XCTAssertFalse(finished)
        XCTAssertEqual(signOuts, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the wait is bounded by the timeout, not the clean-up")
    }

    func testSignOutStillHappensWhenTheCleanupFails() async {
        enum CleanupError: Error { case refused }
        var signOuts = 0
        let finished = await SignOutSequence.run(
            timeoutSeconds: 2,
            cleanup: {
                // The clean-up swallows a refused write, as `removePushToken` does.
                do { throw CleanupError.refused } catch {}
            },
            signOut: { signOuts += 1 }
        )
        XCTAssertTrue(finished)
        XCTAssertEqual(signOuts, 1)
    }

    func testTheDefaultCleanupWaitIsShort() {
        XCTAssertLessThanOrEqual(SignOutSequence.defaultCleanupTimeoutSeconds, 5)
        XCTAssertGreaterThan(SignOutSequence.defaultCleanupTimeoutSeconds, 0)
    }

    /// Every Firebase Auth sign-out in the app goes through `FirebaseBackend.signOutRemovingPushToken`, so no forced
    /// path (expired session, blocked trial) can skip the push-token clean-up.
    func testFirebaseAuthSignOutIsCalledFromOnePlaceOnly() throws {
        let appRoot = repoRoot.appendingPathComponent("Project Planner")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"(\bauth|Auth\.auth\(\))\.signOut\("#)
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(hits.count, 1, "Firebase Auth sign-out outside signOutRemovingPushToken: \(hits)")
        XCTAssertTrue(hits.first?.hasPrefix("FirebaseBackend.swift") == true, "\(hits)")

        let backend = try String(contentsOf: appRoot.appendingPathComponent("FirebaseBackend.swift"), encoding: .utf8)
        let start = try XCTUnwrap(backend.range(of: "func signOutRemovingPushToken(reason: SignOutReason) async {"))
        let end = try XCTUnwrap(backend.range(of: "func clearDeviceQueuesOnSignOut()", range: start.upperBound..<backend.endIndex))
        let body = backend[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("SignOutSequence.run("))
        XCTAssertTrue(body.contains("removePushToken("))
        XCTAssertTrue(body.contains("try auth.signOut()"))
    }

    // MARK: Add User: the toggles shown are the toggles saved

    private func subject(_ permissions: UserPermissions, _ level: RulebookPermissionLevel) -> [String: Any] {
        CanonicalBusinessEngine.permissionSubject(permissions: permissions, role: level.rawValue, isSuperAdmin: false)
    }

    func testTheFirstSeedIsTheRulebookDefaults() throws {
        for level in RulebookPermissionLevel.allCases {
            let defaults = try XCTUnwrap(CanonicalBusinessEngine.addUserPermissionDefaults(level))
            let seeded = AddUserPermissionSeeding.select(level: level, current: UserPermissions(), seededLevel: nil)
            XCTAssertEqual(seeded.seededLevel, level)
            XCTAssertEqual(seeded.permissions, UserPermissions().applying(defaults), "\(level)")
        }
    }

    /// Owner report: the picked toggles were replaced by the role defaults when the Permissions step appeared again
    /// (Back from Review) or Next was pressed on step 1 again. Reselecting the same level now keeps every pick, and
    /// `permissionsWriteMap` (what the invite saves) keeps every editable pick.
    func testReselectingTheSameLevelKeepsEveryEditableToggleAndTheSaveWritesIt() throws {
        for level in RulebookPermissionLevel.allCases {
            var draft = AddUserPermissionSeeding.select(level: level, current: UserPermissions(), seededLevel: nil)
            let editable = CanonicalBusinessEngine
                .permissionToggleRows(level: level, user: subject(draft.permissions, level), mode: .add)
                .filter { $0.visible && $0.editable }
            XCTAssertFalse(editable.isEmpty, "\(level) has editable toggles")
            var picked = draft.permissions
            for row in editable {
                picked.setFlag(row.field, !(picked.flag(row.field) ?? row.value))
            }

            // Step changes / step 3 re-appearing / Next on step 1 with the same level.
            draft = AddUserPermissionSeeding.select(level: level, current: picked, seededLevel: draft.seededLevel)
            XCTAssertEqual(draft.permissions, picked, "\(level): reselecting the same level must not reset the picks")

            let written = try XCTUnwrap(CanonicalBusinessEngine.permissionsWriteMap(subject(draft.permissions, level), level: level))
            for row in editable {
                XCTAssertEqual(written[row.field], picked.flag(row.field), "\(level).\(row.field) saved as shown")
            }
        }
    }

    func testChangingTheLevelStartsFromThatLevelsDefaults() throws {
        let manager = AddUserPermissionSeeding.select(level: .manager, current: UserPermissions(), seededLevel: nil)
        var picked = manager.permissions
        picked.weeklyReports.toggle()
        let operative = AddUserPermissionSeeding.select(level: .operative, current: picked, seededLevel: manager.seededLevel)
        XCTAssertEqual(operative.seededLevel, .operative)
        XCTAssertEqual(
            operative.permissions,
            UserPermissions().applying(try XCTUnwrap(CanonicalBusinessEngine.addUserPermissionDefaults(.operative)))
        )
    }

    /// The Permissions step no longer re-seeds on appear, and the dead hard-coded operative toggle list is gone.
    func testAddUserViewSeedsOnlyThroughTheRulebookDefaults() throws {
        let view = try String(
            contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/AddUserView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(view.contains("stepManagerOperativeSummary"))
        XCTAssertFalse(view.contains("permissions = UserPermissions().applying("))
        XCTAssertTrue(view.contains("AddUserPermissionSeeding.select("))
        let step = try XCTUnwrap(view.range(of: "private var stepPermissionsControlled: some View {"))
        let next = try XCTUnwrap(view.range(of: "private var permissionsDescriptionHeader: String {", range: step.upperBound..<view.endIndex))
        XCTAssertFalse(view[step.upperBound..<next.lowerBound].contains("applyPermissionsForInvitedType()"))
    }

    // MARK: Add User: line managers survive step changes

    private func invitee(_ level: RulebookPermissionLevel, lineManagers: Set<String>, hasNoLineManager: Bool) -> AppUser {
        let role: UserRole = level == .admin ? .admin : (level == .operative ? .operative : .manager)
        let seeded = AddUserPermissionSeeding.select(level: level, current: UserPermissions(), seededLevel: nil)
        var user = AppUser(id: "invite-draft", email: "test-invite@example.test", organizationId: "TEST-org", role: role, permissions: seeded.permissions)
        user.setLineManagerUserIds(Array(lineManagers).sorted())
        user.hasNoLineManager = hasNoLineManager
        return user
    }

    /// Owner report: Next on step 1 cleared an operative's chosen line managers every time, including after Back.
    /// The picks now survive any step change and the same type; only a real account-type change clears them.
    func testLineManagerPicksAreKeptUnlessTheAccountTypeChanges() {
        for level in RulebookPermissionLevel.allCases {
            let kept = AddUserLineManagerSelection.afterAccountTypeSelection(
                previous: level, next: level, lineManagerIds: ["TEST-admin-1"], hasNoLineManager: false
            )
            XCTAssertEqual(kept.lineManagerIds, ["TEST-admin-1"], "\(level)")
            XCTAssertFalse(kept.hasNoLineManager)
        }
        let keptNone = AddUserLineManagerSelection.afterAccountTypeSelection(
            previous: .admin, next: .admin, lineManagerIds: [], hasNoLineManager: true
        )
        XCTAssertTrue(keptNone.hasNoLineManager)

        let changed = AddUserLineManagerSelection.afterAccountTypeSelection(
            previous: .admin, next: .operative, lineManagerIds: ["TEST-admin-1"], hasNoLineManager: true
        )
        XCTAssertEqual(changed.lineManagerIds, [])
        XCTAssertFalse(changed.hasNoLineManager, "No line manager is admin-only; it never carries to another type")
    }

    /// `lineManagerRequiredError` still decides: a kept pick satisfies it for an operative; an operative or manager
    /// with none is refused; only an admin may have none.
    func testKeptLineManagersSatisfyTheRequiredRule() {
        let admin = AppUser(id: "TEST-admin-1", email: "test-admin@example.test", organizationId: "TEST-org", role: .admin, permissions: UserPermissions(adminAccess: true))
        let kept = AddUserLineManagerSelection.afterAccountTypeSelection(
            previous: .operative, next: .operative, lineManagerIds: ["TEST-admin-1"], hasNoLineManager: false
        )
        let operative = invitee(.operative, lineManagers: kept.lineManagerIds, hasNoLineManager: kept.hasNoLineManager)
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: operative, users: [admin]))

        for level in [RulebookPermissionLevel.operative, .manager] {
            let none = invitee(level, lineManagers: [], hasNoLineManager: false)
            XCTAssertNotNil(AnnualLeaveApproval.lineManagerRequiredError(for: none, users: [admin]), "\(level)")
        }
        // RULEBOOK 1.28.0: an admin may have none only with both self-manage toggles on.
        var soloAdmin = invitee(.admin, lineManagers: [], hasNoLineManager: true)
        XCTAssertNotNil(AnnualLeaveApproval.lineManagerRequiredError(for: soloAdmin, users: [admin]))
        soloAdmin.permissions.annualLeaveSelfBook = true
        soloAdmin.permissions.timesheetSelfSign = true
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: soloAdmin, users: [admin]))
    }

    /// The Next button no longer clears line managers; only the account-type card does, through the helper.
    func testAddUserNextDoesNotClearLineManagers() throws {
        let view = try String(
            contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/AddUserView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(view.contains("selectedLineManagerUserIds.removeAll()"))
        XCTAssertTrue(view.contains("AddUserLineManagerSelection.afterAccountTypeSelection("))
    }
}
