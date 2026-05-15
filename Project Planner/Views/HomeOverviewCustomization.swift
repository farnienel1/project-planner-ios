//
//  HomeOverviewCustomization.swift
//  Project Planner
//

import SwiftUI

/// Identifiers for home “Today’s overview” metric pills (admins pick up to three).
enum HomeOverviewMetricID: String, CaseIterable, Codable, Identifiable {
    case tasksDueTodayPersonal
    case tasksDueWeekPersonal
    case warnings
    case operativesOnSite
    case managersOnSite
    case operativesOnAL
    case managersOnAL
    case outstandingTasksAllUsers

    var id: String { rawValue }

    /// Row title in the customize sheet (admin-facing, full wording).
    var catalogTitle: String {
        switch self {
        case .tasksDueTodayPersonal: return "Tasks Today (Personal tasks)"
        case .tasksDueWeekPersonal: return "Tasks due this week (Personal Tasks)"
        case .warnings: return "Warnings"
        case .operativesOnSite: return "Operatives on site"
        case .managersOnSite: return "Managers on Site"
        case .operativesOnAL: return "Operatives on AL"
        case .managersOnAL: return "Managers on AL"
        case .outstandingTasksAllUsers: return "Outstanding Tasks (All Users)"
        }
    }

    /// Short label on the home overview card.
    var compactPillTitle: String {
        switch self {
        case .tasksDueTodayPersonal: return "Due today"
        case .tasksDueWeekPersonal: return "This week"
        case .warnings: return "Warnings"
        case .operativesOnSite: return "Ops on site"
        case .managersOnSite: return "Mgrs on site"
        case .operativesOnAL: return "Ops on AL"
        case .managersOnAL: return "Mgrs on AL"
        case .outstandingTasksAllUsers: return "Open tasks"
        }
    }
}

// MARK: - Admin customize sheet

struct AdminHomeOverviewCustomizeSheet: View {
    @Binding var draftMetricIds: [HomeOverviewMetricID]
    let metricValue: (HomeOverviewMetricID) -> String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var selectedSet: Set<HomeOverviewMetricID> {
        Set(draftMetricIds)
    }

    private var addableMetrics: [HomeOverviewMetricID] {
        HomeOverviewMetricID.allCases.filter { !selectedSet.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Shown on home (up to 3)")
                        .font(.system(size: 13, weight: .semibold))

                    HStack(alignment: .top, spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            if index < draftMetricIds.count {
                                let mid = draftMetricIds[index]
                                metricPillReplica(
                                    value: metricValue(mid),
                                    title: mid.compactPillTitle,
                                    showRemove: draftMetricIds.count > 1
                                ) {
                                    draftMetricIds.remove(at: index)
                                }
                            } else {
                                emptySlotReplica
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.094, green: 0.373, blue: 0.647),
                                Color(red: 0.216, green: 0.541, blue: 0.867)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Text("These are just organisation metrics.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text("Add metrics")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 4)

                    VStack(spacing: 0) {
                        ForEach(addableMetrics) { metric in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(metric.catalogTitle)
                                        .font(.system(size: 15, weight: .medium))
                                    Text("Current: \(metricValue(metric))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    guard draftMetricIds.count < 3 else { return }
                                    draftMetricIds.append(metric)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(draftMetricIds.count >= 3 ? Color.secondary.opacity(0.35) : Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .disabled(draftMetricIds.count >= 3)
                            }
                            .padding(.vertical, 12)
                            if metric != addableMetrics.last {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Dashboard metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .disabled(draftMetricIds.isEmpty)
                }
            }
        }
    }

    private func metricPillReplica(value: String, title: String, showRemove: Bool, onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if showRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptySlotReplica: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
    }
}
