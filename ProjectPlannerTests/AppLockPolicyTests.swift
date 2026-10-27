import XCTest
@testable import Project_Planner

@MainActor
final class AppLockPolicyTests: XCTestCase {
    /// A throwaway defaults suite so tests never touch the simulator's real app-lock choice.
    private func makeDefaults() -> UserDefaults {
        let name = "AppLockPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testGracePeriodIsThirtyMinutes() {
        let left = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(AppLockPolicy.gracePeriod, 1_800)
        XCTAssertFalse(AppLockPolicy.shouldLockOnReturn(enabled: true, backgroundedAt: left, now: left.addingTimeInterval(1_799)))
        XCTAssertTrue(AppLockPolicy.shouldLockOnReturn(enabled: true, backgroundedAt: left, now: left.addingTimeInterval(1_800)))
        XCTAssertFalse(AppLockPolicy.shouldLockOnReturn(enabled: false, backgroundedAt: left, now: left.addingTimeInterval(600)))
        XCTAssertFalse(AppLockPolicy.shouldLockOnReturn(enabled: true, backgroundedAt: nil, now: left))
    }

    func testRestoredSessionLocksButPasswordSignInDoesNot() {
        XCTAssertTrue(AppLockPolicy.shouldLockOnActivate(enabled: true, isInteractiveSignIn: false))
        XCTAssertFalse(AppLockPolicy.shouldLockOnActivate(enabled: true, isInteractiveSignIn: true))
        XCTAssertFalse(AppLockPolicy.shouldLockOnActivate(enabled: false, isInteractiveSignIn: false))
    }

    func testOfferOnlyOnceAfterPasswordSignInOnALockableDevice() {
        XCTAssertTrue(AppLockPolicy.shouldOfferAfterSignIn(enabled: false, alreadyOffered: false, isInteractiveSignIn: true, deviceCanLock: true))
        XCTAssertFalse(AppLockPolicy.shouldOfferAfterSignIn(enabled: false, alreadyOffered: true, isInteractiveSignIn: true, deviceCanLock: true))
        XCTAssertFalse(AppLockPolicy.shouldOfferAfterSignIn(enabled: true, alreadyOffered: false, isInteractiveSignIn: true, deviceCanLock: true))
        XCTAssertFalse(AppLockPolicy.shouldOfferAfterSignIn(enabled: false, alreadyOffered: false, isInteractiveSignIn: false, deviceCanLock: true))
        XCTAssertFalse(AppLockPolicy.shouldOfferAfterSignIn(enabled: false, alreadyOffered: false, isInteractiveSignIn: true, deviceCanLock: false))
    }

    func testPreferenceIsPerUserAndSurvivesSignOut() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockPolicy.enabledKey(uid: "alice"))
        let lock = AppLockService(defaults: defaults)

        lock.activate(uid: "alice")
        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(lock.isLocked, "A restored session with the lock on starts locked")

        lock.deactivate()
        XCTAssertFalse(lock.isLocked)
        XCTAssertTrue(defaults.bool(forKey: AppLockPolicy.enabledKey(uid: "alice")), "Sign-out keeps the choice")

        lock.activate(uid: "bob")
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testPasswordSignInIsNotLockedStraightAway() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockPolicy.enabledKey(uid: "alice"))
        let lock = AppLockService(defaults: defaults)
        lock.noteInteractiveSignIn()
        lock.activate(uid: "alice")
        XCTAssertTrue(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testBackgroundShorterThanGraceStaysUnlocked() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockPolicy.enabledKey(uid: "alice"))
        var clock = Date(timeIntervalSince1970: 10_000)
        let lock = AppLockService(defaults: defaults, now: { clock })
        lock.noteInteractiveSignIn()
        lock.activate(uid: "alice")

        lock.appDidEnterBackground()
        clock = clock.addingTimeInterval(29 * 60)
        lock.appDidBecomeActive()
        XCTAssertFalse(lock.isLocked)

        lock.appDidEnterBackground()
        clock = clock.addingTimeInterval(31 * 60)
        lock.appDidBecomeActive()
        XCTAssertTrue(lock.isLocked)
    }

    func testLockOffNeverLocks() {
        let defaults = makeDefaults()
        var clock = Date(timeIntervalSince1970: 10_000)
        let lock = AppLockService(defaults: defaults, now: { clock })
        lock.activate(uid: "alice")
        lock.appDidEnterBackground()
        clock = clock.addingTimeInterval(3_600)
        lock.appDidBecomeActive()
        XCTAssertFalse(lock.isLocked)
    }

    func testDismissingOfferIsRemembered() {
        let defaults = makeDefaults()
        let lock = AppLockService(defaults: defaults)
        lock.activate(uid: "alice")
        lock.dismissSignInOffer()
        XCTAssertTrue(defaults.bool(forKey: AppLockPolicy.offeredKey(uid: "alice")))
        XCTAssertFalse(lock.showSignInOffer)
    }
}
