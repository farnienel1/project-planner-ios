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
        case .tasksDueTodayPersonal: return "Tasks Due Today (My Tasks)"
        case .tasksDueWeekPersonal: return "Tasks Due This Week (My Tasks)"
        case .warnings: return "Warnings"
        case .operativesOnSite: return "People on Site (Operatives + Managers)"
        case .managersOnSite: return "Managers on Site"
        case .operativesOnAL: return "Operatives on AL"
        case .managersOnAL: return "Managers on AL"
        case .outstandingTasksAllUsers: return "Open Tasks (All Users)"
        }
    }

    /// Short label on the home overview card.
    var compactPillTitle: String {
        switch self {
        case .tasksDueTodayPersonal: return "Tasks Due Today"
        case .tasksDueWeekPersonal: return "Tasks Due This Week"
        case .warnings: return "Warnings"
        case .operativesOnSite: return "People on Site"
        case .managersOnSite: return "Managers on Site"
        case .operativesOnAL: return "Operatives on AL"
        case .managersOnAL: return "Managers on AL"
        case .outstandingTasksAllUsers: return "Open Tasks (All Users)"
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
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)

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
                    .background(PPNavyBackdrop())
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Text("These are just organisation metrics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Add metrics")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .padding(.top, 4)

                    VStack(spacing: 0) {
                        ForEach(addableMetrics) { metric in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(metric.catalogTitle)
                                        .font(.body)
                                    Text("Current: \(metricValue(metric))")
                                        .font(.footnote)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    guard draftMetricIds.count < 3 else { return }
                                    draftMetricIds.append(metric)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(draftMetricIds.count >= 3 ? Color.secondary.opacity(0.35) : PPColor.brand)
                                }
                                .accessibilityIdentifier("adminHomeOverviewCustomize.row.\(metric.id).plusCircleFill")
                                .buttonStyle(.plain)
                                .disabled(draftMetricIds.count >= 3)
                            }
                            .padding(.vertical, 12)
                            if metric != addableMetrics.last {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(height: 0.5)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(PPColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.vertical, 20)
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Dashboard metrics")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("adminHomeOverviewCustomize.cancel")
                        .tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .accessibilityIdentifier("adminHomeOverviewCustomize.save")
                    .font(.body.weight(.semibold))
                    .tint(.white)
                    .disabled(draftMetricIds.isEmpty)
                }
            }
        }
    }

    private func metricPillReplica(value: String, title: String, showRemove: Bool, onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(PPColor.onNavyCaption)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(PPColor.onNavyFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
            )

            if showRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                .accessibilityIdentifier("adminHomeOverviewCustomize.remove")
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
