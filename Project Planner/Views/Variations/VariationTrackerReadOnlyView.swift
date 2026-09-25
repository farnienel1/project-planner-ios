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
            VStack(alignment: .leading, spacing: 12) {
                Text("Read-only tracker. The order and numbering can be managed on the web app.")
                    .font(.subheadline)
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                ForEach(store.visibleVariations) { variation in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(dot(variation.status))
                            .frame(width: 10, height: 10)
                        Text(variation.voNumber)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 72, alignment: .leading)
                        Text(variation.heading.isEmpty ? "Untitled" : variation.heading)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(variation.status.title)
                            .font(.caption)
                            .foregroundStyle(dot(variation.status))
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Tracker")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dot(_ status: VariationStatus) -> Color {
        switch status {
        case .open: return .orange
        case .submitted: return .green
        case .closed: return .red
        }
    }
}
