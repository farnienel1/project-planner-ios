//
//  AppEmailClient.swift
//  Project Planner
//
//  Every email the iPhone sends goes through the authenticated `sendEmail` Cloud Function with the signed-in
//  person's ID token and one of its fixed templates (web docs/EMAIL_FUNCTION.md "iOS request contract"):
//  `invite_setup`, `password_reset_link`, `timesheet_export`, `leave_cancelled` (here) and `material_request`
//  (`MaterialRequestEmailClient`). The function renders the subject and body, chooses the From name and checks who may
//  send to whom; the phone sends only the template name, the recipient and the template's data. Nothing calls the old,
//  unauthenticated `sendProjectPlannerEmail` any more.
//

import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation

/// The fixed `sendEmail` templates the app uses (besides `material_request`).
enum AppEmailTemplate: String {
    case inviteSetup = "invite_setup"
    case passwordResetLink = "password_reset_link"
    case timesheetExport = "timesheet_export"
    case leaveCancelled = "leave_cancelled"
}

/// The request body, pure, so it is tested without a network.
enum AppEmailPayload {
    /// The function's attachment limits (functions/email/attachments.js): at most 80 files, 10 MB decoded in total.
    static let maxAttachments = 80
    static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Attachments make the request large; the material request's 20 s is too short for 10 MB on a slow connection.
    static let attachmentRequestTimeout: TimeInterval = 90

    /// `invite_setup` / `password_reset_link`: the recipient is the email on `invitations/{invitationId}`.
    static func invitationData(invitationId: String) -> [String: Any] {
        ["invitationId": invitationId.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// `timesheet_export`. Download links must be Firebase Storage URLs (the function refuses anything else), so any
    /// other link is left out rather than failing the whole email.
    static func timesheetExportData(
        weekTitle: String,
        paymentRunStamp: String,
        timesheetCount: Int,
        downloadLinks: [(fileName: String, url: String)]
    ) -> [String: Any] {
        let allowed = ["https://firebasestorage.googleapis.com/", "https://storage.googleapis.com/"]
        let links: [[String: Any]] = downloadLinks.compactMap { link in
            guard allowed.contains(where: { link.url.hasPrefix($0) }) else { return nil }
            return ["fileName": link.fileName, "url": link.url]
        }
        var data: [String: Any] = [
            "weekTitle": weekTitle,
            "paymentRunStamp": paymentRunStamp,
            "timesheetCount": max(1, timesheetCount),
        ]
        if !links.isEmpty { data["downloadLinks"] = links }
        return data
    }

    /// `leave_cancelled`: the function writes "<caller> has cancelled your annual leave request for <dateText>."
    static func leaveCancelledData(dateText: String) -> [String: Any] {
        ["dateText": dateText.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Whether the files fit the function's limits (count and decoded size).
    static func attachmentsFit(_ files: [(fileName: String, data: Data)]) -> Bool {
        files.count <= maxAttachments && files.reduce(0) { $0 + $1.data.count } <= maxAttachmentBytes
    }

    /// `[{ filename, content }]`, strict base64 (no line breaks). The function decides the content type itself.
    static func attachmentRows(_ files: [(fileName: String, data: Data)]) -> [[String: Any]] {
        files.map { ["filename": $0.fileName, "content": $0.data.base64EncodedString()] }
    }

    static func body(
        organizationId: String,
        template: AppEmailTemplate,
        to recipients: [String],
        data: [String: Any],
        attachments: [(fileName: String, data: Data)] = [],
        requestId: String? = nil
    ) -> [String: Any] {
        var seen = Set<String>()
        let to = recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var body: [String: Any] = [
            "orgId": organizationId.trimmingCharacters(in: .whitespacesAndNewlines),
            "template": template.rawValue,
            "to": to,
            "data": data,
        ]
        if !attachments.isEmpty { body["attachments"] = attachmentRows(attachments) }
        if let requestId = MaterialRequestEmailPayload.requestIdValue(requestId) { body["requestId"] = requestId }
        return body
    }
}

enum AppEmailClient {
    /// Sends one template call. Throws `MaterialRequestEmailError` (the same `sendEmail` answers) or a transport error.
    static func send(
        template: AppEmailTemplate,
        organizationId: String,
        to recipients: [String],
        data: [String: Any],
        attachments: [(fileName: String, data: Data)] = [],
        requestId: String? = nil,
        transport: MaterialRequestEmailTransport = URLSessionMaterialRequestEmailTransport()
    ) async throws -> MaterialRequestEmailResult {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else {
            throw MaterialRequestEmailError.refused(status: 0, reason: "no organisation is open")
        }
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
        let body = AppEmailPayload.body(
            organizationId: orgId,
            template: template,
            to: recipients,
            data: data,
            attachments: attachments,
            requestId: requestId
        )
        var urlRequest = try MaterialRequestEmailPayload.urlRequest(
            url: url,
            body: body,
            idToken: idToken,
            appCheckToken: appCheckToken
        )
        if !attachments.isEmpty { urlRequest.timeoutInterval = AppEmailPayload.attachmentRequestTimeout }
        return try await MaterialRequestEmailClient.perform(urlRequest, transport: transport)
    }

    /// Plain text for a failed send (never the material wording).
    static func message(for error: Error) -> String {
        switch error {
        case MaterialRequestEmailError.refused(_, let reason):
            return reason
        case MaterialRequestEmailError.unconfirmed, MaterialRequestEmailError.timedOut:
            return "the email service did not confirm the send — check your inbox before sending again"
        case MaterialRequestEmailError.stillSending:
            return "this email is already being sent"
        case MaterialRequestEmailError.notSignedIn:
            return "sign in again and retry"
        case MaterialRequestEmailError.notConfigured:
            return "the email service is not configured"
        default:
            return error.localizedDescription
        }
    }
}

/// Who a timesheet export email goes to: the signed-in person's own sign-in email (the email function's
/// `timesheet_export` sends only to the caller's ID-token email, web #334), else the users-document copy.
enum TimesheetExportRecipient {
    static func email(authEmail: String?, profileEmail: String) -> String {
        let auth = authEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return auth.isEmpty ? profileEmail.trimmingCharacters(in: .whitespacesAndNewlines) : auth
    }
}
