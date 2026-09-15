//
//  ProjectSmallWorksRevampTokens.swift
//  Project Planner
//
//  Shared palette and list UI for Projects / Small Works revamp (matches design reference).
//

import SwiftUI
import UIKit

enum ProjectWorksRevampColors {
    static let canvas = hsDyn("#F7F8FA", "#0B1017")
    static let card = hsDyn("#FFFFFF", "#151C26")
    static let ink = hsDyn("#0B1020", "#F2F5F9")
    static let muted = hsDyn("#6B7280", "#9AA7B8")
    static let border = hsDyn("#EEF0F3", "#252F3D")
    static let searchBorder = hsDyn("#E5E7EB", "#2A3544")
    static let blue = hsDyn("#185FA5", "#6B95FF")
    static let blueLight = hsDyn("#378ADD", "#8BB4FF")
    static let activeGreen = hsDyn("#0F6E56", "#2ED18D")
    static let upcomingAmber = hsDyn("#854F0B", "#F2AE45")
    static let jobTypePillBg = hsDyn("#EEEDFE", "#241F45")
    static let jobTypePillInk = hsDyn("#3C3489", "#C8C0FF")
    static let requiredPillFg = hsDyn("#A32D2D", "#FF6F63")
    static let requiredPillBg = hsDyn("#FCEBEB", "#3A1E1B")
    static let placeholderInk = hsDyn("#C5C9D2", "#6B7686")
    static let pinRoseBg = hsDyn("#FBEAF0", "#3A1E28")
    static let pinRoseFg = hsDyn("#993556", "#F0A0B8")
    static let endDateBg = hsDyn("#FAECE7", "#3A2418")
    static let endDateFg = hsDyn("#993C1D", "#F0B090")
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
    /// Timeline-based progress for list cards (0…1). Completed or past end date shows 100%.
    static func fraction(for project: Project) -> Double {
        if project.status == .completed { return 1 }
        let total = project.endDate.timeIntervalSince(project.startDate)
        guard total > 0 else { return 0 }
        let now = Date()
        if now > project.endDate { return 1 }
        let elapsed = now.timeIntervalSince(project.startDate)
        return min(max(elapsed / total, 0), 1)
    }

    static func percentDisplay(for project: Project) -> Int {
        min(100, Int((fraction(for: project) * 100).rounded()))
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
        .background(ProjectWorksRevampColors.card)
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
        .background(ProjectWorksRevampColors.card)
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
            let letters = parts.prefix(maxLen).compactMap { $0.first }.map { String($0).uppercased() }
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
                        .fill(isSelected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.card)
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
            .background(ProjectWorksRevampColors.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
    }
}
