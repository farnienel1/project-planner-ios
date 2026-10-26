import XCTest
@testable import Project_Planner

/// UTR and VAT number rules from web `lib/canonical/sensitiveProfile.ts`, through `CanonicalBusinessEngine`.
@MainActor
final class SensitiveProfileCanonicalTests: XCTestCase {
    private typealias Engine = CanonicalBusinessEngine

    private func role(
        superAdmin: Bool = false,
        admin: Bool = false,
        manager: Bool = false,
        operativeMode: Bool = false
    ) -> Engine.CanonicalStaffAccountRole {
        Engine.CanonicalStaffAccountRole(
            isSuperAdmin: superAdmin,
            isAdmin: admin,
            isManager: manager,
            isOperativeMode: operativeMode
        )
    }

    func testMaskKeepsLastFour() {
        XCTAssertEqual(Engine.maskSensitiveValue("1234567890"), "•••• 7890")
        XCTAssertEqual(Engine.maskSensitiveValue("1234"), "••••")
        XCTAssertEqual(Engine.maskSensitiveValue("   "), "")
        XCTAssertEqual(Engine.maskSensitiveValue(nil), "")
    }

    func testResolvePrefersPrivateDocEvenWhenBlank() throws {
        let resolved = try XCTUnwrap(Engine.resolveSensitiveProfile(
            privateDoc: ["utrNumber": "", "vatNumber": ""],
            legacyUser: ["utrNumber": "1111111111", "vatNumber": "GB999"]
        ))
        XCTAssertEqual(resolved.source, "private")
        XCTAssertEqual(resolved.utrNumber, "")
        XCTAssertEqual(resolved.vatNumber, "")
    }

    func testResolveFallsBackToLegacyUntilMigrated() throws {
        let resolved = try XCTUnwrap(Engine.resolveSensitiveProfile(
            privateDoc: nil,
            legacyUser: ["utrNumber": " 1111111111 "]
        ))
        XCTAssertEqual(resolved.source, "legacy")
        XCTAssertEqual(resolved.utrNumber, "1111111111")
        XCTAssertEqual(try XCTUnwrap(Engine.resolveSensitiveProfile(privateDoc: nil, legacyUser: nil)).source, "none")
    }

    func testOnlySelfAndAdminsCanView() {
        XCTAssertFalse(Engine.canViewSensitiveProfile(viewerRole: role(manager: true), viewerUserId: "m1", subjectUserId: "o1"))
        XCTAssertFalse(Engine.canViewSensitiveProfile(viewerRole: role(operativeMode: true), viewerUserId: "o2", subjectUserId: "o1"))
        XCTAssertTrue(Engine.canViewSensitiveProfile(viewerRole: role(operativeMode: true), viewerUserId: "o1", subjectUserId: "o1"))
        XCTAssertTrue(Engine.canViewSensitiveProfile(viewerRole: role(admin: true), viewerUserId: "a1", subjectUserId: "o1"))
        XCTAssertTrue(Engine.canViewSensitiveProfile(viewerRole: role(superAdmin: true), viewerUserId: "s1", subjectUserId: "o1"))
        XCTAssertFalse(Engine.canViewSensitiveProfile(viewerRole: role(admin: true, operativeMode: true), viewerUserId: "a1", subjectUserId: "o1"))
    }

    func testExportNeedsRequestAndPermission() {
        XCTAssertFalse(Engine.exportIncludesSensitiveFields(requested: false, canView: true))
        XCTAssertFalse(Engine.exportIncludesSensitiveFields(requested: true, canView: false))
        XCTAssertTrue(Engine.exportIncludesSensitiveFields(requested: true, canView: true))
    }

    func testWriteFieldsTrimAndCap() throws {
        let write = try XCTUnwrap(Engine.sensitiveProfileWriteFields(utrNumber: " 1234567890 ", vatNumber: nil, updatedByUserId: "a1"))
        XCTAssertTrue(write.ok)
        XCTAssertEqual(write.fields?.utrNumber, "1234567890")
        XCTAssertEqual(write.fields?.vatNumber, "")
        XCTAssertEqual(write.fields?.updatedByUserId, "a1")

        let tooLong = try XCTUnwrap(Engine.sensitiveProfileWriteFields(
            utrNumber: String(repeating: "9", count: 21),
            vatNumber: "",
            updatedByUserId: "a1"
        ))
        XCTAssertFalse(tooLong.ok)
        XCTAssertEqual(tooLong.error, "too_long")
    }

    func testConstantsAndPath() {
        XCTAssertEqual(Engine.sensitiveProfileDocId, "taxIds")
        XCTAssertEqual(Engine.sensitiveHeldByAdminCopy, "Held by admin")
        XCTAssertEqual(Engine.sensitiveExportOptionLabel, "Include UTR and VAT number")
        XCTAssertEqual(Engine.sensitiveValueMax, 20)
        XCTAssertEqual(Engine.sensitiveProfileDocPath(userId: "u1"), "users/u1/private/taxIds")
    }

    func testDraftKeepsReplacesAndRemoves() {
        var draft = SensitiveFieldDraft()
        draft.reset(saved: "1234567890")
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.valueToSave, "1234567890")
        draft.typed = "  555  "
        XCTAssertEqual(draft.valueToSave, "555")
        draft.typed = ""
        draft.removed = true
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.valueToSave, "")
    }
}
