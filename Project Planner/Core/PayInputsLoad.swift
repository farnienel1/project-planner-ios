//
//  PayInputsLoad.swift
//  Project Planner
//
//  Pay is worked out from the organisation's working-hours policy and payment runs (`organizations/{orgId}`) and the
//  pay-rate history (`operativeDayRateHistory`, RULEBOOK §8). A failed history read is a failure, never an empty
//  history (which would price every day at the live rate or £0), and nothing is signed, frozen
//  (`weeklyReportOverride`), invoiced or exported until both are loaded. App plumbing; the pay rules stay in the
//  packed script.
//

import SwiftUI

/// Whether the pay-rate history for the open organisation has been read.
enum PayInputsLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

@MainActor
enum PayInputsLoad {
    static let historyFailedMessage = "Pay history could not be loaded, so pay cannot be worked out. Check your connection and tap Retry."
    static let historyLoadingMessage = "Loading pay history…"
    static let organisationNotLoadedMessage = "Organisation settings are still loading, so pay cannot be worked out yet."

    /// Reads the history. `nil` and the message on failure; never `.empty` for a failed read.
    static func loadHistory(_ firebaseBackend: FirebaseBackend) async -> (history: OperativeDayRateHistoryCollection?, state: PayInputsLoadState) {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return (nil, .failed(organisationNotLoadedMessage))
        }
        do {
            let history = try await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)
            return (history, .loaded)
        } catch {
            NSLog("PAY_HISTORY_LOAD_FAILED org=%@ %@", orgId, error.localizedDescription)
            return (nil, .failed(historyFailedMessage))
        }
    }

    /// Why pay cannot be worked out yet (history not loaded, or the organisation's policy and payment runs not
    /// loaded), else nil. Sign-off, freezing the agreed snapshot, invoices and exports wait while this is not nil.
    static func blockMessage(state: PayInputsLoadState, organization: Organization?) -> String? {
        guard organization != nil else { return organisationNotLoadedMessage }
        switch state {
        case .loaded: return nil
        case .loading: return historyLoadingMessage
        case .failed(let message): return message
        }
    }

    // MARK: RULEBOOK 1.43.0 §8 — the period's bookings (`timesheetSnapshotReady`)

    /// Whether the period's labour and manager site bookings have arrived: both stores finished a read for the open
    /// organisation, every query of which the SERVER answered (`serverCoverage`, review r318 — never the cache's copy, a
    /// cache fallback or a partial plan), and that read reaches back to `periodStart` (nil = the whole archive) — never
    /// rows from a narrower, earlier window. A counter-signature made before they arrived froze a snapshot with no
    /// labour lines (owner report, 14 Nov).
    static func periodBookings(
        firebaseBackend: FirebaseBackend,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        from periodStart: Date?
    ) -> (loaded: Bool, failed: Bool) {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return (false, false) }
        let failed = bookingStore.lastLoadFailed || managerScheduleStore.lastLoadFailed
        let finished = !bookingStore.isLoading
            && !managerScheduleStore.isLoading
            && bookingStore.finishedLoadOrganizationId == orgId
            && managerScheduleStore.finishedLoadOrganizationId == orgId
        let covered = bookingStore.serverCoverage?.covers(organizationId: orgId, from: periodStart) == true
            && managerScheduleStore.serverCoverage?.covers(organizationId: orgId, from: periodStart) == true
        return (finished && covered && !failed, finished && failed)
    }

    /// Asks the stores for the period's bookings when the download does not reach `periodStart` (nil = the whole
    /// archive), or — on a retry — when the last read failed. Plumbing only.
    static func ensurePeriodBookings(
        firebaseBackend: FirebaseBackend,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        from periodStart: Date?,
        retryFailed: Bool = false
    ) {
        var reload: Bool
        if let periodStart {
            reload = firebaseBackend.noteScheduleNeedsDate(periodStart)
        } else {
            reload = firebaseBackend.noteScheduleNeedsFullHistory()
        }
        if retryFailed && (bookingStore.lastLoadFailed || managerScheduleStore.lastLoadFailed) { reload = true }
        // No server-answered read covers the period yet (the last one came from cache or a narrower window): read again.
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
           !bookingStore.isLoading, !managerScheduleStore.isLoading,
           bookingStore.serverCoverage?.covers(organizationId: orgId, from: periodStart) != true
            || managerScheduleStore.serverCoverage?.covers(organizationId: orgId, from: periodStart) != true {
            reload = true
        }
        guard reload else { return }
        bookingStore.loadData()
        managerScheduleStore.loadData(force: true)
    }

    /// `blockMessage` plus RULEBOOK 1.43.0 §8 `timesheetSnapshotReady`: sign-off, counter-signature, the agreed snapshot
    /// and invoices also wait for the period's bookings ("Loading bookings…"), or say they could not be loaded.
    static func blockMessage(
        state: PayInputsLoadState,
        organization: Organization?,
        bookings: (loaded: Bool, failed: Bool)
    ) -> String? {
        if let blocked = blockMessage(state: state, organization: organization) { return blocked }
        guard let ready = CanonicalBusinessEngine.timesheetSnapshotReady(
            bookingsLoaded: bookings.loaded,
            bookingsFailed: bookings.failed
        ) else {
            return "The rulebook did not answer. Try again."
        }
        return ready.ready ? nil : (ready.message ?? "Loading bookings…")
    }
}

/// The "pay could not be worked out" notice with a Retry button.
struct PayInputsFailureBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: retry)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("payInputs.retry")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("payInputs.failure")
    }
}

/// RULEBOOK 1.43.0 (review r318, 3rd round): the period's timesheet could not be read. It covers the whole sheet, so
/// there is no blank sheet to edit, sign or add to — only the message and Retry, until it loads.
struct TimesheetPeriodLoadFailedView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(TimesheetDraftStore.periodReadFailedMessage)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("timesheets.periodLoadRetry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .accessibilityIdentifier("timesheets.periodLoadFailed")
    }
}
