//
//  OfflineDeadlineLocalStore.swift
//  Project Planner
//
//  Local snapshot + outbox payload for project/small-works deadlines.
//  First writer to sync wins overlapping edits; locally created ids are merged in.
//

import Foundation

struct OfflineSaveDeadlinesPayload: Codable {
    let projectId: UUID
    let isSmallWorks: Bool
    let baseUpdatedAt: Date?
    let items: [OfflineDeadlineRecord]
}

struct OfflineDeadlineRecord: Codable {
    var id: UUID
    var title: String
    var location: String?
    var trade: String?
    var detail: String?
    var start: Date?
    var due: Date
    var completedAt: Date?
    var assignees: [String]
    var assigneeUserIds: [String]
    var company: String?
    var status: String
    var progress: Double
    var isCritical: Bool
    var dependsOn: [UUID]
    var blockedReason: String?
    var reminderDaysBefore: Int?
    var originalDue: Date?
    var history: [OfflineDeadlineChangeRecord]
    var contextKind: String
    var projectId: UUID?
    var createdByUserId: String
    var fileURL: String?
    var fileName: String?
    var siteAuditId: UUID?
    var siteAuditTitle: String?
}

struct OfflineDeadlineChangeRecord: Codable {
    var id: UUID
    var at: Date
    var author: String
    var type: String
    var due: Date?
    var from: Date?
    var to: Date?
    var reason: String?
    var progress: Int?
    var status: String?
    var note: String?
    var completedOn: Date?
    var assignedTo: String?
    var name: String?
}

enum OfflineDeadlineCodec {
    static func records(from items: [DLDeadline]) -> [OfflineDeadlineRecord] {
        items.map(record(from:))
    }

    static func items(from records: [OfflineDeadlineRecord]) -> [DLDeadline] {
        records.map(item(from:))
    }

    static func record(from item: DLDeadline) -> OfflineDeadlineRecord {
        OfflineDeadlineRecord(
            id: item.id,
            title: item.title,
            location: item.location,
            trade: item.trade,
            detail: item.detail,
            start: item.start,
            due: item.due,
            completedAt: item.completedAt,
            assignees: item.assignees,
            assigneeUserIds: item.assigneeUserIds,
            company: item.company,
            status: item.status.rawValue,
            progress: item.progress,
            isCritical: item.isCritical,
            dependsOn: item.dependsOn,
            blockedReason: item.blockedReason,
            reminderDaysBefore: item.reminderDaysBefore,
            originalDue: item.originalDue,
            history: item.history.map(changeRecord(from:)),
            contextKind: item.contextKind,
            projectId: item.projectId,
            createdByUserId: item.createdByUserId,
            fileURL: item.fileURL,
            fileName: item.fileName,
            siteAuditId: item.siteAuditId,
            siteAuditTitle: item.siteAuditTitle
        )
    }

    static func item(from record: OfflineDeadlineRecord) -> DLDeadline {
        DLDeadline(
            id: record.id,
            title: record.title,
            location: record.location,
            trade: record.trade,
            detail: record.detail,
            start: record.start,
            due: record.due,
            completedAt: record.completedAt,
            assignees: record.assignees,
            assigneeUserIds: record.assigneeUserIds,
            company: record.company,
            status: DLStatus(rawValue: record.status) ?? .notStarted,
            progress: record.progress,
            isCritical: record.isCritical,
            dependsOn: record.dependsOn,
            blockedReason: record.blockedReason,
            reminderDaysBefore: record.reminderDaysBefore,
            originalDue: record.originalDue,
            history: record.history.compactMap(change(from:)),
            contextKind: record.contextKind,
            projectId: record.projectId,
            createdByUserId: record.createdByUserId,
            fileURL: record.fileURL,
            fileName: record.fileName,
            siteAuditId: record.siteAuditId,
            siteAuditTitle: record.siteAuditTitle
        )
    }

    private static func changeRecord(from change: DLChange) -> OfflineDeadlineChangeRecord {
        var record = OfflineDeadlineChangeRecord(id: change.id, at: change.at, author: change.author, type: "note")
        switch change.kind {
        case .created(let due):
            record.type = "created"
            record.due = due
        case .rescheduled(let from, let to, let reason):
            record.type = "rescheduled"
            record.from = from
            record.to = to
            record.reason = reason
        case .progress(let pct):
            record.type = "progress"
            record.progress = pct
        case .status(let status):
            record.type = "status"
            record.status = status.rawValue
        case .note(let text):
            record.type = "note"
            record.note = text
        case .completed(let on):
            record.type = "completed"
            record.completedOn = on
        case .assigned(let who):
            record.type = "assigned"
            record.assignedTo = who
        case .fileAttached(let name):
            record.type = "fileAttached"
            record.name = name
        case .siteAuditAttached(let name):
            record.type = "siteAuditAttached"
            record.name = name
        }
        return record
    }

    private static func change(from record: OfflineDeadlineChangeRecord) -> DLChange? {
        let kind: DLChange.Kind
        switch record.type {
        case "created":
            kind = .created(due: record.due ?? Date())
        case "rescheduled":
            kind = .rescheduled(from: record.from ?? Date(), to: record.to ?? Date(), reason: record.reason ?? "")
        case "progress":
            kind = .progress(to: record.progress ?? 0)
        case "status":
            kind = .status(to: DLStatus(rawValue: record.status ?? "") ?? .notStarted)
        case "completed":
            kind = .completed(on: record.completedOn ?? Date())
        case "assigned":
            kind = .assigned(to: record.assignedTo ?? "")
        case "fileAttached":
            kind = .fileAttached(name: record.name ?? "File")
        case "siteAuditAttached":
            kind = .siteAuditAttached(name: record.name ?? "Site audit")
        default:
            kind = .note(record.note ?? record.type)
        }
        return DLChange(id: record.id, at: record.at, author: record.author, kind: kind)
    }
}

@MainActor
final class OfflineDeadlineLocalStore {
    static let shared = OfflineDeadlineLocalStore()

    private let storageKeyPrefix = "offline_deadlines_snapshot_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func save(items: [DLDeadline], projectId: UUID, organizationId: String, updatedAt: Date?) {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else { return }
        let box = Snapshot(updatedAt: updatedAt, items: OfflineDeadlineCodec.records(from: items))
        guard let data = try? encoder.encode(box) else { return }
        UserDefaults.standard.set(data, forKey: key(orgId, projectId))
    }

    func load(projectId: UUID, organizationId: String) -> (items: [DLDeadline], updatedAt: Date?)? {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(orgId, projectId)),
              let box = try? decoder.decode(Snapshot.self, from: data) else { return nil }
        return (OfflineDeadlineCodec.items(from: box.items), box.updatedAt)
    }

    private func key(_ organizationId: String, _ projectId: UUID) -> String {
        "\(storageKeyPrefix).\(organizationId).\(projectId.uuidString)"
    }

    private struct Snapshot: Codable {
        var updatedAt: Date?
        var items: [OfflineDeadlineRecord]
    }
}
