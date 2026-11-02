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
                        Text("Read-only tracker. The order and numbering can be managed on the web app.")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    .padding(.top, 16)

                    PPGroupLabel(text: "Variations")

                    PPGroupedCard {
                        ForEach(store.visibleVariations) { variation in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(dot(variation.status))
                                    .frame(width: 10, height: 10)
                                Text(variation.voNumber)
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(width: 72, alignment: .leading)
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
        let count = store.visibleVariations.count
        return VStack(alignment: .leading, spacing: 8) {
            PPOverviewTitle(
                eyebrow: parentName,
                count: "\(count)",
                countLabel: count == 1 ? "variation" : "variations"
            )
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func dot(_ status: VariationStatus) -> Color {
        switch status {
        case .open: return .orange
        case .submitted: return .green
        case .closed: return .red
        }
    }
}
