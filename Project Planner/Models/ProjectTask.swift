//
//  ProjectTask.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation

/// A single item (sub-task) within a task. Tasks can have one or many items.
struct ProjectTaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var description: String?
    
    init(id: UUID = UUID(), title: String, description: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
    }
}

struct ProjectTask: Identifiable, Codable, Hashable {
    enum Status: String, Codable, CaseIterable {
        case todo = "To Do"
        case inProgress = "In Progress"
        case completed = "Completed"
    }
    
    let id: UUID
    var projectId: UUID
    var title: String
    var details: String?
    var createdBy: String
    var assignedOperativeId: UUID? // Legacy single assignment (for backward compatibility)
    var assignedManagerId: UUID? // Legacy single assignment (for backward compatibility)
    var assignedOperativeIds: [UUID] // Multiple operative assignments
    var assignedManagerIds: [UUID] // Multiple manager assignments
    var dueDate: Date?
    var status: Status
    var createdAt: Date
    var updatedAt: Date
    var attachedFileURL: String? // Firebase Storage URL for attached file
    var attachedFileName: String? // Original file name
    var attachedImageURLs: [String] // Firebase Storage URLs for attached images
    var completedBy: String? // User who marked task as completed
    var completedAt: Date? // When task was marked as completed
    var completionImages: [String] // Firebase Storage URLs for completion images
    var completionFiles: [String] // Firebase Storage URLs for completion files
    /// Sub-items (multi-item tasks). Empty = legacy single task (title + details).
    var items: [ProjectTaskItem]
    /// For multi-item tasks: which item IDs the assignee has ticked. Only when all are ticked can they mark task completed.
    var completedItemIds: [UUID]
    
    init(
        id: UUID = UUID(),
        projectId: UUID,
        title: String,
        details: String? = nil,
        createdBy: String,
        assignedOperativeId: UUID? = nil,
        assignedManagerId: UUID? = nil,
        assignedOperativeIds: [UUID] = [],
        assignedManagerIds: [UUID] = [],
        dueDate: Date? = nil,
        status: Status = .todo,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attachedFileURL: String? = nil,
        attachedFileName: String? = nil,
        attachedImageURLs: [String] = [],
        completedBy: String? = nil,
        completedAt: Date? = nil,
        completionImages: [String] = [],
        completionFiles: [String] = [],
        items: [ProjectTaskItem] = [],
        completedItemIds: [UUID] = []
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.details = details
        self.createdBy = createdBy
        self.assignedOperativeId = assignedOperativeId
        self.assignedManagerId = assignedManagerId
        self.assignedOperativeIds = assignedOperativeIds
        self.assignedManagerIds = assignedManagerIds
        self.dueDate = dueDate
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachedFileURL = attachedFileURL
        self.attachedFileName = attachedFileName
        self.attachedImageURLs = attachedImageURLs
        self.completedBy = completedBy
        self.completedAt = completedAt
        self.completionImages = completionImages
        self.completionFiles = completionFiles
        self.items = items
        self.completedItemIds = completedItemIds
    }
    
    // Helper to get all assigned operative IDs (combines legacy and new)
    var allAssignedOperativeIds: [UUID] {
        var ids = assignedOperativeIds
        if let legacyId = assignedOperativeId, !ids.contains(legacyId) {
            ids.append(legacyId)
        }
        return ids
    }
    
    // Helper to get all assigned manager IDs (combines legacy and new)
    var allAssignedManagerIds: [UUID] {
        var ids = assignedManagerIds
        if let legacyId = assignedManagerId, !ids.contains(legacyId) {
            ids.append(legacyId)
        }
        return ids
    }
    
    var isCompleted: Bool {
        status == .completed
    }
    
    /// Effective list of items: if items is empty, one logical item from title/details (for legacy tasks).
    var effectiveItems: [ProjectTaskItem] {
        if items.isEmpty {
            return [ProjectTaskItem(title: title, description: details)]
        }
        return items
    }
    
    /// True when task has more than one item (so assignee must tick all before marking complete).
    var isMultiItemTask: Bool {
        effectiveItems.count > 1
    }
    
    /// True when all items have been ticked (for multi-item tasks). Always true for single-item.
    var allItemsTicked: Bool {
        let ids = Set(effectiveItems.map(\.id))
        return ids.isEmpty || ids.isSubset(of: Set(completedItemIds))
    }
}


