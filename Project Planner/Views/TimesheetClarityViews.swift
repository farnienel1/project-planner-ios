//
//  TimesheetClarityViews.swift
//  Project Planner
//
//  RULEBOOK 1.77.0 §8 (owner decisions 23 Nov, points 1, 2, 3, 5): the timesheet's "whose turn" line, the
//  "Changed since you signed" card and the one "Correct this timesheet" entry. Layout only — every word and row comes
//  from the rulebook (`timesheetNextStep`, `signedTimesheetChangeDetails`, `timesheetCorrectionOption`); the actions are
//  the screen's existing ones. Web: `components/timesheets/TimesheetClarity.tsx`.
//

import SwiftUI

/// Point 2 (and 5): one line at the top of the timesheet; Generate Invoice beside it on a signed-off sheet.
struct TimesheetNextStepCard: View {
    let step: RulebookTimesheetNextStep
    /// Point 5: the screen's existing Generate Invoice action, or nil when it may not be offered now.
    var generateInvoice: (() -> Void)? = nil
    var generateInvoiceBusy: Bool = false

    private var accent: Color {
        switch step.tone {
        case "action": return .blue
        case "done": return .green
        default: return .orange
        }
    }

    private var kicker: String {
        if step.generateInvoice { return CanonicalBusinessEngine.timesheetGenerateInvoicePrompt }
        switch step.tone {
        case "action": return "Your turn"
        case "done": return "Done"
        default: return "Waiting"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kicker.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text(step.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if step.generateInvoice, let generateInvoice {
                Button(action: generateInvoice) {
                    HStack {
                        Spacer()
                        if generateInvoiceBusy { ProgressView().tint(.white) } else { Text("Generate Invoice").fontWeight(.semibold) }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(generateInvoiceBusy)
                .accessibilityIdentifier("timesheets.nextStep.generateInvoice")
            }
        }
        .padding(12)
        .background(ProjectWorksRevampColors.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 1)
        )
        .accessibilityIdentifier("timesheets.nextStep")
    }
}

/// Point 3: one tidy card, one compact row per change; three rows, then "Show all (N)".
struct TimesheetChangesCard: View {
    let details: RulebookTimesheetChangeDetails
    @State private var expanded = false

    private func chipColor(_ tone: String) -> Color {
        switch tone {
        case "green": return .green
        case "red": return .red
        default: return .orange
        }
    }

    var body: some View {
        let rows = expanded ? details.rows : Array(details.rows.prefix(details.collapsedCount))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(details.heading)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    if !details.summary.isEmpty {
                        Text(details.summary)
                            .font(.caption)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                }
                Spacer()
                Text("\(details.rows.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .padding(12)
            ForEach(rows) { row in
                Divider()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !row.dayLabel.isEmpty {
                            Text(row.dayLabel)
                                .font(.caption)
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        Text(row.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let before = row.beforeText {
                            Text(before)
                                .font(.caption)
                                .strikethrough()
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                                .multilineTextAlignment(.trailing)
                        }
                        if let after = row.afterText {
                            Text(after)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                                .multilineTextAlignment(.trailing)
                        }
                        Text(row.chipLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(chipColor(row.tone))
                            .background(chipColor(row.tone).opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
            }
            if let showAll = details.showAllLabel {
                Divider()
                Button(expanded ? "Show fewer" : showAll) { expanded.toggle() }
                    .font(.footnote.weight(.semibold))
                    .padding(12)
                    .accessibilityIdentifier("timesheets.changes.showAll")
            }
        }
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 1)
        )
        .accessibilityIdentifier("timesheets.changesSinceSigned")
    }
}

/// Point 1: the one "Correct this timesheet" entry with one help line saying exactly what will happen.
struct TimesheetCorrectionEntryView: View {
    let option: RulebookTimesheetCorrectionOption
    var busy: Bool = false
    var disabled: Bool = false
    let onCorrect: () -> Void

    var body: some View {
        if option.action != nil {
            VStack(alignment: .leading, spacing: 6) {
                if option.hasButton {
                    Button(action: onCorrect) {
                        Label(busy ? "Working…" : option.label, systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || disabled)
                    .opacity(disabled ? 0.5 : 1)
                    .accessibilityIdentifier("timesheets.correct")
                } else {
                    Text(option.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
                if let help = option.help, !help.isEmpty {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
