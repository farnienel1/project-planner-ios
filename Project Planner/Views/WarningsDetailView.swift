//
//  WarningsDetailView.swift
//  Project Planner
//
//  Warnings UI matched to warnings_final.html / WarningsScreen.tsx
//

import SwiftUI

private enum WarningsUI {
    static let screenBg = Color(red: 0.949, green: 0.949, blue: 0.969) // #F2F2F7
    static let doneBlue = Color(red: 0.231, green: 0.373, blue: 0.639) // #3B5FA3
    static let textPrimary = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let textBody = Color(red: 0.216, green: 0.255, blue: 0.318)
    static let textMuted = Color(red: 0.612, green: 0.639, blue: 0.686)
    static let blue = Color(red: 0.145, green: 0.388, blue: 0.922)
    static let blueFrom = Color(red: 0.114, green: 0.306, blue: 0.847)
    static let red = Color(red: 0.863, green: 0.149, blue: 0.149)
    static let avatarPalette: [Color] = [
        Color(red: 0.173, green: 0.357, blue: 0.749),
        Color(red: 0.294, green: 0.478, blue: 0.361),
        Color(red: 0.478, green: 0.294, blue: 0.549),
        Color(red: 0.702, green: 0.337, blue: 0.078),
        Color(red: 0.145, green: 0.388, blue: 0.922),
        Color(red: 0.620, green: 0.165, blue: 0.165)
    ]

    static func avatarColor(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return avatarPalette[abs(hash) % avatarPalette.count]
    }

    static func parseUnbookedPerson(_ raw: String) -> (name: String, badge: String?) {
        if let range = raw.range(of: " (missing ") {
            let name = String(raw[..<range.lowerBound])
            var hours = String(raw[range.upperBound...])
            if hours.hasSuffix(")") { hours.removeLast() }
            hours = hours.replacingOccurrences(of: ".0h", with: "h")
            if !hours.hasSuffix("h") { hours += "h" }
            return (name, "−\(hours)")
        }
        return (raw, nil)
    }
}

struct WarningsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var warningsService: WarningsService
    let projectStore: ProjectStore
    let userStore: UserStore
    let operativeStore: OperativeStore
    let bookingStore: BookingStore
    let managerScheduleStore: ManagerScheduleStore
    let firebaseBackend: FirebaseBackend
    let appSettings: AppSettingsStore
    let holidayStore: HolidayStore
    let notificationService: NotificationService
    let subcontractorStore: SubcontractorStore
    let taskStore: ProjectTaskStore

    @State private var filterChip: WarningsFilterChip = .all
    @State private var openDayDate: IdentifiableDay?
    @State private var openBookLabourDate: IdentifiableDay?
    @State private var warningPendingDismiss: Warning?
    @State private var showingWarningsSettings = false
    @State private var isRefreshingWarnings = false
    @State private var refreshMessage: String?

    private var organisationSubtitle: String {
        firebaseBackend.currentOrganization?.name ?? "Organisation"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                warningsNavBar
                Group {
                    if warningsService.activeWarnings.isEmpty {
                        emptyState
                    } else {
                        warningsScroll
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let refreshMessage {
                    Text(refreshMessage)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .background(WarningsUI.screenBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                WarningsRefreshHelper.isWarningsSheetVisible = true
                print("🔥🔥🔥 DEBUG: WARNINGS_SHEET_APPEARED count=\(warningsService.activeWarnings.count) completed=\(warningsService.hasCompletedLiveDetection)")
            }
            .onDisappear {
                WarningsRefreshHelper.isWarningsSheetVisible = false
            }
            .sheet(isPresented: $showingWarningsSettings) {
                NavigationStack {
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
            }
            .sheet(item: $openDayDate) { day in
                NavigationStack {
                    DailyOverviewView(displayDate: day.date)
                        .environmentObject(bookingStore)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                        .environmentObject(holidayStore)
                        .environmentObject(managerScheduleStore)
                        .environmentObject(subcontractorStore)
                        .environmentObject(firebaseBackend)
                        .environmentObject(appSettings)
                        .environmentObject(taskStore)
                        .environmentObject(notificationService)
                }
            }
            .fullScreenCover(item: $openBookLabourDate) { day in
                BookLabourFlowView(bookDate: day.date)
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
            .sheet(item: $warningPendingDismiss) { warning in
                WarningDismissConfirmationSheet(
                    warning: warning,
                    onCancel: { warningPendingDismiss = nil },
                    onConfirm: { confirmRemoveWarning(warning) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
            }
        }
    }

    private var warningsNavBar: some View {
        HStack(spacing: 12) {
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WarningsUI.doneBlue)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(0.10), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.07), radius: 3, x: 0, y: 1)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text("Warnings")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(WarningsUI.textPrimary)
                Text(organisationSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(WarningsUI.textMuted)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    Task { await refreshWarningsTodayOnly() }
                } label: {
                    Group {
                        if isRefreshingWarnings {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(red: 0.333, green: 0.333, blue: 0.333))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Color.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.07), radius: 3, x: 0, y: 1)
                }
                .disabled(isRefreshingWarnings)
                .accessibilityLabel("Refresh warnings")

                if userStore.hasAdminAccess() {
                    Button {
                        showingWarningsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.333, green: 0.333, blue: 0.333))
                            .frame(width: 34, height: 34)
                            .background(Color.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.5))
                            .shadow(color: Color.black.opacity(0.07), radius: 3, x: 0, y: 1)
                    }
                    .accessibilityLabel("Warning settings")
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if warningsService.hasCompletedLiveDetection {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                Text("No active warnings")
                    .font(.title3.weight(.semibold))
                Text("High: operative booking clashes and unbooked labour. Medium: manager/admin overlaps (tick for weekly report). Low: material orders not placed by 16:00.")
                    .font(.subheadline)
                    .foregroundStyle(WarningsUI.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(WarningsUI.textMuted)
                Text("Check for warnings")
                    .font(.title3.weight(.semibold))
                Text("Tap Refresh to scan today and tomorrow. Results are saved so Home and Weekly Report stay fast.")
                    .font(.subheadline)
                    .foregroundStyle(WarningsUI.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Refresh now") {
                    Task { await refreshWarningsTodayOnly() }
                }
                .buttonStyle(.borderedProminent)
                .tint(WarningsUI.blue)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 32)
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
                onOpenDay: { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) },
                onRemoveWarning: { requestRemoveWarning(warning) }
            )
        case .managerLocationClash:
            ManagerClashWarningCard(
                warning: warning,
                onRemoveA: { removeManagerBooking(warning, entry: warning.managerClash?.entryA) },
                onRemoveB: { removeManagerBooking(warning, entry: warning.managerClash?.entryB) },
                onApprove: { warningsService.approveWarning(warning) },
                onOpenDay: { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) },
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
        let people = (warning.unbookedLabour?.names ?? []).map(WarningsUI.parseUnbookedPerson)
        let dateText: String = {
            guard let d = warning.occurrenceDate ?? warning.unbookedLabour?.date else { return "" }
            return d.formatted(.dateTime.day().month(.abbreviated).year())
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: .high)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.498, green: 0.114, blue: 0.114),
                        Color(red: 0.600, green: 0.106, blue: 0.106),
                        Color(red: 0.725, green: 0.110, blue: 0.110)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if people.isEmpty {
                        Text(warning.message)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WarningsUI.textBody)
                    } else {
                        (
                            Text("\(people.count) \(people.count == 1 ? "person is" : "people are") missing hours on ")
                            + Text(dateText.isEmpty ? "this day" : dateText).fontWeight(.bold)
                            + Text(" and are below the standard paid day.")
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WarningsUI.textBody)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 13)

                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    HStack(spacing: 10) {
                        Text(PlannerUIInitials.from(person.name))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(WarningsUI.avatarColor(for: person.name))
                            .clipShape(Circle())
                        Text(person.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WarningsUI.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let badge = person.badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(WarningsUI.red)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Color(red: 0.996, green: 0.949, blue: 0.949))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(red: 0.996, green: 0.886, blue: 0.886), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 4)

            VStack(spacing: 9) {
                if userStore.hasAdminAccess(), let warningDay = warning.occurrenceDate {
                    Button {
                        openBookLabourDate = IdentifiableDay(warningDay)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Book labour for this day")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(
                                colors: [WarningsUI.blueFrom, WarningsUI.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .shadow(color: WarningsUI.blue.opacity(0.28), radius: 12, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 0) {
                    Button {
                        openDayDate = warning.occurrenceDate.map(IdentifiableDay.init)
                    } label: {
                        Text("Open daily overview")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WarningsUI.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.black.opacity(0.10))
                        .frame(width: 0.5)
                        .padding(.vertical, 8)

                    Button {
                        requestRemoveWarning(warning)
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.420, green: 0.447, blue: 0.502))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 14)
            .background(Color(red: 0.980, green: 0.980, blue: 0.980))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    private func materialsCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: .low)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.216, green: 0.255, blue: 0.318),
                        Color(red: 0.290, green: 0.333, blue: 0.408)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(warning.message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WarningsUI.textBody)
                if let m = warning.materialsCutoff {
                    Text("\(m.jobNumber) · \(m.siteName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WarningsUI.textPrimary)
                }
                Text("Managers should confirm material lists with site teams.")
                    .font(.system(size: 12))
                    .foregroundStyle(WarningsUI.textMuted)
            }
            .padding(16)

            HStack(spacing: 0) {
                Button { requestRemoveWarning(warning) } label: {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.420, green: 0.447, blue: 0.502))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .background(Color(red: 0.980, green: 0.980, blue: 0.980))
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    private func legacyCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: warning.severity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.216, green: 0.255, blue: 0.318),
                        Color(red: 0.290, green: 0.333, blue: 0.408)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Text(warning.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WarningsUI.textBody)
                .padding(16)

            Button { requestRemoveWarning(warning) } label: {
                Text("Dismiss")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.420, green: 0.447, blue: 0.502))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .background(Color(red: 0.980, green: 0.980, blue: 0.980))
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
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
            // Never rescan while the sheet is open — hide this row and ask Home to refresh after dismiss.
            warningsService.dismissWarning(warning)
            NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
        }
    }

    private func removeManagerBooking(_ warning: Warning, entry: Warning.ClashTimelineEntry?) {
        guard let entry else { return }
        if let mgrId = entry.managerBookingId,
           let booking = managerScheduleStore.managerSiteBookings.first(where: { $0.id == mgrId }) {
            Task {
                await managerScheduleStore.deleteBooking(booking)
                warningsService.dismissWarning(warning)
                NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
            }
            return
        }
        if let opBooking = bookingStore.bookings.first(where: { $0.id == entry.bookingId }) {
            Task {
                await bookingStore.deleteBooking(opBooking)
                warningsService.dismissWarning(warning)
                NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
            }
        }
    }

    @MainActor
    private func refreshWarningsTodayOnly() async {
        guard !isRefreshingWarnings else { return }
        isRefreshingWarnings = true
        refreshMessage = nil
        defer { isRefreshingWarnings = false }
        print("🔥🔥🔥 DEBUG: WARNINGS_MANUAL_REFRESH_START")
        // Manual path may run even if sheet visible — temporarily clear the sheet gate.
        let did = await WarningsRefreshHelper.refreshSharedWarnings(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings,
            force: true,
            manualUserInitiated: true
        )
        // no sheet-gate dance needed with manualUserInitiated
        refreshMessage = did
            ? "Updated · \(warningsService.activeWarnings.count) active"
            : "Could not refresh yet (still loading). Try again in a few seconds."
        print("🔥🔥🔥 DEBUG: WARNINGS_MANUAL_REFRESH_DONE did=\(did) active=\(warningsService.activeWarnings.count)")
        NotificationCenter.default.post(name: .warningsDidRecompute, object: nil, userInfo: ["count": warningsService.warningCount])
    }
}


/// Polished confirmation for permanently dismissing a warning.
private struct WarningDismissConfirmationSheet: View {
    let warning: Warning
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let accent = Color(red: 0.722, green: 0.196, blue: 0.196)
    private let ink = Color(red: 0.110, green: 0.110, blue: 0.118)
    private let muted = Color(red: 0.420, green: 0.447, blue: 0.502)

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.black.opacity(0.12))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(.bottom, 16)

            Text("Dismiss this warning?")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("Are you sure you would like to dismiss this warning? Any warnings that are dismissed will not reappear again.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 10)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 10) {
                Text(warning.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ink)
                Text(warning.removalNotificationDetail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                        .padding(.top, 1)
                    Text("All admins will get a notification with who dismissed it and what was dismissed. It also appears in the notification centre on Home.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.969, green: 0.969, blue: 0.980))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text("Dismiss permanently")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.722, green: 0.196, blue: 0.196),
                                    Color(red: 0.620, green: 0.165, blue: 0.165)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text("Keep warning")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color(red: 0.949, green: 0.949, blue: 0.969))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Color.white.ignoresSafeArea())
    }
}

/// Sheet/item identity for a calendar day without making `Date` globally Identifiable.
private struct IdentifiableDay: Identifiable, Hashable {
    let date: Date
    var id: TimeInterval { Calendar.current.startOfDay(for: date).timeIntervalSince1970 }

    init(_ date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
    }
}

#Preview {
    WarningsDetailView(
        warningsService: WarningsService(),
        projectStore: ProjectStore(),
        userStore: UserStore(),
        operativeStore: OperativeStore(),
        bookingStore: BookingStore(),
        managerScheduleStore: ManagerScheduleStore(),
        firebaseBackend: FirebaseBackend(),
        appSettings: AppSettingsStore(),
        holidayStore: HolidayStore(),
        notificationService: NotificationService(),
        subcontractorStore: SubcontractorStore(),
        taskStore: ProjectTaskStore()
    )
}
