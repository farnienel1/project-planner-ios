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
    /// Look only. `.form` is the original look (every existing screen); `.card` is the Add User picker row with an
    /// amber tile (add-user-ui-spec §4). Same picker, same values, same validation.
    var style: Style = .form

    enum Style {
        case form
        case card
    }

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

    /// The picker's selection (unchanged logic, shared by both looks).
    private var selection: Binding<StaffTradeType?> {
        Binding(
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
        )
    }

    private var picker: some View {
        Picker(title, selection: selection) {
            Text("Select trade").tag(Optional<StaffTradeType>.none)
            ForEach(StaffTradeType.pickerCases) { t in
                Text(t.rawValue).tag(Optional(t))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch style {
            case .form:
                Text(title)
                    .font(.headline)
                picker
                    .accessibilityIdentifier("staffTradeTypeFormSection.\(AccessibilityID.token(title))")
                    .pickerStyle(.menu)
            case .card:
                // The same Picker inside a Menu, so the row can carry the tile and the current value.
                Menu {
                    picker
                } label: {
                    HStack(spacing: 12) {
                        PPIconTile(symbol: "wrench.and.screwdriver.fill", family: .trade, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(selectedPreset?.rawValue ?? "Select trade")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .ppFormField(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("staffTradeTypeFormSection.\(AccessibilityID.token(title))")
            }

            if presetRaw == StaffTradeType.other.rawValue {
                TextField("Enter trade type here", text: $customText)
                    .accessibilityIdentifier("staffTradeTypeFormSection.enterTradeTypeHere")
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
                                .accessibilityIdentifier("staffTradeTypeFormSection.row.\(suggestion).\(AccessibilityID.token(suggestion))")
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
