import XCTest
@testable import Project_Planner

/// RULEBOOK 1.32.0 §26 on iOS through `CanonicalBusinessEngine` (`Rulebook+PayeClaims.swift`, web
/// `lib/canonical/payeClaimReviews.ts`): who reviews price work and expenses (`canReviewPayeClaims`), the item fingerprint
/// (`payeClaimFingerprint`), the review reader (`parsePayeClaimReviewDocument`), an item's state (`payeClaimReviewState`),
/// Approve's writes and message (`payeClaimReviewWrites`) and the per-item label (`payeClaimReviewOutcomeLabel`).
/// RULEBOOK 1.33.0 §26: a line manager can always review (no "Needs an admin", no `reviewerIsAdmin`); a review of an item
/// filed under another of the person's ids carries `personUserId`, and new items carry `personUserId` (= the creator).
/// Every answer comes from the packed script; these tests lock the Swift inputs and readings. `overtimePersonIds` is not
/// called here (the person's ids are passed as the screen would receive them).
@MainActor
final class Rulebook1320PayeClaimsTests: XCTestCase {
    private let org = "TEST-ORG-1320"

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 1320"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func row(
        _ id: String,
        role: String,
        isActive: Bool = true,
        manager: Bool = false,
        admin: Bool = false,
        operativeMode: Bool = false,
        lineManagers: [String] = [],
        formerIds: [String] = []
    ) -> [String: Any] {
        [
            "id": id,
            "email": "\(id)@test.example",
            "isActive": isActive,
            "role": role,
            "isSuperAdmin": false,
            "adminAccess": admin,
            "isAdmin": admin,
            "manager": manager,
            "operativeMode": operativeMode,
            "name": "\(id) Test",
            "passwordSet": true,
            "organizationId": org,
            "assignedManagerUserIds": lineManagers,
            "formerUserIds": formerIds,
            "sameEmailUserIds": [String](),
        ]
    }

    private var roster: [[String: Any]] {
        [
            row("TEST-sam", role: "operative", operativeMode: true, lineManagers: ["TEST-mia"], formerIds: ["TEST-sam-old"]),
            row("TEST-mia", role: "manager", manager: true),
            row("TEST-ada", role: "admin", admin: true),
            row("TEST-op2", role: "operative", operativeMode: true, lineManagers: ["TEST-mia"]),
            row("TEST-old", role: "manager", isActive: false, manager: true),
        ]
    }

    private func person(_ id: String) -> [String: Any] {
        roster.first { ($0["id"] as? String) == id } ?? [:]
    }

    private func expense(_ id: String, userId: String = "TEST-sam", amount: Double = 12.5) throws -> PayeClaimItem {
        try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: id,
            data: ["userId": userId, "title": "TEST-Fuel", "jobNumber": "J-1", "date": "2026-11-04", "amount": amount, "currency": "gbp"],
            organizationId: org
        ))
    }

    // MARK: Who reviews

    func testReviewersAreTheActiveLineManagerAndAdminsNeverThePerson() {
        let subject = person("TEST-sam")
        XCTAssertTrue(CanonicalBusinessEngine.canReviewPayeClaims(viewer: person("TEST-mia"), subject: subject, roster: roster), "line manager")
        XCTAssertTrue(CanonicalBusinessEngine.canReviewPayeClaims(viewer: person("TEST-ada"), subject: subject, roster: roster), "admin")
        XCTAssertFalse(CanonicalBusinessEngine.canReviewPayeClaims(viewer: subject, subject: subject, roster: roster), "never the person")
        XCTAssertFalse(CanonicalBusinessEngine.canReviewPayeClaims(viewer: person("TEST-op2"), subject: subject, roster: roster))
        XCTAssertFalse(CanonicalBusinessEngine.canReviewPayeClaims(viewer: person("TEST-old"), subject: subject, roster: roster), "inactive")
    }

    // MARK: Fingerprint, reader, state

    func testFingerprintReaderAndStateFollowTheItemsCurrentFingerprint() throws {
        let item = try expense("TEST-E1")
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimFingerprint(item), "expense|TEST-Fuel|J-1|2026-11-04|12.50|GBP|0")
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimReviewsCollection, "payeClaimReviews")

        let review = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReviewDocument(docId: "expense_TEST-E1", data: [
            "userId": "TEST-sam", "itemId": "TEST-E1", "kind": "expense", "decision": "approved",
            "fingerprint": CanonicalBusinessEngine.payeClaimFingerprint(item), "reviewedBy": "TEST-mia",
            "reviewedAt": ["seconds": 1_762_300_000, "nanoseconds": 0],
        ]))
        XCTAssertEqual(review.id, "expense_TEST-E1")
        XCTAssertEqual(review.decision, "approved")
        XCTAssertEqual(review.reviewedBy, "TEST-mia")
        XCTAssertEqual(review.reviewedAtMs ?? 0, 1_762_300_000_000, accuracy: 0.5)

        let approved = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReviewState(item, reviews: [review]))
        XCTAssertEqual(approved.state, "approved")
        XCTAssertEqual(approved.label, "Approved")
        XCTAssertEqual(approved.review?.id, review.id)

        let edited = try expense("TEST-E1", amount: 13)
        let again = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReviewState(edited, reviews: [review]))
        XCTAssertEqual(again.state, "needsReview", "an item changed after its review needs review again")
        XCTAssertEqual(again.label, "Needs review")
        XCTAssertNil(again.review)

        let unknown = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReviewDocument(docId: "expense_TEST-E9", data: ["decision": "maybe"]))
        XCTAssertEqual(unknown.decision, "rejected", "an unknown decision reads as rejected")
        XCTAssertNil(unknown.reviewedBy)
        XCTAssertNil(unknown.reviewedAtMs)
    }

    // MARK: Approve

    func testALineManagerReviewsEveryIdAndAnOlderIdReviewCarriesPersonUserId() throws {
        let ticked = try expense("TEST-E1")
        let olderId = try expense("TEST-E2", userId: "TEST-sam-old")
        let undecided = try expense("TEST-E3")
        let foreign = try expense("TEST-E4", userId: "TEST-op2")
        let plan = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReviewWrites(
            items: [ticked, olderId, undecided, foreign],
            decisions: ["TEST-E1": "approved", "TEST-E2": "rejected", "TEST-E4": "approved"],
            reviews: [],
            subjectUserId: "TEST-sam",
            personIds: ["TEST-sam", "TEST-sam-old"],
            reviewerId: "TEST-mia"
        ))
        XCTAssertEqual(plan.writes.map(\.docId), ["expense_TEST-E1", "expense_TEST-E2"], "the line manager reviews items under older ids too")
        let fields = try XCTUnwrap(plan.writes.first?.fields)
        XCTAssertEqual(fields["userId"] as? String, "TEST-sam")
        XCTAssertEqual(fields["itemId"] as? String, "TEST-E1")
        XCTAssertEqual(fields["kind"] as? String, "expense")
        XCTAssertEqual(fields["decision"] as? String, "approved")
        XCTAssertEqual(fields["fingerprint"] as? String, CanonicalBusinessEngine.payeClaimFingerprint(ticked))
        XCTAssertEqual(fields["reviewedBy"] as? String, "TEST-mia")
        XCTAssertEqual(Set(fields.keys), ["userId", "itemId", "kind", "decision", "fingerprint", "reviewedBy"],
                       "an item under the person's own id carries no personUserId; the app adds reviewedAt and metadata")
        let older = try XCTUnwrap(plan.writes.last?.fields)
        XCTAssertEqual(older["userId"] as? String, "TEST-sam-old", "the review names the id the item is filed under")
        XCTAssertEqual(older["personUserId"] as? String, "TEST-sam", "and the person's current users id, for the rules")
        XCTAssertEqual(plan.outcomes, ["TEST-E1": "applied", "TEST-E2": "applied", "TEST-E3": "undecided", "TEST-E4": "foreign"])
        XCTAssertFalse(plan.outcomes.values.contains("needsAdmin"))
        XCTAssertEqual(plan.approved, 1)
        XCTAssertEqual(plan.rejected, 1)
        XCTAssertEqual(plan.message, "Approved 1 of 3. 1 rejected; 1 not decided yet.")

        XCTAssertEqual(CanonicalBusinessEngine.payeClaimReviewOutcomeLabel(plan.outcomes["TEST-E4"]), "Not theirs — left out.")
        XCTAssertNil(CanonicalBusinessEngine.payeClaimReviewOutcomeLabel(plan.outcomes["TEST-E2"]))
        XCTAssertNil(CanonicalBusinessEngine.payeClaimReviewOutcomeLabel(plan.outcomes["TEST-E1"]))
        XCTAssertNil(CanonicalBusinessEngine.payeClaimReviewOutcomeLabel(nil))

        // The reader keeps personUserId (null when not stored).
        let review = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReviewDocument(docId: "expense_TEST-E2", data: older))
        XCTAssertEqual(review.personUserId, "TEST-sam")
        XCTAssertNil(ticked.personUserId, "an item stored before 1.33.0 has none")
    }

    func testNewItemsCarryTheCreatorAsPersonUserId() throws {
        let path = try XCTUnwrap(CanonicalBusinessEngine.payeClaimEvidencePath(organizationId: org, userId: "TEST-sam", unixMs: 1_762_250_000_000, fileExtension: "pdf"))
        let expense = try XCTUnwrap(CanonicalBusinessEngine.expenseWriteFields(
            userId: "TEST-sam",
            draft: [
                "title": "TEST-Fuel", "details": "", "jobNumber": "J-1", "date": "2026-11-04", "amount": "20",
                "evidence": [["path": path, "name": "a.pdf", "kind": "file", "contentType": "application/pdf", "auditId": NSNull()]],
            ],
            currency: "GBP",
            organizationId: org
        ))
        XCTAssertEqual(expense["personUserId"] as? String, "TEST-sam", "payeClaimPersonFields: the creator's own uid")
        XCTAssertEqual(expense["userId"] as? String, "TEST-sam")
        let stored = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(kind: .expense, docId: "TEST-E9", data: expense, organizationId: org))
        XCTAssertEqual(stored.personUserId, "TEST-sam")
    }

    func testAnUnchangedDecisionIsNotWrittenAgainAndNothingDecidedSavesNothing() throws {
        let item = try expense("TEST-E1")
        let review = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReviewDocument(docId: "expense_TEST-E1", data: [
            "userId": "TEST-sam", "itemId": "TEST-E1", "kind": "expense", "decision": "approved",
            "fingerprint": CanonicalBusinessEngine.payeClaimFingerprint(item), "reviewedBy": "TEST-mia",
        ]))
        let same = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReviewWrites(
            items: [item], decisions: ["TEST-E1": "approved"], reviews: [review],
            subjectUserId: "TEST-sam", personIds: ["TEST-sam"], reviewerId: "TEST-mia"
        ))
        XCTAssertTrue(same.writes.isEmpty)
        XCTAssertEqual(same.outcomes["TEST-E1"], "unchanged")

        let nothing = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReviewWrites(
            items: [], decisions: [:], reviews: [],
            subjectUserId: "TEST-sam", personIds: [], reviewerId: "TEST-mia"
        ))
        XCTAssertTrue(nothing.writes.isEmpty)
        XCTAssertEqual(nothing.message, "Nothing was approved.")
    }

    // MARK: Listener merge (plumbing for the per-id listeners)

    func testListenerMergeKeepsIdOrderDropsEmptyAndRepeatedIds() {
        let merge = PayeClaimListenerMerge<String>(ids: ["TEST-a", "", "TEST-b", "TEST-a"])
        XCTAssertEqual(merge.ids, ["TEST-a", "TEST-b"])
        merge.set("TEST-b", ["x", "y"])
        merge.set("TEST-a", ["z", "x"])
        XCTAssertEqual(merge.rows(), ["z", "x", "x", "y"])
        XCTAssertEqual(merge.rows(uniqueBy: { $0 }), ["z", "x", "y"])
        // 1.33.0: the `personUserId ==` query is one more key, merged after the ids.
        merge.add("personUserId:TEST-a")
        merge.add("personUserId:TEST-a")
        XCTAssertEqual(merge.ids, ["TEST-a", "TEST-b", "personUserId:TEST-a"])
        merge.set("personUserId:TEST-a", ["w", "y"])
        XCTAssertEqual(merge.rows(uniqueBy: { $0 }), ["z", "x", "y", "w"])
    }
}
