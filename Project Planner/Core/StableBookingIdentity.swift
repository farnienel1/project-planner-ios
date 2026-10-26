//
//  StableBookingIdentity.swift
//  Project Planner
//
//  A booking may store ids that are not UUIDs (web books a person with no operative record under
//  their Firebase user id). Swift models hold UUIDs, so such an id gets the same UUID on every read
//  while the stored string is kept beside it. This is identity only, not a business rule.
//

import CryptoKit
import Foundation

nonisolated enum StableBookingIdentity {
    /// The UUID itself when `raw` is one; otherwise a name-based UUID from SHA-256 of the trimmed string.
    static func uuid(for raw: String) -> UUID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = UUID(uuidString: trimmed) { return direct }
        var bytes = Array(SHA256.hash(data: Data("pp-booking-id:\(trimmed)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The stored string when it is not a UUID, so it can be written back and matched as-is.
    static func storedIdIfNotUUID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed) == nil && !trimmed.isEmpty ? trimmed : nil
    }

}

/// What the last booking read did with each document. `refused > 0` means some stored bookings are
/// not on screen, so coverage results from that read are incomplete.
nonisolated struct BookingDecodeReport: Equatable, Sendable {
    let total: Int
    let refused: Int
    let repaired: Int
    /// The canonical script did not run, so nothing was read.
    let scriptFailed: Bool
}

extension Notification.Name {
    /// The live bookings listener reported an error; on-screen bookings may be stale.
    static let bookingsListenerFailed = Notification.Name("bookingsListenerFailed")
}
