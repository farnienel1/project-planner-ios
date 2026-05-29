//
//  ProjectSmallWorksRevampTokens.swift
//  Project Planner
//
//  Shared palette and list UI for Projects / Small Works revamp (matches design reference).
//

import SwiftUI

enum ProjectWorksRevampColors {
    static let canvas = Color(red: 0.969, green: 0.973, blue: 0.980) // #F7F8FA
    static let ink = Color(red: 0.043, green: 0.063, blue: 0.125) // #0B1020
    static let muted = Color(red: 0.420, green: 0.451, blue: 0.490) // #6B7280
    static let border = Color(red: 0.933, green: 0.941, blue: 0.953) // #EEF0F3
    static let searchBorder = Color(red: 0.898, green: 0.906, blue: 0.922) // #E5E7EB
    static let blue = Color(red: 0.094, green: 0.373, blue: 0.647) // #185FA5
    static let blueLight = Color(red: 0.216, green: 0.541, blue: 0.867) // #378ADD
    static let activeGreen = Color(red: 0.059, green: 0.431, blue: 0.337) // #0F6E56
    static let upcomingAmber = Color(red: 0.522, green: 0.310, blue: 0.043) // #854F0B
    static let jobTypePillBg = Color(red: 0.933, green: 0.929, blue: 0.996) // #EEEDFE
    static let jobTypePillInk = Color(red: 0.235, green: 0.204, blue: 0.537) // #3C3489
    static let requiredPillFg = Color(red: 0.639, green: 0.176, blue: 0.176) // #A32D2D
    static let requiredPillBg = Color(red: 0.988, green: 0.922, blue: 0.922) // #FCEBEB
    static let placeholderInk = Color(red: 0.773, green: 0.788, blue: 0.824) // #C5C9D2
    static let pinRoseBg = Color(red: 0.984, green: 0.918, blue: 0.941) // #FBEAF0
    static let pinRoseFg = Color(red: 0.600, green: 0.208, blue: 0.337) // #993556
    static let endDateBg = Color(red: 0.980, green: 0.925, blue: 0.906) // #FAECE7
    static let endDateFg = Color(red: 0.600, green: 0.235, blue: 0.114) // #993C1D
}

struct WorksListStatusCounts {
    let active: Int
    let upcoming: Int
    let completed: Int

    var all: Int { active + upcoming + completed }

    static func from(_ projects: [Project]) -> WorksListStatusCounts {
        var a = 0, u = 0, c = 0
        for p in projects {
            switch p.status {
            case .active: a += 1
            case .upcoming: u += 1
            case .completed: c += 1
            case .inactive: break
            }
        }
        return WorksListStatusCounts(active: a, upcoming: u, completed: c)
    }
}

enum WorksListProgress {
    /// Timeline-based progress for list cards (0…1). Completed jobs show 100%.
    static func fraction(for project: Project) -> Double {
        if project.status == .completed { return 1 }
        let total = project.endDate.timeIntervalSince(project.startDate)
        guard total > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(project.startDate)
        return min(max(elapsed / total, 0), 1)
    }
}

struct WorksListStatsRow: View {
    let counts: WorksListStatusCounts

    var body: some View {
        HStack(spacing: 10) {
            statCell(value: counts.active, label: "Active", valueColor: ProjectWorksRevampColors.activeGreen)
            statCell(value: counts.upcoming, label: "Upcoming", valueColor: ProjectWorksRevampColors.upcomingAmber)
            statCell(value: counts.completed, label: "Completed", valueColor: ProjectWorksRevampColors.muted)
        }
    }

    private func statCell(value: Int, label: String, valueColor: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }
}

struct WorksListSearchRow<FilterMenu: View>: View {
    @Binding var text: String
    var placeholder: String
    @ViewBuilder var filterMenu: () -> FilterMenu

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            TextField(placeholder, text: $text)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            filterMenu()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
        )
    }
}

/// Two-letter initials for avatars (matches design HTML chips).
enum PlannerUIInitials {
    static func from(_ name: String, maxLen: Int = 2) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count >= 2 {
            let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
            return letters.joined()
        }
        let s = parts.first ?? trimmed
        return String(s.prefix(maxLen)).uppercased()
    }
}

struct WorksRevampFilterChip: View {
    let title: String
    let isSelected: Bool
    let selectedForeground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : selectedForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? ProjectWorksRevampColors.blue : Color.white)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App chrome (DesignReference home HTML — #F7F8FA canvas + nav bar)

extension View {
    /// Matches `project_planner_home_with_up_next_restored.html`: content and navigation bar share the same canvas.
    func appChromeNavigationBarSurface() -> some View {
        self
            .toolbarBackground(ProjectWorksRevampColors.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// White card with 14pt radius and hairline border (quick actions / list rows in mocks).
    func appChromeCardContainer(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
    }
}
