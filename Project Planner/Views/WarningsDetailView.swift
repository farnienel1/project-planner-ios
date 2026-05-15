//
//  WarningsDetailView.swift
//  Project Planner
//

import SwiftUI

struct WarningsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var warningsService: WarningsService
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var holidayStore: HolidayStore

    @State private var filterChip: WarningsFilterChip = .all
    @State private var openDayDate: Date?
    @State private var openProjectId: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if warningsService.activeWarnings.isEmpty {
                    emptyState
                } else {
                    warningsScroll
                }
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("Warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .appChromeNavigationBarSurface()
            .sheet(item: $openDayDate) { day in
                NavigationStack {
                    DailyOverviewView(displayDate: day)
                        .environmentObject(bookingStore)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                        .environmentObject(managerScheduleStore)
                        .environmentObject(firebaseBackend)
                        .environmentObject(appSettings)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(ProjectWorksRevampColors.activeGreen)
            Text("No active warnings")
                .font(.title3.weight(.semibold))
            Text("High: operative booking clashes and unbooked labour. Medium: manager/admin overlaps (tick for weekly report). Low: material orders not placed by 16:00.")
                .font(.subheadline)
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WarningsHeroCard(
                    activeCount: warningsService.warningCount,
                    highCount: warningsService.highCount,
                    mediumCount: warningsService.mediumCount,
                    lowCount: warningsService.lowCount
                )
                WarningsFilterChipsRow(selected: $filterChip, counts: filterCounts)
                ForEach(filteredWarnings) { warning in
                    warningCard(warning)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private var filterCounts: [WarningsFilterChip: Int] {
        let all = warningsService.activeWarnings
        return [
            .all: all.count,
            .clashes: all.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }.count,
            .materials: all.filter { $0.type == .materialsCutoff }.count,
            .expiring: all.filter { $0.type == .qualificationExpiry || $0.type == .operativeNotVerified }.count
        ]
    }

    private var filteredWarnings: [Warning] {
        let sorted = warningsService.warningsSortedByDate()
        switch filterChip {
        case .all: return sorted
        case .clashes:
            return sorted.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }
        case .materials:
            return sorted.filter { $0.type == .materialsCutoff }
        case .expiring:
            return sorted.filter { $0.type == .qualificationExpiry || $0.type == .operativeNotVerified }
        }
    }

    @ViewBuilder
    private func warningCard(_ warning: Warning) -> some View {
        switch warning.type {
        case .operativeBookingClash:
            OperativeClashWarningCard(
                warning: warning,
                onRemoveA: { removeOperativeBooking(warning, bookingId: warning.operativeClash?.bookingAId) },
                onRemoveB: { removeOperativeBooking(warning, bookingId: warning.operativeClash?.bookingBId) },
                onOpenDay: { openDayDate = warning.occurrenceDate }
            )
        case .managerLocationClash:
            ManagerClashWarningCard(
                warning: warning,
                onRemoveA: { removeManagerBooking(warning, entry: warning.managerClash?.entryA) },
                onRemoveB: { removeManagerBooking(warning, entry: warning.managerClash?.entryB) },
                onApprove: { warningsService.approveWarning(warning) },
                onOpenDay: { openDayDate = warning.occurrenceDate }
            )
        case .unbookedLabour:
            unbookedCard(warning)
        case .materialsCutoff:
            materialsCard(warning)
        case .qualificationExpiry, .operativeNotVerified:
            legacyCard(warning)
        }
    }

    private func unbookedCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 14, weight: .medium))
                WarningPriorityBadge(severity: .high)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            if let d = warning.unbookedLabour {
                ForEach(d.names, id: \.self) { name in
                    Text("• \(name)")
                        .font(.system(size: 12))
                }
            }
            Button { openDayDate = warning.occurrenceDate } label: {
                Text("Open day on Daily Overview")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func materialsCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 14, weight: .medium))
                WarningPriorityBadge(severity: .low)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            if let m = warning.materialsCutoff {
                Text("\(m.jobNumber) · \(m.siteName)")
                    .font(.system(size: 12, weight: .medium))
            }
            Text("Managers should confirm material lists with site teams.")
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func legacyCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 14, weight: .medium))
                WarningPriorityBadge(severity: warning.severity)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func removeOperativeBooking(_ warning: Warning, bookingId: UUID?) {
        guard let id = bookingId,
              let booking = bookingStore.bookings.first(where: { $0.id == id }) else { return }
        Task {
            await bookingStore.deleteBooking(booking)
            refreshWarnings()
        }
    }

    private func removeManagerBooking(_ warning: Warning, entry: Warning.ClashTimelineEntry?) {
        guard let entry,
              let mgrId = entry.managerBookingId,
              let booking = managerScheduleStore.managerSiteBookings.first(where: { $0.id == mgrId }) else { return }
        Task {
            await managerScheduleStore.deleteBooking(booking)
            refreshWarnings()
        }
    }

    private func refreshWarnings() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
        let tomorrowIds = Set(
            bookingStore.bookings
                .filter {
                    cal.isDate($0.date, inSameDayAs: tomorrow) &&
                        ($0.status == .confirmed || $0.status == .tentative)
                }
                .map(\.projectId)
        )
        let allProjects = projectStore.projects
        let projectsTomorrow = allProjects.filter { tomorrowIds.contains($0.id) }
        warningsService.updateWarnings(
            operatives: operativeStore.allOperatives,
            bookings: bookingStore.bookings,
            projects: allProjects,
            managers: operativeStore.allManagers,
            users: userStore.organizationUsers,
            managerSiteBookings: managerScheduleStore.managerSiteBookings,
            holidayBookings: holidayStore.bookings,
            payrollTimePolicy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
            labourCoverageStart: cal.date(byAdding: .day, value: -14, to: today),
            labourCoverageEnd: cal.date(byAdding: .day, value: 28, to: today),
            materialOrderCutOffEnabled: appSettings.settings.notifications.materialOrderCutOff,
            projectsWithTomorrowBookings: projectsTomorrow
        )
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}

#Preview {
    WarningsDetailView(warningsService: WarningsService())
        .environmentObject(ProjectStore())
        .environmentObject(UserStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(ManagerScheduleStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(AppSettingsStore())
}
