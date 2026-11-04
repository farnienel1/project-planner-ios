import XCTest
@testable import Project_Planner

/// RULEBOOK 1.26.1 §8 follow-up: a pay editor opened while `privatePay` was off reads its starting record again when the
/// switch turns on (`PayEditorLoadGate`, record from `CanonicalBusinessEngine.payEditorStartingValues`). Values checked
/// in node against the packed 1.26.1 script: users 120, profile 150 → record 150 with the switch on, 120 with it off.
@MainActor
final class PayEditorSwitchFlipTests: XCTestCase {
    override func tearDown() {
        SecuritySwitchContext.reset()
        super.tearDown()
    }

    private func storedUser() -> AppUser {
        var user = LogicFixtures.selfEmployedUser(id: "OP-1", dayRate: 120)
        user.payBasis = "day"
        return user
    }

    private let profile: [String: Any] = ["dayRate": 150, "payBasis": "day", "userId": "OP-1"]

    func testSwitchOffNothingChanges() {
        SecuritySwitchContext.reset()
        var gate = PayEditorLoadGate()
        XCTAssertFalse(gate.isLoading(privatePay: false), "switch off: no loading state, Save is never held")
        XCTAssertTrue(gate.finish(generation: gate.generation))
        XCTAssertFalse(gate.isLoading(privatePay: false))
        let user = storedUser()
        XCTAssertEqual(user.payShown(with: profile, privatePay: false), user, "switch off: the stored document")
        XCTAssertEqual(PayEditorLoadGate.reseeded(draft: "120.00", seededWith: "120.00", record: "120.00"), "120.00")
    }

    func testTheSwitchChangePostsTheReloadNotification() {
        SecuritySwitchContext.reset()
        let posted = expectation(forNotification: .securitySwitchesDidChange, object: nil)
        SecuritySwitchContext.update(config: ["privatePay": true])
        wait(for: [posted], timeout: 2)
        XCTAssertTrue(SecuritySwitchContext.privatePay)
    }

    func testSwitchFlipsOnWhileOpenSaveWaitsThenTheBaselineIsTheProfile() {
        // Opened with the switch off: loaded on the stored document.
        var gate = PayEditorLoadGate()
        let opened = gate.generation
        XCTAssertTrue(gate.finish(generation: opened))
        let user = storedUser()
        var draft = "120.00"

        // The switch turns on (`securitySwitchesDidChange`): Save is held until the record is read again.
        SecuritySwitchContext.update(config: ["privatePay": true])
        gate.switchChanged()
        XCTAssertTrue(gate.isLoading(privatePay: SecuritySwitchContext.privatePay), "Save blocked while the record reloads")
        XCTAssertFalse(gate.finish(generation: opened), "a read begun before the change is dropped")
        XCTAssertTrue(gate.isLoading(privatePay: true))

        // The new read finishes: the record is the pay profile.
        let record = user.payShown(with: profile, privatePay: SecuritySwitchContext.privatePay)
        XCTAssertTrue(gate.finish(generation: gate.generation))
        XCTAssertFalse(gate.isLoading(privatePay: true), "Save allowed once the profile loaded")
        XCTAssertEqual(record.dayRate, 150)
        let baseline = user.withPayFields(of: record)
        XCTAssertEqual(UserStore.storedPay(of: baseline).amount, 150, "the save baseline is the profile value")

        // Only an untouched draft follows the new record.
        draft = PayEditorLoadGate.reseeded(draft: draft, seededWith: "120.00", record: "150.00")
        XCTAssertEqual(draft, "150.00")
        XCTAssertEqual(PayEditorLoadGate.reseeded(draft: "175.00", seededWith: "120.00", record: "150.00"), "175.00")
    }

    func testOperativeRowFollowsTheSameGate() {
        var gate = PayEditorLoadGate()
        XCTAssertTrue(gate.finish(generation: 0))
        gate.switchChanged()
        XCTAssertTrue(gate.isLoading(privatePay: true))
        var row = LogicFixtures.operative(id: UUID(), email: "row@example.com", dayRate: 120)
        row.firestoreDocumentId = "ROW-1"
        let record = row.payShown(with: ["dayRate": 150, "payBasis": "day", "operativeId": "ROW-1"], privatePay: true)
        XCTAssertTrue(gate.finish(generation: 1))
        XCTAssertFalse(gate.isLoading(privatePay: true))
        XCTAssertEqual(record.dayRate, 150)
    }
}
