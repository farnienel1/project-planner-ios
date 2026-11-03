//
//  Rulebook+CreateDocuments.swift
//  Project Planner
//
//  Rulebook 1.9.0 (docs/RULEBOOK.md §1, §11, §12, §13, §14): the shapes of documents created whole — invitations
//  (`invitationCreateFields`, `invitationUsedWriteFields`), organisations (`organizationCreateFields`), the private
//  tax ids document (`taxIdsDocumentFields`) and inbox rows (`notificationCreateFields`, with `relatedId` from
//  `notificationRelatedId`). Web `lib/canonical/createDocuments.ts` and `recordsDocuments.ts`, called through
//  `CanonicalBusinessEngine`; nothing is decided here.
//
//  Instants pass through the script as given, so Swift sends a placeholder string for each SDK value (a Timestamp,
//  `FieldValue.serverTimestamp()`) and swaps it back in the answer (`ScriptPlaceholders`). A conversion, not a rule.
//

import Foundation
import FirebaseFirestore

/// Native Firestore values the script cannot carry, sent as unique placeholder strings and restored afterwards.
nonisolated struct ScriptPlaceholders {
    private var values: [String: Any] = [:]

    init() {}

    /// A placeholder for `value` (any Firestore value: Timestamp, FieldValue, map with them, …).
    mutating func token(_ name: String, _ value: Any) -> String {
        let key = "__pp_native_\(name)_\(values.count)__"
        values[key] = value
        return key
    }

    /// `json` with every placeholder string replaced by its native value (maps and lists recursively).
    func restore(_ json: Any) -> Any {
        if let text = json as? String, let native = values[text] { return native }
        if let map = json as? [String: Any] { return map.mapValues { restore($0) } }
        if let list = json as? [Any] { return list.map { restore($0) } }
        return json
    }

    func restoreMap(_ json: [String: Any]) -> [String: Any] {
        (restore(json) as? [String: Any]) ?? json
    }
}

extension CanonicalBusinessEngine {
    // MARK: invitations/{id}

    /// `invitationCreateFields(input)`: the whole new `invitations/{id}` document, or nil without an email or
    /// organisation (or when the script did not answer). `createdAt` is a native value (Timestamp or server
    /// timestamp); `input` keys are the script's (`email`, `organizationId`, `invitedBy`, `firstName`, `surname`,
    /// `employmentType`, `permissions`, `mobileNumber`, `assignedManagerUserIds`, `hasNoLineManager`, `payBasis`,
    /// `dayRate`, `hourlyRate`, `tradeTypePreset`, `tradeTypeCustom`, `timesheetsEnabled`, the leave figures).
    nonisolated static func invitationCreateFields(_ input: [String: Any], createdAt: Any) -> [String: Any]? {
        var placeholders = ScriptPlaceholders()
        var json = peopleDocumentJSON(input)
        json["createdAt"] = placeholders.token("createdAt", createdAt)
        guard let fields = callJSON("invitationCreateFields", arguments: [json]) as? [String: Any] else { return nil }
        return placeholders.restoreMap(fields)
    }

    /// `invitationUsedWriteFields(usedAt).set`: `{ isUsed: true, usedAt }` as a partial update.
    nonisolated static func invitationUsedWriteFields(usedAt: Any) -> [String: Any]? {
        var placeholders = ScriptPlaceholders()
        let token = placeholders.token("usedAt", usedAt)
        guard let result = callJSON("invitationUsedWriteFields", arguments: [token]) as? [String: Any],
              let set = result["set"] as? [String: Any] else { return nil }
        return placeholders.restoreMap(set)
    }

    // MARK: organizations/{orgId}

    /// `organizationCreateFields(input)`: the whole new `organizations/{orgId}` document. `setupFields` and
    /// `settings` are native maps (Timestamps and FieldValues are carried through placeholders); `createdAt` /
    /// `updatedAt` are native values. Nil without a name or creator, or when the script did not answer.
    nonisolated static func organizationCreateFields(
        name: String,
        creatorUserId: String,
        planKey: String?,
        createdAt: Any,
        updatedAt: Any? = nil,
        setupFields: [String: Any] = [:],
        settings: [String: Any] = [:]
    ) -> [String: Any]? {
        var placeholders = ScriptPlaceholders()
        func carry(_ value: Any, _ name: String) -> Any {
            switch value {
            case is String, is NSNumber, is NSNull:
                return value
            case let map as [String: Any]:
                var out: [String: Any] = [:]
                for (key, inner) in map { out[key] = carry(inner, "\(name).\(key)") }
                return out
            case let list as [Any]:
                return list.enumerated().map { carry($0.element, "\(name).\($0.offset)") }
            default:
                return placeholders.token(name, value)
            }
        }
        var input: [String: Any] = [
            "name": name,
            "creatorUserId": creatorUserId,
            "createdAt": placeholders.token("createdAt", createdAt),
            "setupFields": carry(setupFields, "setup"),
            "settings": carry(settings, "settings"),
        ]
        if let planKey { input["planKey"] = planKey }
        if let updatedAt { input["updatedAt"] = placeholders.token("updatedAt", updatedAt) }
        guard JSONSerialization.isValidJSONObject(input),
              let fields = callJSON("organizationCreateFields", arguments: [input]) as? [String: Any] else { return nil }
        return placeholders.restoreMap(fields)
    }

    // MARK: users/{uid}/private/taxIds

    /// `taxIdsDocumentFields({ utrNumber, vatNumber, updatedByUserId })`: the whole private tax ids document
    /// (`{ utrNumber, vatNumber, updatedByUserId }`; blank clears). Nil when refused (no user, a value too long) or
    /// when the script did not answer. The caller adds its `updatedAt` and writes it whole (a set without merge).
    nonisolated static func taxIdsDocumentFields(utrNumber: String?, vatNumber: String?, updatedByUserId: String) -> [String: Any]? {
        let input: [String: Any] = [
            "utrNumber": utrNumber.map { $0 as Any } ?? NSNull(),
            "vatNumber": vatNumber.map { $0 as Any } ?? NSNull(),
            "updatedByUserId": updatedByUserId,
        ]
        return callJSON("taxIdsDocumentFields", arguments: [input]) as? [String: Any]
    }

    // MARK: Inbox rows

    /// `NOTIFICATION_RELATED_ID[type]`: the kind of id a type's `relatedId` names (`job`, `holidayBooking`, …,
    /// `none`). Nil for an unknown type.
    nonisolated static func notificationRelatedIdKind(_ type: String) -> String? {
        constant("NOTIFICATION_RELATED_ID", as: [String: String].self)?[type]
    }

    /// `notificationRelatedId(type, ids)`: the `relatedId` to write for this type, picked from `ids`
    /// (`holidayBookingId`, `jobId`, `variationId`, `clientId`, `userId`, `taskId`, `deadlineId`, `issueId`,
    /// `warningKey`, `paymentDayKey`, `ideaId`) in stored case. Nil when the type carries none or the id is missing —
    /// never a random id.
    nonisolated static func notificationRelatedId(type: String, ids: [String: String]) -> String? {
        callJSON("notificationRelatedId", arguments: [type, ids]) as? String
    }

    /// `notificationCreateFields(input, stored)`: the new inbox row (`set`), or nil when a row with this id is already
    /// stored (created once; its read state is never reset), when there is no `userId` (not an inbox row) or no type,
    /// or when the script did not answer. `createdAt` / `deepLinkWeekStart` / `serverTimestamp` are native values.
    nonisolated static func notificationCreateFields(
        organizationId: String,
        type: String,
        title: String,
        message: String,
        userId: String?,
        actorUserId: String?,
        relatedId: String?,
        requiresPermission: String?,
        deepLinkUserId: String?,
        deepLinkWeekStart: Any?,
        dayKey: String?,
        catalogue: String?,
        createdAt: Any,
        serverTimestamp: Any? = nil,
        storedExists: Bool
    ) -> [String: Any]? {
        var placeholders = ScriptPlaceholders()
        func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        var input: [String: Any] = [
            "organizationId": organizationId,
            "type": type,
            "title": title,
            "message": message,
            "userId": optional(userId),
            "actorUserId": optional(actorUserId),
            "relatedId": optional(relatedId),
            "requiresPermission": optional(requiresPermission),
            "deepLinkUserId": optional(deepLinkUserId),
            "dayKey": optional(dayKey),
            "catalogue": optional(catalogue),
            "createdAt": placeholders.token("createdAt", createdAt),
        ]
        if let deepLinkWeekStart { input["deepLinkWeekStart"] = placeholders.token("deepLinkWeekStart", deepLinkWeekStart) }
        // RULEBOOK 1.16.0 §13: a due-now row carries the server time (`FieldValue.serverTimestamp()`); only a scheduled
        // type (`SCHEDULED_NOTIFICATION_TYPES`) keeps its own `createdAt` (`notificationCreatedAtIsServerTime`).
        if let serverTimestamp { input["serverTimestamp"] = placeholders.token("serverTimestamp", serverTimestamp) }
        let stored: Any = storedExists ? (["exists": true] as [String: Any]) as Any : NSNull() as Any
        guard let result = callJSON("notificationCreateFields", arguments: [input, stored]) as? [String: Any],
              let set = result["set"] as? [String: Any] else { return nil }
        return placeholders.restoreMap(set)
    }
}

/// Every `invitations/{id}` write (RULEBOOK 1.9.0 §11): created once with `invitationCreateFields`, marked used with
/// `invitationUsedWriteFields` as a partial update. Callers build the same draft map as before; only the fields the
/// rule names are written. App plumbing over the rulebook.
nonisolated enum InvitationDocument {
    /// The fields to create, from a draft map (keys as the rulebook input names them). Throws when the rule refuses
    /// it (no email or organisation) or the script did not answer — nothing is written then.
    static func createFields(from draft: [String: Any], createdAt: Any = Timestamp(date: Date())) throws -> [String: Any] {
        var input = draft
        input.removeValue(forKey: "createdAt")
        input.removeValue(forKey: "isUsed")
        guard let fields = CanonicalBusinessEngine.invitationCreateFields(input, createdAt: createdAt) else {
            throw CanonicalWriteUnavailableError(function: "invitationCreateFields")
        }
        return fields
    }

    /// `{ isUsed: true, usedAt }` for an `updateData` (never a rewrite of the invitation).
    static func usedFields(usedAt: Any = FieldValue.serverTimestamp()) -> [String: Any] {
        CanonicalBusinessEngine.invitationUsedWriteFields(usedAt: usedAt) ?? ["isUsed": true, "usedAt": usedAt]
    }
}
