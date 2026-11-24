import XCTest
@testable import Project_Planner

/// Feedback guide v1.2 §2.1 (owner 24 Nov): the sign-in chord, made in code, once per sign-in, never on launch.
final class WelcomeChordTests: XCTestCase {

    func testChordMatchesTheGuide() {
        XCTAssertEqual(WelcomeChord.notes, [146.83, 220.0, 369.99, 554.37, 659.25])
        XCTAssertEqual(WelcomeChord.levels, [0.55, 0.70, 0.85, 0.80, 0.65])
        XCTAssertEqual(WelcomeChord.staggerSec, 0.16)
        XCTAssertEqual(WelcomeChord.attackSec, 0.55)
        XCTAssertEqual(WelcomeChord.octaveLevel, 0.12)
        XCTAssertEqual(WelcomeChord.totalSec, 2.6)
        XCTAssertEqual(WelcomeChord.masterScale, 0.75)
    }

    func testEnvelopeEntersRisesAndFades() {
        // Voice 2 enters at 0.32 s and peaks at level ÷ 5 after the 0.55 s attack.
        XCTAssertEqual(WelcomeChord.envelope(voice: 2, at: 0.30), 0)
        XCTAssertEqual(WelcomeChord.envelope(voice: 2, at: 0.32 + 0.55), 0.85 / 5, accuracy: 1e-9)
        XCTAssertEqual(WelcomeChord.envelope(voice: 2, at: 2.6), WelcomeChord.silence, accuracy: 1e-9)
        XCTAssertEqual(WelcomeChord.envelope(voice: 2, at: 2.7), 0)
    }

    func testRenderedChordLengthAndLevel() {
        let samples = WelcomeChord.render(sampleRate: 8_000)
        XCTAssertEqual(samples.count, Int((2.65 * 8_000).rounded(.up)))
        let peak = samples.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertLessThan(peak, 1.0, "never clips")
        XCTAssertEqual(samples.first ?? 1, 0, accuracy: 1e-6)
        XCTAssertLessThan(abs(samples.last ?? 1), 0.001, "ends in silence")
    }

    func testPlaysOncePerSignIn() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = SignInWelcomeGate()
        // App launch with an existing session: nothing marked, nothing plays.
        XCTAssertFalse(gate.take(now: start, soundsOn: true))
        gate.markSignedIn(now: start)
        XCTAssertTrue(gate.take(now: start.addingTimeInterval(1), soundsOn: true))
        // Taken: a second call for the same sign-in plays nothing.
        XCTAssertFalse(gate.take(now: start.addingTimeInterval(2), soundsOn: true))
        // The next sign-in plays again.
        gate.markSignedIn(now: start.addingTimeInterval(100))
        XCTAssertTrue(gate.take(now: start.addingTimeInterval(100), soundsOn: true))
    }

    func testNeverPlaysWithSoundsOffOrALateMark() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = SignInWelcomeGate()
        gate.markSignedIn(now: start)
        XCTAssertFalse(gate.take(now: start, soundsOn: false))
        XCTAssertFalse(gate.take(now: start, soundsOn: true), "the mark is cleared even when sounds are off")
        gate.markSignedIn(now: start)
        XCTAssertFalse(gate.take(now: start.addingTimeInterval(61), soundsOn: true))
    }
}
