import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.32.0 on iOS through `CanonicalBusinessEngine` (`Rulebook+Release1320.swift`): the PAYE payday required
/// (`payePaydaySetupError`, `payePaydayMissing`, `payePaydayBanner`), the rules version in Settings
/// (`rulebookVersionLabel`), the export notice (`timesheetExportOwnSheetNotice`), the legal pack acceptance write
/// (`legalPackAcceptanceWriteFields`) and the invitation lookups (`invitationListConstraints`,
/// `invitationReadErrorIsSkippable`). Each answer must be the script's.
@MainActor
final class Rulebook1320SettingsTests: XCTestCase {
    private func text(_ name: String) throws -> String {
        try XCTUnwrap(CanonicalBusinessEngine.constant(name, as: String.self), "\(name) exported")
    }

    // MARK: PAYE payday required (§4.5)

    func testSetupRequiresAPayday() throws {
        XCTAssertEqual(CanonicalBusinessEngine.payePaydaySetupError(nil), try text("PAYE_PAYDAY_REQUIRED_MESSAGE"))
        XCTAssertNil(CanonicalBusinessEngine.payePaydaySetupError(15))
        XCTAssertEqual(CanonicalBusinessEngine.payePaydaySetupError(32), CanonicalBusinessEngine.payePaydayValidationError(32))
        XCTAssertNotNil(CanonicalBusinessEngine.payePaydaySetupError(32))
    }

    func testMissingAndBanner() throws {
        let none: [String: Any] = ["invoicing": [String: Any]()]
        let set: [String: Any] = ["invoicing": ["payePayday": 25, "payePaydayHistory": [["day": 25, "effectiveFrom": "2026-01-01"]]]]
        XCTAssertEqual(CanonicalBusinessEngine.payePaydayMissing(none), true)
        XCTAssertEqual(CanonicalBusinessEngine.payePaydayMissing(set), false)

        XCTAssertEqual(
            CanonicalBusinessEngine.payePaydayBanner(organization: none, loaded: true, viewerIsAdmin: true),
            try text("PAYE_PAYDAY_MISSING_BANNER")
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.payePaydayBanner(organization: none, loaded: true, viewerIsAdmin: false),
            try text("PAYE_PAYDAY_NOT_SET_MESSAGE")
        )
        XCTAssertNil(CanonicalBusinessEngine.payePaydayBanner(organization: none, loaded: false, viewerIsAdmin: true), "not before the organisation loaded")
        XCTAssertNil(CanonicalBusinessEngine.payePaydayBanner(organization: set, loaded: true, viewerIsAdmin: true))
    }

    /// The Settings and Payment runs banner reads the open organisation's stored `invoicing` PAYE fields.
    func testBannerReadsTheOrganisationDocument() throws {
        var organization = Organization(firestoreDocumentId: "TEST-ORG-1320", name: "TEST-Company 1320")
        XCTAssertNotNil(CanonicalBusinessEngine.payePaydayBanner(
            organization: OvertimeOrganizationDocument.document(organization), loaded: true, viewerIsAdmin: true
        ))
        organization.payePaydayJSON = #"{"payePayday":25,"payePaydayHistory":[{"day":25,"effectiveFrom":"2026-01-01"}]}"#
        XCTAssertNil(CanonicalBusinessEngine.payePaydayBanner(
            organization: OvertimeOrganizationDocument.document(organization), loaded: true, viewerIsAdmin: true
        ))
    }

    // MARK: Rules version (§15)

    func testRulesVersionLabel() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp()?.version)
        XCTAssertEqual(CanonicalBusinessEngine.rulebookVersionLabel(), "Rules \(stamp)")
        XCTAssertEqual(CanonicalBusinessEngine.rulebookVersionLabel("1.32.0"), "Rules 1.32.0")
        XCTAssertEqual(CanonicalBusinessEngine.rulebookVersionLabel("TEST-not-a-version"), "")
    }

    func testSettingsShowsTheRulesVersionToEveryone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/SettingsView.swift"), encoding: .utf8)
        let label = try XCTUnwrap(source.range(of: "CanonicalBusinessEngine.rulebookVersionLabel()"))
        let adminSection = try XCTUnwrap(source.range(of: "settingsHubSectionTitle(\"Support & legal\")"))
        XCTAssertGreaterThan(label.lowerBound, adminSection.lowerBound, "after the admin-only Company-wide section, beside the app version")
    }

    // MARK: Export notice (§8)

    func testOwnSheetExportNotice() throws {
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetExportOwnSheetNotice(ownSheetSigned: true, ownSheetExported: false),
            try text("TIMESHEET_EXPORT_OWN_SHEET_NOTICE")
        )
        XCTAssertNil(CanonicalBusinessEngine.timesheetExportOwnSheetNotice(ownSheetSigned: true, ownSheetExported: true))
        XCTAssertNil(CanonicalBusinessEngine.timesheetExportOwnSheetNotice(ownSheetSigned: false, ownSheetExported: false))
    }

    // MARK: Legal pack acceptance write

    func testLegalPackAcceptanceWriteFieldsCarryTheAppTimestamp() throws {
        let at = Timestamp(date: Date(timeIntervalSince1970: 1_793_000_000))
        let fields = try XCTUnwrap(CanonicalBusinessEngine.legalPackAcceptanceWriteFields(userId: "TEST-uid", version: "1.1", acceptedAt: at))
        XCTAssertEqual(fields["policyAccepted"] as? Bool, true)
        XCTAssertEqual(fields["legalPackVersion"] as? String, "1.1")
        XCTAssertEqual(fields["policyAcceptedAt"] as? Timestamp, at)
        XCTAssertEqual(fields["legalPackAcceptedAt"] as? Timestamp, at)
        XCTAssertEqual(fields["updatedBy"] as? String, "TEST-uid")
        XCTAssertEqual(fields["updatedFrom"] as? String, "ios")
        XCTAssertEqual(Set(fields.keys), ["policyAccepted", "policyAcceptedAt", "legalPackVersion", "legalPackAcceptedAt", "updatedBy", "updatedFrom"])
        XCTAssertNil(CanonicalBusinessEngine.legalPackAcceptanceWriteFields(userId: " ", version: "1.1", acceptedAt: at))
        XCTAssertNil(CanonicalBusinessEngine.legalPackAcceptanceWriteFields(userId: "TEST-uid", version: "", acceptedAt: at))
        XCTAssertNotNil(CustomerLegalPack.acceptanceWriteFields(userId: "TEST-uid", acceptedAt: at))
    }

    // MARK: Invitation lookups

    func testInvitationListConstraintsAskBothEmailForms() {
        let admin = CanonicalBusinessEngine.invitationListConstraints(
            organizationId: "TEST-ORG", email: " Invitee@Example.test ", actorManagesOperatives: false, senderIds: ["TEST-ADMIN"]
        )
        XCTAssertEqual(admin, [
            [InvitationQueryConstraint(field: "organizationId", value: "TEST-ORG"), InvitationQueryConstraint(field: "email", value: "Invitee@Example.test")],
            [InvitationQueryConstraint(field: "organizationId", value: "TEST-ORG"), InvitationQueryConstraint(field: "email", value: "invitee@example.test")],
        ])
        let opsManager = CanonicalBusinessEngine.invitationListConstraints(
            organizationId: "TEST-ORG", email: "invitee@example.test", actorManagesOperatives: true, senderIds: ["TEST-OPS", "Ops@Example.test"]
        )
        XCTAssertEqual(opsManager.map { $0.last?.value }, ["TEST-OPS", "Ops@Example.test", "ops@example.test"])
        XCTAssertTrue(opsManager.allSatisfy { $0.map(\.field) == ["organizationId", "email", "invitedBy"] })
        XCTAssertTrue(CanonicalBusinessEngine.invitationListConstraints(
            organizationId: "", email: "a@example.test", actorManagesOperatives: false, senderIds: []
        ).isEmpty)
    }

    func testInvitationReadErrorIsSkippableOnlyForPermissionDenied() {
        XCTAssertTrue(CanonicalBusinessEngine.invitationReadErrorIsSkippable(code: "permission-denied"))
        XCTAssertTrue(CanonicalBusinessEngine.invitationReadErrorIsSkippable(code: "firestore/permission-denied"))
        XCTAssertFalse(CanonicalBusinessEngine.invitationReadErrorIsSkippable(code: "unavailable"))
        XCTAssertFalse(CanonicalBusinessEngine.invitationReadErrorIsSkippable(code: nil))
        XCTAssertEqual(FirestoreErrorCodeName.of(NSError(domain: "FIRFirestoreErrorDomain", code: 7)), "permission-denied")
        XCTAssertNil(FirestoreErrorCodeName.of(NSError(domain: NSURLErrorDomain, code: 7)))
    }
}
