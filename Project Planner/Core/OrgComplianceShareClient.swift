//
//  OrgComplianceShareClient.swift
//  Project Planner
//
//  RULEBOOK 1.83.0 §31 (owner decision 24 Nov): 7-day read-only share links for insurance & accreditations, made,
//  listed and turned off by the web server (`/api/compliance/share-links`, `/api/compliance/share-links/revoke`) with
//  the signed-in admin's ID token. Who may do it is decided by the security rules on the server; this file only calls
//  the routes and maps the answers. Redirects are never followed (a `www` redirect would drop the bearer token).
//

import Foundation
import FirebaseAuth

nonisolated struct OrgComplianceShareLinkRow: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let documents: [String]
    let createdAtMs: Double?
    let expiresAtMs: Double?
    let openCount: Int
    let lastOpenedAtMs: Double?
    /// `active`, `expired`, `revoked` (`orgComplianceShareLinkState`, worked out on the server).
    let state: String
    /// Active, but its creator is no longer an active admin here, so the share page refuses it
    /// (`orgComplianceShareCreatorActive`, worked out by the web list route). Missing from an older server: false.
    let creatorStopped: Bool?

    /// Shown on an active link whose creator is no longer an active admin (same text as web).
    static let creatorStoppedText = "Stopped — creator is no longer an admin"

    /// Why a listed link no longer works, or nil when it works.
    var statusText: String? {
        state == "active" && creatorStopped == true ? Self.creatorStoppedText : nil
    }
}

nonisolated struct OrgComplianceCreatedShareLink: Decodable, Hashable, Sendable {
    let id: String
    let url: String
    let expiresAtMs: Double
    let documentCount: Int
}

nonisolated struct OrgComplianceShareError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum OrgComplianceShareClient {
    static let requestTimeout: TimeInterval = 20

    /// `https://projectplanner.us/api/compliance/<path>` (never `www`, whose redirect drops the bearer token).
    static func endpointURL(_ path: String, baseURL: URL? = URL(string: AppBranding.webAppBaseURL)) -> URL? {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        if components.host?.lowercased() == "www.projectplanner.us" { components.host = "projectplanner.us" }
        components.path = "/api/compliance/" + path
        components.query = nil
        return components.url
    }

    private static func request(_ url: URL, method: String, body: [String: Any]?) async throws -> Data {
        guard let user = Auth.auth().currentUser else { throw OrgComplianceShareError(message: "You need to sign in again.") }
        let token = try await user.getIDToken()
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSessionAccountDeletionTransport().data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OrgComplianceShareError(message: message ?? "That did not work. Try again.")
        }
        return data
    }

    /// Make a link for the ticked documents (`section:id` refs, checked first with `orgComplianceShareSelection`).
    static func create(organizationId: String, documents: [String]) async throws -> OrgComplianceCreatedShareLink {
        guard let url = endpointURL("share-links") else { throw OrgComplianceShareError(message: "That did not work. Try again.") }
        let data = try await request(url, method: "POST", body: ["organizationId": organizationId, "documents": documents])
        return try JSONDecoder().decode(OrgComplianceCreatedShareLink.self, from: data)
    }

    static func list(organizationId: String) async throws -> [OrgComplianceShareLinkRow] {
        guard var components = endpointURL("share-links").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw OrgComplianceShareError(message: "That did not work. Try again.")
        }
        components.queryItems = [URLQueryItem(name: "organizationId", value: organizationId)]
        guard let url = components.url else { throw OrgComplianceShareError(message: "That did not work. Try again.") }
        struct Body: Decodable { let links: [OrgComplianceShareLinkRow]? }
        let data = try await request(url, method: "GET", body: nil)
        return try JSONDecoder().decode(Body.self, from: data).links ?? []
    }

    static func revoke(organizationId: String, id: String) async throws {
        guard let url = endpointURL("share-links/revoke") else { throw OrgComplianceShareError(message: "That did not work. Try again.") }
        _ = try await request(url, method: "POST", body: ["organizationId": organizationId, "id": id])
    }
}
