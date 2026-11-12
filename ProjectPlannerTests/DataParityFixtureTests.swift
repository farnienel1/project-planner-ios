import XCTest
@testable import Project_Planner

/// RULEBOOK 1.38.0 §27 (owner decision 11 Nov) — the two-app comparison, iOS half. `DataParityFixture.json` is web
/// `lib/canonical/data-parity-fixture.json`, mirrored by `scripts/sync-rulebook-from-web.sh` (sha256 in the manifest,
/// `RulebookParityTests`). It holds raw Firestore documents of a test company and a sequence of listener events. Each
/// event is fed through this app's real merge code — `ProjectStore.liveWorkSliceResult` (with `LiveSnapshotMerge` and
/// `ProjectWorksMerge.uniqueWorks`) and `ProjectWorksMerge.smallWorksList`, `BookingStore.liveBookingsMerge`, and
/// `UserStore.liveRosterMerge` with the full reload a server removal triggers — and after every step the held lists
/// must be exactly `expectedHeld`, `worksListMembership` of the held jobs `expectedVisible`, and `dataParityCheck`
/// against the database `expectedParityMismatches`. `rawLists` (operatives, managers, clients) are held as the
/// listener's documents through `DataParityListenerLedger.merge` — what `DataParityMonitor` counts — compared with case
/// kept, and the check is fed exactly what the monitor feeds it (the listener's ids for bookings and the raw lists,
/// the store's list plus the listener's placeholder for jobs). Web runs the same file (`lib/dataParity/dataParityFixture.test.ts`).
/// A failure here is an iOS loading layer that drops or keeps a record the database does not agree with. Test data only.
@MainActor
final class DataParityFixtureTests: XCTestCase {
    private typealias Rows = [(id: String, data: [String: Any])]

    private func loadFixture() throws -> [String: Any] {
        let url = Bundle(for: DataParityFixtureTests.self).url(forResource: "DataParityFixture", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("DataParityFixture.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func rows(_ value: Any?) -> Rows {
        (value as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return (id: id, data: row["data"] as? [String: Any] ?? [:])
        }
    }

    private func lowerSorted(_ ids: [String]) -> [String] { ids.map { $0.lowercased() }.sorted() }

    private func bookings(from documents: Rows) -> [Booking] {
        let payload: [[String: Any]] = documents.map { ["id": $0.id, "data": FirebaseBackend.firestoreJSON($0.data)] }
        return (CanonicalBusinessEngine.parseBookingDocuments(payload) ?? []).compactMap(FirebaseBackend.booking(fromCanonical:))
    }

    private func users(from documents: Rows, organizationId: String) -> [AppUser] {
        documents.map { row in
            var user = FirebaseBackend.parseAppUserDocument(userId: row.id, data: row.data, annualLeaveDefaults: nil)
            if user.organizationId.isEmpty { user.organizationId = organizationId }
            return user
        }
    }

    func testEveryStepHoldsExactlyTheDatabase() throws {
        let fixture = try loadFixture()
        let organizationId = try XCTUnwrap(fixture["organizationId"] as? String)
        let lists = try XCTUnwrap(fixture["lists"] as? [String])
        let rawLists = fixture["rawLists"] as? [String] ?? []
        XCTAssertEqual(rawLists, ["operatives", "managers", "clients"])
        let initial = try XCTUnwrap(fixture["initialDatabase"] as? [String: Any])
        var database: [String: Rows] = [:]
        for list in lists { database[list] = rows(initial[list]) }

        var projects: [Project] = []
        var smallWorksDocuments: [Project] = []
        var heldBookings: [Booking] = []
        var rosterDocuments: [AppUser] = []
        var rosterSeen: [String: String] = [:]
        // What each listener received, by stored id (`DataParityListenerLedger`), as the monitor counts it.
        var listenerIds: [String: [String]] = [:]

        func fingerprint(_ data: [String: Any]) -> String {
            let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
            return json.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        let steps = try XCTUnwrap(fixture["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 7)
        for step in steps {
            let stepId = step["id"] as? String ?? "?"
            for write in step["writes"] as? [[String: Any]] ?? [] {
                guard let list = write["list"] as? String, let id = write["id"] as? String else { continue }
                var current = database[list] ?? []
                current.removeAll { $0.id == id }
                if write["op"] as? String == "set" { current.append((id: id, data: write["data"] as? [String: Any] ?? [:])) }
                database[list] = current
            }
            for event in step["events"] as? [[String: Any]] ?? [] {
                guard let list = event["list"] as? String, let source = event["source"] as? String else { continue }
                if source == "refused" { continue } // the listener stops; the app keeps what it holds
                let fromCache = source == "cache"
                let wanted = Set(event["ids"] as? [String] ?? [])
                let snapshot: Rows = fromCache ? (database[list] ?? []).filter { wanted.contains($0.id) } : (database[list] ?? [])
                listenerIds[list] = DataParityListenerLedger.merge(
                    existing: listenerIds[list] ?? [],
                    incoming: snapshot.map(\.id),
                    fromCache: fromCache
                )
                switch list {
                case "projects", "smallWorks":
                    let smallWorks = list == "smallWorks"
                    let incoming = FirebaseBackend.jobs(fromDocuments: snapshot, smallWorks: smallWorks)
                        .filter { $0.isSmallWorksDocument == smallWorks }
                    if let result = ProjectStore.liveWorkSliceResult(
                        projects: projects,
                        smallWorksDocuments: smallWorksDocuments,
                        incoming: incoming,
                        smallWorks: smallWorks,
                        fromCache: fromCache,
                        rowCount: LiveSnapshotMerge.readableRowCount(snapshot),
                        pendingCreateIds: []
                    ) {
                        if let documents = result.smallWorksDocuments { smallWorksDocuments = documents }
                        if let next = result.projects { projects = next }
                    }
                case "bookings":
                    let merged = BookingStore.liveBookingsMerge(existing: heldBookings, remote: bookings(from: snapshot), fromCache: fromCache)
                    if merged.changed { heldBookings = merged.list }
                case "users":
                    // The roster listener reports document changes; a server snapshot that drops a document triggers
                    // the full reload, whose documents replace the list (`organizationUserDocuments = roster.documents`).
                    let changed = snapshot.filter { rosterSeen[$0.id] != fingerprint($0.data) }
                    let removed = rosterSeen.keys.contains { id in !snapshot.contains { $0.id == id } }
                    if !fromCache || !snapshot.isEmpty {
                        rosterSeen = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, fingerprint($0.data)) })
                    }
                    rosterDocuments = UserStore.liveRosterMerge(
                        onScreen: rosterDocuments,
                        changed: users(from: changed, organizationId: organizationId),
                        isTombstoned: { _ in false }
                    )
                    if removed && !fromCache {
                        rosterDocuments = users(from: database["users"] ?? [], organizationId: organizationId)
                    }
                case _ where rawLists.contains(list):
                    break // held as the listener's documents (`listenerIds`)
                default:
                    XCTFail("\(stepId): unknown list \(list)")
                }
            }

            let heldProjects = projects.filter { !$0.isSmallWorksDocument }
            let heldSmallWorks = ProjectWorksMerge.smallWorksList(store: projects, smallWorksDocuments: smallWorksDocuments)
            var held: [String: [String]] = [
                "projects": lowerSorted(heldProjects.map(\.documentId)),
                "smallWorks": lowerSorted(heldSmallWorks.map(\.documentId)),
                "users": lowerSorted(rosterDocuments.map(\.id)),
                "bookings": lowerSorted(heldBookings.map(\.documentKey)),
            ]
            // rawLists keep their stored case: two ids that differ only in case are two documents.
            for list in rawLists { held[list] = (listenerIds[list] ?? []).sorted() }
            let expectedHeld = step["expectedHeld"] as? [String: [String]] ?? [:]
            for list in lists {
                let expected = rawLists.contains(list) ? (expectedHeld[list] ?? []).sorted() : lowerSorted(expectedHeld[list] ?? [])
                XCTAssertEqual(held[list], expected, "\(stepId): \(list) — \(step["description"] as? String ?? "")")
            }
            // What `DataParityMonitor` gives `dataParityCheck` (ids as stored, never case-folded).
            var counted: [String: [String]] = [
                "projects": heldProjects.map(\.documentId),
                "smallWorks": heldSmallWorks.map(\.documentId),
                "users": rosterDocuments.map(\.id),
            ]
            for list in ["bookings"] + rawLists { counted[list] = listenerIds[list] ?? [] }
            let expectedVisible = step["expectedVisible"] as? [String: [String]] ?? [:]
            XCTAssertEqual(
                lowerSorted(CanonicalBusinessEngine.worksListMembership(heldProjects, kind: .projects).map(\.documentId)),
                lowerSorted(expectedVisible["projects"] ?? []),
                "\(stepId): visible projects"
            )
            XCTAssertEqual(
                lowerSorted(CanonicalBusinessEngine.worksListMembership(heldSmallWorks, kind: .smallWorks).map(\.documentId)),
                lowerSorted(expectedVisible["smallWorks"] ?? []),
                "\(stepId): visible small works"
            )
            let check = try XCTUnwrap(CanonicalBusinessEngine.dataParityCheck(lists: lists.map { list in
                let documents = database[list] ?? []
                let isJobs = list == "projects" || list == "smallWorks"
                return RulebookDataParityListInput(
                    key: list,
                    serverCount: documents.count,
                    localIds: counted[list],
                    readerDroppedCount: isJobs ? (listenerIds[list] ?? []).filter { $0 == "INITIAL-PLACEHOLDER" }.count : 0
                )
            }), "\(stepId): dataParityCheck did not answer")
            XCTAssertEqual(check.reloadKeys, step["expectedParityMismatches"] as? [String] ?? [], "\(stepId): data check")
        }
    }

    /// A data check that counted the store's filtered list or folded id case would report a difference that is not
    /// there; the listener's ids by stored id match the server.
    func testTheCheckCountsStoredIdsNotTheFilteredStoreList() throws {
        let fixture = try loadFixture()
        let initial = try XCTUnwrap(fixture["initialDatabase"] as? [String: Any])
        for list in fixture["rawLists"] as? [String] ?? [] {
            let raw = rows(initial[list]).map(\.id)
            let held = DataParityListenerLedger.merge(existing: [], incoming: raw, fromCache: false)
            XCTAssertEqual(
                CanonicalBusinessEngine.dataParityCheck(lists: [RulebookDataParityListInput(key: list, serverCount: raw.count, localIds: held)])?.reloadKeys,
                [],
                list
            )
            let folded = Array(Set(raw.map { $0.lowercased() }))
            if folded.count < raw.count {
                XCTAssertEqual(
                    CanonicalBusinessEngine.dataParityCheck(lists: [RulebookDataParityListInput(key: list, serverCount: raw.count, localIds: folded)])?.reloadKeys,
                    [list]
                )
            }
        }
        // A cache snapshot never drops an id; a server snapshot does.
        XCTAssertEqual(DataParityListenerLedger.merge(existing: ["a", "b"], incoming: ["b"], fromCache: true), ["a", "b"])
        XCTAssertEqual(DataParityListenerLedger.merge(existing: ["a", "b"], incoming: [], fromCache: true), ["a", "b"])
        XCTAssertEqual(DataParityListenerLedger.merge(existing: ["a", "b"], incoming: ["b"], fromCache: false), ["b"])
    }

    func testTwoLooksBeforeAReload() throws {
        let first = try XCTUnwrap(CanonicalBusinessEngine.dataParityCheck(lists: [
            RulebookDataParityListInput(key: "projects", serverCount: 7, localIds: ["a", "b", "c", "d", "e", "f"]),
            RulebookDataParityListInput(key: "clients", serverCount: 2, localIds: ["x"]),
        ]))
        XCTAssertEqual(first.reloadKeys, ["projects", "clients"])
        let second = CanonicalBusinessEngine.dataParityCheck(lists: [
            RulebookDataParityListInput(key: "projects", serverCount: 7, localIds: ["a", "b", "c", "d", "e", "f"]),
            RulebookDataParityListInput(key: "clients", serverCount: 2, localIds: ["x", "y"]),
        ])
        XCTAssertEqual(CanonicalBusinessEngine.dataParityConfirm(first: first, confirm: second)?.reloadKeys, ["projects"])
        XCTAssertEqual(CanonicalBusinessEngine.dataParityConfirm(first: first, confirm: nil)?.reloadKeys, [])
        XCTAssertGreaterThan(CanonicalBusinessEngine.dataParityConfirmDelayMs, 0)
    }

    func testTheCheckPanelIsHiddenUnlessTheSwitchIsOn() {
        XCTAssertEqual(CanonicalBusinessEngine.dataCheckPanelEnabled(config: nil, organizationId: "org-1"), false)
        XCTAssertEqual(CanonicalBusinessEngine.dataCheckPanelEnabled(config: ["dataCheckPanel": true], organizationId: "org-1"), true)
        XCTAssertEqual(
            CanonicalBusinessEngine.dataCheckPanelEnabled(config: ["dataCheckPanelOrganizationIds": ["org-1"]], organizationId: "org-1"),
            true
        )
        XCTAssertFalse(CanonicalBusinessEngine.dataCheckPanelVisible(viewerIsAdmin: true, dataCheckPanelEnabled: false))
        XCTAssertFalse(CanonicalBusinessEngine.dataCheckPanelVisible(viewerIsAdmin: false, dataCheckPanelEnabled: true))
        XCTAssertTrue(CanonicalBusinessEngine.dataCheckPanelVisible(viewerIsAdmin: true, dataCheckPanelEnabled: true))
    }

    func testThrottleAndSummaryBridge() {
        let now = 1_800_000_000_000.0
        XCTAssertTrue(CanonicalBusinessEngine.dataParityCheckDue(trigger: "open", lastCheckedMs: nil, nowMs: now, online: true))
        XCTAssertFalse(CanonicalBusinessEngine.dataParityCheckDue(trigger: "timer", lastCheckedMs: now - 60_000, nowMs: now, online: true))
        XCTAssertTrue(CanonicalBusinessEngine.dataParityCheckDue(trigger: "manual", lastCheckedMs: now - 1, nowMs: now, online: true))
        XCTAssertFalse(CanonicalBusinessEngine.dataParityCheckDue(trigger: "manual", lastCheckedMs: nil, nowMs: now, online: false))
        XCTAssertEqual(
            CanonicalBusinessEngine.dataParityChecks.map(\.key),
            ["projects", "smallWorks", "users", "operatives", "managers", "clients", "bookings", "managerSiteBookings", "holidayBookings", "tasks"]
        )
        let first = CanonicalBusinessEngine.dataParityCheck(lists: [
            RulebookDataParityListInput(key: "projects", serverCount: 7, localIds: ["a", "b", "c", "d", "e", "f"]),
        ])
        XCTAssertEqual(first?.reloadKeys, ["projects"])
        if let first, let entry = CanonicalBusinessEngine.dataParityLogEntry(atMs: now, trigger: "open", first: first, recheck: nil) {
            let summary = CanonicalBusinessEngine.dataParitySummary(entry: entry, timeZone: "Europe/London")
            XCTAssertEqual(summary.tone, "warning")
            XCTAssertEqual(summary.lines, ["Projects: server 7, this device 6 — not re-checked"])
        } else {
            XCTFail("dataParityLogEntry did not answer")
        }
    }
}
