import XCTest
@testable import Project_Planner

@MainActor
final class WarningsSortCanonicalTests: XCTestCase {
    func testParseWarningsSortDirectionRoundTripsKnownValues() {
        XCTAssertEqual(CanonicalBusinessEngine.parseWarningsSortDirection(nil), "oldest" as String?)
        XCTAssertEqual(CanonicalBusinessEngine.parseWarningsSortDirection("created-at"), "oldest" as String?)
        XCTAssertEqual(CanonicalBusinessEngine.parseWarningsSortDirection(""), "oldest" as String?)
        XCTAssertEqual(CanonicalBusinessEngine.parseWarningsSortDirection("newest"), "newest" as String?)
        XCTAssertEqual(CanonicalBusinessEngine.parseWarningsSortDirection("oldest"), "oldest" as String?)
        XCTAssertEqual(CanonicalBusinessEngine.exportKind("unbookedLabourRowsOnDay"), "function" as String?)
    }

    func testSortWarningsByDateOrdersCoverageDayAndKeepsEveryRow() throws {
        let rows = [
            CanonicalWarningDateRow(id: "later-clash", dayKey: "2026-10-12"),
            CanonicalWarningDateRow(id: "earlier-unbooked", dayKey: "2026-10-10"),
            CanonicalWarningDateRow(id: "same-day-leave", dayKey: "2026-10-10"),
            CanonicalWarningDateRow(id: "undated", dayKey: ""),
        ]
        let oldest = try XCTUnwrap(CanonicalBusinessEngine.sortWarningsByDate(rows, direction: "oldest"))
        XCTAssertEqual(
            oldest.map(\.id),
            ["earlier-unbooked", "same-day-leave", "later-clash", "undated"]
        )
        let newest = try XCTUnwrap(CanonicalBusinessEngine.sortWarningsByDate(rows, direction: "newest"))
        XCTAssertEqual(
            newest.map(\.id),
            ["later-clash", "earlier-unbooked", "same-day-leave", "undated"]
        )
        XCTAssertEqual(oldest.count, rows.count)
        XCTAssertEqual(newest.count, rows.count)
        XCTAssertEqual(Set(oldest.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(Set(newest.map(\.id)), Set(rows.map(\.id)))
    }

    func testSavingUserBDoesNotChangeUserASortKey() {
        let suite = "ProjectPlannerTests.warningsSort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let saved = WarningsSortPreference.save(userId: "user-a", direction: "newest", defaults: defaults)
        XCTAssertEqual(saved, "newest" as String?)
        XCTAssertEqual(
            defaults.string(forKey: WarningsSortPreference.storageKey(userId: "user-a")),
            "newest" as String?
        )

        let other = WarningsSortPreference.save(userId: "user-b", direction: "oldest", defaults: defaults)
        XCTAssertEqual(other, "oldest" as String?)
        XCTAssertEqual(
            defaults.string(forKey: WarningsSortPreference.storageKey(userId: "user-a")),
            "newest" as String?
        )
        XCTAssertEqual(
            defaults.string(forKey: WarningsSortPreference.storageKey(userId: "user-b")),
            "oldest" as String?
        )
        XCTAssertEqual(
            WarningsSortPreference.direction(userId: "user-a", defaults: defaults),
            "newest" as String?
        )

        let neverChosen = "user-c"
        XCTAssertEqual(
            WarningsSortPreference.direction(userId: neverChosen, defaults: defaults),
            "oldest" as String?
        )
        XCTAssertNil(defaults.string(forKey: WarningsSortPreference.storageKey(userId: neverChosen)))
        XCTAssertNil(WarningsSortPreference.save(userId: " ", direction: "newest", defaults: defaults))
        XCTAssertNil(defaults.string(forKey: WarningsSortPreference.storageKey(userId: "")))
    }
}
