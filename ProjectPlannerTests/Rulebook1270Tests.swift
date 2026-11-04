import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.27.0 (owner decisions of 4 Nov) on iOS through `CanonicalBusinessEngine`: the invite draft as the line
/// manager subject, removed variation evidence, the 30-day retention sentence, and catalogue operatives' pay while
/// `privatePay` is on. Expected values were checked in node against the packed `canonical-business.js`
/// (rulebook 1.27.0, sha256 af3a192f…0d94a7c).
@MainActor
final class Rulebook1270Tests: XCTestCase {
    override func tearDown() {
        SecuritySwitchContext.reset()
        super.tearDown()
    }

    func testThePackedScriptIsRulebook1270OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 27, 0]), "rulebook \(stamp.version) predates 1.27.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "inviteDraftLineManagerSubject", "catalogueOperativePaySubjects", "variationEvidenceRemovalWriteFields",
            "canViewRemovedEvidence", "removedEvidenceHeading",
        ] {
            XCTAssertTrue(exports.contains(name), "\(name) is not exported")
        }
    }

    // MARK: (1) Add User — the invite draft

    func testTheInviteDraftIsTheSharedSubject() {
        XCTAssertEqual(CanonicalBusinessEngine.inviteDraftPersonId, "invite-draft")
        XCTAssertEqual(
            CanonicalBusinessEngine.inviteDraftLineManagerEmail(email: "  New.Person@Example.com ", level: "operative"),
            "new.person@example.com"
        )
    }

    func testTheInviteeIsNeverTheirOwnLineManager() {
        let boss = AppUser(id: "MGR-1", email: "boss@example.com", organizationId: "ORG-1", role: .manager,
                           firstName: "Bea", surname: "Boss", passwordSet: true, permissions: UserPermissions(manager: true))
        let selfRow = AppUser(id: "SELF-ROW", email: "new.person@example.com", organizationId: "ORG-1", role: .manager,
                              firstName: "Nia", surname: "New", passwordSet: true, permissions: UserPermissions(manager: true))
        let draft = AppUser(
            id: CanonicalBusinessEngine.inviteDraftPersonId,
            email: CanonicalBusinessEngine.inviteDraftLineManagerEmail(email: " New.Person@Example.com", level: "operative"),
            organizationId: "ORG-1",
            role: .operative
        )
        let ids = LineManagerRulebook.candidates(for: draft, roster: [boss, selfRow]).map(\.id)
        XCTAssertTrue(ids.contains("MGR-1"))
        XCTAssertFalse(ids.contains("SELF-ROW"), "the invitee's own row on the typed email is never offered")
    }

    // MARK: (4) Removed variation evidence

    func testRemovingEvidenceRecordsItFromTheStoredDocument() throws {
        let stored: [String: Any] = [
            "id": "v1",
            "evidence": [
                ["id": "e1", "fileName": "before.jpg", "storagePath": "p/1.jpg", "downloadURL": "https://x/1"],
                ["id": "e2", "fileName": "after.jpg", "storagePath": "p/2.jpg", "downloadURL": "https://x/2"],
            ],
            "evidenceCount": 2,
            "removedEvidence": [["path": "old.pdf", "name": "old.pdf", "removedBy": "u0", "removedAt": Timestamp(seconds: 5, nanoseconds: 0)]],
        ]
        let removedAt = Timestamp(seconds: 1_762_250_000, nanoseconds: 0)
        let answer = CanonicalBusinessEngine.variationEvidenceRemovalWriteFields(
            stored: stored, evidenceId: "e1", removedBy: "A-1", removedAt: removedAt, variationId: "v1"
        )
        let write = try XCTUnwrap(try XCTUnwrap(answer, "the script answered"))
        XCTAssertEqual(Set(write.keys), ["evidence", "evidenceCount", "removedEvidence"], "nothing else is rewritten")
        XCTAssertEqual((write["evidence"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["e2"])
        XCTAssertEqual((write["evidenceCount"] as? NSNumber)?.intValue, 1)
        let removed = try XCTUnwrap(write["removedEvidence"] as? [[String: Any]])
        XCTAssertEqual(removed.count, 2, "the stored list is kept and the new entry appended")
        XCTAssertEqual(removed[0]["removedAt"] as? Timestamp, Timestamp(seconds: 5, nanoseconds: 0))
        XCTAssertEqual(removed[1]["path"] as? String, "p/1.jpg")
        XCTAssertEqual(removed[1]["name"] as? String, "before.jpg")
        XCTAssertEqual(removed[1]["removedBy"] as? String, "A-1")
        XCTAssertEqual(removed[1]["removedAt"] as? Timestamp, removedAt)

        let missing = CanonicalBusinessEngine.variationEvidenceRemovalWriteFields(
            stored: stored, evidenceId: "nope", removedBy: "A-1", removedAt: removedAt, variationId: "v1"
        )
        XCTAssertNotNil(missing, "the script answered")
        XCTAssertNil(missing ?? nil, "evidence not on the variation: nothing to write")
    }

    func testTheReaderReturnsRemovedEvidenceAndASaveNeverWritesIt() throws {
        let data: [String: Any] = [
            "heading": "Extra socket",
            "removedEvidence": [["path": "old.pdf", "name": "old.pdf", "removedBy": "u0", "removedAt": Timestamp(seconds: 5, nanoseconds: 0)]],
        ]
        let variation = try XCTUnwrap(VariationCodec.variation(from: data, documentId: "v1"))
        XCTAssertEqual(variation.removedEvidence, [
            VariationRemovedEvidence(path: "old.pdf", name: "old.pdf", removedBy: "u0", removedAt: Date(timeIntervalSince1970: 5)),
        ])
        XCTAssertNil(VariationCodec.firestoreMap(from: variation)["removedEvidence"], "only the removal write touches the list")
    }

    func testOnlyAdminsOutsideOperativeModeSeeRemovedEvidence() {
        typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole
        XCTAssertTrue(CanonicalBusinessEngine.canViewRemovedEvidence(role: Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false)))
        XCTAssertTrue(CanonicalBusinessEngine.canViewRemovedEvidence(role: Role(isSuperAdmin: true, isAdmin: false, isManager: false, isOperativeMode: false)))
        XCTAssertFalse(CanonicalBusinessEngine.canViewRemovedEvidence(role: Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: true)))
        XCTAssertFalse(CanonicalBusinessEngine.canViewRemovedEvidence(role: Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false)))
        XCTAssertEqual(CanonicalBusinessEngine.removedEvidenceHeading(2), "Removed evidence (2)")
    }

    // MARK: (5) Retention

    func testThePrivacyPolicyAndDPACarryTheSharedRetentionSentence() throws {
        let notice = CanonicalBusinessEngine.deletedDataRetentionNotice
        XCTAssertEqual(
            notice,
            "A deleted company can be restored for 30 days, after which its data is erased. Deleted files, including the files of an erased company, are kept for up to 30 days so they can be recovered, then permanently removed."
        )
        XCTAssertEqual(CanonicalBusinessEngine.deletionRestoreDays, 30)
        XCTAssertEqual(CanonicalBusinessEngine.fileRecoveryRetentionDays, 30)
        for id in [CustomerLegalPack.DocumentID.privacy, .dpa] {
            let document = try XCTUnwrap(CustomerLegalPack.documents.first { $0.id == id })
            XCTAssertTrue(document.body.contains(notice), "\(id.rawValue) carries the sentence word for word")
        }
        XCTAssertEqual(CustomerLegalPack.version, "1.1", "the pack version stays 1.1 (web keeps 1.1)")
    }

    // MARK: (7) Catalogue operatives' pay

    private let roster: [[String: Any]] = [
        ["id": "A-1", "email": "a@x.com", "isActive": true, "role": "admin", "adminAccess": true, "permissions": ["adminAccess": true]],
        ["id": "M-1", "email": "m@x.com", "isActive": true, "role": "manager", "manager": true, "operatives": true, "permissions": ["manager": true, "operatives": true]],
        ["id": "M-2", "email": "m2@x.com", "isActive": true, "role": "manager", "manager": true, "permissions": ["manager": true]],
        ["id": "OP-1", "email": "op@x.com", "isActive": true, "role": "operative", "operativeMode": true, "permissions": ["operativeMode": true]],
    ]

    private var operativesRows: [[String: Any]] {
        [
            ["id": "ROW-1", "email": "cat@x.com", "linkedUserId": NSNull(), "isActive": true],
            ["id": "ROW-2", "email": "op@x.com", "linkedUserId": NSNull(), "isActive": true],
            ["id": "ROW-3", "email": "z@x.com", "linkedUserId": "U-9", "isActive": true],
            ["id": "OP-1", "email": "", "linkedUserId": NSNull(), "isActive": true],
        ]
    }

    func testOnlyRowsWithNoAccountAreCatalogueOperatives() {
        let catalogue = CanonicalBusinessEngine.catalogueOperativePaySubjects(operatives: operativesRows, roster: roster)
        XCTAssertEqual(catalogue.compactMap { $0["id"] as? String }, ["ROW-1"], "a roster email, a linkedUserId or a roster id is an account")
        XCTAssertEqual(catalogue.first?["catalogueOperative"] as? Bool, true)

        var linked = LogicFixtures.operative(id: UUID(), email: "z@x.com")
        linked.firestoreDocumentId = "ROW-3"
        linked.linkedUserId = "U-9"
        XCTAssertEqual(linked.catalogueOperativeRow["linkedUserId"] as? String, "U-9")
        XCTAssertEqual(linked.catalogueOperativeRow["id"] as? String, "ROW-3")
    }

    func testSwitchOnAnOperativesManagerPlansTheCatalogueRow() {
        let catalogue = CanonicalBusinessEngine.catalogueOperativePaySubjects(operatives: operativesRows, roster: roster)
        let subjects = roster + catalogue
        let manager = roster[1]
        XCTAssertEqual(
            CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: manager, subjects: subjects, roster: roster, privatePay: true),
            .people(["M-1", "OP-1"], operativeIds: ["ROW-1"])
        )
        XCTAssertEqual(CanonicalBusinessEngine.payProfileReadPlan(viewer: manager, subjects: subjects, roster: roster), .documents(["M-1", "OP-1", "ROW-1"]))
        // A manager without the Operatives toggle gets neither.
        let other = roster[2]
        XCTAssertEqual(
            CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: other, subjects: subjects, roster: roster, privatePay: true),
            .people(["M-2"], operativeIds: [])
        )
        XCTAssertEqual(CanonicalBusinessEngine.payProfileReadPlan(viewer: other, subjects: subjects, roster: roster), .documents(["M-2"]))
        // Admins read everything.
        XCTAssertEqual(CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: roster[0], subjects: subjects, roster: roster, privatePay: true), .all)
    }

    func testSwitchOffNothingChanges() async {
        SecuritySwitchContext.reset()
        XCTAssertFalse(SecuritySwitchContext.privatePay)
        let catalogue = CanonicalBusinessEngine.catalogueOperativePaySubjects(operatives: operativesRows, roster: roster)
        XCTAssertEqual(
            CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: roster[1], subjects: roster + catalogue, roster: roster, privatePay: false),
            .all,
            "switch off: the whole collection as before"
        )
        XCTAssertEqual(FirebaseBackend().rateHistoryPlan, .all)
        var row = LogicFixtures.operative(id: UUID(), email: "cat@x.com", dayRate: 120)
        row.firestoreDocumentId = "ROW-1"
        let shown = await FirebaseBackend().overlayCatalogueOperativePayIfPrivate([row], roster: [])
        XCTAssertEqual(shown.first?.dayRate, 120, "switch off: no payProfiles read, the row as stored")
    }

    func testSwitchOnTheCatalogueProfileIsLaidOverTheRow() {
        var row = LogicFixtures.operative(id: UUID(), email: "cat@x.com", dayRate: 120)
        row.firestoreDocumentId = "ROW-1"
        let shown = row.payShown(with: ["dayRate": 150, "payBasis": "day", "operativeId": "ROW-1"], privatePay: true)
        XCTAssertEqual(shown.dayRate, 150)
        XCTAssertEqual(shown.payBasis, "day")
    }
}
