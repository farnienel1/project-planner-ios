//
//  StaffTradeType.swift
//  Project Planner
//
//  Trade type for operatives and managers (scheduling, reports, roster).
//

import Foundation

enum StaffTradeType: String, CaseIterable, Identifiable, Codable, Sendable {
    case electrician = "Electrician"
    case plumber = "Plumber"
    case acEngineer = "AC Engineer"
    case ventilation = "Ventilation"
    case gasEngineer = "Gas Engineer"
    case carpenter = "Carpenter"
    case roofer = "Roofer"
    case bricklayer = "Bricklayer"
    case groundworker = "Groundworker"
    case other = "Other"

    var id: String { rawValue }

    /// Presets shown in pickers (includes Other).
    static var pickerCases: [StaffTradeType] { allCases }

    static func displayLabel(presetRaw: String?, custom: String?) -> String {
        let trimmedCustom = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let preset = presetRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !preset.isEmpty else {
            return trimmedCustom.isEmpty ? "—" : trimmedCustom
        }
        if preset == StaffTradeType.other.rawValue {
            return trimmedCustom.isEmpty ? StaffTradeType.other.rawValue : trimmedCustom
        }
        return preset
    }

    /// True when a value can be saved (mandatory fields complete).
    static func isComplete(presetRaw: String?, custom: String?) -> Bool {
        guard let preset = presetRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !preset.isEmpty else {
            return false
        }
        if preset == StaffTradeType.other.rawValue {
            let c = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !c.isEmpty
        }
        return true
    }

    /// Sort key: known presets first (alphabetically by display), then "Other", then unknown/custom-only.
    static func sortKey(presetRaw: String?, custom: String?) -> String {
        let label = displayLabel(presetRaw: presetRaw, custom: custom)
        if label == "—" { return "~" }
        return label.lowercased()
    }
}

extension Operative {
    var displayTradeType: String {
        StaffTradeType.displayLabel(presetRaw: tradeTypePreset, custom: tradeTypeCustom)
    }
}

extension Manager {
    var displayTradeType: String {
        StaffTradeType.displayLabel(presetRaw: tradeTypePreset, custom: tradeTypeCustom)
    }
}

extension AppUser {
    var displayTradeType: String {
        StaffTradeType.displayLabel(presetRaw: tradeTypePreset, custom: tradeTypeCustom)
    }
}
