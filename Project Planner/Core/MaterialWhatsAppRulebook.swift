//
//  MaterialWhatsAppRulebook.swift
//  Project Planner
//
//  The WhatsApp order message and the wa.me number come from the rulebook's
//  `materialWhatsAppRows` (web `lib/canonical`). Swift builds no message text
//  and normalises no phone number. Until the packed script exports that
//  function, `isAvailable` is false and the WhatsApp button stays hidden.
//

import Foundation

enum MaterialWhatsAppRulebook {
    static let functionName = "materialWhatsAppRows"

    /// True once the packed `canonical-business.js` exports `materialWhatsAppRows`.
    static var isAvailable: Bool {
        CanonicalBusinessEngine.exportKind(functionName) == "function"
    }

    struct Recipient: Equatable {
        var id: String
        var name: String
        var wholesalerName: String?
        var phone: String
    }

    struct Line: Equatable {
        var material: String
        var quantity: Int
        var unit: String
        var brand: String?
        var productCode: String?
        var notes: String?
        var lengthDisplay: String?
    }

    struct Input: Equatable {
        var requestType: MaterialOrderRequest.RequestType
        var organisationName: String
        var requestingUserName: String
        var jobNumber: String
        var projectName: String
        var projectAddress: String
        var deliveryAt: Date?
        var countryCode: String
        var materials: [Line]
        var recipients: [Recipient]
    }

    /// One row per recipient (`MaterialWhatsAppRow` in the script).
    struct Row: Equatable {
        var recipientId: String
        var message: String
        var ok: Bool
        var digits: String?
        var reason: String?
        var url: URL?
    }

    static func payload(for input: Input) -> [String: Any] {
        func optional(_ value: String?) -> Any {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? NSNull() : trimmed
        }
        return [
            // The script takes `quote` / `order`; the Swift raw values are capitalised.
            "requestType": input.requestType.rawValue.lowercased(),
            "organisationName": input.organisationName,
            "requestingUserName": input.requestingUserName,
            "jobNumber": input.jobNumber,
            "projectName": input.projectName,
            "projectAddress": input.projectAddress,
            "deliveryAt": input.deliveryAt.map { CanonicalBusinessEngine.isoString(from: $0) } ?? NSNull(),
            "countryCode": input.countryCode,
            "materials": input.materials.map { line -> [String: Any] in
                [
                    "material": line.material,
                    "quantity": line.quantity,
                    "unit": line.unit,
                    "brand": optional(line.brand),
                    "productCode": optional(line.productCode),
                    "notes": optional(line.notes),
                    "lengthDisplay": optional(line.lengthDisplay)
                ]
            },
            "recipients": input.recipients.map { recipient -> [String: Any] in
                [
                    "id": recipient.id,
                    "name": recipient.name,
                    "wholesalerName": optional(recipient.wholesalerName),
                    "phone": recipient.phone
                ]
            }
        ]
    }

    /// Nil when the script did not answer (not packed yet, or it threw).
    static func rows(for input: Input) -> [Row]? {
        guard isAvailable,
              let raw = CanonicalBusinessEngine.objectRows(function: functionName, payload: payload(for: input)) else {
            return nil
        }
        return raw.compactMap(row(from:))
    }

    static func row(from raw: [String: Any]) -> Row? {
        guard let recipientId = raw["recipientId"] as? String,
              let message = raw["message"] as? String else { return nil }
        let ok = (raw["ok"] as? Bool) ?? false
        return Row(
            recipientId: recipientId,
            message: message,
            ok: ok,
            digits: raw["digits"] as? String,
            reason: raw["reason"] as? String,
            url: (raw["url"] as? String).flatMap(URL.init(string:))
        )
    }
}
