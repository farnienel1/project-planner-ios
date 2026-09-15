//
//  OfflineTaskLocalStore.swift
//  Project Planner
//
//  Last-known tasks snapshot so the Home Tasks hub still opens offline.
//

import Foundation

@MainActor
final class OfflineTaskLocalStore {
    static let shared = OfflineTaskLocalStore()

    private let storageKeyPrefix = "offline_tasks_snapshot_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func save(_ tasks: [ProjectTask], organizationId: String) {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else { return }
        do {
            let data = try encoder.encode(tasks)
            UserDefaults.standard.set(data, forKey: key(orgId))
        } catch {
            print("🔥🔥🔥 DEBUG: OfflineTaskLocalStore save failed: \(error.localizedDescription)")
        }
    }

    func load(organizationId: String) -> [ProjectTask] {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(orgId)) else { return [] }
        do {
            return try decoder.decode([ProjectTask].self, from: data)
        } catch {
            print("🔥🔥🔥 DEBUG: OfflineTaskLocalStore load failed: \(error.localizedDescription)")
            return []
        }
    }

    func upsert(_ task: ProjectTask, organizationId: String) {
        var tasks = load(organizationId: organizationId)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        save(tasks, organizationId: organizationId)
    }

    func remove(taskId: UUID, organizationId: String) {
        var tasks = load(organizationId: organizationId)
        tasks.removeAll { $0.id == taskId }
        save(tasks, organizationId: organizationId)
    }

    private func key(_ organizationId: String) -> String {
        "\(storageKeyPrefix).\(organizationId)"
    }
}
