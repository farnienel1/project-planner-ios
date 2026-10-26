//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    private enum InFlightReason {
        case automatic
        case manual
        case bookingData
    }

    private struct BookingScanInputs {
        let operativeStore: OperativeStore
        let bookingStore: BookingStore
        let projectStore: ProjectStore
        let userStore: UserStore
        let managerScheduleStore: ManagerScheduleStore
        let holidayStore: HolidayStore
        let firebaseBackend: FirebaseBackend
        let appSettings: AppSettingsStore
    }

    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Void, Never>?
    @MainActor private static var inFlightReason: InFlightReason?
    @MainActor private static var bookingInputs: BookingScanInputs?
    @MainActor private static var bookingRefreshDeferred = false
    @MainActor private static var replayBookingScanAfterHeavySheet = false
    @MainActor private static var suppressBookingReplay = false
    private static let minRefreshInterval: TimeInterval = 45

    @MainActor private static let bookingScheduler: WarningsBookingScanScheduler = makeBookingScheduler()

    /// Home must not start a live scan while Weekly Report is open.
    @MainActor static var isWeeklyReportVisible = false
    /// Blocks automatic scans while Warnings is open. A booking-listener change still scans.
    @MainActor static var isWarningsSheetVisible = false
    /// True while Home is running its post-quiet lite warm — blocks roster full-sync writes.
    @MainActor static var isHomeWarningsWarmInFlight = false

    /// Booking or manager-booking listener (and local booking edits) schedule one scan.
    /// Rapid deliveries collapse to that scan. This does not run the scan on the caller’s turn.
    @MainActor
    static func scheduleBookingDrivenRefresh(
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        projectStore: ProjectStore,
        userStore: UserStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        firebaseBackend: FirebaseBackend,
        appSettings: AppSettingsStore
    ) {
        bookingInputs = BookingScanInputs(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings
        )
        bookingScheduler.noteBookingChange()
    }

    @MainActor
    static func setWeeklyReportVisible(_ visible: Bool) {
        isWeeklyReportVisible = visible
        guard !visible, replayBookingScanAfterHeavySheet else { return }
        replayBookingScanAfterHeavySheet = false
        bookingScheduler.noteBookingChange()
    }

    /// Opening Warnings must not cancel a scan that bookings already started.
    @MainActor
    static func warningsSheetDidOpen() {
        isWarningsSheetVisible = true
        bookingScheduler.sheetOpened()
        if inFlightReason == .bookingData || bookingScheduler.isDataScanInFlight {
            print("🔥🔥🔥 DEBUG: Warnings sheet left the booking-driven scan running")
            return
        }
        cancelInFlightRefresh()
    }

    @MainActor
    @discardableResult
    static func refreshSharedWarnings(
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        projectStore: ProjectStore,
        userStore: UserStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        firebaseBackend: FirebaseBackend,
        appSettings _: AppSettingsStore,
        force: Bool = false,
        manualUserInitiated: Bool = false,
        allowWhileSheetVisible: Bool = false,
        bypassLaunchQuiet: Bool = false,
        bookingDataChanged: Bool = false
    ) async -> Bool {
        guard userStore.canViewStaffWarnings() else { return false }

        if isWarningsSheetVisible && !manualUserInitiated && !allowWhileSheetVisible && !bookingDataChanged {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Warnings sheet visible)")
            return false
        }
        if isWeeklyReportVisible && !manualUserInitiated && !bookingDataChanged {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Weekly Report visible)")
            return false
        }

        // Launch quiet blocks automatic scans. A booking change waits and retries instead of being dropped.
        // Explicit user Refresh and an organisation switch may proceed.
        if let quietUntil = firebaseBackend.launchQuietUntil, Date() < quietUntil, !manualUserInitiated, !bypassLaunchQuiet, !bookingDataChanged {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (launch quiet period)")
            return false
        }

        // Avoid scanning while stores/bootstrap are mid-load (publishes false empty results).
        // Manual Refresh (and settings Save) retries briefly — Firestore saves often race a short reload.
        if manualUserInitiated {
            for attempt in 0..<8 {
                let bootstrapping = firebaseBackend.isBootstrappingOrgDataLoad
                let storesBusy = bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading
                if !bootstrapping && firebaseBackend.hasBootstrappedOrgDataLoad && !storesBusy {
                    break
                }
                print("🔥🔥🔥 DEBUG: Warnings refresh waiting (attempt \(attempt + 1)/8 bootstrapping=\(bootstrapping) storesBusy=\(storesBusy))")
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }

        if firebaseBackend.isBootstrappingOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap in progress)")
            if bookingDataChanged { bookingRefreshDeferred = true }
            return false
        }
        if !firebaseBackend.hasBootstrappedOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap not finished)")
            if bookingDataChanged { bookingRefreshDeferred = true }
            return false
        }
        if bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (stores still loading)")
            if bookingDataChanged { bookingRefreshDeferred = true }
            return false
        }

        if !force {
            if holidayStore.isLoading {
                return false
            }
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minRefreshInterval {
                return false
            }
        } else if !manualUserInitiated && !bookingDataChanged {
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < 8 {
                // Soft coalesce — avoid stacked force scans from dismiss + notification.
                // Booking-listener changes do not use this. Their debounce schedules one follow-up.
                print("🔥🔥🔥 DEBUG: Warnings force coalesced (<8s)")
                return WarningsService.shared.hasCompletedLiveDetection
            }
        }

        if let inFlightTask {
            if bookingDataChanged && inFlightReason != .bookingData {
                if WarningsService.shared.isLivePublishQueued {
                    print("🔥🔥🔥 DEBUG: Warnings booking change queued behind the publish already running")
                    bookingScheduler.scanWasNotReady()
                    return false
                }
                print("🔥🔥🔥 DEBUG: Warnings booking change replacing in-flight scan")
                cancelInFlightRefresh()
            } else if !bookingDataChanged && inFlightReason == .bookingData {
                print("🔥🔥🔥 DEBUG: Warnings refresh is a duplicate of the booking-driven scan")
                bookingScheduler.armRedundantDuplicate()
                await inFlightTask.value
                return true
            } else {
                print("🔥🔥🔥 DEBUG: Warnings refresh awaiting in-flight pass (no second snapshot)")
                await inFlightTask.value
                return true
            }
        }

        if bookingDataChanged, WarningsService.shared.isLivePublishQueued {
            print("🔥🔥🔥 DEBUG: Warnings booking change queued until the current publish finishes")
            bookingScheduler.scanWasNotReady()
            return false
        }

        let reason: InFlightReason = bookingDataChanged ? .bookingData : (manualUserInitiated ? .manual : .automatic)
        inFlightReason = reason
        let task = Task { @MainActor in
            await performRefresh(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend
            )
        }
        inFlightTask = task
        lastRefreshAt = Date()
        await task.value
        if inFlightTask == task {
            inFlightTask = nil
            inFlightReason = nil
        }
        return true
    }

    /// Organisation switch must not reuse the previous scan's cooldown or in-flight task.
    @MainActor
    static func prepareForOrganizationSwitch() {
        suppressBookingReplay = true
        lastRefreshAt = nil
        replayBookingScanAfterHeavySheet = false
        bookingScheduler.cancelPending()
        cancelInFlightRefresh()
        suppressBookingReplay = false
    }

    /// Cancel any in-flight Home warnings scan before opening heavy sheets (Weekly Report).
    /// A booking-driven replacement cancels without this flag. Weekly Report asks for a replay
    /// so the cancelled scan still runs after the report closes.
    @MainActor
    static func cancelInFlightRefresh(replayIfBookingData: Bool = false) {
        if replayIfBookingData, inFlightReason == .bookingData, !suppressBookingReplay {
            replayBookingScanAfterHeavySheet = true
        }
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightReason = nil
        WarningsService.shared.cancelInFlightUpdate()
        print("🔥🔥🔥 DEBUG: Warnings refresh in-flight cancelled for sheet open")
    }

    /// Cancel scans and wait briefly so detached snapshot memory can drain before heavy UI.
    @MainActor
    static func prepareForHeavySheet() async {
        isWeeklyReportVisible = true
        cancelInFlightRefresh(replayIfBookingData: true)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()
        cancelInFlightRefresh(replayIfBookingData: true)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await Task.yield()
    }

    @MainActor
    private static func makeBookingScheduler() -> WarningsBookingScanScheduler {
        let scheduler = WarningsBookingScanScheduler()
        scheduler.isReadyToScan = { bookingScanIsReady() }
        scheduler.isPublishingNow = { WarningsService.shared.isLivePublishQueued }
        scheduler.onScan = { await runScheduledBookingScan() }
        scheduler.onCancelInFlightCompute = {
            if WarningsService.shared.isLivePublishQueued { return }
            cancelInFlightRefresh()
        }
        WarningsService.shared.onLivePublishFinished = {
            scheduler.publishDidFinish()
        }
        return scheduler
    }

    @MainActor
    private static func bookingScanIsReady() -> Bool {
        guard let inputs = bookingInputs else { return false }
        if isWeeklyReportVisible { return false }
        if inputs.firebaseBackend.isBootstrappingOrgDataLoad { return false }
        if !inputs.firebaseBackend.hasBootstrappedOrgDataLoad { return false }
        if inputs.bookingStore.isLoading || inputs.operativeStore.isLoading || inputs.projectStore.isLoading
            || inputs.managerScheduleStore.isLoading || inputs.holidayStore.isLoading || inputs.userStore.isLoading {
            return false
        }
        if let quietUntil = inputs.firebaseBackend.launchQuietUntil, Date() < quietUntil {
            return false
        }
        return true
    }

    @MainActor
    private static func runScheduledBookingScan() async {
        guard let inputs = bookingInputs else { return }
        bookingRefreshDeferred = false
        let didRun = await refreshSharedWarnings(
            operativeStore: inputs.operativeStore,
            bookingStore: inputs.bookingStore,
            projectStore: inputs.projectStore,
            userStore: inputs.userStore,
            managerScheduleStore: inputs.managerScheduleStore,
            holidayStore: inputs.holidayStore,
            firebaseBackend: inputs.firebaseBackend,
            appSettings: inputs.appSettings,
            force: true,
            bookingDataChanged: true
        )
        if !didRun, bookingRefreshDeferred {
            bookingRefreshDeferred = false
            bookingScheduler.scanWasNotReady()
        }
    }

    @MainActor
    private static func performRefresh(
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        projectStore: ProjectStore,
        userStore: UserStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        firebaseBackend: FirebaseBackend
    ) async {
        let cal = CanonicalBusinessEngine.businessCalendar
        let today = cal.startOfDay(for: Date())
        // The phone can still be on the default horizon until settings is opened.
        // Re-read the organisation document so exclusion and the scan window match Firestore.
        let livePaymentRuns = await firebaseBackend.refreshWarningDetectionFromServer()
        if Task.isCancelled { return }
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let warningDetection = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
        let invoicingSettings = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
        if warningDetection.clashLookaheadMode == .endOfInvoicingPeriod && !livePaymentRuns {
            print("🔥🔥🔥 DEBUG: Warnings refresh waiting for live payment runs")
            return
        }
        // Missing bookings must never become unbooked warnings: skip the scan and say why.
        if let reason = WarningsDataCompleteness.blockingReason(
            bookingsLoadFailed: bookingStore.lastLoadFailed,
            managerBookingsLoadFailed: managerScheduleStore.lastLoadFailed,
            bookingDecode: firebaseBackend.lastBookingDecodeReport
        ) {
            NSLog("WARNINGS_SCAN_SKIPPED reason=%@", reason)
            WarningsService.shared.setIncompleteDataMessage(reason)
            return
        }
        WarningsService.shared.setIncompleteDataMessage(nil)
        let activeOperatives = operativeStore.allOperatives.filter(\.isActive)

        // Honor Organisation Warnings detection horizon (days / working week / invoicing period).
        let canonical = CanonicalBusinessEngine.warningBounds(
            detection: warningDetection,
            invoicing: invoicingSettings,
            reference: today
        )
        let coverageStart = canonical.start
        let coverageEnd = canonical.end
        let unbookedEnd = CanonicalBusinessEngine.unbookedLabourWindowEnd(
            coverageEnd: coverageEnd,
            clashLookaheadMode: warningDetection.clashLookaheadMode.rawValue,
            includeWeekends: warningDetection.includeWeekendsForUnbookedLabour
        )
        let dataEnd = max(coverageEnd, unbookedEnd)
        let dayCount = max(1, (cal.dateComponents([.day], from: coverageStart, to: coverageEnd).day ?? 0) + 1)
        print("🔥🔥🔥 DEBUG: Warnings coverage mode=\(warningDetection.clashLookaheadMode.displayName) days=\(dayCount) \(coverageStart)…\(coverageEnd)")
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
        let tomorrowIds = Set(
            bookingStore.bookings
                .filter {
                    cal.isDate($0.date, inSameDayAs: tomorrow) &&
                        ($0.status == .confirmed || $0.status == .tentative)
                }
                .map(\.projectId)
        )
        let projects = projectStore.projects
        let projectsTomorrow = projects.filter { tomorrowIds.contains($0.id) }

        // Pre-window to the detection horizon before WarningsService snapshot work.
        let liveBookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= dataEnd
        }
        let liveManager = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= dataEnd
        }
        let liveHolidays = holidayStore.bookings.filter { holiday in
            let start = cal.startOfDay(for: holiday.startDate)
            let end = cal.startOfDay(for: holiday.endDate)
            return end >= coverageStart && start <= dataEnd
        }
        let dismissedQualificationKeys = await firebaseBackend.loadDismissedQualificationKeys(
            organizationId: firebaseBackend.currentOrganization?.firestoreDocumentId ?? ""
        )
        print("🔥🔥🔥 DEBUG: Warnings helper pre-window \(coverageStart)…\(coverageEnd) bookings=\(liveBookings.count)/\(bookingStore.bookings.count) mgr=\(liveManager.count)/\(managerScheduleStore.managerSiteBookings.count) dismissedQualifications=\(dismissedQualificationKeys.count)")

        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)
        await Task.yield()
        if Task.isCancelled { return }

        let materialCutOffClock = OrgMaterialCutOff.resolve(
            stored: firebaseBackend.currentOrganization?.settings.materialCutOff,
            organizationLoaded: firebaseBackend.currentOrganization != nil
        )
        let materialCutOffMinutes = materialCutOffClock.flatMap {
            CanonicalBusinessEngine.materialCutOffClockMinutes($0)
        } ?? 0
        let materialCutOffLabel = materialCutOffClock.flatMap {
            CanonicalBusinessEngine.formatMaterialCutOffClock($0)
        } ?? ""

        await WarningsService.shared.updateWarningsAsync(
            operatives: activeOperatives,
            bookings: liveBookings,
            projects: projects,
            users: userStore.organizationUsers,
            managerSiteBookings: liveManager,
            holidayBookings: liveHolidays,
            payrollTimePolicy: policy,
            warningDetection: warningDetection,
            invoicingSettings: invoicingSettings,
            labourCoverageStart: coverageStart,
            labourCoverageEnd: coverageEnd,
            unbookedCoverageEnd: unbookedEnd,
            materialOrderCutOffEnabled: materialCutOffClock?.materialOrderCutOff ?? false,
            materialCutOffOnSaturday: materialCutOffClock?.materialCutOffOnSaturday ?? false,
            materialCutOffOnSunday: materialCutOffClock?.materialCutOffOnSunday ?? false,
            materialCutOffMinutes: materialCutOffMinutes,
            materialCutOffLabel: materialCutOffLabel,
            projectsWithTomorrowBookings: projectsTomorrow,
            dismissedQualificationKeys: dismissedQualificationKeys,
            publishToLiveCache: true
        )
        postWarningsCountDidChange()
    }

    @MainActor
    static func postWarningsCountDidChange() {
        NotificationCenter.default.post(
            name: .warningsDidRecompute,
            object: nil,
            userInfo: ["count": WarningsService.shared.warningCount]
        )
    }
}
