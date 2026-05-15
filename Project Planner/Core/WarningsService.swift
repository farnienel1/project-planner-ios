//
//  WarningsService.swift
//  Project Planner
//

import Foundation
import Combine

@MainActor
class WarningsService: ObservableObject {
    /// Shared instance for Warnings sheet / weekly report (avoid duplicating state on Home).
    static let shared = WarningsService()

    @Published private(set) var allGeneratedWarnings: [Warning] = []
    @Published private(set) var activeWarnings: [Warning] = []

    private let resolutionStore: WarningResolutionStore
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0

    init(resolutionStore: WarningResolutionStore = .shared) {
        self.resolutionStore = resolutionStore
    }

    /// Counts only core priority warnings (operative clashes, unbooked labour, manager clashes, materials).
    var warningCount: Int { corePriorityActiveWarnings.count }

    var highCount: Int { corePriorityActiveWarnings.filter { $0.severity == .high }.count }
    var mediumCount: Int { corePriorityActiveWarnings.filter { $0.severity == .medium }.count }
    var lowCount: Int { corePriorityActiveWarnings.filter { $0.severity == .low }.count }

    private var corePriorityActiveWarnings: [Warning] {
        activeWarnings.filter(\.isCorePriorityWarning)
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
        payrollTimePolicy: OrgPayrollTimePolicy = .default,
        labourCoverageStart: Date? = nil,
        labourCoverageEnd: Date? = nil,
        materialOrderCutOffEnabled: Bool = true,
        projectsWithTomorrowBookings: [Project] = []
    ) {
        updateTask?.cancel()
        updateTask = Task { @MainActor in
            await performUpdate(
                operatives: operatives,
                bookings: bookings,
                projects: projects,
                users: users,
                managerSiteBookings: managerSiteBookings,
                holidayBookings: holidayBookings,
                payrollTimePolicy: payrollTimePolicy,
                labourCoverageStart: labourCoverageStart,
                labourCoverageEnd: labourCoverageEnd,
                materialOrderCutOffEnabled: materialOrderCutOffEnabled,
                projectsWithTomorrowBookings: projectsWithTomorrowBookings
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
        payrollTimePolicy: OrgPayrollTimePolicy = .default,
        labourCoverageStart: Date? = nil,
        labourCoverageEnd: Date? = nil,
        materialOrderCutOffEnabled: Bool = true,
        projectsWithTomorrowBookings: [Project] = []
    ) async {
        updateTask?.cancel()
        await performUpdate(
            operatives: operatives,
            bookings: bookings,
            projects: projects,
            users: users,
            managerSiteBookings: managerSiteBookings,
            holidayBookings: holidayBookings,
            payrollTimePolicy: payrollTimePolicy,
            labourCoverageStart: labourCoverageStart,
            labourCoverageEnd: labourCoverageEnd,
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            projectsWithTomorrowBookings: projectsWithTomorrowBookings
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
        labourCoverageStart: Date?,
        labourCoverageEnd: Date?,
        materialOrderCutOffEnabled: Bool,
        projectsWithTomorrowBookings: [Project]
    ) async {
        updateGeneration += 1
        let generation = updateGeneration
        let generated = await Task.detached(priority: .utility) {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let coverageStart = cal.startOfDay(for: labourCoverageStart ?? cal.date(byAdding: .day, value: -14, to: today) ?? today)
            let coverageEnd = cal.startOfDay(for: labourCoverageEnd ?? cal.date(byAdding: .day, value: 28, to: today) ?? today)
            let input = WarningsComputationInput(
                operatives: operatives,
                bookings: bookings,
                projects: projects,
                users: users,
                managerSiteBookings: managerSiteBookings,
                holidayBookings: holidayBookings,
                payrollTimePolicy: payrollTimePolicy,
                coverageStart: coverageStart,
                coverageEnd: coverageEnd,
                materialOrderCutOffEnabled: materialOrderCutOffEnabled,
                projectsWithTomorrowBookings: projectsWithTomorrowBookings
            )
            return WarningsComputation.generate(input)
        }.value
        guard generation == updateGeneration else { return }
        allGeneratedWarnings = generated
        activeWarnings = generated.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
    }

    /// Approve only applies to MEDIUM manager/admin clashes (weekly report tick).
    func approveWarning(_ warning: Warning) {
        guard warning.requiresWeeklyReportApproval else { return }
        resolutionStore.approve(warning.resolutionKey)
        refreshActiveFromGenerated()
    }

    func dismissWarning(_ warning: Warning) {
        resolutionStore.dismiss(warning.resolutionKey)
        refreshActiveFromGenerated()
    }

    private func refreshActiveFromGenerated() {
        activeWarnings = allGeneratedWarnings.filter { resolutionStore.shouldShowActive($0.resolutionKey) }
    }

    private func severityRank(_ severity: Warning.WarningSeverity) -> Int {
        switch severity {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

}
