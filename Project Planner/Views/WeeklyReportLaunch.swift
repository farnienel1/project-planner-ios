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

/// Store-free gate. Important: do NOT nest NavigationStack around WeeklyReportView —
/// that produces a blank white sheet on Simulator.
struct WeeklyReportOpenShell: View {
    let token: WeeklyReportLaunchToken
    @Environment(\.dismiss) private var dismiss
    @State private var showReport = false
    @State private var isOpeningReport = false

    var body: some View {
        Group {
            if showReport {
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
                            guard !isOpeningReport else { return }
                            isOpeningReport = true
                            print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_CONTINUE \(WarningsBuildStamp.id)")
                            Task { @MainActor in
                                // Drop any in-flight Home warnings scan so Continue does not jetsam.
                                WarningsRefreshHelper.cancelInFlightRefresh()
                                await Task.yield()
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                await Task.yield()
                                showReport = true
                            }
                        } label: {
                            if isOpeningReport {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Text("Continue")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isOpeningReport)
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
        }
    }
}
