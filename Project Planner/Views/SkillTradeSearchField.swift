//
//  SkillTradeSearchField.swift
//  Project Planner
//

import SwiftUI

/// Predictive trade search for the skills catalogue.
/// Suggestions include staff preset trades (user setup) plus trades already used on skills.
struct SkillTradeSearchField: View {
    @Binding var trade: String
    var existingTrades: [String]
    var title: String = "Trade"
    var footnote: String? = "Predicts from staff trades and your skills catalogue. New trades apply to skills grouping only."

    @FocusState private var isFocused: Bool

    private var sortedTrades: [String] {
        let staffPresets = StaffTradeType.pickerCases
            .map(\.rawValue)
            .filter { $0 != StaffTradeType.other.rawValue }
        return TradeTypeInventory.knownTrades(extra: staffPresets + existingTrades)
    }

    private var suggestions: [String] {
        let q = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return sortedTrades
            .filter {
                $0.localizedCaseInsensitiveContains(q) &&
                $0.compare(q, options: .caseInsensitive) != .orderedSame
            }
            .prefix(8)
            .map { $0 }
    }

    private var isNewTrade: Bool {
        let q = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return !sortedTrades.contains { $0.compare(q, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            TextField("Enter trade name", text: $trade)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)

            if isFocused && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            trade = suggestion
                            isFocused = false
                        } label: {
                            HStack {
                                Text(suggestion)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if suggestion != suggestions.last {
                            Divider()
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }

            if isNewTrade {
                Text("New trade — used for skills grouping only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
