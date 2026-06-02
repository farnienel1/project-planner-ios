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
    @EnvironmentObject var notificationService: NotificationService

    @State private var filterChip: WarningsFilterChip = .all
    @State private var openDayDate: Date?
    @State private var openBookLabourDate: Date?
    @State private var openProjectId: UUID?
    @State private var warningPendingDismiss: Warning?
    @State private var showingWarningsSettings = false

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
                if userStore.hasAdminAccess() {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingWarningsSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .accessibilityLabel("Warning settings")
                    }
                }
            }
            .navigationDestination(isPresented: $showingWarningsSettings) {
                OrganisationWarningsSettingsView(
                    exitsToHomeOnBack: true,
                    onExitToHome: {
                        showingWarningsSettings = false
                        dismiss()
                    },
                    onSaved: {
                        showingWarningsSettings = false
                    }
                )
                .environmentObject(firebaseBackend)
                .environmentObject(operativeStore)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(userStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(holidayStore)
                .environmentObject(appSettings)
            }
            .appChromeNavigationBarSurface()
            .task {
                await refreshWarningsAsync()
            }
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
            .fullScreenCover(item: $openBookLabourDate) { day in
                BookLabourFlowView(bookDate: day)
                    .environmentObject(appSettings)
                    .environmentObject(bookingStore)
                    .environmentObject(projectStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(holidayStore)
                    .environmentObject(managerScheduleStore)
                    .environmentObject(firebaseBackend)
                    .environmentObject(notificationService)
            }
            .alert(
                "Remove this warning?",
                isPresented: Binding(
                    get: { warningPendingDismiss != nil },
                    set: { if !$0 { warningPendingDismiss = nil } }
                ),
                presenting: warningPendingDismiss
            ) { warning in
                Button("Cancel", role: .cancel) {
                    warningPendingDismiss = nil
                }
                Button("Remove warning", role: .destructive) {
                    confirmRemoveWarning(warning)
                }
            } message: { warning in
                Text("Are you sure you want to remove this warning? It will be hidden from the list and other admins will be notified. You may still need to resolve the issue manually.\n\n\(warning.removalNotificationDetail)")
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
            .unbooked: all.filter { $0.type == .unbookedLabour }.count,
            .materials: all.filter { $0.type == .materialsCutoff }.count
        ]
    }

    private var filteredWarnings: [Warning] {
        let sorted = warningsService.warningsSortedByDate()
        switch filterChip {
        case .all: return sorted
        case .clashes:
            return sorted.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }
        case .unbooked:
            return sorted.filter { $0.type == .unbookedLabour }
        case .materials:
            return sorted.filter { $0.type == .materialsCutoff }
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
                onOpenDay: { openDayDate = warning.occurrenceDate },
                onRemoveWarning: { requestRemoveWarning(warning) }
            )
        case .managerLocationClash:
            ManagerClashWarningCard(
                warning: warning,
                onRemoveA: { removeManagerBooking(warning, entry: warning.managerClash?.entryA) },
                onRemoveB: { removeManagerBooking(warning, entry: warning.managerClash?.entryB) },
                onApprove: { warningsService.approveWarning(warning) },
                onOpenDay: { openDayDate = warning.occurrenceDate },
                onRemoveWarning: { requestRemoveWarning(warning) }
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
            if userStore.hasAdminAccess(), let warningDay = warning.occurrenceDate {
                Button {
                    openBookLabourDate = warningDay
                } label: {
                    Text("Book labour")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
            }
            WarningRemoveButton { requestRemoveWarning(warning) }
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
            WarningRemoveButton { requestRemoveWarning(warning) }
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
            WarningRemoveButton { requestRemoveWarning(warning) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func requestRemoveWarning(_ warning: Warning) {
        warningPendingDismiss = warning
    }

    private func confirmRemoveWarning(_ warning: Warning) {
        warningPendingDismiss = nil
        let removedBy = userStore.currentUser?.fullName
            ?? userStore.currentUser?.email
            ?? "An admin"
        warningsService.dismissWarning(warning)
        Task {
            await notificationService.notifyWarningRemoved(warning: warning, removedBy: removedBy)
        }
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
        guard let entry else { return }
        if let mgrId = entry.managerBookingId,
           let booking = managerScheduleStore.managerSiteBookings.first(where: { $0.id == mgrId }) {
            Task {
                await managerScheduleStore.deleteBooking(booking)
                refreshWarnings()
            }
            return
        }
        if let opBooking = bookingStore.bookings.first(where: { $0.id == entry.bookingId }) {
            Task {
                await bookingStore.deleteBooking(opBooking)
                refreshWarnings()
            }
        }
    }

    private func refreshWarnings() {
        Task { await refreshWarningsAsync() }
    }

    private func refreshWarningsAsync() async {
        await WarningsRefreshHelper.refreshSharedWarnings(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings,
            force: true
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
        .environmentObject(NotificationService())
}
