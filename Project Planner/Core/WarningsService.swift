//
//  WarningsService.swift
//  Project Planner
//

import Foundation
import Combine

// Disk cache lives in this file (not a separate source) so Xcode always compiles it
// with WarningsService — avoids "Cannot find WarningsDiskCacheStore in scope".

struct WarningsDiskCache: Codable {
    var savedAt: Date
    var hasCompletedLiveDetection: Bool
    var allGeneratedWarnings: [Warning]
    var activeWarnings: [Warning]
    var warningCount: Int
    var highCount: Int
    var mediumCount: Int
    var lowCount: Int

    static let empty = WarningsDiskCache(
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

enum WarningsDiskCacheStore {
    private static let fileName = "warnings-live-cache-v1.json"

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("ProjectPlanner", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    static func load() -> WarningsDiskCache {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(WarningsDiskCache.self, from: data)) ?? .empty
    }

    static func save(_ cache: WarningsDiskCache) {
        let url = fileURL
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
        print("🔥🔥🔥 DEBUG: WarningsDiskCache saved active=\(cache.activeWarnings.count) completed=\(cache.hasCompletedLiveDetection)")
    }
}

@MainActor
class WarningsService: ObservableObject {
    /// Shared instance for Warnings sheet / weekly report (avoid duplicating state on Home).
    static let shared = WarningsService()

    @Published private(set) var allGeneratedWarnings: [Warning] = []
    @Published private(set) var activeWarnings: [Warning] = []
    /// Period scans for Weekly Report only — never overwrite the live Home/Warnings list.
    @Published private(set) var periodGeneratedWarnings: [Warning] = []
    @Published private(set) var hasCompletedPeriodDetection = false
    @Published private(set) var warningCount: Int = 0
    @Published private(set) var highCount: Int = 0
    @Published private(set) var mediumCount: Int = 0
    @Published private(set) var lowCount: Int = 0
    /// True after at least one *live* scan has published (empty = all clear for that window).
    @Published private(set) var hasCompletedLiveDetection = false

    enum WarningListSource {
        case live
        case period
    }

    private let resolutionStore: WarningResolutionStore
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0

    init(resolutionStore: WarningResolutionStore? = nil, hydrateFromDisk: Bool = true) {
        self.resolutionStore = resolutionStore ?? .shared
        // Rebuild: hydrate from disk immediately so Home/Warnings never need an auto-scan.
        // Do NOT compare `self === .shared` here — shared is still being created.
        if hydrateFromDisk {
            let cache = WarningsDiskCacheStore.load()
            if cache.hasCompletedLiveDetection || !cache.activeWarnings.isEmpty {
                allGeneratedWarnings = cache.allGeneratedWarnings
                activeWarnings = cache.activeWarnings
                warningCount = cache.warningCount
                highCount = cache.highCount
                mediumCount = cache.mediumCount
                lowCount = cache.lowCount
                hasCompletedLiveDetection = cache.hasCompletedLiveDetection
                print("🔥🔥🔥 DEBUG: WarningsService hydrated from disk active=\(activeWarnings.count) completed=\(hasCompletedLiveDetection)")
            }
        }
    }

    private func persistLiveCacheToDisk() {
        // Only the shared live service writes the Home/Warnings cache.
        guard self === WarningsService.shared else { return }
        WarningsDiskCacheStore.save(
            WarningsDiskCache(
                savedAt: Date(),
                hasCompletedLiveDetection: hasCompletedLiveDetection,
                allGeneratedWarnings: allGeneratedWarnings,
                activeWarnings: activeWarnings,
                warningCount: warningCount,
                highCount: highCount,
                mediumCount: mediumCount,
                lowCount: lowCount
            )
        )
    }

    /// Counts only core priority warnings (operative clashes, unbooked labour, manager clashes, materials).
    private var corePriorityActiveWarnings: [Warning] {
        activeWarnings.filter(\.isCorePriorityWarning)
    }

    private func refreshSeverityCounts() {
        let core = corePriorityActiveWarnings
        warningCount = core.count
        var high = 0
        var medium = 0
        var low = 0
        for warning in core {
            switch warning.severity {
            case .high: high += 1
            case .medium: medium += 1
            case .low: low += 1
            }
        }
        highCount = high
        mediumCount = medium
        lowCount = low
    }

    func warningsSortedByDate() -> [Warning] {
        activeWarnings.sorted { lhs, rhs in
            let l = lhs.occurrenceDate ?? .distantPast
            let r = rhs.occurrenceDate ?? .distantPast
            if l != r { return l > r }
            if lhs.isCorePriorityWarning != rhs.isCorePriorityWarning {
                return lhs.isCorePriorityWarning
            }
            return severityRank(lhs.severity) > severityRank(rhs.severity)
        }
    }

    /// HIGH: operative booking clashes still active in range.
    func operativeBookingClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.operativeBookingClash], activeOnly: true, source: source)
    }

    /// HIGH: manager/admin overlaps still awaiting tick for weekly report.
    func unresolvedManagerClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.managerLocationClash], activeOnly: true, source: source)
    }

    /// Booking clashes ticked on Warnings — included on weekly report CSV.
    func approvedManagerClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.operativeBookingClash, .managerLocationClash], activeOnly: false, source: source)
            .filter { resolutionStore.isApproved($0.resolutionKey) }
    }

    func unresolvedBookingClashes(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.operativeBookingClash, .managerLocationClash], activeOnly: true, source: source)
    }

    /// HIGH: unbooked labour per weekday in range.
    func unbookedLabourWarnings(in range: ClosedRange<Date>, source: WarningListSource = .live) -> [Warning] {
        warningsInRange(range, types: [.unbookedLabour], activeOnly: true, source: source)
    }

    /// LOW: material orders not placed by 16:00.
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
                return resolutionStore.shouldShowActive(w.resolutionKey)
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
        materialOrderCutOffEnabled: Bool = true,
        materialCutOffOnSaturday: Bool = false,
        materialCutOffOnSunday: Bool = false,
        projectsWithTomorrowBookings: [Project] = [],
        materialItemsForTomorrow: [MaterialItem] = []
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
                materialOrderCutOffEnabled: materialOrderCutOffEnabled,
                materialCutOffOnSaturday: materialCutOffOnSaturday,
                materialCutOffOnSunday: materialCutOffOnSunday,
                projectsWithTomorrowBookings: projectsWithTomorrowBookings,
                materialItemsForTomorrow: materialItemsForTomorrow,
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
        materialOrderCutOffEnabled: Bool = true,
        materialCutOffOnSaturday: Bool = false,
        materialCutOffOnSunday: Bool = false,
        projectsWithTomorrowBookings: [Project] = [],
        materialItemsForTomorrow: [MaterialItem] = [],
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
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings,
            materialItemsForTomorrow: materialItemsForTomorrow,
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
        materialOrderCutOffEnabled: Bool,
        materialCutOffOnSaturday: Bool,
        materialCutOffOnSunday: Bool,
        projectsWithTomorrowBookings: [Project],
        materialItemsForTomorrow: [MaterialItem],
        publishToLiveCache: Bool
    ) async {
        updateGeneration += 1
        let generation = updateGeneration
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Explicit coverage (from refresh helper) still publishes to the live Warnings list
        // when publishToLiveCache is true. Period-only callers can set it false.
        let isLiveScan = publishToLiveCache
        let coverageStart = cal.startOfDay(
            for: labourCoverageStart
                ?? warningDetection.coverageStart(from: today, invoicing: invoicingSettings, calendar: cal)
        )
        let coverageEnd = cal.startOfDay(
            for: labourCoverageEnd
                ?? warningDetection.coverageEnd(from: today, invoicing: invoicingSettings, calendar: cal)
        )
        let windowedBookings = bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= coverageEnd
        }
        let windowedManager = managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= coverageEnd
        }
        let windowedHolidays = holidayBookings.filter { holiday in
            let start = cal.startOfDay(for: holiday.startDate)
            let end = cal.startOfDay(for: holiday.endDate)
            return end >= coverageStart && start <= coverageEnd
        }
        print("🔥🔥🔥 DEBUG: WarningsService live=\(isLiveScan) window bookings=\(windowedBookings.count)/\(bookings.count) mgr=\(windowedManager.count) \(coverageStart)…\(coverageEnd)")
        let referencedProjectIds = Set(windowedBookings.map(\.projectId))
            .union(windowedManager.compactMap(\.locationId))
            .union(projectsWithTomorrowBookings.map(\.id))
        let slimProjects = referencedProjectIds.isEmpty
            ? projects
            : projects.filter { referencedProjectIds.contains($0.id) }
        let input = WarningsComputationInput(
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
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings,
            materialItemsForTomorrow: materialItemsForTomorrow
        )
        // Snapshot on MainActor (Swift 6 default isolation) over the *windowed* arrays.
        // Detach only generate. Extra yields stop Home quiet-expired jetsam.
        await Task.yield()
        try? await Task.sleep(nanoseconds: isLiveScan ? 300_000_000 : 50_000_000)
        await Task.yield()
        let snapshot = WarningsComputation.makeSnapshot(from: input)
        await Task.yield()
        let generated = await Task.detached(priority: .utility) {
            WarningsComputation.generate(snapshot)
        }.value
        guard generation == updateGeneration else { return }
        if isLiveScan {
            allGeneratedWarnings = generated
            activeWarnings = generated.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
            refreshSeverityCounts()
            hasCompletedLiveDetection = true
            persistLiveCacheToDisk()
            print("🔥🔥🔥 DEBUG: WarningsService LIVE published active=\(activeWarnings.count) generated=\(generated.count)")
        } else {
            // Period scan must not wipe Home/Warnings live cache on the shared instance.
            periodGeneratedWarnings = generated
            hasCompletedPeriodDetection = true
            if self !== WarningsService.shared {
                // Private Weekly Report export service — local only.
                allGeneratedWarnings = generated
                activeWarnings = generated.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
                refreshSeverityCounts()
            }
            print("🔥🔥🔥 DEBUG: WarningsService PERIOD published count=\(generated.count) sharedLiveUntouched=\(self === WarningsService.shared) active=\(WarningsService.shared.activeWarnings.count)")
        }
    }

    /// Rebuild: Weekly Report copies live-cache rows into the private period bucket (no heavy rescan).
    func replaceWithPeriodWarnings(_ warnings: [Warning]) {
        periodGeneratedWarnings = warnings
        hasCompletedPeriodDetection = true
        allGeneratedWarnings = warnings
        activeWarnings = warnings.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
        refreshSeverityCounts()
    }

    func cancelInFlightUpdate() {
        updateGeneration += 1
        updateTask?.cancel()
        updateTask = nil
        print("🔥🔥🔥 DEBUG: WarningsService cancelInFlightUpdate")
    }

    /// Approve a booking clash so it is noted on the weekly report.
    func approveWarning(_ warning: Warning) {
        guard warning.requiresWeeklyReportApproval else { return }
        resolutionStore.approve(warning.resolutionKey)
        refreshActiveFromGenerated()
        WarningsRefreshHelper.postWarningsCountDidChange()
    }

    func dismissWarning(_ warning: Warning) {
        resolutionStore.dismiss(warning.resolutionKey)
        refreshActiveFromGenerated()
        WarningsRefreshHelper.postWarningsCountDidChange()
    }

    private func refreshActiveFromGenerated() {
        activeWarnings = allGeneratedWarnings.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
        refreshSeverityCounts()
        persistLiveCacheToDisk()
    }

    private func severityRank(_ severity: Warning.WarningSeverity) -> Int {
        switch severity {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

}
