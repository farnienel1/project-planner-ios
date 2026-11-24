//
//  ClientErrorReporter.swift
//  Project Planner
//
//  RULEBOOK 1.84.0 §32 (owner decision D7; review of web #448): pseudonymous error reports to `clientErrors/{id}`.
//  A report never holds message text: the error class and code (`kind`), the file and function that logged it
//  (`where`), the route, the build, a known-message key (`other` unless the message is exactly a fixed constant) and a
//  SHA-256 of the message. The fields, the key, the document id, the throttle and the next slot are the rulebook's
//  (`clientErrorCreateFields`, `clientErrorHashInput`, `clientErrorDocId`, `clientErrorThrottle`,
//  `clientErrorSignature`, `clientErrorNextSlot`); this file only hashes (CryptoKit SHA-256) and writes. At most 20
//  reports per person per UTC day (the security rules enforce it from the document id), the same error once per app
//  session, only while signed in. Never throws, never reports its own failures. Web is
//  `lib/clientErrors/reportClientError.ts`.
//
//  Sources: `caught` — an error line the app already logged (`logAndReportError`); `uncaught` — an Objective-C
//  exception that ends the app, kept on the device and sent from a background task on the next launch (or after
//  sign-in).
//

import CryptoKit
import Foundation
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Prints `message` exactly as before and sends a report of where it was logged (never its text; rulebook §32).
nonisolated func logAndReportError(_ message: String, file: String = #fileID, function: String = #function) {
    print(message)
    ClientErrorReporter.report(
        source: "caught", kind: "LoggedError", code: nil, message: message, file: file, function: function
    )
}

nonisolated enum ClientErrorReporter {
    private static let stateKey = "pp.clientErrors.state"
    static let pendingUncaughtKey = "pp.clientErrors.pendingUncaught"
    nonisolated(unsafe) private static var sessionSent: [String] = []
    nonisolated(unsafe) private static var preparing = false
    nonisolated(unsafe) private static var previousHandler: (@convention(c) (NSException) -> Void)?
    private static let lock = NSLock()

    static var build: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return number.isEmpty ? version : "\(version) (\(number))"
    }

    /// Lower-case hex SHA-256 of `text` (the document id's hash and the message hash; the rules recompute the first).
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Installs the uncaught-exception hook (chained to any handler installed before it) and sends a report a
    /// previous crash left, from a background task. Call once at launch.
    static func install() {
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // Only the exception's class name is kept (its reason is free text).
            let defaults = UserDefaults.standard
            defaults.set(exception.name.rawValue, forKey: ClientErrorReporter.pendingUncaughtKey)
            defaults.synchronize()
            ClientErrorReporter.previousHandler?(exception)
        }
        sendPendingUncaughtInBackground()
    }

    /// Sends the report a crash left on the device, off the main thread, once someone is signed in. Also called
    /// after sign-in.
    static func sendPendingUncaughtInBackground() {
        Task.detached(priority: .utility) {
            guard let name = UserDefaults.standard.string(forKey: pendingUncaughtKey),
                  Auth.auth().currentUser != nil else { return }
            UserDefaults.standard.removeObject(forKey: pendingUncaughtKey)
            report(source: "uncaught", kind: name, code: nil, message: name, file: "NSException", function: "uncaught")
        }
    }

    /// One report. Dropped when signed out, over the day's limit or already sent this session.
    static func report(source: String, kind: String, code: String?, message: String, file: String, function: String) {
        guard let user = Auth.auth().currentUser else { return }
        lock.lock()
        if preparing { lock.unlock(); return }
        preparing = true
        lock.unlock()

        var prepared: (id: String, hash: String, slot: Int, data: [String: Any])?
        do {
            defer { lock.lock(); preparing = false; lock.unlock() }
            let nowMs = Date().timeIntervalSince1970 * 1000
            var input: [String: Any] = [
                "platform": "ios",
                "source": source,
                "name": kind,
                "message": message,
                "messageHash": sha256Hex(message),
                "file": file,
                "function": function,
                "route": "/ios",
                "build": build,
                "organizationId": OrganizationRulebookContext.organizationId ?? "",
                "nowMs": nowMs,
            ]
            if let code { input["code"] = code }
            guard let fields = CanonicalBusinessEngine.callJSON("clientErrorCreateFields", arguments: [input]) as? [String: Any],
                  let dayIndex = (fields["dayIndex"] as? NSNumber)?.intValue,
                  let expireAtMs = (fields["expireAtMs"] as? NSNumber)?.doubleValue,
                  let signature = CanonicalBusinessEngine.callJSON("clientErrorSignature", arguments: [fields]) as? String
            else { return }

            var stored = UserDefaults.standard.dictionary(forKey: stateKey) ?? [:]
            if (stored["uid"] as? String) != user.uid { stored = [:] }
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
            UserDefaults.standard.set(
                ["uid": user.uid, "dayIndex": dayIndex, "used": (next["used"] as? NSNumber)?.intValue ?? 0],
                forKey: stateKey
            )
            let hash = sha256Hex(CanonicalBusinessEngine.callJSON("clientErrorHashInput", arguments: [user.uid, dayIndex]) as? String ?? "")
            guard let id = CanonicalBusinessEngine.callJSON("clientErrorDocId", arguments: [hash, slot]) as? String else { return }
            var data = fields
            data.removeValue(forKey: "expireAtMs")
            data["dayIndex"] = dayIndex
            data["createdAt"] = FieldValue.serverTimestamp()
            data["expireAt"] = Timestamp(date: Date(timeIntervalSince1970: expireAtMs / 1000))
            prepared = (id, hash, slot, data)
        }
        guard let prepared else { return }
        write(id: prepared.id, hash: prepared.hash, slot: prepared.slot, data: prepared.data, uid: user.uid)
    }

    /// Creates the report; when the slot is already used (refused: the counter on this device was lost), tries the
    /// next slot (`clientErrorNextSlot`) up to 19. Firestore keeps an offline write queued; nothing waits on it.
    private static func write(id: String, hash: String, slot: Int, data: [String: Any], uid: String) {
        Firestore.firestore().collection("clientErrors").document(id).setData(data) { error in
            guard let error = error as NSError?,
                  error.domain == FirestoreErrorDomain,
                  error.code == FirestoreErrorCode.permissionDenied.rawValue,
                  let nextSlot = (CanonicalBusinessEngine.callJSON("clientErrorNextSlot", arguments: [slot]) as? NSNumber)?.intValue,
                  let nextId = CanonicalBusinessEngine.callJSON("clientErrorDocId", arguments: [hash, nextSlot]) as? String
            else { return }
            if var stored = UserDefaults.standard.dictionary(forKey: stateKey), (stored["uid"] as? String) == uid {
                stored["used"] = max((stored["used"] as? NSNumber)?.intValue ?? 0, nextSlot + 1)
                UserDefaults.standard.set(stored, forKey: stateKey)
            }
            write(id: nextId, hash: hash, slot: nextSlot, data: data, uid: uid)
        }
    }
}
