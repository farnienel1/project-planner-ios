//
//  WarningsService.swift
//  Project Planner
//

import Foundation
import Combine

// Disk cache lives in this file (not a separate source) so Xcode always compiles it
// with WarningsService — avoids "Cannot find WarningsDiskCacheStore in scope".

nonisolated struct WarningsDiskCache: Codable, Sendable {
    var organizationId: String
    var savedAt: Date
    var hasCompletedLiveDetection: Bool
    var allGeneratedWarnings: [Warning]
    var activeWarnings: [Warning]
    var warningCount: Int
    var highCount: Int
    var mediumCount: Int
    var lowCount: Int

    static let empty = WarningsDiskCache(
        organizationId: "",
        savedAt: .distantPast,
        hasCompletedLiveDetection: false,
        allGeneratedWarnings: [],
        activeWarnings: [],
        warningCount: 0,
        highCount: 0,
        mediumCount: 0,
        lowCount: 0
    )
}

nonisolated enum WarningsDiskCacheStore {
    private static let activeOrgDefaultsKey = "warnings-live-cache-active-org"
    /// Serial so a newer scan cannot be overwritten by an older encode still in flight.
    private static let writeQueue = DispatchQueue(label: "farnie.warnings-live-cache", qos: .utility)

    static var activeOrganizationId: String? {
        get { UserDefaults.standard.string(forKey: activeOrgDefaultsKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: activeOrgDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeOrgDefaultsKey)
            }
        }
    }

    private static func fileURL(organizationId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("ProjectPlanner", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = organizationId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent("warnings-live-cache-v2-\(safe).json")
    }

    static func load(organizationId: String) -> WarningsDiskCache {
        guard !organizationId.isEmpty else { return .empty }
        let url = fileURL(organizationId: organizationId)
        if let data = try? Data(contentsOf: url),
           let cache = try? JSONDecoder().decode(WarningsDiskCache.self, from: data),
           cache.organizationId == organizationId {
            return cache
        }
        return migrateLegacyCacheIfNeeded(into: organizationId)
    }

    /// The old cache had no organisation. Give it to the first organisation that opens, then leave other organisations empty.
    private static func migrateLegacyCacheIfNeeded(into organizationId: String) -> WarningsDiskCache {
        let migratedKey = "warnings-live-cache-v1-migrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return .empty }
        UserDefaults.standard.set(true, forKey: migratedKey)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let legacyURL = dir
            .appendingPathComponent("ProjectPlanner", isDirectory: true)
            .appendingPathComponent("warnings-live-cache-v1.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(LegacyWarningsDiskCache.self, from: data) else {
            return .empty
        }
        let cache = WarningsDiskCache(
            organizationId: organizationId,
            savedAt: legacy.savedAt,
            hasCompletedLiveDetection: legacy.hasCompletedLiveDetection,
            allGeneratedWarnings: legacy.allGeneratedWarnings,
            activeWarnings: legacy.activeWarnings,
            warningCount: legacy.warningCount,
            highCount: legacy.highCount,
            mediumCount: legacy.mediumCount,
            lowCount: legacy.lowCount
        )
        save(cache)
        return cache
    }

    static func save(_ cache: WarningsDiskCache) {
        guard !cache.organizationId.isEmpty else { return }
        // Record the org before the file write. A switch must not be overwritten
        // when an older encode finishes, and the file name stays keyed by this id.
        activeOrganizationId = cache.organizationId
        let organizationId = cache.organizationId
        let activeCount = cache.activeWarnings.count
        let completed = cache.hasCompletedLiveDetection
        writeQueue.async {
            let url = fileURL(organizationId: organizationId)
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: url, options: [.atomic])
            print("🔥🔥🔥 DEBUG: WarningsDiskCache saved org=\(organizationId) active=\(activeCount) completed=\(completed)")
        }
    }
}

nonisolated private struct LegacyWarningsDiskCache: Codable {
    var savedAt: Date
    var hasCompletedLiveDetection: Bool
    var allGeneratedWarnings: [Warning]
    var activeWarnings: [Warning]
    var warningCount: Int
    var highCount: Int
    var mediumCount: Int
    var lowCount: Int
}

struct WarningTotals: Equatable, Sendable {
    var total = 0
    var high = 0
    var medium = 0
    var low = 0
}

@MainActor
class WarningsService: ObservableObject {
    /// Shared instance for Warnings sheet / weekly report (avoid duplicating state on Home).
    static let shared = WarningsService()

    /// Not @Published. The open Warnings sheet reads these inside the same turn they are
    /// stored; publishing each one made that read re-enter the setter and the main thread
    /// never came back. One objectWillChange is scheduled after the values are stored.
    private(set) var allGeneratedWarnings: [Warning] = []
    private(set) var activeWarnings: [Warning] = []
    /// Period scans for Weekly Report only — never overwrite the live Home/Warnings list.
    @Published private(set) var periodGeneratedWarnings: [Warning] = []
    @Published private(set) var hasCompletedPeriodDetection = false
    /// Set when the last scan was skipped because a booking read failed. The list on screen is then the
    /// previous complete scan (or empty), never a scan of partial data.
    @Published private(set) var incompleteDataMessage: String?

    func setIncompleteDataMessage(_ message: String?) {
        guard incompleteDataMessage != message else { return }
        incompleteDataMessage = message
    }
    /// `coverageWindow.fallbackReason` of the last live scan (`lookaheadDaysMissing` / `lookaheadDaysInvalid`).
    /// The Warnings screen says the scan used 7 days instead of the saved number.
    @Published private(set) var scanFallbackReason: String?
    /// High, medium, low, and the total. One value, written once per live update.
    private(set) var totals = WarningTotals()
    var warningCount: Int { totals.total }
    var highCount: Int { totals.high }
    var mediumCount: Int { totals.medium }
    var lowCount: Int { totals.low }
    /// True after at least one *live* scan has published (empty = all clear for that window).
    private(set) var hasCompletedLiveDetection = false
    private var livePublishScheduled = false
    /// True until the deferred objectWillChange for this live list has been sent.
    var isLivePublishQueued: Bool { livePublishScheduled }
    /// Runs on the turn after objectWillChange so a follow-up scan is not a second publish on this stack.
    var onLivePublishFinished: (@MainActor () -> Void)?

    enum WarningListSource {
        case live
        case period
    }

    private let resolutionStore: WarningResolutionStore
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0
    private var cacheOrganizationId: String?

    init(resolutionStore: WarningResolutionStore? = nil, hydrateFromDisk: Bool = true) {
        self.resolutionStore = resolutionStore ?? .shared
        // Hydrate only the organisation that last owned this cache. A switch must not
        // keep the previous organisation's warnings on Home.
        if hydrateFromDisk, let organizationId = WarningsDiskCacheStore.activeOrganizationId, !organizationId.isEmpty {
            cacheOrganizationId = organizationId
            // Sign-in must not put the last scan back on screen. That snapshot can still
            // list the day after the payment run until live ranges have been read.
        }
    }

    /// Drop the previous organisation's warnings and show this organisation's own cache.
    func adoptOrganization(_ organizationId: String) {
        let trimmed = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard cacheOrganizationId != trimmed else { return }
        cancelInFlightUpdate()
        cacheOrganizationId = trimmed
        WarningResolutionStore.shared.adoptOrganization(trimmed)
        clearPublishedWarnings()
        WarningsRefreshHelper.postWarningsCountDidChange()
        print("🔥🔥🔥 DEBUG: WarningsService adopted org=\(trimmed) active=\(activeWarnings.count)")
    }

    private func clearPublishedWarnings() {
        allGeneratedWarnings = []
        activeWarnings = []
        totals = WarningTotals()
        hasCompletedLiveDetection = false
        scheduleLivePublish()
    }

    /// Drops schedule rows whose organisation day is outside the scan window. Qualification and
    /// unverified rows have no day in that window and stay. Unbooked rows run to `unbookedEnd`, clash rows to
    /// `clashEnd` (`clashScanDays`: a booked Saturday or Sunday in Full week), material rows are for tomorrow.
    static func warningsInsideCoverageWindow(
        _ warnings: [Warning],
        start: Date,
        end: Date,
        unbookedEnd: Date,
        clashEnd: Date? = nil,
        calendar: Calendar = CanonicalBusinessEngine.businessCalendar
    ) -> [Warning] {
        let startKey = CanonicalBusinessEngine.dayKey(for: start, calendar: calendar)
        let endKey = CanonicalBusinessEngine.dayKey(for: end, calendar: calendar)
        let unbookedEndKey = CanonicalBusinessEngine.dayKey(for: unbookedEnd, calendar: calendar)
        let clashEndKey = clashEnd.map { CanonicalBusinessEngine.dayKey(for: $0, calendar: calendar) } ?? endKey
        return warnings.filter { warning in
            guard warning.isCorePriorityWarning else { return true }
            // `materialCutOffWarningRows` rows are for tomorrow, which can sit after the scan window.
            if warning.type == .materialsCutoff { return true }
            guard let date = warning.occurrenceDate ?? warning.clashDate else { return true }
            let key = CanonicalBusinessEngine.dayKey(for: date, calendar: calendar)
            let limit: String
            switch warning.type {
            case .unbookedLabour: limit = unbookedEndKey
            case .operativeBookingClash, .managerLocationClash: limit = max(clashEndKey, endKey)
            default: limit = endKey
            }
            return key >= startKey && key <= limit
        }
    }

    /// Snapshot from the arrays already in hand. Reading `allGeneratedWarnings` again on the
    /// publish turn calls `swift_beginAccess` and does not return, so the deferred
    /// `objectWillChange` never runs and the sheet stays on "Scanning…".
    private func persistLiveCacheToDisk(
        organizationId: String?,
        generated: [Warning],
        active: [Warning],
        completed: Bool
    ) {
        guard self === WarningsService.shared else { return }
        guard let organizationId, !organizationId.isEmpty else { return }
        let counts = Self.totals(for: active)
        WarningsDiskCacheStore.save(
            WarningsDiskCache(
                organizationId: organizationId,
                savedAt: Date(),
                hasCompletedLiveDetection: completed,
                allGeneratedWarnings: generated,
                activeWarnings: active,
                warningCount: counts.total,
                highCount: counts.high,
                mediumCount: counts.medium,
                lowCount: counts.low
            )
        )
    }

    /// Store the live list and the one totals value, then tell SwiftUI on the next turn.
    private func applyLiveWarnings(generated: [Warning], active: [Warning], completed: Bool) {
        allGeneratedWarnings = generated
        activeWarnings = active
        totals = Self.totals(for: active)
        hasCompletedLiveDetection = completed
        scheduleLivePublish()
    }

    /// objectWillChange during the scan's turn re-entered the open Warnings body while
    /// activeWarnings was still being stored. The next main-actor turn reads the stored values.
    private func scheduleLivePublish() {
        guard !livePublishScheduled else { return }
        livePublishScheduled = true
        Task { @MainActor in
            self.livePublishScheduled = false
            self.objectWillChange.send()
            let finished = self.onLivePublishFinished
            guard finished != nil else { return }
            Task { @MainActor in
                finished?()
            }
        }
    }

    private static func totals(for warnings: [Warning]) -> WarningTotals {
        var high = 0
        var medium = 0
        var low = 0
        for warning in warnings {
            switch warning.severity {
            case .high: high += 1
            case .medium: medium += 1
            case .low: low += 1
            }
        }
        return WarningTotals(total: warnings.count, high: high, medium: medium, low: low)
    }

    /// HIGH: operative booking clashes still active in range.
    func operativeBookingClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.operativeBookingClash], activeOnly: true, source: source)
    }

    /// MEDIUM: manager/admin overlaps still awaiting tick for weekly report.
    func unresolvedManagerClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.managerLocationClash], activeOnly: true, source: source)
    }

    /// Booking clashes approved on any device (`isClashApproved`) — included on weekly report CSV.
    func approvedManagerClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        var seen = Set<String>()
        return warningsInRange(range, types: [.operativeBookingClash, .managerLocationClash], activeOnly: false, source: source)
            .filter { resolutionStore.isClashApproved($0) && seen.insert($0.resolutionKey).inserted }
    }

    /// Every approved clash in the live scan, for the Un-approve list on Warnings.
    func approvedClashWarnings() -> [Warning] {
        var seen = Set<String>()
        return allGeneratedWarnings.filter { warning in
            warning.requiresWeeklyReportApproval
                && resolutionStore.isClashApproved(warning)
                && seen.insert(warning.resolutionKey).inserted
        }
    }

    func unresolvedBookingClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.operativeBookingClash, .managerLocationClash], activeOnly: true, source: source)
    }

    /// HIGH: unbooked labour per weekday in range.
    func unbookedLabourWarnings(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.unbookedLabour], activeOnly: true, source: source)
    }

    /// LOW: material orders not placed by the organisation cut-off.
    func materialsCutoffWarnings(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.materialsCutoff], activeOnly: true, source: source)
    }

    private func warningsInRange(
        _ range: ClosedRange<Date>,
        types: Set<Warning.WarningType>,
        activeOnly: Bool,
        source: WarningListSource
    ) -> [Warning] {
        let pool = source == .period ? periodGeneratedWarnings : allGeneratedWarnings
        return pool.filter { w in
            guard types.contains(w.type) else { return false }
            guard let day = w.occurrenceDate else { return false }
            guard range.contains(day) else { return false }
            if activeOnly {
                // `isWarningActive` over `resolvedWarningKeys` and `acceptedBookingClashes`.
                return resolutionStore.shouldShowActive(w)
            }
            return true
        }
    }

    func updateWarnings(
        operatives: [Operative],
        bookings: [Booking],
        projects: [Project],
        managers: [Manager],
        users: [AppUser] = [],
        managerSiteBookings: [ManagerSiteBooking] = [],
        holidayBookings: [HolidayBooking] = [],
        payrollTimePolicy: OrgPayrollTimePolicy? = nil,
        warningDetection: OrgWarningDetectionSettings? = nil,
        invoicingSettings: OrganizationInvoicingSettings? = nil,
        labourCoverageStart: Date? = nil,
        labourCoverageEnd: Date? = nil,
        unbookedCoverageEnd: Date? = nil,
        materialOrderCutOffEnabled: Bool = true,
        materialCutOffOnSaturday: Bool = false,
        materialCutOffOnSunday: Bool = false,
        materialCutOffMinutes: Int = 0,
        materialCutOffLabel: String = "",
        projectsWithTomorrowBookings: [Project] = [],
        materialItemsForTomorrow: [MaterialItem] = [],
        dismissedQualificationKeys: Set<String> = [],
        materialCutOff: OrgMaterialCutOff? = nil,
        materialCutOffBookings: [Booking] = [],
        materialSendRecords: [MaterialSendRecord] = []
    ) {
        let resolvedPayrollTimePolicy = payrollTimePolicy ?? .default
        let resolvedWarningDetection = warningDetection ?? .default
        let resolvedInvoicing = invoicingSettings ?? .default

        updateTask?.cancel()
        updateTask = Task { @MainActor in
            await performUpdate(
                operatives: operatives,
                bookings: bookings,
                projects: projects,
                users: users,
                managerSiteBookings: managerSiteBookings,
                holidayBookings: holidayBookings,
                payrollTimePolicy: resolvedPayrollTimePolicy,
                warningDetection: resolvedWarningDetection,
                invoicingSettings: resolvedInvoicing,
                labourCoverageStart: labourCoverageStart,
                labourCoverageEnd: labourCoverageEnd,
                unbookedCoverageEnd: unbookedCoverageEnd,
                materialOrderCutOffEnabled: materialOrderCutOffEnabled,
                materialCutOffOnSaturday: materialCutOffOnSaturday,
                materialCutOffOnSunday: materialCutOffOnSunday,
                materialCutOffMinutes: materialCutOffMinutes,
                materialCutOffLabel: materialCutOffLabel,
                projectsWithTomorrowBookings: projectsWithTomorrowBookings,
                materialItemsForTomorrow: materialItemsForTomorrow,
                dismissedQualificationKeys: dismissedQualificationKeys,
                materialCutOff: materialCutOff,
                materialCutOffBookings: materialCutOffBookings,
                materialSendRecords: materialSendRecords,
                publishToLiveCache: true
            )
        }
    }

    /// Awaitable update for Home / report (build + compute off main thread).
    func updateWarningsAsync(
        operatives: [Operative],
        bookings: [Booking],
        projects: [Project],
        users: [AppUser] = [],
        managerSiteBookings: [ManagerSiteBooking] = [],
        holidayBookings: [HolidayBooking] = [],
        payrollTimePolicy: OrgPayrollTimePolicy? = nil,
        warningDetection: OrgWarningDetectionSettings? = nil,
        invoicingSettings: OrganizationInvoicingSettings? = nil,
        labourCoverageStart: Date? = nil,
        labourCoverageEnd: Date? = nil,
        unbookedCoverageEnd: Date? = nil,
        materialOrderCutOffEnabled: Bool = true,
        materialCutOffOnSaturday: Bool = false,
        materialCutOffOnSunday: Bool = false,
        materialCutOffMinutes: Int = 0,
        materialCutOffLabel: String = "",
        projectsWithTomorrowBookings: [Project] = [],
        materialItemsForTomorrow: [MaterialItem] = [],
        dismissedQualificationKeys: Set<String> = [],
        materialCutOff: OrgMaterialCutOff? = nil,
        materialCutOffBookings: [Booking] = [],
        materialSendRecords: [MaterialSendRecord] = [],
        publishToLiveCache: Bool = true
    ) async {
        let resolvedPayrollTimePolicy = payrollTimePolicy ?? .default
        let resolvedWarningDetection = warningDetection ?? .default
        let resolvedInvoicing = invoicingSettings ?? .default

        updateTask?.cancel()
        await performUpdate(
            operatives: operatives,
            bookings: bookings,
            projects: projects,
            users: users,
            managerSiteBookings: managerSiteBookings,
            holidayBookings: holidayBookings,
            payrollTimePolicy: resolvedPayrollTimePolicy,
            warningDetection: resolvedWarningDetection,
            invoicingSettings: resolvedInvoicing,
            labourCoverageStart: labourCoverageStart,
            labourCoverageEnd: labourCoverageEnd,
            unbookedCoverageEnd: unbookedCoverageEnd,
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            materialCutOffMinutes: materialCutOffMinutes,
            materialCutOffLabel: materialCutOffLabel,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings,
            materialItemsForTomorrow: materialItemsForTomorrow,
            dismissedQualificationKeys: dismissedQualificationKeys,
            materialCutOff: materialCutOff,
            materialCutOffBookings: materialCutOffBookings,
            materialSendRecords: materialSendRecords,
            publishToLiveCache: publishToLiveCache
        )
    }

    private func performUpdate(
        operatives: [Operative],
        bookings: [Booking],
        projects: [Project],
        users: [AppUser],
        managerSiteBookings: [ManagerSiteBooking],
        holidayBookings: [HolidayBooking],
        payrollTimePolicy: OrgPayrollTimePolicy,
        warningDetection: OrgWarningDetectionSettings,
        invoicingSettings: OrganizationInvoicingSettings,
        labourCoverageStart: Date?,
        labourCoverageEnd: Date?,
        unbookedCoverageEnd: Date?,
        materialOrderCutOffEnabled: Bool,
        materialCutOffOnSaturday: Bool,
        materialCutOffOnSunday: Bool,
        materialCutOffMinutes: Int,
        materialCutOffLabel: String,
        projectsWithTomorrowBookings: [Project],
        materialItemsForTomorrow: [MaterialItem],
        dismissedQualificationKeys: Set<String>,
        materialCutOff: OrgMaterialCutOff?,
        materialCutOffBookings: [Booking],
        materialSendRecords: [MaterialSendRecord],
        publishToLiveCache: Bool
    ) async {
        if Task.isCancelled { return }
        updateGeneration += 1
        let generation = updateGeneration
        let cal = CanonicalBusinessEngine.businessCalendar
        // `coverageWindow` + `clashScanDays` (a booked Saturday or Sunday joins the clash days in Full week).
        var bookedDayKeySet = Set<String>()
        for booking in bookings { bookedDayKeySet.insert(CanonicalBusinessEngine.dayKey(for: booking.date, calendar: cal)) }
        for booking in managerSiteBookings { bookedDayKeySet.insert(CanonicalBusinessEngine.dayKey(for: booking.date, calendar: cal)) }
        let scanWindow = CanonicalBusinessEngine.warningScanWindow(
            detection: warningDetection,
            invoicing: invoicingSettings,
            bookedDayKeys: bookedDayKeySet.sorted()
        )
        let canonical = scanWindow.map { (start: $0.start, end: $0.end) }
            ?? CanonicalBusinessEngine.warningBounds(detection: warningDetection, invoicing: invoicingSettings)
        // Explicit coverage (from refresh helper) still publishes to the live Warnings list
        // when publishToLiveCache is true. Period-only callers can set it false.
        let isLiveScan = publishToLiveCache
        let coverageStart = cal.startOfDay(for: labourCoverageStart ?? canonical.start)
        let coverageEnd = cal.startOfDay(for: labourCoverageEnd ?? canonical.end)
        let unbookedEnd = cal.startOfDay(for: unbookedCoverageEnd ?? scanWindow?.unbookedEnd ?? coverageEnd)
        // The script's clash days only when this scan is the script's window.
        let usesScriptWindow = scanWindow.map {
            CanonicalBusinessEngine.dayKey(for: coverageStart, calendar: cal) == $0.startDayKey
                && CanonicalBusinessEngine.dayKey(for: coverageEnd, calendar: cal) == $0.endDayKey
        } ?? false
        let clashDayKeys = usesScriptWindow ? scanWindow?.clashDayKeys : nil
        let clashEnd = usesScriptWindow ? (scanWindow?.clashEnd ?? coverageEnd) : coverageEnd
        if isLiveScan, self === WarningsService.shared, scanFallbackReason != scanWindow?.fallbackReason {
            scanFallbackReason = scanWindow?.fallbackReason
        }
        let dataEnd = max(coverageEnd, max(unbookedEnd, clashEnd))
        let windowedBookings = bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= dataEnd
        }
        let windowedManager = managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= dataEnd
        }
        let windowedHolidays = holidayBookings.filter { holiday in
            let start = cal.startOfDay(for: holiday.startDate)
            let end = cal.startOfDay(for: holiday.endDate)
            return end >= coverageStart && start <= dataEnd
        }
        print("🔥🔥🔥 DEBUG: WarningsService live=\(isLiveScan) window bookings=\(windowedBookings.count)/\(bookings.count) mgr=\(windowedManager.count) \(coverageStart)…\(coverageEnd)")
        let referencedProjectIds = Set(windowedBookings.map(\.projectId))
            .union(windowedManager.compactMap(\.locationId))
            .union(projectsWithTomorrowBookings.map(\.id))
            .union(materialCutOffBookings.map(\.projectId))
        let slimProjects = referencedProjectIds.isEmpty
            ? projects
            : projects.filter { referencedProjectIds.contains($0.id) }
        var input = WarningsComputationInput(
            operatives: operatives,
            bookings: windowedBookings,
            projects: slimProjects,
            users: users,
            managerSiteBookings: windowedManager,
            holidayBookings: windowedHolidays,
            payrollTimePolicy: payrollTimePolicy,
            warningDetection: warningDetection,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            unbookedCoverageEnd: unbookedEnd,
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            materialCutOffMinutes: materialCutOffMinutes,
            materialCutOffLabel: materialCutOffLabel,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings,
            materialItemsForTomorrow: materialItemsForTomorrow,
            dismissedQualificationKeys: dismissedQualificationKeys
        )
        input.materialCutOff = materialCutOff
        input.materialCutOffBookings = materialCutOffBookings
        input.materialSendRecords = materialSendRecords
        input.clashDayKeys = clashDayKeys
        // Snapshot on MainActor (Swift 6 default isolation) over the *windowed* arrays.
        // Detach only generate. Extra yields stop Home quiet-expired jetsam.
        await Task.yield()
        try? await Task.sleep(nanoseconds: isLiveScan ? 300_000_000 : 50_000_000)
        await Task.yield()
        let snapshot = WarningsComputation.makeSnapshot(from: input)
        await Task.yield()
        let result = await Task.detached(priority: .utility) {
            WarningsComputation.generateWithLegacyKeys(snapshot)
        }.value
        guard generation == updateGeneration else { return }
        let generated = result.warnings
        let generatedInWindow = Self.warningsInsideCoverageWindow(
            generated,
            start: coverageStart,
            end: coverageEnd,
            unbookedEnd: unbookedEnd,
            clashEnd: clashEnd
        )
        // D3: rows whose approval or dismissal was saved under an older iOS key.
        if isLiveScan || self !== WarningsService.shared {
            resolutionStore.updateLegacyKeys(result.legacyKeys, warnings: generatedInWindow)
        }
        if isLiveScan {
            let active = uniqueActive(generatedInWindow)
            let organizationId = cacheOrganizationId
            NSLog("WARNINGS_PUBLISH active=%d generated=%d", active.count, generatedInWindow.count)
            applyLiveWarnings(generated: generatedInWindow, active: active, completed: true)
            persistLiveCacheToDisk(
                organizationId: organizationId,
                generated: generatedInWindow,
                active: active,
                completed: true
            )
            print("🔥🔥🔥 DEBUG: WarningsService LIVE published active=\(active.count) generated=\(generatedInWindow.count)")
        } else {
            // Period scan must not wipe Home/Warnings live cache on the shared instance.
            periodGeneratedWarnings = generatedInWindow
            hasCompletedPeriodDetection = true
            if self !== WarningsService.shared {
                // Private Weekly Report export service — local only.
                let active = uniqueActive(generatedInWindow)
                applyLiveWarnings(generated: generatedInWindow, active: active, completed: hasCompletedLiveDetection)
            }
            print("🔥🔥🔥 DEBUG: WarningsService PERIOD published count=\(generatedInWindow.count) sharedLiveUntouched=\(self === WarningsService.shared) active=\(WarningsService.shared.activeWarnings.count)")
        }
    }

    /// Rebuild: Weekly Report copies live-cache rows into the private period bucket (no heavy rescan).
    func replaceWithPeriodWarnings(_ warnings: [Warning]) {
        periodGeneratedWarnings = warnings
        hasCompletedPeriodDetection = true
        let active = uniqueActive(warnings)
        applyLiveWarnings(generated: warnings, active: active, completed: hasCompletedLiveDetection)
    }

    func cancelInFlightUpdate() {
        updateGeneration += 1
        updateTask?.cancel()
        updateTask = nil
        print("🔥🔥🔥 DEBUG: WarningsService cancelInFlightUpdate")
    }

    /// Approve a booking clash so it is noted on the weekly report (`clashApprovalWrites`). Staff only:
    /// the store refuses anyone `canViewStaffWarnings` says no to.
    @discardableResult
    func approveWarning(_ warning: Warning) -> Bool {
        guard warning.requiresWeeklyReportApproval else { return false }
        guard resolutionStore.approve(warning) else { return false }
        refreshActiveFromGenerated()
        WarningsRefreshHelper.postWarningsCountDidChange()
        return true
    }

    /// Un-approve a booking clash: deletes both approval documents. Staff only, online only (the screen checks).
    @discardableResult
    func unapproveWarning(_ warning: Warning, completion: ((Error?) -> Void)? = nil) -> Bool {
        guard warning.requiresWeeklyReportApproval else { return false }
        let started = resolutionStore.unapprove(warning) { [weak self] error in
            self?.refreshActiveFromGenerated()
            WarningsRefreshHelper.postWarningsCountDidChange()
            completion?(error)
        }
        guard started else { return false }
        refreshActiveFromGenerated()
        WarningsRefreshHelper.postWarningsCountDidChange()
        return true
    }

    /// Approvals and accepted clashes loaded from Firestore (web or another phone) hide their warnings now.
    func reapplyResolutions() {
        refreshActiveFromGenerated()
        WarningsRefreshHelper.postWarningsCountDidChange()
    }

    /// Staff only: the store refuses anyone `canViewStaffWarnings` says no to.
    @discardableResult
    func dismissWarning(_ warning: Warning) -> Bool {
        guard resolutionStore.dismiss(warning.resolutionKey) else { return false }
        refreshActiveFromGenerated()
        WarningsRefreshHelper.postWarningsCountDidChange()
        return true
    }

    private func uniqueActive(_ warnings: [Warning]) -> [Warning] {
        var seen = Set<String>()
        return warnings.filter { warning in
            resolutionStore.shouldShowActive(warning) && seen.insert(warning.resolutionKey).inserted
        }
    }

    private func refreshActiveFromGenerated() {
        let generated = allGeneratedWarnings
        let organizationId = cacheOrganizationId
        let completed = hasCompletedLiveDetection
        let active = uniqueActive(generated)
        activeWarnings = active
        totals = Self.totals(for: active)
        scheduleLivePublish()
        persistLiveCacheToDisk(
            organizationId: organizationId,
            generated: generated,
            active: active,
            completed: completed
        )
    }

}
