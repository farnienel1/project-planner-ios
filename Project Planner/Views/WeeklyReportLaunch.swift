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

/// Opens straight into Weekly Report after a short settle — no Continue gate.
/// Do NOT wrap WeeklyReportView in an extra NavigationStack (blank white sheet on Simulator).
struct WeeklyReportOpenShell: View {
    let token: WeeklyReportLaunchToken
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case settling
        case report
    }

    @State private var phase: Phase = .settling

    var body: some View {
        Group {
            switch phase {
            case .report:
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
            case .settling:
                NavigationStack {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Opening weekly report…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Close") { dismiss() }
                            .padding(.top, 8)
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
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SHELL")
            WarningsRefreshHelper.isWeeklyReportVisible = true
            WarningsRefreshHelper.cancelInFlightRefresh()
            await WarningsRefreshHelper.prepareForHeavySheet()
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SETTLED")
            phase = .report
        }
        .onDisappear {
            WarningsRefreshHelper.isWeeklyReportVisible = false
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SHELL_DISMISS")
        }
    }
}
