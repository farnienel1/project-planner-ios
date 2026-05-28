import Foundation

enum TradeTypeInventory {
    nonisolated private static let storageKey = "tradeTypeInventory.v1"

    nonisolated private static let seededDefaults: [String] = [
        "Electrician",
        "Plumber",
        "AC Engineer",
        "Ventilation",
        "Gas Engineer",
        "Carpenter",
        "Roofer",
        "Bricklayer",
        "Groundworker",
        "Scaffolder",
        "Brick & Block",
        "Dryliner",
        "Painter & Decorator",
        "Demolition",
        "Steel Fixer",
        "Plant Operator",
        "Finance",
        "Contract Manager",
        "Project Manager",
        "Site Manager",
        "Supervisor",
        "Installer",
        "Commissioning Engineer",
        "Programmer",
    ]

    nonisolated static func knownTrades(extra: [String] = []) -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        return uniqueSorted(from: seededDefaults + stored + extra)
    }

    nonisolated static func register(_ trade: String) {
        let value = normalized(trade)
        guard !value.isEmpty else { return }
        let stored = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        let merged = uniqueSorted(from: stored + [value])
        UserDefaults.standard.set(merged, forKey: storageKey)
    }

    nonisolated static func suggestions(query: String, extra: [String] = []) -> [String] {
        let q = normalized(query)
        guard !q.isEmpty else { return [] }
        return knownTrades(extra: extra)
            .filter {
                $0.localizedCaseInsensitiveContains(q) &&
                $0.compare(q, options: .caseInsensitive) != .orderedSame
            }
    }

    nonisolated private static func uniqueSorted(from values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map(normalized)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

