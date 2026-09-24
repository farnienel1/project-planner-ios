//
//  WarningsRevampViews.swift
//  Project Planner
//
//  Revamped warnings UI (warnings_three_priorities.html).
//

import SwiftUI

enum WarningsFilterChip: String, CaseIterable, Identifiable {
    case all = "All"
    case clashes = "Clashes"
    case unbooked = "Unbooked"
    case materials = "Materials"
    case qualifications = "Qualifications"

    var id: String { rawValue }
}

struct WarningsHeroCard: View {
    let activeCount: Int
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Active issues")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(alignment: .center) {
                Text("\(activeCount) need attention")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                priorityStat(value: highCount, label: "High")
                priorityStat(value: mediumCount, label: "Medium")
                priorityStat(value: lowCount, label: "Low")
            }
            .padding(.bottom, 12)

            Text("High: operative booking clashes & unbooked labour (approve clashes for the weekly report) · Medium: manager/admin overlaps · Low: materials and qualifications")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.722, green: 0.196, blue: 0.196), // #B83232
                    Color(red: 0.620, green: 0.165, blue: 0.165)  // #9E2A2A
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func priorityStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WarningsFilterChipsRow: View {
    @Binding var selected: WarningsFilterChip
    let counts: [WarningsFilterChip: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WarningsFilterChip.allCases) { chip in
                    let count = counts[chip] ?? 0
                    let isOn = selected == chip
                    Button {
                        selected = chip
                    } label: {
                        Text("\(chip.rawValue) · \(count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isOn ? Color.white : Color(red: 0.420, green: 0.447, blue: 0.502))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(isOn ? Color(red: 0.110, green: 0.110, blue: 0.118) : Color.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.black.opacity(0.10), lineWidth: isOn ? 0 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct WarningPriorityBadge: View {
    let severity: Warning.WarningSeverity

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.18))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private var label: String {
        switch severity {
        case .high: return "HIGH"
        case .medium: return "MEDIUM"
        case .low: return "LOW"
        }
    }
}


struct WarningRemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Dismiss")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.420, green: 0.447, blue: 0.502))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}
