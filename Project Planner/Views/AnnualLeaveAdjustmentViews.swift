//
//  AnnualLeaveAdjustmentViews.swift
//  Project Planner
//
//  RULEBOOK 1.40.0 §4.4 (owner decisions 11 Nov H28–H35): manual annual-leave adjustments on screen, the iOS
//  counterpart of web `components/annual-leave/LeaveAdjustments.tsx`. The person sees each adjustment (amount, reason,
//  date) on My leave; admins and their line managers see the history with who made it on the person's annual leave
//  page and may add one (`canAdjustAnnualLeave`). Every rule is the script's: `annualLeaveAdjustmentValidationError`,
//  `annualLeaveAdjustmentLabel`. Online only.
//

import SwiftUI

struct AnnualLeaveAdjustmentsCard: View {
    let adjustments: [AnnualLeaveAdjustmentRecord]
    /// The leave year shown (`annualLeaveBalance.yearKey`): only its adjustments are listed.
    let yearKey: String
    /// True for admins and line managers (the history with who made each one).
    let showAuthor: Bool
    let hasAllowance: Bool

    private var rows: [AnnualLeaveAdjustmentRecord] {
        adjustments.filter { $0.yearKey == yearKey }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Adjustments this leave year")
                    .font(.headline)
                    .foregroundStyle(AnnualLeavePalette.ink)
                if !hasAllowance {
                    Text("Kept, but not counted while there is no paid allowance (self-employed).")
                        .font(.footnote)
                        .foregroundStyle(AnnualLeavePalette.ink3)
                }
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.reason.isEmpty ? "No reason given" : row.reason)
                                .font(.subheadline)
                                .foregroundStyle(AnnualLeavePalette.ink)
                            Text(caption(for: row))
                                .font(.caption)
                                .foregroundStyle(AnnualLeavePalette.ink3)
                        }
                        Spacer(minLength: 0)
                        Text(CanonicalBusinessEngine.annualLeaveAdjustmentLabel(row.days))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(row.days < 0 ? AnnualLeavePalette.red : AnnualLeavePalette.approved)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("leaveAdjustment.row.\(row.id)")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card)
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func caption(for row: AnnualLeaveAdjustmentRecord) -> String {
        let date = row.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .omitted) } ?? "Saving…"
        guard showAuthor, !row.createdByName.isEmpty else { return date }
        return "\(date) · by \(row.createdByName)"
    }
}

struct AnnualLeaveAdjustmentForm: View {
    let personName: String
    /// Remaining now (`annualLeaveBalance.remaining`), to show what it becomes.
    let remaining: Double?
    /// Online only (§2, Manage Users): the control is disabled offline with `OfflinePolicy.onlineOnlyMessage`.
    var isOnline: Bool = true
    let onSave: (Double, String) async throws -> Void

    @State private var isOpen = false
    @State private var adds = true
    @State private var days: Double = 1
    @State private var reason = ""
    @State private var isSaving = false
    @State private var errorText: String?

    private var signedDays: Double { adds ? days : -days }

    var body: some View {
        if !isOpen {
            VStack(alignment: .leading, spacing: 6) {
            Button {
                isOpen = true
            } label: {
                Label("Adjust leave for this year", systemImage: "plusminus.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(PPColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isOnline)
            .accessibilityIdentifier("leaveAdjustment.open")
            if !isOnline {
                Label(OfflinePolicy.onlineOnlyMessage, systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.ink3)
            }
            }
            .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust \(personName)'s leave")
                    .font(.headline)
                    .foregroundStyle(AnnualLeavePalette.ink)
                Text(CanonicalBusinessEngine.annualLeaveAdjustmentNote)
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                Picker("Add or take off", selection: $adds) {
                    Text("Add days").tag(true)
                    Text("Take off days").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("leaveAdjustment.direction")
                Stepper(value: $days, in: 0.5...365, step: 0.5) {
                    Text(CanonicalBusinessEngine.annualLeaveAdjustmentLabel(signedDays))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                .accessibilityIdentifier("leaveAdjustment.days")
                TextField("Reason (required)", text: $reason, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(AnnualLeavePalette.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("leaveAdjustment.reason")
                if let remaining {
                    let after = remaining + signedDays
                    Text(after < 0
                         ? "Remaining becomes \(AnnualLeavePolicy.formatAllowanceDays(after)) days — below zero."
                         : "Remaining becomes \(AnnualLeavePolicy.formatAllowanceDays(after)) days.")
                        .font(.footnote.weight(after < 0 ? .semibold : .regular))
                        .foregroundStyle(after < 0 ? AnnualLeavePalette.red : AnnualLeavePalette.ink3)
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(AnnualLeavePalette.red)
                }
                HStack(spacing: 10) {
                    Button("Cancel") {
                        isOpen = false
                        errorText = nil
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("leaveAdjustment.cancel")
                    Button(isSaving ? "Saving…" : "Save adjustment") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !isOnline)
                    .accessibilityIdentifier("leaveAdjustment.save")
                }
            }
            .padding(16)
            .background(PPColor.card)
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func save() async {
        if let problem = CanonicalBusinessEngine.annualLeaveAdjustmentValidationError(days: signedDays, reason: reason) {
            errorText = problem
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(signedDays, reason)
            isOpen = false
            reason = ""
            days = 1
            adds = true
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
