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

/// Store-free gate → settle → report. Do NOT nest NavigationStack around WeeklyReportView
/// (blank white sheet on Simulator). WeeklyReportView is only constructed after memory settles.
struct WeeklyReportOpenShell: View {
    let token: WeeklyReportLaunchToken
    @Environment(\.dismiss) private var dismiss
    private enum Phase {
        case gate
        case settling
        case report
    }

    @State private var phase: Phase = .gate

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
                        Text(WarningsBuildStamp.id)
                            .font(.caption2.weight(.medium))
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
            case .gate:
                NavigationStack {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40))
                            .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                        Text("Weekly Report")
                            .font(.title3.weight(.semibold))
                        Text("Warnings on Home are live ops (from today forward). This report is a separate period summary — it only recalculates when you tap Generate.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        Text(WarningsBuildStamp.id)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button {
                            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_CONTINUE \(WarningsBuildStamp.id)")
                            phase = .settling
                            Task { @MainActor in
                                await WarningsRefreshHelper.prepareForHeavySheet()
                                print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SETTLED \(WarningsBuildStamp.id)")
                                phase = .report
                            }
                        } label: {
                            Text("Continue")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 28)
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
        .onAppear {
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SHELL \(WarningsBuildStamp.id)")
            WarningsRefreshHelper.isWeeklyReportVisible = true
            WarningsRefreshHelper.cancelInFlightRefresh()
        }
        .onDisappear {
            WarningsRefreshHelper.isWeeklyReportVisible = false
            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_SHELL_DISMISS \(WarningsBuildStamp.id)")
        }
    }
}
