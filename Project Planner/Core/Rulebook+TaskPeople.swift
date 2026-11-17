//
//  Rulebook+TaskPeople.swift
//  Project Planner
//
//  Owner decision 17 Nov ("fix on both apps", web #364 `lib/tasks/taskAssigneePeople.ts`): a person with more than one
//  record appears once in the task assignee pickers, the task filter and the task assignee names. Tasks store
//  `operatives` and `managers` catalogue row ids (`assignedOperativeIds`, `assignedManagerIds`); one person can have
//  several — a converted ghost's old `operatives` row (its id is the ghost's users id, RULEBOOK §11), duplicate rows
//  linked to it, a row linked to an account (`linkedUserId` / `userId` / `uid`), and a `managers` row on their email.
//
//  Each row is folded with the rulebook's `personIdSet` over every users document of the organisation (own id,
//  `formerUserIds`, `sameEmailUserIds`, same email), with the row's stored account link counted as one of its ids — the
//  identity link `notificationRecipientAccountId` already reads. Ghosts are `isGhostUser`. Swift keeps no matcher of its
//  own (guardrail 1): it only maps rows to the rulebook's input and groups by the answer.
//
//  Display only (guardrail 3): nothing stored changes. Ticking a person adds the row shown; unticking removes every id
//  of that person; an assignment to an id no picker row shows stays listed as "Already assigned".
//

import Foundation

enum TaskPersonKind: String, Hashable, Sendable {
    case manager
    case operative
}

/// Who each task assignee row is. Keys are computed once per row through `personIdSet` and kept for the life of the
/// index (`TaskPersonIndex.current` reuses an index while the rows and roster are unchanged).
final class TaskPersonIndex {
    private struct RowSeed {
        let storedId: String
        let email: String
        let linkedUserId: String?
    }

    private let managersById: [UUID: Manager]
    private let operativesById: [UUID: Operative]
    private let managersByStoredId: [String: Manager]
    private let operativesByStoredId: [String: Operative]
    private let rosterRows: [[String: Any]]
    private let rosterIds: Set<String>
    private let ghostAccountIds: Set<String>
    private var cache: [String: String] = [:]
    private var ghostKeys: Set<String> = []

    init(managers: [Manager], operatives: [Operative], users: [AppUser]) {
        var managersById: [UUID: Manager] = [:]
        var managersByStoredId: [String: Manager] = [:]
        for row in managers {
            if managersById[row.id] == nil { managersById[row.id] = row }
            let key = Self.idKey(row.firestoreDocumentId)
            if !key.isEmpty, managersByStoredId[key] == nil { managersByStoredId[key] = row }
        }
        var operativesById: [UUID: Operative] = [:]
        var operativesByStoredId: [String: Operative] = [:]
        for row in operatives {
            if operativesById[row.id] == nil { operativesById[row.id] = row }
            let key = Self.idKey(row.documentId)
            if !key.isEmpty, operativesByStoredId[key] == nil { operativesByStoredId[key] = row }
        }
        self.managersById = managersById
        self.operativesById = operativesById
        self.managersByStoredId = managersByStoredId
        self.operativesByStoredId = operativesByStoredId

        var rows: [[String: Any]] = []
        var ids = Set<String>()
        var ghosts = Set<String>()
        for user in users {
            let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let row: [String: Any] = [
                "id": id,
                "email": user.email,
                "formerUserIds": user.formerUserIds,
                "sameEmailUserIds": user.sameEmailUserIds,
                "ghost": user.isGhost,
            ]
            rows.append(row)
            ids.insert(Self.idKey(id))
            if user.isGhost, CanonicalBusinessEngine.isGhostUser(row) { ghosts.insert(Self.idKey(id)) }
        }
        self.rosterRows = rows
        self.rosterIds = ids
        self.ghostAccountIds = ghosts
    }

    static func idKey(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The stored id a task wrote for `id` (`WorkDocumentKeys`, the task reader's mapping).
    private static func storedTaskId(_ id: UUID) -> String {
        WorkDocumentKeys.storedId(for: id)
    }

    func manager(_ id: UUID) -> Manager? {
        managersById[id] ?? managersByStoredId[Self.idKey(Self.storedTaskId(id))]
    }

    func operative(_ id: UUID) -> Operative? {
        operativesById[id] ?? operativesByStoredId[Self.idKey(Self.storedTaskId(id))]
    }

    private func seed(_ kind: TaskPersonKind, _ id: UUID) -> RowSeed {
        switch kind {
        case .manager:
            if let row = manager(id) {
                return RowSeed(storedId: row.firestoreDocumentId, email: row.email, linkedUserId: row.linkedUserId)
            }
        case .operative:
            if let row = operative(id) {
                return RowSeed(storedId: row.documentId, email: row.email, linkedUserId: row.linkedUserId)
            }
        }
        return RowSeed(storedId: Self.storedTaskId(id), email: "", linkedUserId: nil)
    }

    /// One key per person: `account:<id>` when a users document is found, else `email:<email>`, else `id:<id>`.
    func key(_ kind: TaskPersonKind, _ id: UUID) -> String {
        let cacheKey = "\(kind.rawValue):\(id.uuidString)"
        if let known = cache[cacheKey] { return known }
        let row = seed(kind, id)
        let linked = row.linkedUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = row.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let person: [String: Any] = [
            "id": row.storedId.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": email.isEmpty ? NSNull() : email,
            "formerUserIds": linked.isEmpty ? [String]() : [linked],
        ]
        var result: String
        let ids = CanonicalBusinessEngine.personIdSet(person: person, roster: rosterRows) ?? []
        let accounts = ids.map { Self.idKey($0) }.filter { rosterIds.contains($0) }.sorted()
        if let first = accounts.first {
            result = "account:\(first)"
            if accounts.contains(where: { ghostAccountIds.contains($0) }) { ghostKeys.insert(result) }
        } else if !email.isEmpty {
            result = "email:\(email.lowercased())"
        } else {
            result = "id:\(Self.idKey(row.storedId))"
        }
        cache[cacheKey] = result
        return result
    }

    /// True when the person is a ghost operative (no login).
    func isGhost(_ key: String) -> Bool {
        ghostKeys.contains(key)
    }

    // MARK: Shared index

    private static var lastSignature: String?
    private static var lastIndex: TaskPersonIndex?

    /// The index for these rows, reused while the rows and roster are unchanged (each new row costs one script call).
    static func current(managers: [Manager], operatives: [Operative], users: [AppUser]) -> TaskPersonIndex {
        var parts: [String] = []
        parts.reserveCapacity(managers.count + operatives.count + users.count + 3)
        parts.append("m")
        for row in managers { parts.append("\(row.id.uuidString)|\(row.firestoreDocumentId)|\(row.email)|\(row.linkedUserId ?? "")") }
        parts.append("o")
        for row in operatives { parts.append("\(row.id.uuidString)|\(row.documentId)|\(row.email)|\(row.linkedUserId ?? "")") }
        parts.append("u")
        for user in users {
            parts.append("\(user.id)|\(user.email)|\(user.formerUserIds.joined(separator: ","))|\(user.sameEmailUserIds.joined(separator: ","))|\(user.isGhost)")
        }
        let signature = parts.joined(separator: "\n")
        if signature == lastSignature, let index = lastIndex { return index }
        let index = TaskPersonIndex(managers: managers, operatives: operatives, users: users)
        lastSignature = signature
        lastIndex = index
        return index
    }
}

/// An id already assigned to the task whose person no picker row shows (an inactive or old row, a ghost, a row since
/// deleted). Listed as a ticked row so it stays visible and removable.
struct TaskPickerExtra: Identifiable, Hashable {
    let kind: TaskPersonKind
    let id: UUID
    let label: String
}

enum TaskPeopleRulebook {
    enum Route { case managers, operatives, combined }

    private static func emailKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One row per person for a new assignment (web `peopleForTaskPicker`). `operatives` rows without an email are left
    /// out (as web); ghosts are never offered; in the combined picker a person with a `managers` row is shown there only.
    static func pickerPeople(
        managers: [Manager],
        operatives: [Operative],
        route: Route,
        index: TaskPersonIndex
    ) -> (managers: [Manager], operatives: [Operative]) {
        var managerKeys = Set<String>()
        var uniqueManagers: [Manager] = []
        for row in managers {
            let key = index.key(.manager, row.id)
            if managerKeys.contains(key) { continue }
            managerKeys.insert(key)
            uniqueManagers.append(row)
        }
        var operativeKeys = Set<String>()
        var uniqueOperatives: [Operative] = []
        for row in operatives where !emailKey(row.email).isEmpty {
            let key = index.key(.operative, row.id)
            if index.isGhost(key) || operativeKeys.contains(key) { continue }
            operativeKeys.insert(key)
            uniqueOperatives.append(row)
        }
        switch route {
        case .managers: return (uniqueManagers, [])
        case .operatives: return ([], uniqueOperatives)
        case .combined:
            return (uniqueManagers, uniqueOperatives.filter { !managerKeys.contains(index.key(.operative, $0.id)) })
        }
    }

    /// Whether the person a row shows is assigned: any of their row ids (either kind) is selected.
    static func isSelected(
        _ kind: TaskPersonKind,
        _ id: UUID,
        managers: Set<UUID>,
        operatives: Set<UUID>,
        index: TaskPersonIndex
    ) -> Bool {
        let key = index.key(kind, id)
        return managers.contains { index.key(.manager, $0) == key }
            || operatives.contains { index.key(.operative, $0) == key }
    }

    /// Tick or untick the person a row shows. Unticking removes every id of that person from both sets; ticking adds
    /// the row's own id. Ids already stored are never rewritten while the person stays ticked.
    static func toggle(
        _ kind: TaskPersonKind,
        _ id: UUID,
        managers: Set<UUID>,
        operatives: Set<UUID>,
        index: TaskPersonIndex
    ) -> (managers: Set<UUID>, operatives: Set<UUID>) {
        var nextManagers = managers
        var nextOperatives = operatives
        if isSelected(kind, id, managers: managers, operatives: operatives, index: index) {
            let key = index.key(kind, id)
            nextManagers = managers.filter { index.key(.manager, $0) != key }
            nextOperatives = operatives.filter { index.key(.operative, $0) != key }
        } else if kind == .manager {
            nextManagers.insert(id)
        } else {
            nextOperatives.insert(id)
        }
        return (nextManagers, nextOperatives)
    }

    /// The label for an id whose row is gone: "Unknown person · 6A9632BA" (`bookingPersonIdHint`).
    static func unknownLabel(_ id: UUID) -> String {
        let stored = WorkDocumentKeys.storedId(for: id)
        let hint = CanonicalBusinessEngine.callJSON("bookingPersonIdHint", arguments: [stored]) as? String
            ?? String(stored.prefix(8)).uppercased()
        return "\(CanonicalBusinessEngine.unknownBookingPersonLabel) · \(hint)"
    }

    private static func rowName(_ kind: TaskPersonKind, _ id: UUID, index: TaskPersonIndex) -> String? {
        switch kind {
        case .manager:
            guard let row = index.manager(id) else { return nil }
            let name = row.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? row.email : name
        case .operative:
            guard let row = index.operative(id) else { return nil }
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? row.email : name
        }
    }

    /// Guardrail 3: ids already assigned whose person no picker row shows, one entry per person, in stored order
    /// (managers first). Pass empty sets for a kind the picker does not show.
    static func extras(
        shown: [(kind: TaskPersonKind, id: UUID)],
        managers: [UUID],
        operatives: [UUID],
        index: TaskPersonIndex
    ) -> [TaskPickerExtra] {
        let shownKeys = Set(shown.map { index.key($0.kind, $0.id) })
        var seen = Set<String>()
        var out: [TaskPickerExtra] = []
        func add(_ kind: TaskPersonKind, _ id: UUID) {
            let key = index.key(kind, id)
            guard !shownKeys.contains(key), seen.insert(key).inserted else { return }
            out.append(TaskPickerExtra(kind: kind, id: id, label: rowName(kind, id, index: index) ?? unknownLabel(id)))
        }
        for id in managers { add(.manager, id) }
        for id in operatives { add(.operative, id) }
        return out
    }

    /// One option per person for the task filter (every row kept, inactive and ghost people included: they may have
    /// tasks). The person's active row with an email is preferred as the option shown.
    static func filterManagers(_ rows: [Manager], index: TaskPersonIndex) -> [Manager] {
        fold(rows, kind: .manager, id: \.id, isActive: \.isActive, email: \.email, index: index)
    }

    static func filterOperatives(_ rows: [Operative], index: TaskPersonIndex) -> [Operative] {
        fold(rows, kind: .operative, id: \.id, isActive: \.isActive, email: \.email, index: index)
    }

    private static func fold<T>(
        _ rows: [T],
        kind: TaskPersonKind,
        id: KeyPath<T, UUID>,
        isActive: KeyPath<T, Bool>,
        email: KeyPath<T, String>,
        index: TaskPersonIndex
    ) -> [T] {
        func score(_ row: T) -> Int { (row[keyPath: isActive] ? 2 : 0) + (emailKey(row[keyPath: email]).isEmpty ? 0 : 1) }
        var byKey: [String: T] = [:]
        var order: [String] = []
        for row in rows {
            let key = index.key(kind, row[keyPath: id])
            if let existing = byKey[key] {
                if score(row) > score(existing) { byKey[key] = row }
            } else {
                byKey[key] = row
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Whether a task is assigned to the person of a filter option, under any of their rows of either kind.
    static func task(
        _ task: ProjectTask,
        isAssignedTo kind: TaskPersonKind,
        _ id: UUID,
        index: TaskPersonIndex
    ) -> Bool {
        isSelected(kind, id, managers: Set(task.allAssignedManagerIds), operatives: Set(task.allAssignedOperativeIds), index: index)
    }

    /// The names of a task's assignees, one per person (two stored ids of one person show one name), managers first.
    /// An id whose row is gone is left out, as before.
    static func assigneeNames(
        managerIds: [UUID],
        operativeIds: [UUID],
        index: TaskPersonIndex
    ) -> [(kind: TaskPersonKind, name: String)] {
        var seen = Set<String>()
        var out: [(kind: TaskPersonKind, name: String)] = []
        func add(_ kind: TaskPersonKind, _ id: UUID) {
            guard let name = rowName(kind, id, index: index) else { return }
            guard seen.insert(index.key(kind, id)).inserted else { return }
            out.append((kind, name))
        }
        for id in managerIds { add(.manager, id) }
        for id in operativeIds { add(.operative, id) }
        return out
    }
}
