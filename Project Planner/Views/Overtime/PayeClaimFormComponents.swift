//
//  PayeClaimFormComponents.swift
//  Project Planner
//
//  Look only, for Add Price Work / Add Expense (`AddPayeClaimSheet`): labelled cards, labelled fields, the evidence
//  source rows and the attached-evidence rows, built from the app design system (PPDesign). No data, no rule, no
//  action of their own: every action, message and enabled state is the sheet's, from `CanonicalBusinessEngine`.
//

import SwiftUI

/// A labelled card on the light sheet: icon and title, the fields, an optional note, and the rulebook's validation
/// message for this card (shown in red, with the card outlined).
struct PayeClaimFormCard<Content: View>: View {
    let title: String
    let symbol: String
    let family: PPFamily
    var note: String?
    var message: String?
    let identifier: String
    let content: Content

    init(
        title: String,
        symbol: String,
        family: PPFamily,
        note: String? = nil,
        message: String? = nil,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.family = family
        self.note = note
        self.message = message
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PPIconTile(symbol: symbol, family: family, size: 26)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            content
            if let note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message, !message.isEmpty {
                PayeClaimFieldMessage(text: message)
                    .accessibilityIdentifier("\(identifier).message")
            }
        }
        .ppBookingCard()
        .overlay {
            if message?.isEmpty == false {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(PPColor.danger.opacity(0.7), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A message from the rulebook (or an upload / save error), in the app's danger colour.
struct PayeClaimFieldMessage: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(PPColor.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A field with its label always visible above it, on the inset well.
struct PayeClaimLabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(PPColor.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// One way to add evidence (File, Take photo, Photo library, Personal site audit) as a menu-style row.
struct PayeClaimEvidenceSourceButton: View {
    let title: String
    let symbol: String
    let family: PPFamily
    var isEnabled: Bool = true
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PPMenuRowLabel(title: title, symbol: symbol, family: family, showsChevron: true)
        }
        .buttonStyle(PPMenuRowButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
    }
}

/// A piece of evidence picked but not uploaded yet: its name, its type and a remove button.
struct PayeClaimAttachedEvidenceRow: View {
    let entry: PendingPayeClaimEvidence
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PPIconTile(symbol: entry.symbol, family: entry.family, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(entry.typeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(PPColor.danger)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.label)")
            .accessibilityIdentifier("payeClaims.add.evidence.remove")
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
    }
}

extension PendingPayeClaimEvidence {
    /// What the picked piece is, for the row under its name.
    var typeText: String {
        switch source {
        case .file(let data, let contentType, _):
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return contentType == "application/pdf" ? "PDF · \(size)" : "Photo · JPEG · \(size)"
        case .audit:
            return "Personal site audit · a PDF copy is attached when you add"
        }
    }

    var symbol: String {
        switch source {
        case .file(_, let contentType, _):
            return contentType == "application/pdf" ? "doc.richtext" : "photo"
        case .audit:
            return "checklist"
        }
    }

    var family: PPFamily {
        switch source {
        case .file(_, let contentType, _):
            return contentType == "application/pdf" ? .plan : .people
        case .audit:
            return .trade
        }
    }
}
