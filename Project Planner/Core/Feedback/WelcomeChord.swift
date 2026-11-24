//
//  WelcomeChord.swift
//  Project Planner
//
//  The sign-in chord (`signedIn`, feedback guide §2.1, v1.2, owner 24 Nov: "a nice slow harmony when you first log
//  in — unique, generated, mind copyright"). It is not a file: the same numbers as web `WELCOME_CHORD` are rendered to a
//  PCM buffer in code and played through `AVAudioEngine` under the `.ambient` session (the silent switch mutes it).
//  No samples and no melody from anywhere else: a plain D major 9 chord. Platform-specific feedback, not a business
//  rule (rulebook §15); nothing here reads or writes Firestore.
//
//  When: once, after a successful sign-in on this phone, when Home first draws (the session is usable) (the iOS app signs in with a password only — it has no
//  emailed code or passkey step), never when the app opens an existing session, and only while the Sounds setting
//  (`pp.feedback.sounds`) is on. No haptic.
//

import AVFoundation
import Foundation

/// Guide §2.1, the same values as web `lib/feedbackSounds/feedback.ts` `WELCOME_CHORD`.
nonisolated enum WelcomeChord {
    /// D3, A3, F♯4, C♯5, E5 (Hz), lowest first.
    static let notes: [Double] = [146.83, 220.0, 369.99, 554.37, 659.25]
    /// Each voice's relative level; each voice peaks at level ÷ number of voices.
    static let levels: [Double] = [0.55, 0.70, 0.85, 0.80, 0.65]
    /// Seconds between one voice entering and the next.
    static let staggerSec = 0.16
    /// Seconds each voice takes to swell from silence (0.0001) to its level.
    static let attackSec = 0.55
    /// The second sine, one octave up, relative to the voice.
    static let octaveLevel = 0.12
    /// First voice in to silence; every voice has faded to 0.0001 by then.
    static let totalSec = 2.6
    /// Oscillators stop this long after `totalSec`.
    static let stopAfterSec = 0.05
    /// Master level relative to the feedback level (web 0.35 × 0.75; iOS the file volume 0.6 × 0.75).
    static let masterScale = 0.75
    static let silence = 0.0001
    static let sampleRate: Double = 44_100

    /// The iOS feedback file volume (`BundleFeedbackSoundOutput.volume`, owner decision 12).
    static let iosFeedbackVolume = 0.6
    /// iOS master: the same relative level as web under the `.ambient` session.
    static var masterGain: Double { iosFeedbackVolume * masterScale }

    /// One voice's level at `t` seconds after the chord starts (the Web Audio ramps: hold 0.0001 until it enters,
    /// a linear rise over `attackSec`, then an exponential fall to 0.0001 at `totalSec`; nothing after the stop).
    static func envelope(voice index: Int, at t: Double) -> Double {
        let enter = Double(index) * staggerSec
        let level = levels[index] / Double(notes.count)
        let peakAt = enter + attackSec
        if t < enter || t >= totalSec + stopAfterSec { return 0 }
        if t >= totalSec { return silence }
        if t <= peakAt {
            return silence + (level - silence) * (t - enter) / attackSec
        }
        let progress = (t - peakAt) / (totalSec - peakAt)
        return level * pow(silence / level, progress)
    }

    /// The whole chord as mono samples at `sampleRate`, master gain applied.
    static func render(sampleRate: Double = sampleRate, masterGain: Double = masterGain) -> [Float] {
        let count = Int(((totalSec + stopAfterSec) * sampleRate).rounded(.up))
        var out = [Float](repeating: 0, count: count)
        for (index, frequency) in notes.enumerated() {
            let enter = Double(index) * staggerSec
            let first = Int((enter * sampleRate).rounded(.up))
            guard first < count else { continue }
            for sample in first..<count {
                let t = Double(sample) / sampleRate
                let gain = envelope(voice: index, at: t)
                guard gain > 0 else { continue }
                let phase = 2 * Double.pi * frequency * (t - enter)
                let value = sin(phase) + octaveLevel * sin(2 * phase)
                out[sample] += Float(masterGain * gain * value)
            }
        }
        return out
    }
}

/// Plays the rendered chord once through `AVAudioEngine`. The buffer is rendered on first use only.
@MainActor
final class WelcomeChordPlayer {
    static let shared = WelcomeChordPlayer()

    private var buffer: AVAudioPCMBuffer?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    /// Which play the engine belongs to, so a late completion never stops a newer one.
    private var generation = 0

    private func makeBuffer() -> AVAudioPCMBuffer? {
        if let buffer { return buffer }
        let samples = WelcomeChord.render()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: WelcomeChord.sampleRate, channels: 1),
              let made = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = made.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        made.frameLength = AVAudioFrameCount(samples.count)
        buffer = made
        return made
    }

    /// Returns false when audio could not start. Never throws.
    @discardableResult
    func play() -> Bool {
        guard let buffer = makeBuffer() else { return false }
        BundleFeedbackSoundOutput.configureAudioSession()
        stop()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        do {
            try engine.start()
        } catch {
            #if DEBUG
            print("Feedback: welcome chord could not start (\(error.localizedDescription))")
            #endif
            return false
        }
        self.engine = engine
        self.node = node
        generation += 1
        let playing = generation
        // The completion runs on an audio thread: hop to the main actor before touching the player (review of #284).
        node.scheduleBuffer(buffer, at: nil, options: []) { @Sendable in
            Task { @MainActor in
                // Let the last samples drain, then release the engine.
                try? await Task.sleep(nanoseconds: 200_000_000)
                WelcomeChordPlayer.shared.finish(generation: playing)
            }
        }
        node.play()
        return true
    }

    private func finish(generation finished: Int) {
        guard finished == generation else { return }
        stop()
    }

    private func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }
}

/// "Play once per sign-in": a successful sign-in on this phone marks it; the chord plays when the mark is taken, once,
/// within `maxAge`, and only while sounds are on. The app opening an existing session never marks it, so it never plays
/// on launch. Pure, so it is tested.
nonisolated struct SignInWelcomeGate: Equatable {
    /// As web `WELCOME_PENDING_MAX_AGE_MS`: a mark older than this is dropped.
    static let maxAge: TimeInterval = 60

    private(set) var markedAt: Date?

    mutating func markSignedIn(now: Date) {
        markedAt = now
    }

    /// True once per mark: the mark is cleared whatever the answer, so a second call (or a later screen) never plays.
    mutating func take(now: Date, soundsOn: Bool) -> Bool {
        guard let markedAt else { return false }
        self.markedAt = nil
        let age = now.timeIntervalSince(markedAt)
        return soundsOn && age >= 0 && age <= Self.maxAge
    }
}

/// The two calls: `SignInWelcome.signedIn()` after a successful interactive sign-in marks it; `sessionReady()` when the
/// signed-in app is usable (Home drew — never on the deactivated, deleted-company or lapsed-subscription screens, which
/// replace Home) plays the chord, once, if that mark is under `SignInWelcomeGate.maxAge` old and sounds are on.
@MainActor
enum SignInWelcome {
    private static var gate = SignInWelcomeGate()

    /// Call only after a sign-in the person made on this phone has succeeded.
    static func signedIn(now: Date = Date()) {
        gate.markSignedIn(now: now)
    }

    /// Call when the signed-in session is usable. Does nothing without a fresh sign-in mark.
    static func sessionReady(defaults: UserDefaults = .standard, now: Date = Date()) {
        guard gate.take(now: now, soundsOn: FeedbackCenter.soundsEnabled(defaults)) else { return }
        WelcomeChordPlayer.shared.play()
    }
}
