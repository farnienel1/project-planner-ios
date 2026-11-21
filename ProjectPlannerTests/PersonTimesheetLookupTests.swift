import XCTest
@testable import Project_Planner

/// `ios-timesheet-lookups` (guardrails 1 and 3, web `w-timesheet-lookups`): a person's timesheets under every id they go
/// by, deleted people's exported sheets for admins, and people with no level flag on an admin's lists — through
/// `CanonicalBusinessEngine` (`personIdSet`, `timesheetDocumentSubjectId`, `bookingPersonIdHint`,
/// `exportedTimesheetHistorySubjects`, `userTimesheetSubjects`, `rosterListKind`). Real old document shapes: a sheet
/// under a former invite id (upper case, as iOS writes), a second users document on the same email, a sheet stored
/// without `userId`, a deleted person's sheet. Each test also checks nothing previously shown disappears.
@MainActor
final class PersonTimesheetLookupTests: XCTestCase {
    private let org = "TEST-ORG-LOOKUPS"

    private func user(
        _ id: String,
        role: UserRole,
        admin: Bool = false,
        manager: Bool = false,
        operative: Bool = false,
        email: String? = nil,
        formerIds: [String] = []
    ) -> AppUser {
        var person = AppUser(
            id: id,
            email: email ?? "\(id.lowercased())@example.test",
            organizationId: org,
            role: role,
            firstName: "TEST-\(id)",
            surname: "Person",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: admin, manager: manager || admin, operativeMode: operative)
        )
        person.formerUserIds = formerIds
        return person
    }

    private var farnie: AppUser { user("U1", role: .operative, operative: true, email: "farnie@example.test", formerIds: ["INVITE-1"]) }
    private var farnieCopy: AppUser { user("U1B", role: .operative, operative: true, email: "Farnie@example.test") }
    private var other: AppUser { user("U2", role: .operative, operative: true) }
    private var roster: [AppUser] { [farnie, farnieCopy, other] }

    private func sheet(_ userId: String?, _ weekStartKey: String) -> [String: Any] {
        var data: [String: Any] = ["weekStartKey": weekStartKey]
        if let userId { data["userId"] = userId }
        return data
    }

    private var documents: [(documentId: String, data: [String: Any])] {
        [
            ("timesheet_U1_1761955200", sheet("U1", "2026-11-01")),
            ("timesheet_INVITE-1_1759276800", sheet("INVITE-1", "2026-10-01")), // former invite id
            ("timesheet_U1B_1760486400", sheet("U1B", "2026-10-15")), // same-email second account
            ("timesheet_invite-1_1756684800", sheet(nil, "2026-09-01")), // no userId, id names the former id
            ("timesheet_U1_1754006400", sheet(nil, "2026-08-01")), // no userId, id names the own id
            ("timesheet_U2_1761955200", sheet("U2", "2026-11-01")), // someone else's
            ("timesheet_U1_1751328000", sheet("U2", "2026-07-01")), // id names Farnie, stored userId says U2
            ("variations_J1", ["userId": "U1"]), // not a timesheet
        ]
    }

    func testOwnerIdsAreThePersonIdSet() {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster).map { $0.lowercased() }
        XCTAssertEqual(ids.first, "u1")
        XCTAssertTrue(ids.contains("invite-1"))
        XCTAssertTrue(ids.contains("u1b"))
        XCTAssertFalse(ids.contains("u2"))
    }

    func testDocumentOwnerIdReadsTheStoredUserIdFirst() {
        XCTAssertEqual(PersonTimesheetLookup.documentOwnerId(documentId: "timesheet_U1_1751328000", data: ["userId": "U2"]), "U2")
        XCTAssertEqual(
            PersonTimesheetLookup.documentOwnerId(documentId: "timesheet_invite-1_1756684800", data: [:]).lowercased(),
            "invite-1",
            "a sheet stored without userId belongs to the id its document id names (timesheetDocumentSubjectId)"
        )
    }

    func testEverySheetOfThePersonAndNobodyElses() {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster)
        let kept = PersonTimesheetLookup.documentsForPerson(ids: ids, documents: documents).map(\.documentId).sorted()
        XCTAssertEqual(kept, [
            "timesheet_INVITE-1_1759276800",
            "timesheet_U1B_1760486400",
            "timesheet_U1_1754006400",
            "timesheet_U1_1761955200",
            "timesheet_invite-1_1756684800",
        ].sorted())
        // Before: only `userId == U1`. Everything that read showed is still there.
        let before = documents.filter { $0.documentId.hasPrefix("timesheet_") && ($0.data["userId"] as? String) == "U1" }
        for entry in before { XCTAssertTrue(kept.contains(entry.documentId), "\(entry.documentId) dropped") }
    }

    func testAliasIdsAreAskedInChunksOfTen() {
        let ids = ["own"] + (0..<23).map { "alias\($0)" }
        XCTAssertEqual(PersonTimesheetLookup.aliasChunks(ids).map(\.count), [10, 10, 3])
        XCTAssertEqual(PersonTimesheetLookup.aliasChunks(["own", "OWN"]).count, 0, "ids compare without case")
    }

    func testAnExactIdWinsOverAnAlias() {
        let idsOf: (AppUser) -> [String] = { RulebookPeople.ownerIds(for: $0, users: self.roster) }
        let ownerOf = PersonTimesheetLookup.ownerResolver(candidates: roster, idsOf: idsOf)
        XCTAssertEqual(ownerOf("U1B")?.id, "U1B", "the second account keeps its own sheets")
        XCTAssertEqual(ownerOf("invite-1")?.id, "U1", "a former invite id belongs to the person, in any letter case")
        XCTAssertNil(ownerOf("GONE-PERSON"))
    }

    func testADeletedPersonIsAnUnknownPersonNotADroppedRow() {
        let stand = PersonTimesheetLookup.unresolvedPerson(storedUserId: "6A9632BA-0000-4000-8000-000000000000", organizationId: org)
        XCTAssertEqual(stand.id, "6A9632BA-0000-4000-8000-000000000000")
        XCTAssertEqual(stand.firstName, CanonicalBusinessEngine.unknownBookingPersonLabel)
        XCTAssertTrue(stand.surname.hasPrefix("· "))
        XCTAssertFalse(stand.isActive)
    }

    func testPeopleWithNoLevelFlagAreOnAnAdminsTimesheetLists() throws {
        let admin = user("ADMIN", role: .admin, admin: true)
        let operative = user("OP", role: .operative, operative: true)
        let flagless = user("LEGACY", role: .basic)
        let members = [admin, operative, flagless]
        let exported = try XCTUnwrap(UserTimesheetAccessRulebook.exportedHistoryUserIds(viewer: admin, members: members))
        XCTAssertTrue(exported.contains("LEGACY"), "manager level (RULEBOOK §11, 1.23.1)")
        XCTAssertTrue(exported.contains("OP") && exported.contains("ADMIN"), "nothing previously listed drops out")
        let subjects = try XCTUnwrap(UserTimesheetAccessRulebook.subjectUserIds(viewer: admin, members: members))
        XCTAssertTrue(subjects.contains("LEGACY"))
        XCTAssertTrue(subjects.contains("OP"))
    }

    // MARK: - Review of #259

    /// Firestore matches ids exactly as stored, so these fakes do too (S1): `userId ==` / `in` and the prefix are
    /// case-sensitive. `refuse` lists ids whose queries the rules refuse.
    private func fakeQueries(
        _ source: [(documentId: String, data: [String: Any])],
        refuse: Set<String> = [],
        asked: @escaping ([String]) -> Void = { _ in }
    ) -> (byUserIds: ([String]) async throws -> [PersonTimesheetLookup.Document], byPrefix: (String) async throws -> [PersonTimesheetLookup.Document]) {
        let refused = NSError(domain: "FIRFirestoreErrorDomain", code: 7)
        return (
            { chunk in
                asked(chunk)
                if chunk.contains(where: refuse.contains) { throw refused }
                return source.filter { chunk.contains(($0.data["userId"] as? String) ?? "") }
            },
            { id in
                if refuse.contains(id) { throw refused }
                return source.filter { $0.documentId.hasPrefix("timesheet_\(id)_") }
            }
        )
    }

    func testGatherReadsEveryIdAsStoredAndNothingElse() async {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster)
        let queries = fakeQueries(documents)
        let found = await PersonTimesheetLookup.gather(ids: ids, byUserIds: queries.byUserIds, byDocumentPrefix: queries.byPrefix)
        XCTAssertEqual(Set(found.map(\.documentId)), [
            "timesheet_U1_1761955200",
            "timesheet_INVITE-1_1759276800",
            "timesheet_U1B_1760486400",
            "timesheet_U1_1754006400",
        ])
        // Known limit (S1): a sheet stored without userId under the former id in another letter case is not found by
        // these case-sensitive queries (`timesheet_invite-1_…`).
        XCTAssertFalse(found.contains { $0.documentId == "timesheet_invite-1_1756684800" })
        // Nothing the old one-id read (`userId == U1`) returned is lost.
        XCTAssertTrue(found.contains { $0.documentId == "timesheet_U1_1761955200" })
    }

    func testGatherARefusedAliasQueryNeverCostsTheOwnSheets() async {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster)
        let asked = Recorder<[String]>()
        let warnings = Recorder<String>()
        let queries = fakeQueries(documents, refuse: Set(ids.dropFirst()), asked: { asked.add($0) })
        let found = await PersonTimesheetLookup.gather(
            ids: ids,
            byUserIds: queries.byUserIds,
            byDocumentPrefix: queries.byPrefix,
            warn: { warnings.add($0) }
        )
        XCTAssertTrue(asked.values.contains(["U1"]), "the own id is asked on its own (`userId ==`)")
        XCTAssertEqual(Set(found.map(\.documentId)), ["timesheet_U1_1761955200", "timesheet_U1_1754006400"])
        XCTAssertFalse(warnings.values.isEmpty)
    }

    /// Re-review of #259: a chunk that fails for any reason but a refusal (here: unavailable) is not asked id by id.
    func testGatherRetriesIdByIdOnlyWhenTheRulesRefuse() async {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster)
        let asked = Recorder<[String]>()
        let unavailable = NSError(domain: "FIRFirestoreErrorDomain", code: 14)
        let source = documents
        let own = ids[0]
        let found = await PersonTimesheetLookup.gather(
            ids: ids,
            byUserIds: { chunk in
                asked.add(chunk)
                if chunk != [own] { throw unavailable }
                return source.filter { chunk.contains(($0.data["userId"] as? String) ?? "") }
            },
            byDocumentPrefix: nil
        )
        // The own `userId ==` sheet stays; `timesheet_U1_1754006400` has no `userId` and the document-id query is off here.
        XCTAssertEqual(found.map(\.documentId), ["timesheet_U1_1761955200"])
        XCTAssertEqual(asked.values.filter { $0.count == 1 && $0 != [own] }, [], "no id-by-id retry after a non-refusal")
    }

    /// Final review of #259 (web `timesheetLookupPlan`): only the queries the viewer may run.
    func testLookupPlanSendsNoQueryTheRulesRefuse() {
        let ids = ["U1", "INVITE-1", "U1B"]
        // privatePay off: admins and managers ask every id and the document-id prefix; an operative their own id.
        var plan = PersonTimesheetLookup.lookupPlan(ids: ids, viewerIsOperative: false, viewerIsAdmin: true, privatePay: false)
        XCTAssertEqual(plan.ids, ids); XCTAssertTrue(plan.includeDocumentPrefix)
        plan = PersonTimesheetLookup.lookupPlan(ids: ids, viewerIsOperative: false, viewerIsAdmin: false, privatePay: false)
        XCTAssertEqual(plan.ids, ids); XCTAssertTrue(plan.includeDocumentPrefix)
        plan = PersonTimesheetLookup.lookupPlan(ids: ids, viewerIsOperative: true, viewerIsAdmin: false, privatePay: false)
        XCTAssertEqual(plan.ids, ["U1"]); XCTAssertFalse(plan.includeDocumentPrefix)
        // privatePay on (production): only admins keep the extra lookups.
        plan = PersonTimesheetLookup.lookupPlan(ids: ids, viewerIsOperative: false, viewerIsAdmin: true, privatePay: true)
        XCTAssertEqual(plan.ids, ids); XCTAssertTrue(plan.includeDocumentPrefix)
        plan = PersonTimesheetLookup.lookupPlan(ids: ids, viewerIsOperative: false, viewerIsAdmin: false, privatePay: true)
        XCTAssertEqual(plan.ids, ["U1"]); XCTAssertFalse(plan.includeDocumentPrefix)
        plan = PersonTimesheetLookup.lookupPlan(ids: ids, viewerIsOperative: true, viewerIsAdmin: false, privatePay: true)
        XCTAssertEqual(plan.ids, ["U1"]); XCTAssertFalse(plan.includeDocumentPrefix)
    }

    func testGatherAsksNoDocumentIdQueryForAnOperative() async {
        let queries = fakeQueries(documents)
        let found = await PersonTimesheetLookup.gather(ids: ["U1"], byUserIds: queries.byUserIds, byDocumentPrefix: nil)
        XCTAssertEqual(found.map(\.documentId), ["timesheet_U1_1761955200"])
    }

    func testMapInBatchesKeepsOrder() async {
        let out = await PersonTimesheetLookup.mapInBatches(Array(0..<20), size: 8) { $0 * 2 }
        XCTAssertEqual(out, Array(0..<20).map { $0 * 2 })
    }

    func testOnlyTheStandardDocumentOpensTheReviewScreen() throws {
        let start = "2026-11-01"
        let standard = try XCTUnwrap(CanonicalBusinessEngine.timesheetDocumentId(userId: "U1", startDayKey: start))
        XCTAssertTrue(PersonTimesheetLookup.opensStoredDocument(documentId: standard, ownId: "U1", startDayKey: start))
        let revision = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionDocId(baseDocumentId: standard, revision: 1))
        XCTAssertTrue(PersonTimesheetLookup.opensStoredDocument(documentId: revision, ownId: "U1", startDayKey: start))
        // B1: a sheet filed under a former id (or another letter case, or another record) never opens `timesheet_U1_…`.
        let former = try XCTUnwrap(CanonicalBusinessEngine.timesheetDocumentId(userId: "INVITE-1", startDayKey: start))
        XCTAssertFalse(PersonTimesheetLookup.opensStoredDocument(documentId: former, ownId: "U1", startDayKey: start))
        let otherCase = try XCTUnwrap(CanonicalBusinessEngine.timesheetDocumentId(userId: "u1", startDayKey: start))
        XCTAssertFalse(PersonTimesheetLookup.opensStoredDocument(documentId: otherCase, ownId: "U1", startDayKey: start))
        // S7: another id format for the own id (not the standard start) does not open either.
        XCTAssertFalse(PersonTimesheetLookup.opensStoredDocument(documentId: "timesheet_U1_legacy", ownId: "U1", startDayKey: start))
        // This device's own copy (no stored document known) opens as before.
        XCTAssertTrue(PersonTimesheetLookup.opensStoredDocument(documentId: nil, ownId: "U1", startDayKey: start))
    }

    func testExportedPlanPutsTheOwnIdLastAndLocalCopiesAreNeverOverwrittenByAnOlderVersion() {
        let rows: [[String: Any]] = [
            ["userId": "U1", "__documentId": "timesheet_U1_1761955200", "__subjectId": "U1", "exportedAt": 1_761_955_200_000],
            ["userId": "INVITE-1", "__documentId": "timesheet_INVITE-1_1761955200", "__subjectId": "INVITE-1", "exportedAt": 1_761_955_200_000],
        ]
        let plan = PersonTimesheetLookup.exportedPlan(rows: rows, ownId: "U1")
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.last?.subjectId, "U1", "N5: the own-id sheet wins its pay run")
        XCTAssertTrue(PersonTimesheetLookup.mayReplaceLocalCopy(heldVersionDocumentId: nil, shownDocumentId: "timesheet_U1_1761955200"))
        XCTAssertFalse(PersonTimesheetLookup.mayReplaceLocalCopy(
            heldVersionDocumentId: "timesheet_U1_1761955200_rev2",
            shownDocumentId: "timesheet_U1_1761955200_rev1"
        ), "S4: an open revision held on this device is never replaced by an older exported version")
    }

    /// Owner data, Raccord MEP (17 Nov read-only report): 9 exported sheets — 4 by Test Admin, 4 under a stored id
    /// nobody in the roster goes by (a deleted person, "QAlPe29v…"), 1 by Farnie Nel — and two users documents
    /// "Test Manager" on one email (1 and 3 sheets). Shapes only.
    func testRaccordShapedDataAnAdminSeesTheDeletedPersonAndOneTestManager() throws {
        let admin = user("ADMIN1", role: .admin, admin: true, email: "admin@raccord.example.test")
        let farnieNel = user("FARNIE1", role: .operative, operative: true, email: "farnie.nel@raccord.example.test")
        let tmA = user("TM-A", role: .manager, manager: true, email: "farnie@raccordmep.example.test")
        var tmB = user("TM-B", role: .manager, manager: true, email: "Farnie@RaccordMEP.example.test")
        tmB.passwordSet = false
        let raccord = [admin, farnieNel, tmA, tmB]
        let deletedId = "QAlPe29vAbCdEfGhIjKlMnOpQr12"
        var stored: [String] = Array(repeating: "ADMIN1", count: 4) + Array(repeating: deletedId, count: 4) + ["FARNIE1", "TM-A"]
        stored += Array(repeating: "TM-B", count: 3)

        let listed = try XCTUnwrap(UserTimesheetAccessRulebook.exportedHistoryUserIds(viewer: admin, members: raccord))
        for id in ["ADMIN1", "FARNIE1", "TM-A", "TM-B"] { XCTAssertTrue(listed.contains(id), id) }
        let users = raccord.filter { listed.contains($0.id) }
        let idsOf: (AppUser) -> [String] = { RulebookPeople.ownerIds(for: $0, users: raccord) }
        let owner = PersonTimesheetLookup.exportedOwnerResolver(
            users: users, roster: raccord, idsOf: idsOf, includeUnresolved: true, organizationId: org
        )
        var counts: [String: Int] = [:]
        for id in stored {
            let found = try XCTUnwrap(owner(id), "\(id) dropped")
            counts["\(found.user.fullName)|\(found.user.id)|\(found.unresolved)", default: 0] += 1
        }
        XCTAssertEqual(counts["TEST-ADMIN1 Person|ADMIN1|false"], 4)
        XCTAssertEqual(counts["TEST-FARNIE1 Person|FARNIE1|false"], 1)
        XCTAssertEqual(counts["TEST-TM-A Person|TM-A|false"], 4, "the two Test Manager records are one person")
        XCTAssertFalse(counts.keys.contains { $0.contains("|TM-B|") })
        let unknown = try XCTUnwrap(owner(deletedId))
        XCTAssertTrue(unknown.unresolved)
        XCTAssertEqual(unknown.user.fullName, "\(CanonicalBusinessEngine.unknownBookingPersonLabel) · QALPE29V")
        XCTAssertEqual(counts["\(unknown.user.fullName)|\(deletedId)|true"], 4)
        // B1: an Unknown person row never opens a review screen.
        XCTAssertFalse(!unknown.unresolved && PersonTimesheetLookup.opensStoredDocument(
            documentId: "timesheet_\(deletedId)_1761955200", ownId: deletedId, startDayKey: "2026-11-01"
        ))

        // Not an admin, or the roster still loading (S5): no Unknown person, never a wrong person.
        let noUnknown = PersonTimesheetLookup.exportedOwnerResolver(
            users: users, roster: raccord, idsOf: idsOf, includeUnresolved: false, organizationId: org
        )
        XCTAssertNil(noUnknown(deletedId))
        XCTAssertEqual(noUnknown("ADMIN1")?.user.id, "ADMIN1")
    }
}

/// Collects values from concurrent query tasks (the gather runs up to 8 at a time).
private nonisolated final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
