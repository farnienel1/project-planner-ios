import XCTest
@testable import Project_Planner

/// RULEBOOK 1.44.0 and 1.45.0 through `CanonicalBusinessEngine` (owner decisions 14 Nov). Expected values were checked
/// in node against the packed `canonical-business.js` (sha256 5b80d57d…9a51d441) and match web
/// `lib/canonical/canonical.test.ts`:
///   - 1.44.0: the Monday–Friday paid day is always derived; a weekend day with no stored "counts as" falls back to
///     `weekendCountsAsHours` (8h); a booking nobody resolves keeps its scheduling row (`scheduleRowPerson`); a person
///     with no level flag is a line-manager candidate (`levelOf`).
///   - 1.45.0: evidence survives a timesheet save; `timesheetOwnerEntriesError` refuses a new expense with no evidence
///     and passes an untouched older one with only a receipt name; a PAYE edit writes only the changed fields.
@MainActor
final class Rulebook1440And1450Tests: XCTestCase {
    private let org = "TEST-org"
    private let owner = "TEST-owner"

    // Readers drop evidence outside the open organisation (`parseTimesheetEntries` `organizationId`), so the open
    // organisation is this test's, never one another test left behind.
    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 145"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    func testThePackedScriptIs145AndExportsTheNewRules() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 45, 0]), "rulebook \(stamp.version) predates 1.45.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "scheduleRowPerson", "weekendCountsAsHours", "timesheetOwnerEntriesError", "canEditTimesheetEntry",
            "timesheetEntryEvidenceToDelete", "timesheetEvidencePages", "timesheetEntryEvidenceWriteFields",
            "timesheetEvidenceOwnerIds", "priceWorkUpdateWriteFields", "expenseUpdateWriteFields", "payeClaimEditDraft",
            "canEditPayeClaim", "claimEvidenceCountText", "claimEvidenceRemoved",
        ] {
            XCTAssertTrue(names.contains(name), "\(name) is exported")
        }
    }

    // MARK: 1.44.0

    func testTheWeekdayPaidDayIsAlwaysDerived() {
        // The owner example: 07:00–16:00, 30 min unpaid 12:00–12:30 → 8.5h, whatever an older save stored.
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = "07:00"
        policy.standardDayEnd = "16:00"
        policy.unpaidBreakMinutes = 30
        policy.breakPaid = false
        policy.breakWindowStart = "12:00"
        policy.breakWindowEnd = "12:30"
        policy.standardPaidHours = 9
        policy.paidHoursDerived = nil
        XCTAssertEqual(CanonicalBusinessEngine.weekdayPaidHours(policy), 8.5, accuracy: 0.0001)
    }

    func testAWeekendDayWithNoCountsAsFallsBackToEightHoursNotThePaidDay() {
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHoursFallback, 8, accuracy: 0.0001)
        let source = (try? String(contentsOfFile: Self.repoPath("Project Planner/Views/OrganisationWorkingHoursView.swift"), encoding: .utf8)) ?? ""
        XCTAssertFalse(source.contains("fallback: draft.standardPaidHours"), "no weekend fallback to the stored weekday figure")
    }

    func testAnUnresolvedBookingKeepsItsRowWithTheShortId() throws {
        let input = CanonicalBusinessEngine.CanonicalBookingPersonInput(accounts: [], operatives: [])
        let row = try XCTUnwrap(CanonicalBusinessEngine.scheduleRowPerson("6a9632ba-1111-2222-3333-444455556666", input))
        XCTAssertTrue(row.unresolved)
        XCTAssertEqual(row.label, "Unknown person · 6A9632BA")
        XCTAssertEqual(CanonicalBusinessEngine.unresolvedBookingPersonChip, "Not linked to a person")

        let stray = UUID()
        let rows = ScheduleWeekGrid.staffRows(operativeIds: [stray], userIds: [], operatives: [], users: [])
        XCTAssertEqual(rows.count, 1, "1.44.0: never hidden from the scheduling week")
        XCTAssertEqual(rows.first?.role, .unknown)
        XCTAssertTrue(rows.first?.name.hasPrefix("Unknown person · ") == true)
        XCTAssertNil(rows.first.flatMap { ScheduleWeekGrid.saveTarget(for: $0, jobType: .catA) }, "no Quick Add")
    }

    func testAFlaglessLegacyManagerIsALineManagerCandidateAndAnOperativeIsNot() throws {
        let flagless = AppUser(
            id: "TEST-flagless", email: "flagless@example.test", organizationId: org, role: .basic,
            firstName: "Flag", surname: "Less", permissions: UserPermissions()
        )
        let operative = AppUser(
            id: "TEST-op", email: "op@example.test", organizationId: org, role: .operative,
            firstName: "Op", surname: "Erative", permissions: UserPermissions(operativeMode: true)
        )
        XCTAssertTrue(UserStore.staffAccountRole(for: operative).isOperativeMode, "operatives carry isOperativeMode")
        let person = LineManagerRulebook.row(AppUser(
            id: "TEST-new", email: "new@example.test", organizationId: org, role: .operative,
            firstName: "New", surname: "Person", permissions: UserPermissions(operativeMode: true)
        ))
        let roster = LineManagerRulebook.roster([flagless, operative].map { user -> AppUser in
            var user = user
            user.isActive = true
            user.passwordSet = true
            return user
        })
        let candidates = try XCTUnwrap(CanonicalBusinessEngine.lineManagerCandidates(person: person, roster: roster))
        XCTAssertEqual(candidates.map(\.id), ["TEST-flagless"])
        XCTAssertEqual(candidates.first?.level, "manager")
    }

    // MARK: 1.45.0

    private func evidence(_ name: String = "receipt.jpg") -> PayeClaimEvidence {
        PayeClaimEvidence(
            path: "organizations/\(org)/payeClaims/\(owner)/\(owner)_1763100000000.jpg",
            name: name,
            kind: "photo",
            contentType: "image/jpeg",
            auditId: nil
        )
    }

    func testAnEntryWithEvidenceSurvivesASave() throws {
        var draft = TimesheetDraft()
        draft.expenseEntries = [TimesheetExpenseEntry(
            id: UUID(), title: "TEST-Fuel", details: "", jobNumber: "J-1", date: Date(timeIntervalSince1970: 1_763_100_000),
            amount: 42.5, receiptName: nil, evidence: [evidence()]
        )]
        draft.priceWorkEntries = [TimesheetPriceWorkEntry(
            id: UUID(), title: "TEST-Tiling", details: "", jobNumber: "J-2", agreedManagerName: "Sam",
            startDate: Date(timeIntervalSince1970: 1_763_100_000), endDate: nil, amount: 100
        )]
        var stored = TimesheetDraftStore.asFirestoreMap(draft)
        stored["userId"] = owner
        stored["__documentId"] = "timesheet_\(owner)_1763078400"
        let expenses = try XCTUnwrap(stored["expenseEntries"] as? [[String: Any]])
        XCTAssertEqual((expenses.first?["evidence"] as? [[String: Any]])?.first?["path"] as? String, evidence().path)
        let priceWork = try XCTUnwrap(stored["priceWorkEntries"] as? [[String: Any]])
        XCTAssertNil(priceWork.first?["evidence"], "no evidence key on an entry with none (older shape kept)")

        let read = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(stored))
        XCTAssertEqual(read.expenseEntries.first?.evidence.map(\.path), [evidence().path])
        XCTAssertEqual(read.priceWorkEntries.first?.evidence, [])
        // And back again: the second save writes the same evidence.
        let again = TimesheetDraftStore.asFirestoreMap(read)
        let againExpenses = try XCTUnwrap(again["expenseEntries"] as? [[String: Any]])
        XCTAssertEqual((againExpenses.first?["evidence"] as? [[String: Any]])?.count, 1)
        // Review #322: the stored row's fingerprint is kept on the model for the review rules and never written back.
        XCTAssertNotNil(read.expenseEntries.first?.reviewFingerprint)
        XCTAssertNil(againExpenses.first?["reviewFingerprint"])
        // 38a1be7: handed to the rules explicitly (`timesheetEntryFingerprintMap` → `entryFingerprints`).
        let fingerprints = TimesheetDraftStore.entryFingerprints(read)
        XCTAssertEqual(fingerprints.count, 2, "one per entry read from the sheet")
        XCTAssertTrue(fingerprints.values.contains { ($0 as? String) == read.expenseEntries.first?.reviewFingerprint })
    }

    func testANewExpenseNeedsEvidenceAndAnOlderReceiptOnlyEntryNeverBlocks() {
        let older: [String: Any] = [
            "id": "TEST-old", "title": "TEST-Old fuel", "details": "", "jobNumber": "", "date": 1_700_000_000_000.0,
            "amount": 10.0, "receiptName": "receipt.jpg",
        ]
        let fresh: [String: Any] = [
            "id": "TEST-new", "title": "TEST-New fuel", "details": "", "jobNumber": "", "date": 1_763_100_000_000.0,
            "amount": 12.0,
        ]
        var withEvidence = fresh
        withEvidence["evidence"] = CanonicalBusinessEngine.timesheetEntryEvidenceWriteFields([evidence()])
        XCTAssertNil(CanonicalBusinessEngine.timesheetOwnerEntriesError(
            previous: (priceWork: [], expenses: [older]), next: (priceWork: [], expenses: [older]),
            organizationId: org, ownerUserIds: [owner]
        ), "an untouched older entry with only a receipt name passes")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetOwnerEntriesError(
            previous: (priceWork: [], expenses: [older]), next: (priceWork: [], expenses: [older, fresh]),
            organizationId: org, ownerUserIds: [owner]
        ), CanonicalBusinessEngine.expenseEvidenceRequiredMessage)
        XCTAssertNil(CanonicalBusinessEngine.timesheetOwnerEntriesError(
            previous: (priceWork: [], expenses: [older]), next: (priceWork: [], expenses: [older, withEvidence]),
            organizationId: org, ownerUserIds: [owner]
        ))
    }

    func testAPayeEditWritesOnlyTheChangedFields() throws {
        let item = PayeClaimItem(
            id: "TEST-item", kind: "expense", userId: owner, title: "TEST-Fuel", details: "", amount: 20, currency: "GBP",
            evidence: [evidence()], createdAtMs: nil, createdBy: owner, jobNumber: "J-1", date: "2026-11-10"
        )
        var draft = try XCTUnwrap(CanonicalBusinessEngine.payeClaimEditDraft(item))
        draft["amount"] = 25
        let write = try XCTUnwrap(CanonicalBusinessEngine.expenseUpdateWriteFields(
            item: item, userId: owner, draft: draft, organizationId: org
        ))
        XCTAssertEqual(Set(write.set.keys), ["amount"])
        XCTAssertTrue(write.remove.isEmpty)
        XCTAssertNil(CanonicalBusinessEngine.expenseUpdateWriteFields(
            item: item, userId: "TEST-someone-else", draft: draft, organizationId: org
        ), "only the person edits their own item")
        XCTAssertTrue(CanonicalBusinessEngine.canEditPayeClaim(viewerId: owner, item: item))
        XCTAssertFalse(CanonicalBusinessEngine.canEditPayeClaim(viewerId: "TEST-someone-else", item: item))
    }

    func testWordingComesFromTheRulebook() {
        XCTAssertEqual(CanonicalBusinessEngine.claimAmountLabel(isExpense: true), "Amount inc VAT")
        XCTAssertEqual(CanonicalBusinessEngine.claimAmountLabel(isExpense: false), "Amount")
        XCTAssertEqual(CanonicalBusinessEngine.expensesReportColumns.last, "Amount inc VAT")
        XCTAssertEqual(CanonicalBusinessEngine.claimEvidenceCountText(1), "1 piece of evidence")
        XCTAssertEqual(CanonicalBusinessEngine.claimEvidenceCountText(3), "3 pieces of evidence")
        XCTAssertEqual(CanonicalBusinessEngine.claimEvidenceCountText(0), "")
    }

    // MARK: Review #232

    /// A draft cached before 1.45.0 has no `evidence` (or `reviewFingerprint`) on its entries; it must still decode,
    /// or the save loses its "only what this editor changed" baseline.
    func testADraftCachedBefore145StillDecodes() throws {
        let json = """
        {"expenseEntries":[{"id":"6A9632BA-1111-2222-3333-444455556666","title":"TEST-Fuel","details":"","jobNumber":"J-1",
          "date":0,"amount":12.5,"receiptName":"receipt.jpg","managerDecision":"approved","storedId":"TEST-old-expense"}],
         "priceWorkEntries":[{"id":"7B9632BA-1111-2222-3333-444455556666","title":"TEST-Tiling","details":"","jobNumber":"",
          "agreedManagerName":"Sam","startDate":0,"amount":100,"managerDecision":"approved"}],
         "payrollLineReviews":{},"managerNote":""}
        """
        let draft = try JSONDecoder().decode(TimesheetDraft.self, from: Data(json.utf8))
        XCTAssertEqual(draft.expenseEntries.first?.evidence, [])
        XCTAssertNil(draft.expenseEntries.first?.reviewFingerprint)
        XCTAssertEqual(draft.expenseEntries.first?.receiptName, "receipt.jpg")
        XCTAssertEqual(draft.expenseEntries.first?.storedId, "TEST-old-expense")
        XCTAssertEqual(draft.priceWorkEntries.first?.evidence, [])
        XCTAssertNil(draft.priceWorkEntries.first?.storedId)
        // And a 1.45.0 draft round-trips with its evidence.
        var current = draft
        current.expenseEntries[0].evidence = [evidence()]
        let again = try JSONDecoder().decode(TimesheetDraft.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(again.expenseEntries.first?.evidence.map(\.path), [evidence().path])
    }

    /// Evidence the stored sheet holds that the editor never saw (read before every id of the person was known) is
    /// kept on save; evidence the editor removed stays removed.
    func testASaveKeepsEvidenceTheEditorNeverSaw() {
        let seen = evidence("seen.jpg")
        let unseen = PayeClaimEvidence(
            path: "organizations/\(org)/payeClaims/TEST-old-invite/TEST-old-invite_1763100000001.jpg",
            name: "unseen.jpg", kind: "photo", contentType: "image/jpeg", auditId: nil
        )
        let removed = PayeClaimEvidence(
            path: "organizations/\(org)/payeClaims/\(owner)/\(owner)_1763100000002.jpg",
            name: "removed.jpg", kind: "photo", contentType: "image/jpeg", auditId: nil
        )
        let entryId = UUID()
        func entry(_ evidence: [PayeClaimEvidence]) -> TimesheetExpenseEntry {
            TimesheetExpenseEntry(
                id: entryId, title: "TEST-Fuel", details: "", jobNumber: "", date: Date(timeIntervalSince1970: 0),
                amount: 10, receiptName: nil, storedId: "TEST-entry", evidence: evidence
            )
        }
        var loaded = TimesheetDraft()
        loaded.expenseEntries = [entry([seen, removed])]
        var stored = TimesheetDraft()
        stored.expenseEntries = [entry([seen, unseen, removed])]
        var draft = TimesheetDraft()
        draft.expenseEntries = [entry([seen])]

        let saved = TimesheetDraftStore.keepingEvidenceUnseenByEditor(draft, stored: stored, loaded: loaded)
        XCTAssertEqual(saved.expenseEntries.first?.evidence.map(\.name), ["seen.jpg", "unseen.jpg"])
        // No sheet is saved before the roster (every id of the person) has loaded.
        let previous = RulebookRosterSnapshot.users
        RulebookRosterSnapshot.update([])
        XCTAssertFalse(RulebookRosterSnapshot.hasLoaded)
        RulebookRosterSnapshot.update(previous)
    }

    // MARK: Review #231 follow-ups

    func testAQueuedBookingsCheckKeepsRetryFailedWhileItWaits() {
        let key = PayInputsLoad.rerunKey(Date(timeIntervalSince1970: 1_234))
        _ = PayInputsLoad.takeQueuedRerun(key: key)
        XCTAssertTrue(PayInputsLoad.queueRerun(key: key, retryFailed: false), "the first request starts a wait")
        XCTAssertFalse(PayInputsLoad.queueRerun(key: key, retryFailed: true), "a second request joins the wait")
        XCTAssertTrue(PayInputsLoad.takeQueuedRerun(key: key), "a Retry made while waiting is kept")
        XCTAssertFalse(PayInputsLoad.takeQueuedRerun(key: key))
        XCTAssertEqual(PayInputsLoad.rerunWaitSeconds, 60)
    }

    // MARK: Helpers

    private static func repoPath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative).path
    }
}
