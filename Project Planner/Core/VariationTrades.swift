//
//  VariationTrades.swift
//  Project Planner
//
//  Shared trade list for variations. Custom trades live on
//  organizations/{orgId}/settings/variationTrades.
//

import Foundation

nonisolated enum VariationTrades {
    static let standard: [String] = [
        "Electrician",
        "Approved electrician",
        "Electrician's mate",
        "Plumber",
        "Pipefitter",
        "Ductwork fitter",
        "Ventilation fitter",
        "Sheet metal worker",
        "Gas engineer",
        "Refrigeration engineer",
        "Welder",
        "Insulation engineer",
        "BMS engineer",
        "Fire alarm engineer",
        "Sprinkler fitter",
        "Drainage operative",
        "Commissioning engineer",
        "Testing and inspection",
        "Supervisor",
        "Labourer"
    ]

    static let customPickerTitle = "Custom trade…"

    static func mergedPickerOptions(custom: [String]) -> [String] {
        var seen = Set(standard.map { $0.lowercased() })
        var extras: [String] = []
        for trade in custom {
            let trimmed = trade.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            extras.append(trimmed)
        }
        extras.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return standard + extras
    }
}
