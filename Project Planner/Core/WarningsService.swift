//
//  WarningsService.swift
//  Project Planner
//

import Foundation
import Combine

@MainActor
class WarningsService: ObservableObject {
    /// Shared instance for Warnings sheet / Home badge (avoid duplicating org-horizon state).
    static let shared = WarningsService()

    @Published private(set) var allGeneratedWarnings: [Warning] = []
    @Published private(set) var activeWarnings: [Warning] = []
    @Published private(set) var warningCount: Int = 0
    @Published private(set) var highCount: Int = 0
    @Published private(set) var mediumCount: Int = 0
    @Published private(set) var lowCount: Int = 0

    private let resolutionStore: WarningResolutionStore
    private var updateTask: Task<Void, Never>?
    /// Detached snapshot/generate — cancelled when Weekly Report opens.
    private var inFlightComputeTask: Task<[Warning], Error>?
    private var updateGeneration = 0

    init(resolutionStore: WarningResolutionStore? = nil) {
        self.resolutionStore = resolutionStore ?? .shared
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

    /// HIGH: operative booking clashes still active in range (must be removed — not ticked for report).
    func operativeBookingClashes(in range: ClosedRange<Date>) -> [Warning] {
        warningsInRange(range, types: [.operativeBookingClash], activeOnly: true)
    }

    /// MEDIUM: manager/admin overlaps still awaiting tick for weekly report.
    func unresolvedManagerClashes(in range: ClosedRange<Date>) -> [Warning] {
        warningsInRange(range, types: [.managerLocationClash], activeOnly: true)
    }

    /// MEDIUM: manager/admin overlaps ticked on Warnings — included on weekly report CSV.
    func approvedManagerClashes(in range: ClosedRange<Date>) -> [Warning] {
        warningsInRange(range, types: [.managerLocationClash], activeOnly: false)
            .filter { resolutionStore.isApproved($0.resolutionKey) }
    }

    /// HIGH: unbooked labour per weekday in range.
    func unbookedLabourWarnings(in range: ClosedRange<Date>) -> [Warning] {
        warningsInRange(range, types: [.unbookedLabour], activeOnly: true)
    }

    /// LOW: material orders not placed by 16:00.
    func materialsCutoffWarnings(in range: ClosedRange<Date>) -> [Warning] {
        warningsInRange(range, types: [.materialsCutoff], activeOnly: true)
    }

    private func warningsInRange(
        _ range: ClosedRange<Date>,
        types: Set<Warning.WarningType>,
        activeOnly: Bool
    ) -> [Warning] {
        allGeneratedWarnings.filter { w in
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
        scanUnbookedFromCoverageStart: Bool = false,
        materialOrderCutOffEnabled: Bool = true,
        materialCutOffOnSaturday: Bool = false,
        materialCutOffOnSunday: Bool = false,
        projectsWithTomorrowBookings: [Project] = [],
        materialItemsForTomorrow: [MaterialItem] = [],
        materialsDataLoaded: Bool = false,
        pruneDismissals: Bool = true
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
                scanUnbookedFromCoverageStart: scanUnbookedFromCoverageStart,
                materialOrderCutOffEnabled: materialOrderCutOffEnabled,
                materialCutOffOnSaturday: materialCutOffOnSaturday,
                materialCutOffOnSunday: materialCutOffOnSunday,
                projectsWithTomorrowBookings: projectsWithTomorrowBookings,
                materialItemsForTomorrow: materialItemsForTomorrow,
                materialsDataLoaded: materialsDataLoaded,
                pruneDismissals: pruneDismissals
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
        scanUnbookedFromCoverageStart: Bool = false,
        materialOrderCutOffEnabled: Bool = true,
        materialCutOffOnSaturday: Bool = false,
        materialCutOffOnSunday: Bool = false,
        projectsWithTomorrowBookings: [Project] = [],
        materialItemsForTomorrow: [MaterialItem] = [],
        materialsDataLoaded: Bool = false,
        pruneDismissals: Bool = true
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
            scanUnbookedFromCoverageStart: scanUnbookedFromCoverageStart,
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings,
            materialItemsForTomorrow: materialItemsForTomorrow,
            materialsDataLoaded: materialsDataLoaded,
            pruneDismissals: pruneDismissals
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
        scanUnbookedFromCoverageStart: Bool,
        materialOrderCutOffEnabled: Bool,
        materialCutOffOnSaturday: Bool,
        materialCutOffOnSunday: Bool,
        projectsWithTomorrowBookings: [Project],
        materialItemsForTomorrow: [MaterialItem],
        materialsDataLoaded: Bool,
        pruneDismissals: Bool
    ) async {
        updateGeneration += 1
        let generation = updateGeneration
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
                // Live Home passes nil coverage overrides. Cap full-period lookback (see liveScanDayCap).
        // Weekly Report passes explicit labourCoverageStart/End and must not be capped here.
        let coverageStart = cal.startOfDay(
            for: labourCoverageStart
                ?? warningDetection.coverageStart(
                    from: today,
                    invoicing: invoicingSettings,
                    calendar: cal,
                    liveScanDayCap: labourCoverageStart == nil ? 21 : nil
                )
        )
        let coverageEnd = cal.startOfDay(
            for: labourCoverageEnd
                ?? warningDetection.coverageEnd(from: today, invoicing: invoicingSettings, calendar: cal)
        )
        let effectiveScanUnbookedFromStart = scanUnbookedFromCoverageStart
            || (labourCoverageStart == nil && warningDetection.scansUnbookedFromCoverageStart)
        let input = WarningsComputationInput(
            operatives: operatives,
            bookings: bookings,
            projects: projects,
            users: users,
            managerSiteBookings: managerSiteBookings,
            holidayBookings: holidayBookings,
            payrollTimePolicy: payrollTimePolicy,
            warningDetection: warningDetection,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            scanUnbookedFromCoverageStart: effectiveScanUnbookedFromStart,
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings,
            materialItemsForTomorrow: materialItemsForTomorrow,
            materialsDataLoaded: materialsDataLoaded
        )
        // Detached compute (off main) with cancellation linkage — Weekly Report open must be able
        // to abort this work or Simulator jetsams under Home + report memory pressure.
        let computeTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let snapshot = WarningsComputation.makeSnapshot(from: input)
            try Task.checkCancellation()
            return WarningsComputation.generate(snapshot)
        }
        inFlightComputeTask?.cancel()
        inFlightComputeTask = computeTask
        let generated: [Warning]
        do {
            generated = try await withTaskCancellationHandler {
                try await computeTask.value
            } onCancel: {
                computeTask.cancel()
            }
        } catch is CancellationError {
            print("🔥🔥🔥 DEBUG: WarningsService update cancelled before publish")
            if inFlightComputeTask == computeTask { inFlightComputeTask = nil }
            return
        } catch {
            print("🔥🔥🔥 DEBUG: WarningsService update failed: \(error)")
            if inFlightComputeTask == computeTask { inFlightComputeTask = nil }
            return
        }
        if inFlightComputeTask == computeTask { inFlightComputeTask = nil }
        guard generation == updateGeneration else { return }
        if Task.isCancelled { return }
        if pruneDismissals {
            // Only drop dismissals before the live detection start — never wipe future keys
            // when a report uses a narrower/past window.
            resolutionStore.pruneDismissedUnbookedKeys(
                olderThan: coverageStart,
                calendar: cal
            )
        }
        allGeneratedWarnings = generated
        activeWarnings = generated.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
        refreshSeverityCounts()
    }

    /// Abort any in-flight detection so heavy sheets (Weekly Report) can open without jetsam.
    func cancelInFlightUpdate() {
        updateGeneration += 1
        updateTask?.cancel()
        updateTask = nil
        inFlightComputeTask?.cancel()
        inFlightComputeTask = nil
        print("🔥🔥🔥 DEBUG: WarningsService in-flight update cancelled")
    }

    /// Approve only applies to MEDIUM manager/admin clashes (weekly report tick).
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
    }

    private func severityRank(_ severity: Warning.WarningSeverity) -> Int {
        switch severity {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

}
