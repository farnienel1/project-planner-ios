import XCTest
@testable import Project_Planner

/// Release-readiness gates: forced update, privacy manifest, pay inputs that did not load, sign-out with queued
/// changes, App Store billing copy. App plumbing (no rulebook function owns these).
@MainActor
final class ReleaseReadinessTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Forced update

    func testAnOlderBuildIsBlockedAndAnythingUnknownNeverBlocks() {
        XCTAssertTrue(ForcedUpdateGate.blocks(running: 10, stored: NSNumber(value: 11)))
        XCTAssertFalse(ForcedUpdateGate.blocks(running: 11, stored: NSNumber(value: 11)))
        XCTAssertFalse(ForcedUpdateGate.blocks(running: 12, stored: NSNumber(value: 11)))
        XCTAssertTrue(ForcedUpdateGate.blocks(running: 10, stored: "11"))
        XCTAssertFalse(ForcedUpdateGate.blocks(running: 10, stored: nil), "a missing field never blocks")
        XCTAssertFalse(ForcedUpdateGate.blocks(running: 10, stored: "soon"), "an unreadable field never blocks")
        XCTAssertFalse(ForcedUpdateGate.blocks(running: 10, stored: NSNumber(value: true)), "a bool is not a build")
        XCTAssertFalse(ForcedUpdateGate.blocks(running: nil, stored: NSNumber(value: 99)), "an unknown running build never blocks")
        XCTAssertEqual(ForcedUpdateGate.documentPath, "platformConfig/app")
        XCTAssertEqual(ForcedUpdateGate.fieldName, "minimumIosBuild")
    }

    // MARK: Privacy manifest

    func testThePrivacyManifestDeclaresTheRequiredReasonAPIs() throws {
        let url = repoRoot.appendingPathComponent("Project Planner/PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).reduce(into: [String: [String]]()) {
            $0[$1["NSPrivacyAccessedAPIType"] as? String ?? ""] = $1["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(apis["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(apis["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
        let collected = plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        XCTAssertFalse(collected.isEmpty)
        for row in collected {
            XCTAssertEqual(row["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(row["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        }
    }

    // MARK: Pay inputs

    func testPayIsNotWorkedOutUntilTheHistoryAndOrganisationLoaded() {
        let org = Organization(name: "TEST-Org")
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: org))
        XCTAssertEqual(PayInputsLoad.blockMessage(state: .failed("x"), organization: org), "x")
        XCTAssertNotNil(PayInputsLoad.blockMessage(state: .loading, organization: org))
        XCTAssertEqual(PayInputsLoad.blockMessage(state: .loaded, organization: nil), PayInputsLoad.organisationNotLoadedMessage)
    }

    // MARK: Sign-out

    func testSignOutWarningCountsTheQueuedChanges() {
        XCTAssertEqual(PendingSyncCount.message(1), "You have 1 change waiting to sync. Signing out will discard it.")
        XCTAssertEqual(PendingSyncCount.message(3), "You have 3 changes waiting to sync. Signing out will discard them.")
    }

    // MARK: App Store billing copy

    func testNoPriceRenewalOrWebLinkIsShown() {
        for text in [SubscriptionLapsedCopy.headline, SubscriptionLapsedCopy.detail(isSuperAdmin: true), SubscriptionLapsedCopy.detail(isSuperAdmin: false)] {
            XCTAssertFalse(text.lowercased().contains("renew"))
            XCTAssertFalse(text.lowercased().contains("web"))
            XCTAssertFalse(text.contains("£"))
        }
    }
}
