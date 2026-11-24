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

/// Who each task assignee row is (web `taskPersonIndex`, final version after the review of #364). Built in one pass:
/// every record of one person — users documents (folded with the rulebook's `personIdSet` over the whole roster, one
/// call per roster row), their emails, `operatives` / `managers` rows on those emails or ids and the accounts those
/// rows link to — is joined into one group first, then each group gets one key: the smallest `account:<id>`, else the
/// smallest `email:<email>`, else the smallest `id:<id>` (ids and emails without case). A person is a ghost only when
/// every account in their group is a ghost.
@MainActor
final class TaskPersonIndex {
    private let managersById: [UUID: Manager]
    private let operativesById: [UUID: Operative]
    private let managersByStoredId: [String: Manager]
    private let operativesByStoredId: [String: Operative]
    private var parent: [String: String] = [:]
    private var keyByRoot: [String: String] = [:]
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

        // The roster as `personIdSet` reads it (plus the ghost flag `isGhostUser` reads).
        var rosterRows: [[String: Any]] = []
        var rosterById: [String: [String: Any]] = [:]
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
            rosterRows.append(row)
            if rosterById[Self.idKey(id)] == nil { rosterById[Self.idKey(id)] = row }
        }

        // The whole closure first.
        for row in rosterRows {
            let id = row["id"] as? String ?? ""
            let linked = CanonicalBusinessEngine.personIdSet(person: row, roster: rosterRows)
                ?? ([id] + (row["formerUserIds"] as? [String] ?? []) + (row["sameEmailUserIds"] as? [String] ?? []))
            join([Self.idNode(id), Self.emailNode(row["email"] as? String)] + linked.map { Self.idNode($0) })
        }
        for row in managers {
            join([Self.idNode(row.firestoreDocumentId), Self.emailNode(row.email), Self.idNode(row.linkedUserId)])
        }
        for row in operatives {
            join([Self.idNode(row.documentId), Self.emailNode(row.email), Self.idNode(row.linkedUserId)])
        }

        // One deterministic key per group.
        var accounts: [String: [String]] = [:]
        var emails: [String: [String]] = [:]
        var ids: [String: [String]] = [:]
        for node in Array(parent.keys) {
            let root = find(node)
            if node.hasPrefix("email:") {
                emails[root, default: []].append(String(node.dropFirst(6)))
            } else {
                let id = String(node.dropFirst(3))
                ids[root, default: []].append(id)
                if rosterById[id] != nil { accounts[root, default: []].append(id) }
            }
        }
        let roots = Set(accounts.keys).union(emails.keys).union(ids.keys)
        for root in roots {
            let groupAccounts = accounts[root] ?? []
            let key: String
            if let first = groupAccounts.min() {
                key = "account:\(first)"
            } else if let first = emails[root]?.min() {
                key = "email:\(first)"
            } else {
                key = "id:\(ids[root]?.min() ?? "")"
            }
            keyByRoot[root] = key
            // A ghost only when every account of the person is a ghost (a ghost's old record beside a live login is not).
            if !groupAccounts.isEmpty,
               groupAccounts.allSatisfy({ id in rosterById[id].map { CanonicalBusinessEngine.isGhostUser($0) } ?? false }) {
                ghostKeys.insert(key)
            }
        }
    }

    static func idKey(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func idNode(_ value: String?) -> String {
        let key = idKey(value)
        return key.isEmpty ? "" : "id:\(key)"
    }

    private static func emailNode(_ value: String?) -> String {
        let key = idKey(value)
        return key.isEmpty ? "" : "email:\(key)"
    }

    private func find(_ node: String) -> String {
        var root = node
        while let next = parent[root], next != root { root = next }
        if parent[root] == nil { parent[root] = root }
        var current = node
        while current != root {
            let next = parent[current] ?? root
            parent[current] = root
            current = next
        }
        return root
    }

    private func join(_ nodes: [String]) {
        let present = nodes.filter { !$0.isEmpty }
        guard let first = present.first else { return }
        _ = find(first)
        for node in present.dropFirst() {
            let a = find(first)
            let b = find(node)
            if a != b { parent[a] = b }
        }
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

    /// One key per person, the same for every record of them.
    func key(_ kind: TaskPersonKind, _ id: UUID) -> String {
        let storedId: String
        switch kind {
        case .manager: storedId = manager(id)?.firestoreDocumentId ?? Self.storedTaskId(id)
        case .operative: storedId = operative(id)?.documentId ?? Self.storedTaskId(id)
        }
        let node = Self.idNode(storedId)
        guard !node.isEmpty else { return "id:" }
        guard parent[node] != nil else { return node }
        return keyByRoot[find(node)] ?? node
    }

    /// True when every users document of the person is a ghost operative (no login).
    func isGhost(_ key: String) -> Bool {
        ghostKeys.contains(key)
    }

    // MARK: Shared index

    /// The last index, the store revisions it was checked against, and the hash of the fields it reads.
    private static var cached: (
        operativeStore: ObjectIdentifier,
        operativeRevision: Int,
        userStore: ObjectIdentifier,
        userRevision: Int,
        contentHash: Int,
        index: TaskPersonIndex
    )?

    /// A hash of exactly the fields the index reads: every users document's id, email, former and same-email ids and
    /// ghost flag; every row's id, stored id, email, account link and name (names are shown through the index).
    /// Anything else on a user (`lastSeenAt`, pay, permissions) does not rebuild it.
    static func contentHash(managers: [Manager], operatives: [Operative], users: [AppUser]) -> Int {
        var hasher = Hasher()
        hasher.combine(managers.count)
        for row in managers {
            hasher.combine(row.id)
            hasher.combine(row.firestoreDocumentId)
            hasher.combine(row.email)
            hasher.combine(row.linkedUserId)
            hasher.combine(row.firstName)
            hasher.combine(row.lastName)
        }
        hasher.combine(operatives.count)
        for row in operatives {
            hasher.combine(row.id)
            hasher.combine(row.documentId)
            hasher.combine(row.email)
            hasher.combine(row.linkedUserId)
            hasher.combine(row.firstName)
            hasher.combine(row.lastName)
        }
        hasher.combine(users.count)
        for user in users {
            hasher.combine(user.id)
            hasher.combine(user.email)
            hasher.combine(user.formerUserIds)
            hasher.combine(user.sameEmailUserIds)
            hasher.combine(user.isGhost)
        }
        return hasher.finalize()
    }

    /// The index for the open stores. Unchanged store revisions reuse it at once (task cards call this on every
    /// redraw). When a revision moved, the fields the index reads are hashed, and the closure (one `personIdSet` call
    /// per roster row) is rebuilt only when that hash changed — never for a `lastSeenAt` or other unrelated write.
    static func current(operativeStore: OperativeStore, userStore: UserStore) -> TaskPersonIndex {
        let operativeId = ObjectIdentifier(operativeStore)
        let userId = ObjectIdentifier(userStore)
        if let cached,
           cached.operativeStore == operativeId, cached.operativeRevision == operativeStore.revision,
           cached.userStore == userId, cached.userRevision == userStore.revision {
            return cached.index
        }
        let managers = operativeStore.allManagers
        let operatives = operativeStore.allOperatives
        let users = userStore.organizationUsers
        let hash = contentHash(managers: managers, operatives: operatives, users: users)
        let index: TaskPersonIndex
        if let cached, cached.contentHash == hash {
            index = cached.index
        } else {
            index = TaskPersonIndex(managers: managers, operatives: operatives, users: users)
        }
        cached = (operativeId, operativeStore.revision, userId, userStore.revision, hash, index)
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
    /// Ids of the rows `listedCurrentLabourPeople` keeps (web `isCurrentLabourNamedPerson`: never an anonymised
    /// deleted profile). Nil when the script did not answer (then every row is kept).
    private static func currentLabourIds(_ rows: [(id: UUID, email: String, first: String, last: String)]) -> Set<String>? {
        let input: [[String: Any]] = rows.map {
            [
                "id": $0.id.uuidString,
                "email": $0.email,
                "firstName": $0.first,
                "surname": $0.last,
                "name": "\($0.first) \($0.last)".trimmingCharacters(in: .whitespaces),
                "displayName": "",
            ]
        }
        guard let listed = CanonicalBusinessEngine.callJSON("listedCurrentLabourPeople", arguments: [input]) as? [Any] else {
            return nil
        }
        return Set(listed.compactMap { ($0 as? [String: Any])?["id"] as? String })
    }

    static func pickerPeople(
        managers allManagers: [Manager],
        operatives allOperatives: [Operative],
        route: Route,
        index: TaskPersonIndex
    ) -> (managers: [Manager], operatives: [Operative]) {
        let currentManagers = currentLabourIds(allManagers.map { (id: $0.id, email: $0.email, first: $0.firstName, last: $0.lastName) })
        let currentOperatives = currentLabourIds(allOperatives.map { (id: $0.id, email: $0.email, first: $0.firstName, last: $0.lastName) })
        let managers = allManagers.filter { currentManagers?.contains($0.id.uuidString) ?? true }
        let operatives = allOperatives.filter { currentOperatives?.contains($0.id.uuidString) ?? true }
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

    /// Guardrail 3: ids already assigned whose person no picker row shows, one entry per person, in the order given
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

    /// RULEBOOK 1.89.0 §32 bug B11: every assignee, one per person, managers first — an id whose row is gone, or an
    /// anonymised deleted profile, reads "Removed user" (`taskAssigneeDisplay`) and is flagged so the task can be
    /// reassigned. Display only.
    static func assigneeEntries(
        managerIds: [UUID],
        operativeIds: [UUID],
        index: TaskPersonIndex
    ) -> [(kind: TaskPersonKind, name: String, removed: Bool)] {
        var seen = Set<String>()
        var out: [(kind: TaskPersonKind, name: String, removed: Bool)] = []
        func add(_ kind: TaskPersonKind, _ id: UUID) {
            guard seen.insert(index.key(kind, id)).inserted else { return }
            let display: (name: String, removed: Bool)
            switch kind {
            case .manager:
                if let row = index.manager(id) {
                    display = TaskRulebook.assigneeDisplay(firstName: row.fullName, lastName: nil, email: row.email, exists: true)
                } else {
                    display = TaskRulebook.assigneeDisplay(firstName: nil, lastName: nil, email: nil, exists: false)
                }
            case .operative:
                if let row = index.operative(id) {
                    display = TaskRulebook.assigneeDisplay(firstName: row.name, lastName: nil, email: row.email, exists: true)
                } else {
                    display = TaskRulebook.assigneeDisplay(firstName: nil, lastName: nil, email: nil, exists: false)
                }
            }
            out.append((kind, display.name, display.removed))
        }
        for id in managerIds { add(.manager, id) }
        for id in operativeIds { add(.operative, id) }
        return out
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
