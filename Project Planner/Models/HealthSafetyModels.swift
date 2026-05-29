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

enum HSToolboxIssueStatus: String, Codable, CaseIterable, Hashable {
    case awaiting
    case completed
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

struct HSToolboxIssue: Identifiable, Codable, Hashable {
    let id: String
    var projectId: UUID
    var talkId: String
    var weekCommencing: Date
    var issuedByUserId: String
    var issuedAt: Date
    var recipientUserIds: [String]
    var status: HSToolboxIssueStatus
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
}

struct HSOtherDocument: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var trade: String?
    var category: String
    var uploadedAt: Date
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
