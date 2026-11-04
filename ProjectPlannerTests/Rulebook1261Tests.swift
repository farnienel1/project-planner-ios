import XCTest
@testable import Project_Planner

/// RULEBOOK 1.26.1 §8 "Pay editors start from the pay shown" on iOS through `CanonicalBusinessEngine`
/// (`payEditorStartingValues`, `payRateChangeWrites`). Expected values were checked in node against the packed
/// `canonical-business.js` (rulebook 1.26.1, sha256 4f4c44d9…d89d86).
@MainActor
final class Rulebook1261Tests: XCTestCase {
    override func tearDown() {
        SecuritySwitchContext.reset()
        super.tearDown()
    }

    /// Releasing a main-actor store at the end of a test hits a Swift runtime crash in this host.
    private static var retained: [AnyObject] = []

    private let seedDay = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 London
    private let saveDay = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04 00:00 London

    private func storedUser() -> AppUser {
        var user = LogicFixtures.selfEmployedUser(id: "OP-1", dayRate: 120)
        user.payBasis = "day"
        return user
    }

    private let profile: [String: Any] = ["dayRate": 150, "payBasis": "day", "userId": "OP-1"]

    func testThePackedScriptIsRulebook1261OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 26, 1]), "rulebook \(stamp.version) predates 1.26.1")
        XCTAssertTrue(Set(CanonicalBusinessEngine.exportNames()).contains("payEditorStartingValues"))
    }

    // MARK: Switch on

    func testSwitchOnTheEditorStartsFromThePayProfile() throws {
        let user = storedUser()
        let answer = try XCTUnwrap(CanonicalBusinessEngine.payEditorStartingValues(
            person: user.payProfileFieldsJSON, profileId: "OP-1", profile: profile, privatePay: true
        ))
        XCTAssertTrue(answer.fromPayProfile)
        XCTAssertEqual((answer.record["dayRate"] as? NSNumber)?.doubleValue, 150)
        let record = user.payShown(with: profile, privatePay: true)
        XCTAssertEqual(record.dayRate, 150, "users 120, profile 150: the editor opens on 150")
        XCTAssertEqual(record.payBasis, "day")
        // A former invite id's profile is read the same way (web `payEditorRecord`).
        let former: [String: Any] = ["dayRate": 150, "payBasis": "day", "userId": "INV-1"]
        XCTAssertEqual(user.payShown(with: former, profileId: "INV-1", privatePay: true).dayRate, 150)
        // No profile: the stored document.
        XCTAssertEqual(user.payShown(with: nil, privatePay: true), user)
    }

    func testSwitchOnTheSaveBaselineIsTheSameRecord() throws {
        let user = storedUser()
        let record = user.payShown(with: profile, privatePay: true)
        var renamed = user
        renamed.firstName = "Grace"
        let baseline = renamed.withPayFields(of: record)
        XCTAssertEqual(baseline.firstName, "Grace", "only the pay fields come from the record")
        XCTAssertEqual(UserStore.storedPay(of: baseline).amount, 150)

        // Unchanged save (field still 150): no pay change and no history rows.
        let unchanged = try XCTUnwrap(CanonicalBusinessEngine.payRateChangeWrites(
            userId: "OP-1", operativeId: nil,
            previous: (150, "day"), next: (150, "day"),
            historyRowIds: nil, effective: saveDay, seedEffective: seedDay, timeZone: "Europe/London"
        ))
        XCTAssertNil(unchanged.refusal)
        XCTAssertTrue(unchanged.rows.isEmpty, "an untouched field writes no pay and no history")

        // Save at 180 with no history yet: the seed row is the record's 150, then 180.
        let changed = try XCTUnwrap(CanonicalBusinessEngine.payRateChangeWrites(
            userId: "OP-1", operativeId: nil,
            previous: (150, "day"), next: (180, "day"),
            historyRowIds: [], effective: saveDay, seedEffective: seedDay, timeZone: "Europe/London"
        ))
        XCTAssertNil(changed.refusal)
        XCTAssertEqual(changed.rows.map(\.dayRate), [150, 180])
        XCTAssertEqual(changed.rows.map(\.effectiveDayKey), ["2026-01-01", "2026-11-04"])
    }

    func testSwitchOnTheOperativeRowEditorStartsFromItsPayProfile() {
        var row = LogicFixtures.operative(id: UUID(), email: "row@example.com", dayRate: 120)
        row.firestoreDocumentId = "ROW-1"
        let rowProfile: [String: Any] = ["dayRate": 150, "payBasis": "day", "operativeId": "ROW-1"]
        let record = row.payShown(with: rowProfile, privatePay: true)
        XCTAssertEqual(record.dayRate, 150)
        XCTAssertEqual(record.payBasis, "day")
        XCTAssertEqual(record.firstName, row.firstName)
        XCTAssertEqual(row.payShown(with: nil, privatePay: true).dayRate, 120, "no profile: the row as stored")
    }

    func testSwitchOnARefusedReadKeepsTheStoredDocument() async {
        SecuritySwitchContext.update(config: ["privatePay": true])
        XCTAssertTrue(SecuritySwitchContext.privatePay)
        let store = UserStore()
        Self.retained.append(store)
        let record = await store.payEditorRecord(for: storedUser())
        XCTAssertEqual(record.dayRate, 120, "no profile could be read: the stored document")
    }

    // MARK: Switch off

    func testSwitchOffTheRecordIsTheStoredDocumentAndNothingIsRead() async throws {
        SecuritySwitchContext.reset()
        XCTAssertFalse(SecuritySwitchContext.privatePay)
        let user = storedUser()
        let answer = try XCTUnwrap(CanonicalBusinessEngine.payEditorStartingValues(
            person: user.payProfileFieldsJSON, profileId: "OP-1", profile: profile, privatePay: false
        ))
        XCTAssertFalse(answer.fromPayProfile)
        XCTAssertEqual((answer.record["dayRate"] as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual(user.payShown(with: profile, privatePay: false), user)
        var row = LogicFixtures.operative(id: UUID(), email: "row@example.com", dayRate: 120)
        row.firestoreDocumentId = "ROW-1"
        XCTAssertEqual(row.payShown(with: ["dayRate": 150, "payBasis": "day"], privatePay: false).dayRate, 120)
        let store = UserStore()
        Self.retained.append(store)
        let record = await store.payEditorRecord(for: user)
        XCTAssertEqual(record, user, "switch off: the subject unchanged, no pay profile read")
    }
}
