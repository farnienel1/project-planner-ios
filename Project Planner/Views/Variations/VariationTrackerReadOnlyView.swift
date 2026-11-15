//
//  VariationTrackerReadOnlyView.swift
//  Project Planner
//

import SwiftUI

struct VariationTrackerReadOnlyView: View {
    @ObservedObject var store: VariationStore
    let parentName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                trackerNavyHeader

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        PPIconTile(symbol: "lock.fill", family: .trade)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Read-only tracker. The order and numbering can be managed on the web app.")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            // RULEBOOK 1.52.0 §22: the tracker's order lock, set on web (`orderLocked`).
                            if store.tracker.orderLocked {
                                Text(lockedText)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("variationTracker.locked")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    .padding(.top, 16)

                    PPGroupLabel(text: "Variations")

                    PPGroupedCard {
                        ForEach(planRows, id: \.id) { row in
                            if let variation = byId[row.id.lowercased()] {
                                trackerRow(variation, row: row)
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Tracker")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
    }

    /// Navy header: the parent this tracker belongs to and how many variations it lists.
    private var trackerNavyHeader: some View {
        // RULEBOOK 1.52.0 §22 `variationListTotals`.
        let totals = CanonicalBusinessEngine.variationListTotals(store.variations.map(\.rulebookInput)) ?? .zero
        let count = totals.count
        return VStack(alignment: .leading, spacing: 8) {
            PPOverviewTitle(
                eyebrow: parentName,
                count: "\(count)",
                countLabel: count == 1 ? "variation" : "variations"
            )
            Text("\(String(format: "%g", totals.labourHours)) hrs · \(totals.materialsCount) materials · \(totals.evidenceCount) evidence")
                .font(.footnote)
                .foregroundStyle(PPColor.onNavySecondary)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    /// RULEBOOK 1.52.0 §22 `variationRenumberPlan` over every stored variation (deleted ones included, which keep their
    /// numbers reserved) with no new order: the tracker's order and numbers, pinned rows in their places.
    private var planRows: [RulebookVariationPlanRow] {
        let plan = CanonicalBusinessEngine.variationRenumberPlan(
            rows: store.variations.map(\.rulebookInput),
            prefix: store.tracker.prefix,
            padding: store.tracker.padding,
            orderLocked: store.tracker.orderLocked
        )
        return plan?.rows ?? store.visibleVariations.map {
            RulebookVariationPlanRow(id: $0.id, from: $0.voNumber, to: $0.voNumber, changed: false, pinned: false, sequence: $0.sequence)
        }
    }

    private var byId: [String: Variation] {
        var out: [String: Variation] = [:]
        for variation in store.variations where !variation.isDeleted { out[variation.id.lowercased()] = variation }
        return out
    }

    /// "Locked by Sam · 15 Nov 2026" and `VARIATION_ORDER_LOCKED_MESSAGE`.
    private var lockedText: String {
        var parts = ["Locked"]
        if let name = store.tracker.orderLockedByName, !name.isEmpty { parts.append("by \(name)") }
        var line = parts.joined(separator: " ")
        let date = CanonicalBusinessEngine.variationDateText(store.tracker.orderLockedAt, timeZone: OrganizationRulebookContext.timeZoneIdentifier)
        if !date.isEmpty { line += " · \(date)" }
        let message = CanonicalBusinessEngine.variationOrderLockedMessage
        return message.isEmpty ? line : "\(line). \(message)"
    }

    private func trackerRow(_ variation: Variation, row: RulebookVariationPlanRow) -> some View {
        let previous = CanonicalBusinessEngine.variationPreviousNumbers(voNumber: variation.voNumber, history: variation.numberHistory.map(\.from))
        let pinned = CanonicalBusinessEngine.variationIsPinned(status: variation.status.rawValue, voNumberLocked: variation.voNumberLocked)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dot(variation.status))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(variation.voNumber)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Keeps its number")
                        }
                    }
                    if !previous.isEmpty {
                        Text("was " + previous.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, alignment: .leading)
                Text(variation.heading.isEmpty ? "Untitled" : variation.heading)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(variation.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dot(variation.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(dot(variation.status).opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            Divider()
                .padding(.leading, 14)
        }
    }

    private func dot(_ status: VariationStatus) -> Color {
        switch status {
        case .open: return .orange
        case .submitted: return .green
        case .closed: return .red
        }
    }
}
