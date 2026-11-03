//
//  WarningInputsReadiness.swift
//  Project Planner
//
//  Whether every input the shared warning functions read has loaded for the open organisation:
//  organisation settings (warning detection, working hours, material cut-off), payment runs, bookings,
//  manager bookings, people (operatives and the users roster), annual leave and jobs. Until it has,
//  the Warnings screen and Home show "loading", never "0 active", "All clear" or a payment-run notice.
//  This is load state only; the warnings themselves are `warningScanWindow` / `generateWarnings` in the
//  packed rulebook (`CanonicalBusinessEngine`).
//

import Foundation

nonisolated struct WarningInputsReadiness: Equatable, Sendable {
    nonisolated enum Input: String, CaseIterable, Sendable {
        case organisationSettings
        case paymentRuns
        case bookings
        case managerBookings
        case people
        case annualLeave
        case jobs

        var label: String {
            switch self {
            case .organisationSettings: return "organisation settings"
            case .paymentRuns: return "payment runs"
            case .bookings: return "bookings"
            case .managerBookings: return "manager schedules"
            case .people: return "people"
            case .annualLeave: return "annual leave"
            case .jobs: return "jobs"
            }
        }
    }

    /// `organizations/{orgId}` has been read for this organisation (live listener or server read).
    var organisationSettingsLoaded: Bool
    /// The payment runs were read from the server in this scan. Only the Invoicing period mode needs them.
    var paymentRunsLoaded: Bool
    var usesInvoicingPeriod: Bool
    var bookingsLoaded: Bool
    var managerBookingsLoaded: Bool
    var operativesLoaded: Bool
    var rosterLoaded: Bool
    var annualLeaveLoaded: Bool
    var jobsLoaded: Bool

    /// Inputs still loading, in a fixed order.
    var missing: [Input] {
        var out: [Input] = []
        if !organisationSettingsLoaded { out.append(.organisationSettings) }
        if usesInvoicingPeriod && !paymentRunsLoaded { out.append(.paymentRuns) }
        if !bookingsLoaded { out.append(.bookings) }
        if !managerBookingsLoaded { out.append(.managerBookings) }
        if !operativesLoaded || !rosterLoaded { out.append(.people) }
        if !annualLeaveLoaded { out.append(.annualLeave) }
        if !jobsLoaded { out.append(.jobs) }
        return out
    }

    var isReady: Bool { missing.isEmpty }

    /// The inputs held in this app's stores (bookings, manager bookings, people, leave, jobs). A scan may
    /// start once they have loaded: it reads the organisation document from the server itself, then
    /// publishes only when `isReady` (settings and, for Invoicing period, the payment runs) holds too.
    var missingStoreInputs: [Input] {
        missing.filter { $0 != .organisationSettings && $0 != .paymentRuns }
    }

    var storeInputsReady: Bool { missingStoreInputs.isEmpty }

    /// The invoicing-period summary (`activePaymentRunSummary`) is shown only from loaded payment runs.
    var canShowInvoicingSummary: Bool {
        organisationSettingsLoaded && (!usesInvoicingPeriod || paymentRunsLoaded)
    }

    /// Short line for the loading state, e.g. "Waiting for bookings and annual leave."
    var waitingMessage: String? {
        let labels = missing.map(\.label)
        guard let last = labels.last else { return nil }
        if labels.count == 1 { return "Waiting for \(last)." }
        return "Waiting for \(labels.dropLast().joined(separator: ", ")) and \(last)."
    }

    static let allLoaded = WarningInputsReadiness(
        organisationSettingsLoaded: true,
        paymentRunsLoaded: true,
        usesInvoicingPeriod: false,
        bookingsLoaded: true,
        managerBookingsLoaded: true,
        operativesLoaded: true,
        rosterLoaded: true,
        annualLeaveLoaded: true,
        jobsLoaded: true
    )
}

/// What the Warnings screen and the Home pill show for the live list.
nonisolated enum WarningsDisplayPhase: Equatable, Sendable {
    /// No complete scan of loaded inputs yet: a loading state, never a count.
    case loading
    /// A booking read failed: the reason is shown, never an all-clear.
    case incomplete(String)
    /// The last scan ran on loaded inputs; its count is the real count (0 is a real all-clear).
    case ready(activeCount: Int)

    static func phase(
        hasCompletedLiveDetection: Bool,
        incompleteDataMessage: String?,
        activeCount: Int
    ) -> WarningsDisplayPhase {
        if let incompleteDataMessage, !incompleteDataMessage.isEmpty, activeCount == 0 {
            return .incomplete(incompleteDataMessage)
        }
        guard hasCompletedLiveDetection else { return .loading }
        return .ready(activeCount: activeCount)
    }

    /// Home pill value: "Checking…" until a scan of loaded inputs has published.
    static func homePillValue(hasCompletedLiveDetection: Bool, activeCount: Int) -> String {
        guard hasCompletedLiveDetection else { return "Checking…" }
        return activeCount == 0 ? "All clear" : "\(activeCount) active"
    }

    /// Home overview metric value: a dash until a scan of loaded inputs has published.
    static func homeMetricValue(hasCompletedLiveDetection: Bool, activeCount: Int) -> String {
        hasCompletedLiveDetection ? "\(activeCount)" : "–"
    }
}
