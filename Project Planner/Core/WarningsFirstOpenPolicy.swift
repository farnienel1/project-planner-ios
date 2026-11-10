//
//  WarningsFirstOpenPolicy.swift
//  Project Planner
//
//  1.33.1 (owner report: Warnings took a while on first open and needed Refresh tapped a few times). Screen flow only:
//  which warnings are listed is the rulebook's (`unbookedLabourRows`, `operativeClashGroups`, …), unchanged.
//
//  Before: the first-open loop stopped for good as soon as one scan was skipped for incomplete data (a booking read
//  that failed at launch), its pause grew to 5 s, and the organisation re-read every scan makes had no time limit, so
//  a slow server answer held the scan with nothing on screen. Now the loop keeps going while the screen is open until a
//  scan of loaded inputs publishes, asks a failed booking store to load again, pauses at most 2 s, and the re-read of
//  the organisation document is bounded (the live organisation listener's settings stand in when it times out).
//

import Foundation

enum WarningsFirstOpenPolicy {
    /// The first pause between tries.
    static let firstPauseNanoseconds: UInt64 = 300_000_000
    /// The longest pause between tries while the screen is open.
    static let maxPauseNanoseconds: UInt64 = 2_000_000_000
    /// The bound on the organisation re-read a scan makes (`refreshWarningDetectionFromServer`).
    static let organizationReadSeconds: Double = 5

    /// Keep trying while the screen is open and no scan of loaded inputs has published. Incomplete data (a failed
    /// booking read) does not stop the loop: the store is asked to load again and the next try scans.
    static func keepWaiting(cancelled: Bool, hasCompletedLiveDetection: Bool) -> Bool {
        !cancelled && !hasCompletedLiveDetection
    }

    static func nextPause(after pause: UInt64) -> UInt64 {
        min(pause.multipliedReportingOverflow(by: 2).partialValue, maxPauseNanoseconds)
    }

    /// A store whose last load failed is asked to load again (at most once per try, never while it is loading).
    static func shouldReload(lastLoadFailed: Bool, isLoading: Bool) -> Bool {
        lastLoadFailed && !isLoading
    }

    /// Whether the scan may use the organisation's warning settings and payment runs: the server re-read answered, or
    /// it did not (timed out or failed) but the live organisation listener has already delivered this organisation's
    /// settings (`warningSettingsLoadedOrganizationId`), which it keeps current.
    static func settingsUsable(serverReadAnswered: Bool, listenerLoadedThisOrganization: Bool) -> Bool {
        serverReadAnswered || listenerLoadedThisOrganization
    }
}
