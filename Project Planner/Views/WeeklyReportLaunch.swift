import SwiftUI

/// Stable sheet token — identity fixed at tap time so Home re-renders do not rebuild the sheet.
struct WeeklyReportLaunchToken: Identifiable {
    let id: UUID
    let bookingStore: BookingStore
    let managerScheduleStore: ManagerScheduleStore
    let projectStore: ProjectStore
    let operativeStore: OperativeStore
    let holidayStore: HolidayStore
    let userStore: UserStore
    let firebaseBackend: FirebaseBackend
    let subcontractorStore: SubcontractorStore
    let appSettings: AppSettingsStore
    let notificationService: NotificationService
    let taskStore: ProjectTaskStore

    init(
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        holidayStore: HolidayStore,
        userStore: UserStore,
        firebaseBackend: FirebaseBackend,
        subcontractorStore: SubcontractorStore,
        appSettings: AppSettingsStore,
        notificationService: NotificationService,
        taskStore: ProjectTaskStore
    ) {
        self.id = UUID()
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.projectStore = projectStore
        self.operativeStore = operativeStore
        self.holidayStore = holidayStore
        self.userStore = userStore
        self.firebaseBackend = firebaseBackend
        self.subcontractorStore = subcontractorStore
        self.appSettings = appSettings
        self.notificationService = notificationService
        self.taskStore = taskStore
    }
}

/// Light settle gate, then the real WeeklyReportView (which defers its own branded chrome).
struct WeeklyReportOpenShell: View {
    let token: WeeklyReportLaunchToken
    @Environment(\.dismiss) private var dismiss
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                WeeklyReportView(
                    bookingStore: token.bookingStore,
                    managerScheduleStore: token.managerScheduleStore,
                    projectStore: token.projectStore,
                    operativeStore: token.operativeStore,
                    holidayStore: token.holidayStore,
                    userStore: token.userStore,
                    firebaseBackend: token.firebaseBackend,
                    subcontractorStore: token.subcontractorStore,
                    appSettings: token.appSettings,
                    notificationService: token.notificationService,
                    taskStore: token.taskStore
                )
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Opening weekly report…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(WarningsBuildStamp.id)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button("Close") { dismiss() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { dismiss() }
                        }
                    }
                }
            }
        }
        .task {
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SHELL \(WarningsBuildStamp.id)")
            WarningsRefreshHelper.isWeeklyReportVisible = true
            WarningsRefreshHelper.cancelInFlightRefresh()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 450_000_000)
            await Task.yield()
            isReady = true
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_READY \(WarningsBuildStamp.id)")
        }
        .onDisappear {
            WarningsRefreshHelper.isWeeklyReportVisible = false
            Task { @MainActor in
                _ = await WarningsRefreshHelper.refreshSharedWarnings(
                    operativeStore: token.operativeStore,
                    bookingStore: token.bookingStore,
                    projectStore: token.projectStore,
                    userStore: token.userStore,
                    managerScheduleStore: token.managerScheduleStore,
                    holidayStore: token.holidayStore,
                    firebaseBackend: token.firebaseBackend,
                    appSettings: token.appSettings,
                    force: true
                )
            }
        }
    }
}
