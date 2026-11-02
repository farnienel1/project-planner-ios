//
//  OfflinePartialUpdate.swift
//  Project Planner
//
//  Queued partial updates for the other RULEBOOK §2 "allowed offline" areas: annual leave requests,
//  the user's own profile fields and own notification toggles. The outbox stores the changed fields
//  only; replay writes them with `updateData` plus write metadata (never a merge-set of a stale copy).
//

import Foundation
import FirebaseFirestore

/// A JSON-safe Firestore field value for the outbox.
enum OfflineFieldValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case strings([String])
    case null
    /// `FieldValue.delete()` (only valid in an update).
    case delete

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "string": self = .string(try container.decode(String.self, forKey: .value))
        case "number": self = .number(try container.decode(Double.self, forKey: .value))
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "date": self = .date(try container.decode(Date.self, forKey: .value))
        case "strings": self = .strings(try container.decode([String].self, forKey: .value))
        case "delete": self = .delete
        default: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode("string", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode("number", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode("bool", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode("date", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .strings(let value):
            try container.encode("strings", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode("null", forKey: .kind)
        case .delete:
            try container.encode("delete", forKey: .kind)
        }
    }

    /// The value handed to the Firestore SDK.
    var firestoreValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .date(let value): return Timestamp(date: value)
        case .strings(let value): return value
        case .null: return NSNull()
        case .delete: return FieldValue.delete()
        }
    }
}

/// One queued partial update (or, for a new annual leave request, a create).
struct OfflinePartialUpdatePayload: Codable {
    /// Full document path, e.g. `users/{uid}` or `organizations/{orgId}/holidayBookings/{id}`.
    let documentPath: String
    /// Changed fields only. Dotted keys are allowed (they are written with `updateData`).
    var fields: [String: OfflineFieldValue]
    /// True only for a document that does not exist yet (a new leave request). Replayed with a set
    /// of these fields; dotted keys and `.delete` are not allowed then.
    var isCreate: Bool
    /// The signed-in user who queued it. Replay is dropped if someone else is signed in.
    let userId: String
}

enum OfflinePartialUpdateWriter {
    enum WriteError: LocalizedError {
        case signedInUserChanged
        case invalidPath

        var errorDescription: String? {
            switch self {
            case .signedInUserChanged: return "This change was made by another account on this device."
            case .invalidPath: return "This queued change has no valid destination."
            }
        }
    }

    /// Writes the queued fields with write metadata. Firestore errors are thrown unchanged.
    static func replay(_ payload: OfflinePartialUpdatePayload, db: Firestore, signedInUserId: String?) async throws {
        guard let signedInUserId, signedInUserId == payload.userId else { throw WriteError.signedInUserChanged }
        let segments = payload.documentPath.split(separator: "/")
        guard !segments.isEmpty, segments.count % 2 == 0 else { throw WriteError.invalidPath }
        let ref = db.document(payload.documentPath)
        var data: [String: Any] = [:]
        for (key, value) in payload.fields {
            if payload.isCreate, value == .delete { continue }
            data[key] = value.firestoreValue
        }
        data = WriteMetadata.stamped(data, userId: signedInUserId)
        if payload.isCreate {
            try await ref.setData(data, merge: true)
        } else {
            try await ref.updateData(data)
        }
    }
}
