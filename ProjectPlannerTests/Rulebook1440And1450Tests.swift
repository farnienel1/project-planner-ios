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
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertEqual(fingerprints.values.first as? String, read.expenseEntries.first?.reviewFingerprint)
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
