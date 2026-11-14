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
        // Review r318: a read already in flight (the launch / bootstrap one, which may ignore a reload request and may
        // read a narrower window) is waited for, then this check runs again, so an older period still gets covered.
        // No second load is started meanwhile: the re-check reloads once, after the read in flight (the window it needs
        // was already moved by `noteScheduleNeedsDate`, so the coverage test asks for it).
        if bookingStore.isLoading || managerScheduleStore.isLoading {
            scheduleRerunAfterLoads(
                firebaseBackend: firebaseBackend,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                from: periodStart,
                retryFailed: retryFailed
            )
            return
        }
        guard reload else { return }
        bookingStore.loadData()
        managerScheduleStore.loadData(force: true)
    }

    /// The periods with a queued re-check (review r318: per period, so a second period's request is never dropped),
    /// each with whether the re-check must re-run a failed load (`retryFailed`, kept while it waits — review #231).
    private static var queuedRerunPeriods: [String: Bool] = [:]

    /// How long one wait for a read in flight lasts before the check is queued again (review #231: a slow read is
    /// waited for again, never given up on).
    nonisolated static let rerunWaitSeconds: Double = 60

    static func rerunKey(_ periodStart: Date?) -> String {
        periodStart.map { String($0.timeIntervalSince1970) } ?? "all"
    }

    /// Records a queued re-check for `key`. Returns true when a new wait must start (none was queued); a second request
    /// for a queued period only adds `retryFailed`, so a Retry made while a read is in flight is never lost.
    static func queueRerun(key: String, retryFailed: Bool) -> Bool {
        if let queued = queuedRerunPeriods[key] {
            queuedRerunPeriods[key] = queued || retryFailed
            return false
        }
        queuedRerunPeriods[key] = retryFailed
        return true
    }

    /// Ends the wait for `key`: whether the re-check re-runs a failed load.
    static func takeQueuedRerun(key: String) -> Bool {
        queuedRerunPeriods.removeValue(forKey: key) ?? false
    }

    private static func scheduleRerunAfterLoads(
        firebaseBackend: FirebaseBackend,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        from periodStart: Date?,
        retryFailed: Bool
    ) {
        let key = rerunKey(periodStart)
        guard queueRerun(key: key, retryFailed: retryFailed) else { return }
        Task { @MainActor [weak firebaseBackend, weak bookingStore, weak managerScheduleStore] in
            let steps = Int(rerunWaitSeconds / 0.5)
            for _ in 0..<steps {
                guard let bookingStore, let managerScheduleStore else { break }
                if !bookingStore.isLoading && !managerScheduleStore.isLoading { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let retry = takeQueuedRerun(key: key)
            guard let firebaseBackend, let bookingStore, let managerScheduleStore else { return }
            // Still reading after a minute: wait again (review #231) rather than give up, keeping `retryFailed`.
            // `ensurePeriodBookings` queues the next wait itself while a read is in flight.
            ensurePeriodBookings(
                firebaseBackend: firebaseBackend,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                from: periodStart,
                retryFailed: retry
            )
        }
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

/// RULEBOOK 1.43.0 (review r318): the wording of a User Timesheets export (web `lib/timesheets/timesheetExportRun.ts`
/// `exportSummaryMessage`, `EXPORT_RECOVER_HINT`) and of the Exported tab's rebuilt Download PDF. Copy only.
enum TimesheetExportMessages {
    /// Web `EXPORT_RECOVER_HINT`.
    static let exportRecoverHint = "Open Exported to download any timesheet again."

    /// RULEBOOK 1.43.0 (review r318): the Exported tab's Download PDF of a sheet exported before signed copies were kept
    /// (no stored `weeklyReportOverride`) is rebuilt from today's bookings and rates; asked first and marked on the PDF.
    static let rebuiltExportConfirmMessage = "This timesheet was exported before signed copies were kept, so this PDF is rebuilt from today's bookings and rates and may differ from the one sent at the time."

    static func rebuiltExportNote(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.calendar.timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return "Rebuilt on \(formatter.string(from: date)) — may differ from the original export."
    }

    /// Web `exportSummaryMessage`: what was exported, what was sent, what could not be sent and why — never "Export
    /// failed" once anything was stamped.
    static func summaryMessage(
        stamped: [String],
        notSent: [String],
        emailProblem: String?,
        recipientEmail: String?,
        sentCount: Int,
        backupSkipped: [String],
        skipped: [String],
        stampError: String?
    ) -> String {
        var parts: [String] = []
        let n = stamped.count
        if n == 0 {
            parts.append(stampError.map { "Nothing was exported (\($0))." } ?? "Nothing to export.")
        } else {
            parts.append("\(n) exported.")
            if sentCount > 0, emailProblem == nil, let recipientEmail {
                parts.append("Sent: \(sentCount) emailed to \(recipientEmail) for filing.")
            }
            var couldNot = notSent
            if let emailProblem { couldNot.append("the email (\(emailProblem))") }
            if !couldNot.isEmpty { parts.append("Couldn't send: \(couldNot.joined(separator: ", "))." ) }
            if let stampError { parts.append("Export stopped before the rest (\(stampError)); try again for them.") }
            if !backupSkipped.isEmpty { parts.append("Storage backup skipped: \(backupSkipped.joined(separator: ", "))." ) }
        }
        if !skipped.isEmpty { parts.append("Already exported, left as it was: \(skipped.joined(separator: ", "))." ) }
        if n > 0 && (!notSent.isEmpty || emailProblem != nil || stampError != nil) { parts.append(exportRecoverHint) }
        return parts.joined(separator: " ")
    }

}
