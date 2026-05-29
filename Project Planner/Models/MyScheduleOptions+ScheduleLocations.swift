//
//  MyScheduleOptions+ScheduleLocations.swift
//  Project Planner
//
//  Shared helpers so General → My Schedule, Book labour, daily overview, and weekly
//  reports use the same enabled location set.
//

import Foundation

/// A pickable “other” location row (office / WFH / site survey / custom), aligned with
/// `MyScheduleOptions` in App & account → General.
enum ScheduleLocationPick: Hashable, Identifiable {
    case office
    case workingFromHome
    case siteSurvey
    case custom(String)

    var id: String {
        switch self {
        case .office: return "office"
        case .workingFromHome: return "wfh"
        case .siteSurvey: return "site_survey"
        case .custom(let name): return "custom:\(name)"
        }
    }

    var title: String {
        switch self {
        case .office: return "Office"
        case .workingFromHome: return "Working from home"
        case .siteSurvey: return "Site survey"
        case .custom(let name): return name
        }
    }

    var managerLocationType: ManagerLocationType {
        switch self {
        case .office: return .office
        case .workingFromHome: return .workingFromHome
        case .siteSurvey: return .siteSurvey
        case .custom: return .custom
        }
    }

    var customLocationName: String? {
        if case .custom(let name) = self { return name }
        return nil
    }
}

extension MyScheduleOptions {
    /// Locations shown under “Other” / Book labour — same rows as My Schedule “Book yourself in”.
    func enabledScheduleLocationPicks() -> [ScheduleLocationPick] {
        var rows: [ScheduleLocationPick] = []
        if showOffice { rows.append(.office) }
        if showWorkingFromHome { rows.append(.workingFromHome) }
        if showSiteSurvey { rows.append(.siteSurvey) }
        for raw in customItems {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { rows.append(.custom(trimmed)) }
        }
        return rows
    }

    /// Whether a manager-site booking should appear in UI/reports driven by schedule options.
    func includesManagerScheduleLocation(_ booking: ManagerSiteBooking) -> Bool {
        switch booking.locationType {
        case .project, .smallWork:
            return true
        case .office:
            return showOffice
        case .workingFromHome:
            return showWorkingFromHome
        case .siteSurvey:
            return showSiteSurvey
        case .custom:
            let name = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty { return false }
            return customItems.contains { custom in
                custom.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }
}
