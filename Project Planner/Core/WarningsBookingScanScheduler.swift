//
//  WarningsBookingScanScheduler.swift
//  Project Planner
//
//  One warning scan for a burst of booking-listener deliveries. The Warnings sheet
//  does not cancel that scan. A second publish is queued until the current one finishes.
//

import Foundation

@MainActor
final class WarningsBookingScanScheduler {
    /// A few hundred milliseconds. Tests use a shorter window.
    var debounceNanoseconds: UInt64 = 700_000_000
    var readinessRetryNanoseconds: UInt64 = 500_000_000

    private(set) var sheetVisible = false
    private(set) var scanStarts = 0
    private(set) var followUpsStarted = 0
    private(set) var staleListenerDrops = 0
    private(set) var dataScanCancelCount = 0
    private(set) var redundantCancelCount = 0
    private(set) var isDataScanInFlight = false
    private(set) var followUpQueued = false

    /// Bootstrap, launch quiet, and the weekly report wait. The Warnings sheet does not.
    var isReadyToScan: @MainActor () -> Bool = { true }
    /// True while the live list is being handed to SwiftUI.
    var isPublishingNow: @MainActor () -> Bool = { false }

    var onScan: (@MainActor () async -> Void)?
    var onCancelInFlightCompute: (@MainActor () -> Void)?
    var onCancelRedundantDuplicate: (@MainActor () -> Void)?

    private var generation = 0
    private var debouncePending = false
    private var cancelRequested = false
    private var redundantDuplicateArmed = false
    private var debounceTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?

    /// Same organisation, including a path (`organizations/{id}`) or different letter case.
    /// An empty current id is not a different organisation: the first snapshot often arrives
    /// before `currentOrganization` is published, and dropping it leaves the schedule at 0.
    /// When the session company is already chosen, a snapshot for that company is applied
    /// even if `currentOrganization` is still empty or briefly the other company.
    static func acceptsListener(
        listenerOrganizationId: String,
        currentOrganizationId: String?,
        sessionOrganizationId: String? = nil
    ) -> Bool {
        let listenerId = canonicalOrganizationId(listenerOrganizationId)
        guard !listenerId.isEmpty else { return false }
        let sessionId = canonicalOrganizationId(sessionOrganizationId ?? "")
        if !sessionId.isEmpty {
            return organizationIdsMatch(listenerId, sessionId)
        }
        let currentId = canonicalOrganizationId(currentOrganizationId ?? "")
        if currentId.isEmpty { return true }
        return organizationIdsMatch(listenerId, currentId)
    }

    /// An ignored snapshot must leave the list already on screen. An empty incoming list
    /// must not replace bookings that are already loaded. Rejecting a listener does not
    /// mean the list should be cleared.
    static func bookingCountAfterListener(
        existingCount: Int,
        incomingCount: Int,
        listenerOrganizationId: String,
        currentOrganizationId: String?,
        sessionOrganizationId: String? = nil
    ) -> Int {
        guard acceptsListener(
            listenerOrganizationId: listenerOrganizationId,
            currentOrganizationId: currentOrganizationId,
            sessionOrganizationId: sessionOrganizationId
        ) else {
            return existingCount
        }
        if incomingCount == 0 {
            return existingCount
        }
        return incomingCount
    }

    private static func canonicalOrganizationId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return organizationIdFromFirestore(trimmed) ?? trimmed
    }

    func bookingListenerDelivered(listenerOrganizationId: String, currentOrganizationId: String?) {
        guard Self.acceptsListener(
            listenerOrganizationId: listenerOrganizationId,
            currentOrganizationId: currentOrganizationId
        ) else {
            staleListenerDrops += 1
            return
        }
        noteBookingChange()
    }

    func noteBookingChange() {
        generation += 1
        let token = generation
        debouncePending = true
        if isDataScanInFlight && !isPublishingNow() && !cancelRequested {
            cancelRequested = true
            dataScanCancelCount += 1
            onCancelInFlightCompute?()
        }
        debounceTask?.cancel()
        readinessTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            guard !Task.isCancelled, token == self.generation else { return }
            self.debouncePending = false
            await self.commit(token: token)
        }
    }

    /// Opening Warnings keeps a scan that bookings started. A redundant duplicate may still be dropped.
    func sheetOpened() {
        sheetVisible = true
        guard redundantDuplicateArmed else { return }
        redundantDuplicateArmed = false
        redundantCancelCount += 1
        onCancelRedundantDuplicate?()
    }

    func sheetClosed() {
        sheetVisible = false
    }

    /// Marks a second request that only repeats the scan already running.
    func armRedundantDuplicate() {
        redundantDuplicateArmed = true
    }

    /// Drops a debounce left over from the previous organisation.
    func cancelPending() {
        generation += 1
        debounceTask?.cancel()
        readinessTask?.cancel()
        debouncePending = false
        followUpQueued = false
        debounceTask = nil
        readinessTask = nil
    }

    func scanWasNotReady() {
        armReadinessRetry(token: generation)
    }

    /// Called on the turn after objectWillChange, never from inside the publish itself.
    func publishDidFinish() {
        guard followUpQueued, !debouncePending else { return }
        followUpQueued = false
        followUpsStarted += 1
        let token = generation
        Task { @MainActor in
            await self.commit(token: token)
        }
    }

    private func commit(token: Int) async {
        guard token == generation else { return }
        if isPublishingNow() {
            followUpQueued = true
            return
        }
        if !isReadyToScan() {
            armReadinessRetry(token: token)
            return
        }
        if isDataScanInFlight {
            followUpQueued = true
            return
        }
        followUpQueued = false
        isDataScanInFlight = true
        cancelRequested = false
        scanStarts += 1
        await onScan?()
        isDataScanInFlight = false
        cancelRequested = false
        guard followUpQueued, !debouncePending, !isPublishingNow(), token == generation else { return }
        followUpQueued = false
        followUpsStarted += 1
        let followToken = generation
        Task { @MainActor in
            await self.commit(token: followToken)
        }
    }

    private func armReadinessRetry(token: Int) {
        readinessTask?.cancel()
        readinessTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.readinessRetryNanoseconds)
            guard !Task.isCancelled, token == self.generation else { return }
            await self.commit(token: token)
        }
    }
}
