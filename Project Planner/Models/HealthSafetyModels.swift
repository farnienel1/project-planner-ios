import Foundation

enum HSToolboxTalkSource: String, Codable, CaseIterable, Hashable {
    case library
    case uploaded
}

enum HSToolboxTalkStatus: String, Codable, CaseIterable, Hashable {
    case draft
    case approved
}

enum HSToolboxTalkCategory: String, Codable, CaseIterable, Hashable {
    case general
    case trade
}

/// RULEBOOK 1.8.0 (`HS_ISSUE_STATUSES`, `HS_ISSUE_STATUS_STORED`): awaiting, scheduled, complete. A finished issue
/// is stored `completed` (the raw value here); web's `complete` reads as `.completed` through
/// `parseHealthSafetyDocument`.
enum HSToolboxIssueStatus: String, Codable, CaseIterable, Hashable {
    case awaiting
    case scheduled
    case completed

    /// The reader's token (`awaiting` / `scheduled` / `complete`) as a case.
    static func fromRulebook(_ token: String) -> HSToolboxIssueStatus {
        switch token {
        case "complete", "completed": return .completed
        case "scheduled": return .scheduled
        default: return .awaiting
        }
    }
}

enum HSToolboxSignatureStatus: String, Codable, CaseIterable, Hashable {
    case pending
    case signed
}

struct HSToolboxTalk: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var category: HSToolboxTalkCategory
    var isGeneral: Bool
    var trades: [String]
    var purpose: String
    var keyPoints: [String]
    var source: HSToolboxTalkSource
    var ownerOrganizationId: String?
    var status: HSToolboxTalkStatus
    var version: Int
    var updatedAt: Date
    var fileURL: String?
}

extension HSToolboxTalk {
    var displayTitle: String {
        ToolboxTalkLibrary.resolvedTitle(talkId: id, storedTalks: [self])
    }
}

struct HSToolboxIssue: Identifiable, Codable, Hashable {
    let id: String
    var projectId: UUID
    var talkId: String
    var weekCommencing: Date
    var issuedByUserId: String
    var issuedAt: Date
    /// If set, this issue remains scheduled and hidden until this date/time.
    var publishAt: Date?
    var recipientUserIds: [String]
    var status: HSToolboxIssueStatus
    /// When set, this issue is a RAMS send-for-signature rather than a toolbox talk.
    var ramsDocumentId: String? = nil
}

struct HSToolboxSignature: Identifiable, Codable, Hashable {
    let id: String
    var issueId: String
    var userId: String
    var status: HSToolboxSignatureStatus
    var readConfirmed: Bool
    /// Base64 encoded PNG bytes from signature pad.
    var signatureImageBase64: String?
    var signedAt: Date?
    var reminderSentAt: Date?

    var isSigned: Bool {
        status == .signed && readConfirmed && signatureImageBase64?.isEmpty == false && signedAt != nil
    }
}

struct HSRamsDocument: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var trade: String
    var version: Int
    var status: String
    var uploadedAt: Date
    var fileURL: String?
    var fileName: String?
    var reviewDate: Date?
    var attachedDocTitles: [String]
}

struct HSOtherDocument: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var trade: String?
    var category: String
    var uploadedAt: Date
    var fileURL: String?
    var fileName: String?
    var issuableToClient: Bool
}

extension HSToolboxTalk {
    var isCustomUpload: Bool { source == .uploaded }

    var storedFileURL: URL? {
        // `StoredFileTarget`: a download URL, `gs://` URL or Storage path opens (resolved on open); a blank, `file://`
        // or unknown reference does not.
        guard let fileURL, StoredFileTarget.canOpen(fileURL),
              let url = URL(string: fileURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }

    var tradeLabel: String {
        if isGeneral { return "General" }
        let joined = trades
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return joined.isEmpty ? "General" : joined
    }
}

extension HSRamsDocument {
    var storedFileURL: URL? {
        // `StoredFileTarget`: a download URL, `gs://` URL or Storage path opens (resolved on open); a blank, `file://`
        // or unknown reference does not.
        guard let fileURL, StoredFileTarget.canOpen(fileURL),
              let url = URL(string: fileURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }
}

extension HSOtherDocument {
    var storedFileURL: URL? {
        // `StoredFileTarget`: a download URL, `gs://` URL or Storage path opens (resolved on open); a blank, `file://`
        // or unknown reference does not.
        guard let fileURL, StoredFileTarget.canOpen(fileURL),
              let url = URL(string: fileURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }
}

struct HSProjectSafetyData: Codable, Hashable {
    var talks: [HSToolboxTalk]
    var issues: [HSToolboxIssue]
    var signatures: [HSToolboxSignature]
    var ramsDocuments: [HSRamsDocument]
    var otherDocuments: [HSOtherDocument]
    var updatedAt: Date

    static let empty = HSProjectSafetyData(
        talks: [],
        issues: [],
        signatures: [],
        ramsDocuments: [],
        otherDocuments: [],
        updatedAt: Date()
    )
}
