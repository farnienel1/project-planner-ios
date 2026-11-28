import XCTest
@testable import Project_Planner

/// Owner report 26 Nov: (1) the orange "working offline" banner was drawn under the status bar; (2) a toolbox talk
/// signed offline showed unsigned again after backing out and back in.
@MainActor
final class OfflineBannerAndToolboxSignatureTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: 1. Banner below the status bar

    func testPaddingClearsTheStatusBarOnlyWhenTheViewIsUnderIt() {
        // A view at the very top of a Dynamic Island iPhone (59pt inset) needs the whole inset.
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 59, viewMinY: 0), 59)
        // Already below the status bar (Home under the banner): no second gap.
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 59, viewMinY: 120), 0)
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 59, viewMinY: 59), 0)
        // Partly under it: only the part that overlaps, rounded up to whole points.
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 47, viewMinY: 20.4), 27)
        // No status bar (iPad full screen in some modes), a negative or broken frame never gives odd padding.
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 0, viewMinY: 0), 0)
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 24, viewMinY: -10), 24)
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: .nan, viewMinY: 0), 0)
        XCTAssertEqual(StatusBarOverlap.padding(windowTopInset: 24, viewMinY: .infinity), 0)
    }

    func testBannerAndHomeMeasureTheirOwnOverlap() throws {
        let banner = try source("Project Planner/Views/OfflineStatusBanner.swift")
        XCTAssertTrue(banner.contains(".measuresStatusBarOverlap($statusBarPadding)"))
        let home = try source("Project Planner/Views/HomeView.swift")
        XCTAssertTrue(home.contains(".measuresStatusBarOverlap($homeTopInset)"))
        XCTAssertFalse(home.contains("topSafeInset()"), "Home must not add the full inset under the banner")
    }

    // MARK: 2. Toolbox talk signature offline

    func testSigningOfflineIsOnlineOnlyUntilTheRulebookListsIt() {
        // RULEBOOK §2: `health_safety.sign_toolbox_talk` is not in OFFLINE_ACTIONS today, so it is online only.
        XCTAssertEqual(UnlistedOfflineAction.signToolboxTalk.rawValue, "health_safety.sign_toolbox_talk")
        XCTAssertEqual(OfflinePolicy.availability(UnlistedOfflineAction.signToolboxTalk), .onlineOnly)
        XCTAssertFalse(OfflinePolicy.isEnabled(.signToolboxTalk, isOnline: false))
        XCTAssertTrue(OfflinePolicy.isEnabled(.signToolboxTalk, isOnline: true))
    }

    func testSignSheetRefusesOfflineBeforeAnythingShowsSigned() throws {
        let view = try source("Project Planner/Views/ProjectHealthSafetyView.swift")
        XCTAssertTrue(view.contains("guard isOnline || OfflinePolicy.isEnabled(.signToolboxTalk, isOnline: false) else {"))
        XCTAssertTrue(view.contains("offlineBlockedMessage: (smartCache.isOnline || OfflinePolicy.isEnabled(.signToolboxTalk, isOnline: false))"))
        XCTAssertTrue(view.contains("isOnline: smartCache.isOnline,"))
    }

    private func signature(issue: String = "I1", user: String = "U1", signed: Bool) -> HSToolboxSignature {
        HSToolboxSignature(
            id: "S-\(issue)-\(user)",
            issueId: issue,
            userId: user,
            status: signed ? .signed : .pending,
            readConfirmed: signed,
            signatureImageBase64: signed ? "iVBORw0KGgo=" : nil,
            signedAt: signed ? Date(timeIntervalSince1970: 1_800_000_000) : nil,
            reminderSentAt: nil
        )
    }

    private func pending(_ sig: HSToolboxSignature) -> PendingToolboxSignature {
        PendingToolboxSignature(organizationId: "ORG", jobId: "JOB", signature: sig, queuedAt: Date())
    }

    func testOfflineAPendingSignatureIsNeverShownUnsigned() {
        let mine = pending(signature(user: "u1", signed: true))
        // The loaded copy holds the unsigned row (stored id in upper case): it is shown signed and stays pending.
        let result = PendingToolboxSignatureRules.overlay(loaded: [signature(user: "U1", signed: false)], pending: [mine], isOnline: false)
        XCTAssertEqual(result.signatures.count, 1)
        XCTAssertTrue(result.signatures[0].isSigned)
        XCTAssertEqual(result.signatures[0].userId, "U1", "the stored row keeps its id")
        XCTAssertEqual(result.stillPending, [mine.key])
        XCTAssertTrue(result.confirmed.isEmpty)
        XCTAssertTrue(result.lost.isEmpty)
        // No loaded row at all: the pending one is added.
        let added = PendingToolboxSignatureRules.overlay(loaded: [], pending: [mine], isOnline: false)
        XCTAssertEqual(added.signatures.map(\.id), [mine.signature.id])
    }

    func testOnlineTheServerCopyConfirmsOrReportsTheSignature() {
        let mine = pending(signature(signed: true))
        let confirmed = PendingToolboxSignatureRules.overlay(loaded: [signature(signed: true)], pending: [mine], isOnline: true)
        XCTAssertEqual(confirmed.confirmed, [mine.key])
        XCTAssertTrue(confirmed.stillPending.isEmpty)
        // Online and the loaded copy (which includes this device's queued writes) is not signed: the write was lost.
        let lost = PendingToolboxSignatureRules.overlay(loaded: [signature(signed: false)], pending: [mine], isOnline: true)
        XCTAssertEqual(lost.lost, [mine.key])
        XCTAssertFalse(lost.signatures[0].isSigned, "never show a signature that is not stored")
        // Offline and the cache already shows it signed (queued write): still labelled as waiting to sync.
        let cached = PendingToolboxSignatureRules.overlay(loaded: [signature(signed: true)], pending: [mine], isOnline: false)
        XCTAssertEqual(cached.stillPending, [mine.key])
    }

    func testOtherSignersAreNeverTouched() {
        let mine = pending(signature(user: "U1", signed: true))
        let other = signature(user: "U2", signed: false)
        let result = PendingToolboxSignatureRules.overlay(loaded: [other], pending: [mine], isOnline: false)
        XCTAssertEqual(result.signatures.first(where: { $0.userId == "U2" }), other)
    }

    func testStoreKeepsOneEntryPerSignerAndFiltersByJob() throws {
        let suite = "OfflineBannerAndToolboxSignatureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PendingToolboxSignatureStore(defaults: defaults, storageKey: "k")
        let first = pending(signature(user: "U1", signed: true))
        store.add(first)
        store.add(pending(signature(user: "u1", signed: true)))
        XCTAssertEqual(store.all().count, 1, "same signer in another case replaces the entry")
        store.add(PendingToolboxSignature(organizationId: "ORG", jobId: "OTHER", signature: signature(signed: true), queuedAt: Date()))
        XCTAssertEqual(store.entries(organizationId: "org", jobId: "job").count, 1)
        store.remove(keys: [first.key])
        XCTAssertEqual(store.entries(organizationId: "ORG", jobId: "JOB").count, 0)
        XCTAssertEqual(store.all().count, 1)
    }
}
