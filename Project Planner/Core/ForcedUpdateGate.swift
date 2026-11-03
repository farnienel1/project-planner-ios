//
//  ForcedUpdateGate.swift
//  Project Planner
//
//  Forced update (RULEBOOK 1.12.0 §18): the one document `PLATFORM_CONFIG_APP_PATH` (`platformConfig/app`) is read at
//  launch and whenever the app returns to the foreground — signed out too (the rules allow that read) — and the
//  rulebook decides with `appUpdateRequired({ platform: 'ios', runningBuild: CFBundleVersion }, config)`. When it is
//  true the app shows a blocking "Update required" screen. A missing document, a failed read, an unreadable value or
//  an unanswered script never blocks.
//

import Foundation
import Combine
import FirebaseCore
import FirebaseFirestore

@MainActor
final class ForcedUpdateGate: ObservableObject {
    /// True only when `platformConfig/app` was read and `appUpdateRequired` says this build is too old.
    @Published private(set) var updateRequired = false

    /// `PLATFORM_CONFIG_APP_PATH`. Nil when the script did not answer (the check is then skipped).
    static var documentPath: String? { CanonicalBusinessEngine.platformConfigAppPath }

    /// This build's `CFBundleVersion` as a whole number, nil when it is not one.
    static var runningBuild: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// `appUpdateRequired` for this build against the `platformConfig/app` document as read (nil when missing).
    nonisolated static func blocks(running: Int?, config: [String: Any]?) -> Bool {
        CanonicalBusinessEngine.appUpdateRequired(runningBuild: running, config: config)
    }

    private var inFlight = false

    /// Reads `platformConfig/app` (server first, then cache). Any failure leaves the app usable.
    func check() async {
        #if DEBUG
        if UITestingMode.shouldSkipNetworkBootstrap { return }
        #endif
        guard FirebaseApp.app() != nil, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        guard let path = Self.documentPath else {
            NSLog("FORCED_UPDATE_CHECK_SKIPPED no PLATFORM_CONFIG_APP_PATH from the rulebook")
            return
        }
        let ref = Firestore.firestore().document(path)
        let snapshot: DocumentSnapshot?
        do {
            snapshot = try await ref.getDocument(source: .server)
        } catch {
            snapshot = try? await ref.getDocument(source: .cache)
            if snapshot == nil {
                NSLog("FORCED_UPDATE_CHECK_SKIPPED %@", error.localizedDescription)
            }
        }
        guard let snapshot, snapshot.exists else {
            updateRequired = false
            return
        }
        updateRequired = Self.blocks(running: Self.runningBuild, config: snapshot.data())
    }
}
