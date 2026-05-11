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
                TextField("Enter trade name", text: $customText)
                    .textFieldStyle(.roundedBorder)
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
