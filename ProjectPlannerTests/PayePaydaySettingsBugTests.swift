import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// Owner bug 23 Nov (RULEBOOK 1.32.0 §4.5): on Settings → Organisation settings → Payment runs & timesheets the PAYE
/// payday "reverts back to Not set", and More → Settings while on that page stayed on it.
@MainActor
final class PayePaydaySettingsBugTests: XCTestCase {
    // MARK: Bug 1 — the pick

    func testPickingADayKeepsItUntilSaved() {
        XCTAssertEqual(OrganisationInvoicingSettingsView.payePaydayPick(25, saved: nil), 25)
        XCTAssertEqual(OrganisationInvoicingSettingsView.payePaydayPick(16, saved: 25), 16)
        // Picking the saved day again is no change.
        XCTAssertNil(OrganisationInvoicingSettingsView.payePaydayPick(25, saved: 25))
    }

    func testAfterSaveThePickStaysUnlessThePaydayReadsBack() {
        let ok = OrganisationInvoicingSettingsView.payePaydayPickAfterSave(picked: 25, readBack: 25)
        XCTAssertNil(ok.pick)
        XCTAssertFalse(ok.failed)
        // Never back to "Not set" silently: the pick stays and the screen says it did not save.
        let lost = OrganisationInvoicingSettingsView.payePaydayPickAfterSave(picked: 25, readBack: nil)
        XCTAssertEqual(lost.pick, 25)
        XCTAssertTrue(lost.failed)
        let none = OrganisationInvoicingSettingsView.payePaydayPickAfterSave(picked: nil, readBack: nil)
        XCTAssertNil(none.pick)
        XCTAssertFalse(none.failed)
    }

    /// The save path: `payePaydayWriteFields` on the server document (as `firestoreJSON` makes it), the fields applied,
    /// and the stored document read back the way the screen reads it (`payePaydayJSON` → `document` → `payePayday`).
    func testSaveFieldsReadBackAsThePickedPayday() throws {
        let server: [String: Any] = [
            "name": "Payday Ltd",
            "countryCode": "GB",
            "createdAt": Timestamp(seconds: 1_760_000_000, nanoseconds: 0),
            "invoicing": ["paymentRunMode": "date_ranges", "paymentDates": [15, 31]],
        ]
        let stored = try XCTUnwrap(FirebaseBackend.firestoreJSON(server) as? [String: Any])
        let fields = try XCTUnwrap(
            CanonicalBusinessEngine.payePaydayWriteFields(stored, day: 25, todayKey: "2026-11-23"),
            "payePaydayWriteFields gave no fields for a first payday"
        )
        var invoicing = server["invoicing"] as? [String: Any] ?? [:]
        invoicing["payePayday"] = fields["invoicing.payePayday"]
        invoicing["payePaydayHistory"] = fields["invoicing.payePaydayHistory"]
        var after = server
        after["invoicing"] = invoicing
        var org = Organization(name: "Payday Ltd")
        org.payePaydayJSON = OvertimeOrganizationDocument.payePaydayJSON(fromOrganizationData: after)
        XCTAssertEqual(CanonicalBusinessEngine.payePayday(OvertimeOrganizationDocument.document(org)), 25)
    }

    // MARK: Bug 2 — More → Settings shows the Settings main page

    func testChoosingSettingsAgainRebuildsItAtItsRoot() {
        XCTAssertTrue(ContentView.tabRebuildsAtRootWhenReselected(5), "Settings")
        XCTAssertTrue(ContentView.tabRebuildsAtRootWhenReselected(6), "Help")
        // Home is not a stack; Projects, Small works, Operatives and Managers pop themselves (resetNavigationForTab).
        for tag in [0, 1, 2, 3, 4] {
            XCTAssertFalse(ContentView.tabRebuildsAtRootWhenReselected(tag), "tab \(tag)")
        }
    }
}

/// Review of #275: choosing the open Settings tab again never throws an unsaved settings draft away silently — the
/// shell asks first while any `SettingsSwipeBackGuard` reports a dirty draft.
@MainActor
final class SettingsUnsavedDraftsTests: XCTestCase {
    override func tearDown() {
        SettingsUnsavedDrafts.reset()
        super.tearDown()
    }

    func testADirtyGuardIsReportedUntilCleanOrRemoved() {
        SettingsUnsavedDrafts.reset()
        let guardController = SettingsSwipeBackGuard.Controller()
        XCTAssertFalse(SettingsUnsavedDrafts.any)
        guardController.disabled = true
        guardController.apply()
        XCTAssertTrue(SettingsUnsavedDrafts.any, "a dirty draft is reported")
        guardController.disabled = false
        guardController.apply()
        XCTAssertFalse(SettingsUnsavedDrafts.any, "a clean draft is not")
        guardController.disabled = true
        guardController.apply()
        SettingsSwipeBackGuard.dismantleUIViewController(guardController, coordinator: ())
        XCTAssertFalse(SettingsUnsavedDrafts.any, "a removed screen is not")
    }
}
