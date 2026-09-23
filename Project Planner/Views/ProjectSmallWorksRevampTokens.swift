//
//  ProjectSmallWorksRevampTokens.swift
//  Project Planner
//
//  Shared palette and list UI for Projects / Small Works revamp (matches design reference).
//

import SwiftUI
import UIKit

enum ProjectWorksRevampColors {
    static let canvas = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.969, 0.973, 0.980), // #F7F8FA
        dark: AppAdaptiveColor.rgb(0.071, 0.078, 0.102)   // #12141A
    )
    static let surface = AppAdaptiveColor.dynamic(
        light: .white,
        dark: AppAdaptiveColor.rgb(0.110, 0.122, 0.157)   // #1C1F28
    )
    static let card = surface
    static let ink = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.043, 0.063, 0.125), // #0B1020
        dark: AppAdaptiveColor.rgb(0.953, 0.961, 0.973)   // #F3F5F8
    )
    static let muted = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.420, 0.451, 0.490), // #6B7280
        dark: AppAdaptiveColor.rgb(0.620, 0.655, 0.710)   // #9EA7B5
    )
    static let border = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.941, 0.953), // #EEF0F3
        dark: AppAdaptiveColor.rgb(0.180, 0.196, 0.247)   // #2E3240
    )
    static let searchBorder = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.898, 0.906, 0.922), // #E5E7EB
        dark: AppAdaptiveColor.rgb(0.220, 0.239, 0.298)   // #383D4C
    )
    static let blue = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.094, 0.373, 0.647), // #185FA5
        dark: AppAdaptiveColor.rgb(0.380, 0.655, 0.910)   // #61A7E8
    )
    static let blueLight = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.216, 0.541, 0.867), // #378ADD
        dark: AppAdaptiveColor.rgb(0.478, 0.722, 0.941)   // #7AB8F0
    )
    static let activeGreen = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.059, 0.431, 0.337), // #0F6E56
        dark: AppAdaptiveColor.rgb(0.290, 0.827, 0.655)   // #4AD3A7
    )
    static let upcomingAmber = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.522, 0.310, 0.043), // #854F0B
        dark: AppAdaptiveColor.rgb(0.957, 0.769, 0.376)   // #F4C460
    )
    static let jobTypePillBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.929, 0.996), // #EEEDFE
        dark: AppAdaptiveColor.rgb(0.173, 0.161, 0.314)   // #2C2950
    )
    static let jobTypePillInk = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.235, 0.204, 0.537), // #3C3489
        dark: AppAdaptiveColor.rgb(0.769, 0.718, 0.992)   // #C4B7FD
    )
    static let requiredPillFg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.639, 0.176, 0.176), // #A32D2D
        dark: AppAdaptiveColor.rgb(0.973, 0.506, 0.506)   // #F88181
    )
    static let requiredPillBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.988, 0.922, 0.922), // #FCEBEB
        dark: AppAdaptiveColor.rgb(0.239, 0.125, 0.137)   // #3D2023
    )
    static let placeholderInk = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.773, 0.788, 0.824), // #C5C9D2
        dark: AppAdaptiveColor.rgb(0.420, 0.451, 0.522)   // #6B7385
    )
    static let pinRoseBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.984, 0.918, 0.941), // #FBEAF0
        dark: AppAdaptiveColor.rgb(0.239, 0.133, 0.176)   // #3D222D
    )
    static let pinRoseFg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.600, 0.208, 0.337), // #993556
        dark: AppAdaptiveColor.rgb(0.957, 0.655, 0.753)   // #F4A7C0
    )
    static let endDateBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.980, 0.925, 0.906), // #FAECE7
        dark: AppAdaptiveColor.rgb(0.239, 0.157, 0.125)   // #3D2820
    )
    static let endDateFg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.600, 0.235, 0.114), // #993C1D
        dark: AppAdaptiveColor.rgb(0.941, 0.659, 0.510)   // #F0A882
    )
    static let blueTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.902, 0.945, 0.984),
        dark: AppAdaptiveColor.rgb(0.110, 0.173, 0.247)
    )
    static let greenTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.882, 0.961, 0.933),
        dark: AppAdaptiveColor.rgb(0.090, 0.220, 0.165)
    )
    static let amberTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.980, 0.933, 0.855),
        dark: AppAdaptiveColor.rgb(0.239, 0.180, 0.090)
    )
    static let grayTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.949, 0.953, 0.961),
        dark: AppAdaptiveColor.rgb(0.145, 0.157, 0.196)
    )
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
        .background(ProjectWorksRevampColors.surface)
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
        .background(ProjectWorksRevampColors.surface)
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
                        .fill(isSelected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.surface)
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
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
    }
}
