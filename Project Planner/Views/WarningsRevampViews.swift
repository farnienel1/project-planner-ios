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
    case annualLeave = "Annual leave"
    case materials = "Materials"
    case qualifications = "Qualifications"

    var id: String { rawValue }
}

/// Content of the Warnings navy header. Sits on the navy backdrop the Warnings screen draws behind it.
struct WarningsHeroCard: View {
    let activeCount: Int
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active issues")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.1)
                        .foregroundStyle(PPColor.onNavySecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(activeCount)")
                            .font(.system(.largeTitle, design: .rounded))
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("need attention")
                            .font(.system(.title3, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                PPIconTile(symbol: "exclamationmark.triangle.fill", family: .alert, size: 44, lifted: true)
            }

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(highCount)", label: "High", highlight: true)
                PPStatDivider()
                PPStat(value: "\(mediumCount)", label: "Medium")
                PPStatDivider()
                PPStat(value: "\(lowCount)", label: "Low")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)

            Text("High: operative booking clashes, unbooked labour, and bookings during annual leave (approve clashes for the weekly report) · Medium: manager/admin overlaps and a half day of leave that is not covered · Low: materials and qualifications")
                .font(.caption)
                .foregroundStyle(PPColor.onNavyCaption)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(isOn ? PPColor.brand : PPColor.card))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(.separator), lineWidth: isOn ? 0 : 0.5)
                            )
                    }
                    .accessibilityIdentifier("warningsFilterChips.row.\(chip.id)")
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
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.18)))
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
        )
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .accessibilityIdentifier("warningRemove.dismiss")
        .buttonStyle(.plain)
    }
}
