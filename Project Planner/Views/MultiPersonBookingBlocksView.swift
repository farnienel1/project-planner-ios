//
//  MultiPersonBookingBlocksView.swift
//  Project Planner
//
//  RULEBOOK 1.60.0 §5 (owner request 17 Nov 2026): the people in a multi-person booking who already have hours booked
//  on a selected day, named with the day and `MULTI_PERSON_ALREADY_BOOKED_MESSAGE`, each with Remove. The booking
//  cannot be saved until every one is removed. Web: `components/scheduling/MultiPersonBookingBlocks.tsx`.
//

import SwiftUI

struct MultiPersonBookingBlocksView: View {
    let blocks: [RulebookMultiPersonBlock]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(block.name) · \(MultiPersonBookingCheck.daysText(block.dayKeys))")
                            .font(.system(size: 13, weight: .semibold))
                        Text(block.message)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(CanonicalBusinessEngine.multiPersonAlreadyBookedRemoveLabel) {
                        onRemove(block.personKey)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityIdentifier("multiPersonBlock.remove.\(block.personKey)")
                }
                .foregroundStyle(Color(red: 0.64, green: 0.18, blue: 0.18))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
