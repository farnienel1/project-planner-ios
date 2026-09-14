//
//  WarningsDiskCache.swift
//  Project Planner
//
//  Rebuild contract: Home never scans. Warnings UI reads this cache.
//  Only an explicit user Refresh (today-only) rewrites the cache.
//

import Foundation

struct WarningsDiskCache: Codable {
    var savedAt: Date
    var hasCompletedLiveDetection: Bool
    var allGeneratedWarnings: [Warning]
    var activeWarnings: [Warning]
    var warningCount: Int
    var highCount: Int
    var mediumCount: Int
    var lowCount: Int

    static let empty = WarningsDiskCache(
        savedAt: .distantPast,
        hasCompletedLiveDetection: false,
        allGeneratedWarnings: [],
        activeWarnings: [],
        warningCount: 0,
        highCount: 0,
        mediumCount: 0,
        lowCount: 0
    )
}

enum WarningsDiskCacheStore {
    private static let fileName = "warnings-live-cache-v1.json"

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("ProjectPlanner", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    static func load() -> WarningsDiskCache {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(WarningsDiskCache.self, from: data)) ?? .empty
    }

    static func save(_ cache: WarningsDiskCache) {
        let url = fileURL
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
        print("🔥🔥🔥 DEBUG: WarningsDiskCache saved active=\(cache.activeWarnings.count) completed=\(cache.hasCompletedLiveDetection)")
    }
}
