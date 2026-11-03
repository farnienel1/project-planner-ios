//
//  ForcedUpdateGate.swift
//  Project Planner
//
//  Forced update: `platformConfig/app.minimumIosBuild` (an Int build number, compared with this build's
//  `CFBundleVersion`) is read at launch and whenever the app returns to the foreground. When the running build is
//  lower, the app shows a blocking "Update required" screen. A missing document, a missing or unreadable field, a
//  read error or a build number that is not a whole number never blocks. App plumbing; no business rule.
//

import Foundation
import Combine
import FirebaseCore
import FirebaseFirestore

@MainActor
final class ForcedUpdateGate: ObservableObject {
    /// True only when `minimumIosBuild` was read and this build is lower.
    @Published private(set) var updateRequired = false

    static let documentPath = "platformConfig/app"
    static let fieldName = "minimumIosBuild"

    /// This build's `CFBundleVersion` as a whole number, nil when it is not one.
    static var runningBuild: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether `stored` (the field as read) asks for a newer build than `running`. Unknown values never block.
    nonisolated static func blocks(running: Int?, stored: Any?) -> Bool {
        guard let running else { return false }
        let minimum: Int?
        if let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            minimum = number.intValue
        } else if let text = stored as? String {
            minimum = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            minimum = nil
        }
        guard let minimum else { return false }
        return running < minimum
    }

    private var inFlight = false

    /// Reads the minimum build (server first, then cache). Any failure leaves the app usable.
    func check() async {
        #if DEBUG
        if UITestingMode.shouldSkipNetworkBootstrap { return }
        #endif
        guard FirebaseApp.app() != nil, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let ref = Firestore.firestore().document(Self.documentPath)
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
        updateRequired = Self.blocks(running: Self.runningBuild, stored: snapshot.data()?[Self.fieldName])
    }
}
