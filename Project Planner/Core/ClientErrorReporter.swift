//
//  ClientErrorReporter.swift
//  Project Planner
//
//  RULEBOOK 1.84.0 §32 (owner decision D7): anonymous error reports to `clientErrors/{id}`. The fields, the sanitiser
//  (no emails, ids, URL queries), the document id and the throttle are the rulebook's (`clientErrorCreateFields`,
//  `clientErrorHashInput`, `clientErrorDocId`, `clientErrorThrottle`, `clientErrorSignature`); this file only hashes
//  (CryptoKit SHA-256) and writes. At most 20 reports per person per UTC day (the security rules enforce it from the
//  document id), the same error once per app session, only while signed in. Never throws, never reports its own
//  failures. Web is `lib/clientErrors/reportClientError.ts`.
//
//  Sources: `caught` — an error the app already logged (`logAndReportError`, the old `print("❌ …")` lines);
//  `uncaught` — an Objective-C exception that ends the app, kept on the device and sent on the next launch once
//  someone is signed in.
//

import CryptoKit
import Foundation
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Prints `message` exactly as before and sends it, sanitised, as a `caught` error report (rulebook §32).
nonisolated func logAndReportError(_ message: String) {
    print(message)
    ClientErrorReporter.report(source: "caught", message: message)
}

nonisolated enum ClientErrorReporter {
    private static let stateKey = "pp.clientErrors.state"
    private static let pendingUncaughtKey = "pp.clientErrors.pendingUncaught"
    nonisolated(unsafe) private static var sessionSent: [String] = []
    nonisolated(unsafe) private static var reporting = false
    private static let lock = NSLock()

    static var build: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return number.isEmpty ? version : "\(version) (\(number))"
    }

    /// Lower-case hex SHA-256 of `text` (the document id's hash; the security rules recompute it).
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Installs the uncaught-exception hook and sends a report a previous crash left. Call once at launch.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")"
            UserDefaults.standard.set(text, forKey: "pp.clientErrors.pendingUncaught")
        }
        sendPendingUncaught()
    }

    /// Sends the report a crash left on the device, once someone is signed in.
    static func sendPendingUncaught() {
        guard let text = UserDefaults.standard.string(forKey: pendingUncaughtKey), Auth.auth().currentUser != nil else { return }
        UserDefaults.standard.removeObject(forKey: pendingUncaughtKey)
        report(source: "uncaught", message: text)
    }

    /// One report. `source`: caught or uncaught. Dropped when signed out, over the day's limit or already sent.
    static func report(source: String, message: String, route: String? = nil) {
        guard let user = Auth.auth().currentUser else { return }
        lock.lock()
        if reporting { lock.unlock(); return }
        reporting = true
        lock.unlock()
        defer { lock.lock(); reporting = false; lock.unlock() }

        let nowMs = Date().timeIntervalSince1970 * 1000
        guard let fields = CanonicalBusinessEngine.callJSON("clientErrorCreateFields", arguments: [[
            "platform": "ios",
            "source": source,
            "message": message,
            "route": route ?? "/ios",
            "build": build,
            "organizationId": OrganizationRulebookContext.organizationId ?? "",
            "nowMs": nowMs,
        ]]) as? [String: Any],
            let dayIndex = (fields["dayIndex"] as? NSNumber)?.intValue,
            let expireAtMs = (fields["expireAtMs"] as? NSNumber)?.doubleValue,
            let signature = CanonicalBusinessEngine.callJSON("clientErrorSignature", arguments: [fields]) as? String
        else { return }

        var stored = (UserDefaults.standard.dictionary(forKey: stateKey) ?? [:])
        let storedUid = stored["uid"] as? String
        if storedUid != user.uid { stored = [:] }
        let state: [String: Any] = [
            "dayIndex": (stored["dayIndex"] as? NSNumber)?.intValue ?? dayIndex,
            "used": (stored["used"] as? NSNumber)?.intValue ?? 0,
            "sent": sessionSent,
        ]
        guard let decision = CanonicalBusinessEngine.callJSON(
            "clientErrorThrottle",
            arguments: [state, ["dayIndex": dayIndex, "signature": signature]]
        ) as? [String: Any],
            let next = decision["state"] as? [String: Any]
        else { return }
        sessionSent = (next["sent"] as? [String]) ?? sessionSent
        guard (decision["send"] as? Bool) == true, let slot = (decision["slot"] as? NSNumber)?.intValue else { return }
        UserDefaults.standard.set(["uid": user.uid, "dayIndex": dayIndex, "used": (next["used"] as? NSNumber)?.intValue ?? 0], forKey: stateKey)

        let hash = sha256Hex(CanonicalBusinessEngine.callJSON("clientErrorHashInput", arguments: [user.uid, dayIndex]) as? String ?? "")
        guard let id = CanonicalBusinessEngine.callJSON("clientErrorDocId", arguments: [hash, slot]) as? String else { return }
        var data = fields
        data.removeValue(forKey: "expireAtMs")
        data["dayIndex"] = dayIndex
        data["createdAt"] = FieldValue.serverTimestamp()
        data["expireAt"] = Timestamp(date: Date(timeIntervalSince1970: expireAtMs / 1000))
        Firestore.firestore().collection("clientErrors").document(id).setData(data) { _ in
            // A refused or failed report is dropped: it must never cause another report.
        }
    }
}
