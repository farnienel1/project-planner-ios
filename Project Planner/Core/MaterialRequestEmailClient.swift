//
//  MaterialRequestEmailClient.swift
//  Project Planner
//
//  Material quote and order emails through the authenticated `sendEmail` Cloud Function
//  (web docs/EMAIL_FUNCTION.md, template `material_request`). Replaces the open
//  `sendProjectPlannerEmail` call that rendered HTML on the phone and sent the sender a
//  separate "Copy:" email.
//
//  One email per recipient: the recipient in To, the signed-in user in CC (`ccCaller`), sent as
//  "<user> via Project Planner" (`fromCaller`) with Reply-To the user. The function renders the
//  subject and body with the same builder web uses and takes the sender's name, email, company and
//  logo from the verified caller and organisation, never from this request. The phone never sends
//  HTML, a From name, a Reply-To or a CC address.
//
//  `sendProjectPlannerEmail` stays deployed for older builds (launch checklist 3.2 removes it once
//  `minimumIosBuild` is raised).
//

import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation

protocol MaterialRequestEmailTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionMaterialRequestEmailTransport: MaterialRequestEmailTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// What the function reported for a send. `messageIds` are the Resend ids (one per recipient that went).
struct MaterialRequestEmailResult: Equatable {
    var sentCount: Int
    var messageIds: [String]
    /// Recipients the provider refused while others went (`sent: false` with a 200).
    var failed: [String]
    /// CC addresses the function put on the messages. Empty when the deployed function ignored `ccCaller`.
    var cc: [String]
    var ccSupported: Bool
}

enum MaterialRequestEmailError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case timedOut
    /// The function answered with an error status; `reason` is its `error` text.
    case refused(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Email not sent: the email service is not configured (missing Firebase project)."
        case .notSignedIn:
            return "Email not sent: sign in again and retry."
        case .timedOut:
            // Same wording as web `sendProjectPlannerEmail` (lib/email/resendClient.ts).
            return "The email service did not answer in time. Check your sent items before sending again."
        case .refused(_, let reason):
            return "Email not sent: \(reason)"
        }
    }
}

/// The `sendEmail` request body for a material quote or order. Pure, so the payload is tested without a network.
enum MaterialRequestEmailPayload {
    static let template = "material_request"
    static let functionName = "sendEmail"
    static let appCheckHeader = "X-Firebase-AppCheck"
    static let requestTimeout: TimeInterval = 20

    /// `quote` / `order`, as the function and web send it.
    static func requestTypeValue(_ type: MaterialOrderRequest.RequestType) -> String {
        switch type {
        case .quote: return "quote"
        case .order: return "order"
        }
    }

    /// Each wholesaler contact once (trimmed, lower case, first spelling wins), never the sender:
    /// the sender is copied on the same message by `ccCaller`, not sent a separate email.
    static func recipientEmails(contacts: [WholesalerContact], senderEmail: String) -> [String] {
        let sender = normalizedEmail(senderEmail)
        var seen = Set<String>()
        var out: [String] = []
        for contact in contacts {
            let email = normalizedEmail(contact.email)
            guard !email.isEmpty, email != sender, !seen.contains(email) else { continue }
            seen.insert(email)
            out.append(email)
        }
        return out
    }

    /// The material lines, same keys as web `MaterialsSendListSheet` / the function's `parseMaterialLines`.
    static func materialLines(_ items: [MaterialItem]) -> [[String: Any]] {
        items.map { item in
            var line: [String: Any] = [
                "material": item.material,
                "quantity": item.quantity,
                "unit": item.unit.rawValue,
            ]
            if let brand = trimmed(item.brand) { line["brand"] = brand }
            if let productCode = trimmed(item.productCode) { line["productCode"] = productCode }
            if let notes = trimmed(item.notes) { line["notes"] = notes }
            if let length = trimmed(item.formattedLengthSpecification) { line["lengthDisplay"] = length }
            return line
        }
    }

    /// `data` for template `material_request`. `includesDeliveryRequired` is the rulebook's
    /// `materialOrderIncludesDeliveryRequired(requestType)` (orders only).
    static func data(for request: MaterialOrderRequest, includesDeliveryRequired: Bool) -> [String: Any] {
        var data: [String: Any] = [
            "requestType": requestTypeValue(request.requestType),
            "jobNumber": request.projectNumber,
            "siteName": request.projectName,
            "siteAddress": request.siteAddress,
            "materials": materialLines(request.materials),
            "sendAsPlainText": request.sendAsPlainText,
            "fromCaller": true,
            "ccCaller": true,
        ]
        if includesDeliveryRequired, let at = request.requiredDeliveryDate {
            data["deliveryRequiredAt"] = isoString(at)
        }
        if let phone = trimmed(request.senderPhone) {
            data["senderPhone"] = phone
        }
        return data
    }

    static func body(
        organizationId: String,
        request: MaterialOrderRequest,
        senderEmail: String,
        includesDeliveryRequired: Bool
    ) -> [String: Any] {
        [
            "orgId": organizationId,
            "template": template,
            "to": recipientEmails(contacts: request.recipientContacts, senderEmail: senderEmail),
            "data": data(for: request, includesDeliveryRequired: includesDeliveryRequired),
        ]
    }

    static func functionURL(projectId: String) -> URL? {
        URL(string: "https://us-central1-\(projectId).cloudfunctions.net/\(functionName)")
    }

    static func urlRequest(url: URL, body: [String: Any], idToken: String, appCheckToken: String?) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        if let appCheckToken, !appCheckToken.isEmpty {
            request.setValue(appCheckToken, forHTTPHeaderField: appCheckHeader)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Maps the function's answer. 200 with at least one message is a send (some recipients may be in `failed`);
    /// any other status is an error carrying the function's `error` text.
    static func parseResponse(statusCode: Int, data: Data) -> Result<MaterialRequestEmailResult, MaterialRequestEmailError> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard statusCode == 200 else {
            let raw = (json["error"] as? String) ?? (json["message"] as? String) ?? ""
            let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.refused(
                status: statusCode,
                reason: reason.isEmpty ? "the email service answered \(statusCode)" : reason
            ))
        }
        let results = json["results"] as? [[String: Any]] ?? []
        let ids = results.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        var cc: [String] = []
        for row in results {
            for address in (row["cc"] as? [String] ?? []) where !cc.contains(address) {
                cc.append(address)
            }
        }
        let sentCount = (json["sentCount"] as? Int) ?? results.count
        guard sentCount > 0 else {
            return .failure(.refused(status: statusCode, reason: "the email service did not confirm delivery"))
        }
        return .success(MaterialRequestEmailResult(
            sentCount: sentCount,
            messageIds: ids,
            failed: json["failed"] as? [String] ?? [],
            cc: cc,
            ccSupported: json["ccSupported"] as? Bool ?? false
        ))
    }

    private static func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

enum MaterialRequestEmailClient {
    /// Sends one `material_request` call for every recipient. Transport errors (offline) are rethrown as they are,
    /// so `OfflineWriteSupport.shouldQueue` still queues the send.
    static func send(
        _ request: MaterialOrderRequest,
        organizationId: String,
        senderEmail: String,
        transport: MaterialRequestEmailTransport = URLSessionMaterialRequestEmailTransport()
    ) async throws -> MaterialRequestEmailResult {
        guard let projectId = FirebaseApp.app()?.options.projectID,
              let url = MaterialRequestEmailPayload.functionURL(projectId: projectId) else {
            throw MaterialRequestEmailError.notConfigured
        }
        guard let user = Auth.auth().currentUser else { throw MaterialRequestEmailError.notSignedIn }
        let idToken: String
        do {
            idToken = try await user.getIDToken()
        } catch {
            throw MaterialRequestEmailError.notSignedIn
        }
        // Not enforced by the function yet; an unavailable token is left out rather than blocking the send.
        let appCheckToken = try? await AppCheck.appCheck().token(forcingRefresh: false).token
        let includesDeliveryRequired = CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired(
            MaterialRequestEmailPayload.requestTypeValue(request.requestType)
        ) ?? (request.requestType == .order)
        let body = MaterialRequestEmailPayload.body(
            organizationId: organizationId,
            request: request,
            senderEmail: senderEmail,
            includesDeliveryRequired: includesDeliveryRequired
        )
        let urlRequest = try MaterialRequestEmailPayload.urlRequest(
            url: url,
            body: body,
            idToken: idToken,
            appCheckToken: appCheckToken
        )
        return try await perform(urlRequest, transport: transport)
    }

    static func perform(_ urlRequest: URLRequest, transport: MaterialRequestEmailTransport) async throws -> MaterialRequestEmailResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw MaterialRequestEmailError.timedOut
        }
        guard let http = response as? HTTPURLResponse else {
            throw MaterialRequestEmailError.refused(status: 0, reason: "the email service gave no answer")
        }
        return try MaterialRequestEmailPayload.parseResponse(statusCode: http.statusCode, data: data).get()
    }
}
