//
//  StaffTradeTypeFormSection.swift
//  Project Planner
//

import SwiftUI

/// Trade picker + "Other" text field. Use `presetRaw` = `StaffTradeType.rawValue` (non-empty).
struct StaffTradeTypeFormSection: View {
    @Binding var presetRaw: String
    @Binding var customText: String
    var title: String = "Trade type"
    var footnote: String? = nil

    /// `nil` when `presetRaw` is empty (e.g. legacy user — prompts “Select trade”).
    private var selectedPreset: StaffTradeType? {
        guard !presetRaw.isEmpty else { return nil }
        return StaffTradeType(rawValue: presetRaw)
    }

    private var customSuggestions: [String] {
        guard presetRaw == StaffTradeType.other.rawValue else { return [] }
        return TradeTypeInventory.suggestions(query: customText)
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Picker(title, selection: Binding(
                get: { selectedPreset },
                set: { newValue in
                    if let newValue {
                        presetRaw = newValue.rawValue
                        if newValue != .other {
                            customText = ""
                        }
                    } else {
                        presetRaw = ""
                        customText = ""
                    }
                }
            )) {
                Text("Select trade").tag(Optional<StaffTradeType>.none)
                ForEach(StaffTradeType.pickerCases) { t in
                    Text(t.rawValue).tag(Optional(t))
                }
            }
            .pickerStyle(.menu)

            if presetRaw == StaffTradeType.other.rawValue {
                TextField("Enter trade type here", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customText) { _, newValue in
                        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            TradeTypeInventory.register(value)
                        }
                    }
                if !customSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(customSuggestions, id: \.self) { suggestion in
                                Button {
                                    customText = suggestion
                                } label: {
                                    Text(suggestion)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.theme.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.theme.primary.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func isValid(presetRaw: String, customText: String) -> Bool {
        StaffTradeType.isComplete(presetRaw: presetRaw, custom: customText)
    }
}
