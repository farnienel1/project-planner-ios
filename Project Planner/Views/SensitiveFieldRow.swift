//
//  SensitiveFieldRow.swift
//  Project Planner
//
//  UTR and VAT number rows. Who may see a value is `canViewSensitiveProfile`; the masked text is
//  `maskSensitiveValue`; the held-by-admin copy is `SENSITIVE_HELD_BY_ADMIN_COPY`. This file only lays them out.
//

import SwiftUI

/// Edit state for one sensitive field. Editing starts empty: typed text replaces the saved value,
/// Remove clears it, and leaving both alone keeps it.
struct SensitiveFieldDraft: Equatable {
    var saved: String = ""
    var typed: String = ""
    var removed = false

    /// The value to save: blank clears (rulebook `sensitiveProfileWriteFields`).
    var valueToSave: String {
        let replacement = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !replacement.isEmpty { return replacement }
        return removed ? "" : saved
    }

    var isDirty: Bool { valueToSave != saved }

    /// Back to the saved value with nothing typed.
    mutating func reset(saved newSaved: String) {
        saved = newSaved
        typed = ""
        removed = false
    }
}

struct SensitiveFieldColors {
    var primary: Color = .primary
    var secondary: Color = .secondary
    var accent: Color = .accentColor
    var destructive: Color = .red
}

/// Saved value masked by default with Show / Hide. Used where the value is read only.
struct SensitiveFieldValue: View {
    let value: String
    var colors = SensitiveFieldColors()
    var accessibilityToken: String
    @State private var revealed = false

    var body: some View {
        if value.isEmpty {
            Text("Not set")
                .font(.system(size: 13))
                .foregroundStyle(colors.secondary)
        } else {
            HStack(spacing: 8) {
                Text(revealed ? value : (CanonicalBusinessEngine.maskSensitiveValue(value) ?? ""))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(colors.primary)
                    .textSelection(.disabled)
                    .accessibilityIdentifier("sensitiveField.\(accessibilityToken).value")
                Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sensitiveField.\(accessibilityToken).toggle")
            }
        }
    }
}

/// Edit control: masked saved value with Show / Hide, an empty field hinting "Saved: •••• 1234 — type to replace",
/// and Remove. Only shown when `canViewSensitiveProfile` is true.
struct SensitiveFieldEditor: View {
    let label: String
    let placeholder: String
    @Binding var draft: SensitiveFieldDraft
    var colors = SensitiveFieldColors()
    var accessibilityToken: String

    private var maskedSaved: String {
        CanonicalBusinessEngine.maskSensitiveValue(draft.saved) ?? ""
    }

    private var hint: String {
        guard !draft.saved.isEmpty, !draft.removed, !maskedSaved.isEmpty else { return placeholder }
        return "Saved: \(maskedSaved) — type to replace"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondary)
                Spacer(minLength: 8)
                if !draft.saved.isEmpty && !draft.removed {
                    SensitiveFieldValue(value: draft.saved, colors: colors, accessibilityToken: accessibilityToken)
                    Button("Remove") {
                        draft.typed = ""
                        draft.removed = true
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.destructive)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sensitiveField.\(accessibilityToken).remove")
                } else if draft.removed && !draft.saved.isEmpty {
                    Text("Will be removed")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondary)
                    Button("Undo") { draft.removed = false }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.accent)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sensitiveField.\(accessibilityToken).undo")
                }
            }
            TextField(hint, text: $draft.typed)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.primary)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sensitiveField.\(accessibilityToken).input")
                .onChange(of: draft.typed) { _, newValue in
                    if !newValue.isEmpty { draft.removed = false }
                    let limit = CanonicalBusinessEngine.sensitiveValueMax ?? 20
                    if newValue.count > limit { draft.typed = String(newValue.prefix(limit)) }
                }
        }
    }
}

/// For managers and operatives viewing someone else: no value, not even masked.
struct SensitiveFieldHeldByAdmin: View {
    let label: String
    var colors = SensitiveFieldColors()
    var accessibilityToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(colors.secondary)
            Text(CanonicalBusinessEngine.sensitiveHeldByAdminCopy ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.secondary)
                .accessibilityIdentifier("sensitiveField.\(accessibilityToken).heldByAdmin")
        }
    }
}

/// Export / invoice option labelled `SENSITIVE_EXPORT_OPTION_LABEL`. Callers show it only when
/// `canViewSensitiveProfile` is true and start it off each time.
struct SensitiveExportToggle: View {
    @Binding var isOn: Bool
    var accessibilityToken: String

    var body: some View {
        Toggle(CanonicalBusinessEngine.sensitiveExportOptionLabel ?? "", isOn: $isOn)
            .font(.system(size: 13, weight: .medium))
            .accessibilityIdentifier("sensitiveExportToggle.\(accessibilityToken)")
    }
}
