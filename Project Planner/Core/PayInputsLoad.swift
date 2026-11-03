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
