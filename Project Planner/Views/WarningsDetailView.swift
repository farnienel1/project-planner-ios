//
//  WarningsDetailView.swift
//  Project Planner
//
//  Warnings UI matched to warnings_final.html / WarningsScreen.tsx
//

import SwiftUI

private enum WarningsUI {
    static let screenBg = PPColor.page
    static let textPrimary = Color.primary
    static let textBody = Color.primary
    static let textMuted = Color.secondary
    static let blue = PPColor.brand
    static let red = PPColor.danger
    /// Warning card header colours: red for high warnings, graphite for low ones.
    static var highHeader: LinearGradient { PPFamily.alert.gradient }
    static var lowHeader: LinearGradient { PPFamily.system.gradient }
    static var footerFill: Color { PPColor.well }
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
        let index = Int(UInt(bitPattern: hash) % UInt(avatarPalette.count))
        return avatarPalette[index]
    }

    nonisolated static func parseUnbookedPerson(_ raw: String) -> (name: String, badge: String?) {
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
    /// Loaded before the first list render. Nil only when the script did not answer.
    @State private var sortDirection: String?
    @State private var sortDirectionUserId: String
    @State private var openDayDate: IdentifiableDay?
    @State private var presentedFullScreen: WarningsFullScreenCover?
    @State private var warningPendingDismiss: Warning?
    @State private var isRefreshingWarnings = false
    @State private var refreshMessage: String?
    @State private var operativeUserToEdit: AppUser?

    private var organisationSubtitle: String {
        firebaseBackend.currentOrganization?.name ?? "Organisation"
    }

    private var canBookLabourFromWarning: Bool {
        userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true
    }

    init(
        warningsService: WarningsService,
        projectStore: ProjectStore,
        userStore: UserStore,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        firebaseBackend: FirebaseBackend,
        appSettings: AppSettingsStore,
        holidayStore: HolidayStore,
        notificationService: NotificationService,
        subcontractorStore: SubcontractorStore,
        taskStore: ProjectTaskStore
    ) {
        self.warningsService = warningsService
        self.projectStore = projectStore
        self.userStore = userStore
        self.operativeStore = operativeStore
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.firebaseBackend = firebaseBackend
        self.appSettings = appSettings
        self.holidayStore = holidayStore
        self.notificationService = notificationService
        self.subcontractorStore = subcontractorStore
        self.taskStore = taskStore
        let userId = Self.signedInUserId(userStore: userStore)
        _sortDirection = State(initialValue: WarningsSortPreference.direction(userId: userId))
        _sortDirectionUserId = State(initialValue: userId)
    }

    private var signedInUserId: String {
        Self.signedInUserId(userStore: userStore)
    }

    /// Auth uid for this device session. The profile id is the same account when auth is not ready yet.
    private static func signedInUserId(userStore: UserStore) -> String {
        let authId = LocalLayoutPreferences.signedInUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !authId.isEmpty { return authId }
        return userStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// This user's saved direction. A different signed-in user does not reuse the previous choice.
    private var activeSortDirection: String? {
        let userId = signedInUserId
        if userId == sortDirectionUserId {
            return sortDirection
        }
        return WarningsSortPreference.direction(userId: userId)
    }

    /// A failed booking read: the list is not an all-clear, and no warning was worked out from partial data.
    private func incompleteDataBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PPColor.warningAmber)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(PPColor.onNavyFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityIdentifier("warnings.incompleteData")
    }

    var body: some View {
        VStack(spacing: 0) {
                VStack(spacing: 0) {
                    warningsNavBar
                    if let incomplete = warningsService.incompleteDataMessage {
                        incompleteDataBanner(incomplete)
                            .padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(PPColor.navy.ignoresSafeArea(edges: .top))
                .environment(\.colorScheme, .dark)
                Group {
                    if warningsService.activeWarnings.isEmpty {
                        if warningsService.incompleteDataMessage == nil {
                            emptyState
                        } else {
                            Spacer(minLength: 0)
                        }
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
            // One fullScreenCover only — a second cover on the same view swallowed
            // "Book labour for this day" and looked like a dead button.
            .fullScreenCover(item: $presentedFullScreen) { cover in
                switch cover {
                case .settings:
                    NavigationStack {
                        OrganisationWarningsSettingsView(
                            exitsToHomeOnBack: true,
                            onExitToHome: {
                                presentedFullScreen = nil
                            },
                            onSaved: {
                                presentedFullScreen = nil
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
                case .bookLabour(let date, let focusedUserIds):
                    BookLabourFlowView(bookDate: date, focusedUserIds: focusedUserIds)
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
            .sheet(item: $operativeUserToEdit) { user in
                NavigationStack {
                    EditUserView(user: user)
                }
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
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

    private var warningsNavBar: some View {
        HStack(spacing: 12) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("warnings.done")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 7)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text("Warnings")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(organisationSubtitle)
                    .font(.caption)
                    .foregroundStyle(PPColor.onNavySecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(action: startManualRefresh) {
                    Group {
                        if isRefreshingWarnings {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                .accessibilityIdentifier("warnings.refresh")
                .disabled(isRefreshingWarnings)
                .accessibilityLabel("Refresh warnings")

                if userStore.hasAdminAccess() {
                    Button {
                        presentedFullScreen = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                    .accessibilityIdentifier("warnings.settings")
                    .accessibilityLabel("Warning settings")
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: PPMetrics.headerBottomPadding)
                    .ppNavyHeader()
                VStack(spacing: 16) {
                    if isRefreshingWarnings {
                        ProgressView()
                            .controlSize(.large)
                            .padding(.top, 32)
                        Text("Scanning for warnings…")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("Keep this screen open until results appear.")
                            .font(.subheadline)
                            .foregroundStyle(WarningsUI.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else if warningsService.hasCompletedLiveDetection {
                        PPIconTile(symbol: "checkmark", family: .sites, size: 64, lifted: true)
                        Text("No active warnings")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("High: operative booking clashes and unbooked labour. Medium: manager/admin overlaps (tick for weekly report). Low: materials and qualifications.")
                            .font(.subheadline)
                            .foregroundStyle(WarningsUI.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else {
                        Button(action: startManualRefresh) {
                            PPIconTile(symbol: "arrow.clockwise", family: .system, size: 64, lifted: true)
                        }
                        .accessibilityIdentifier("warnings.arrowClockwiseCircle")
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                        Text("Check for warnings")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("Tap Refresh now, or the refresh icon at the top right. Results are saved so Home and Weekly Report stay fast.")
                            .font(.subheadline)
                            .foregroundStyle(WarningsUI.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        if let refreshMessage {
                            Text(refreshMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(WarningsUI.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        // Device/TestFlight: `.borderedProminent` in this sheet does not receive taps
                        // (the top-right plain refresh icon does). Use the same plain control.
                        Button(action: startManualRefresh) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.body.weight(.semibold))
                                Text("Refresh now")
                                    .font(.body.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(WarningsUI.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("warnings.refresh2")
                        .buttonStyle(.plain)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                        .disabled(isRefreshingWarnings)
                        .accessibilityLabel("Refresh now")
                        .highPriorityGesture(TapGesture().onEnded {
                            startManualRefresh()
                        })
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .ppContentSheet()
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WarningsHeroCard(
                    activeCount: warningsService.warningCount,
                    highCount: warningsService.highCount,
                    mediumCount: warningsService.mediumCount,
                    lowCount: warningsService.lowCount
                )
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.top, 8)
                .padding(.bottom, PPMetrics.headerBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ppNavyHeader()

                LazyVStack(alignment: .leading, spacing: 14) {
                    WarningsFilterChipsRow(selected: $filterChip, counts: filterCounts)
                    warningsSortControl
                    ForEach(filteredWarnings) { warning in
                        warningCard(warning)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 32)
                .ppContentSheet()
            }
        }
    }

    private var filterCounts: [WarningsFilterChip: Int] {
        var clashes = 0
        var unbooked = 0
        var annualLeave = 0
        var materials = 0
        var qualifications = 0
        for warning in warningsService.activeWarnings {
            switch warning.type {
            case .operativeBookingClash, .managerLocationClash: clashes += 1
            case .unbookedLabour: unbooked += 1
            case .annualLeave: annualLeave += 1
            case .materialsCutoff: materials += 1
            case .qualificationExpiry, .operativeNotVerified: qualifications += 1
            }
        }
        return [
            .all: warningsService.activeWarnings.count,
            .clashes: clashes,
            .unbooked: unbooked,
            .annualLeave: annualLeave,
            .materials: materials,
            .qualifications: qualifications
        ]
    }

    private var warningsSortControl: some View {
        HStack(spacing: 6) {
            Text("Sort")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WarningsUI.textMuted)
            sortDirectionButton(title: "Oldest", direction: "oldest")
            sortDirectionButton(title: "Newest", direction: "newest")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort warnings by date")
    }

    private func sortDirectionButton(title: String, direction: String) -> some View {
        let isOn = activeSortDirection == direction
        return Button {
            chooseSortDirection(direction)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(isOn ? PPColor.navy : PPColor.card))
                .overlay(
                    Capsule()
                        .strokeBorder(Color(.separator), lineWidth: isOn ? 0 : 0.5)
                )
        }
        .accessibilityIdentifier("warnings.sort.\(direction)")
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func chooseSortDirection(_ raw: String) {
        let userId = signedInUserId
        guard let saved = WarningsSortPreference.save(userId: userId, direction: raw) else { return }
        sortDirectionUserId = userId
        sortDirection = saved
    }

    private var filteredWarnings: [Warning] {
        var seen = Set<String>()
        let unique = warningsService.activeWarnings.filter { seen.insert($0.resolutionKey).inserted }
        let scoped: [Warning]
        switch filterChip {
        case .all: scoped = unique
        case .clashes:
            scoped = unique.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }
        case .unbooked:
            scoped = unique.filter { $0.type == .unbookedLabour }
        case .annualLeave:
            scoped = unique.filter { $0.type == .annualLeave }
        case .materials:
            scoped = unique.filter { $0.type == .materialsCutoff }
        case .qualifications:
            scoped = unique.filter { $0.type == .qualificationExpiry || $0.type == .operativeNotVerified }
        }
        return warningsOrderedByCoverageDay(groupUnbookedLabourByDay(scoped))
    }

    /// Coverage day for the shared sort. Blank rows (unverified operatives) stay undated.
    private func coverageDayKey(for warning: Warning) -> String {
        if let expiry = warning.qualificationExpiry?.expiryDayKey.trimmingCharacters(in: .whitespacesAndNewlines),
           !expiry.isEmpty {
            return expiry
        }
        guard let date = warning.occurrenceDate ?? warning.unbookedLabour?.date else { return "" }
        return CanonicalBusinessEngine.dayKey(for: date)
    }

    /// Reorders the cards already on screen. A nil script result leaves that order unchanged.
    private func warningsOrderedByCoverageDay(_ warnings: [Warning]) -> [Warning] {
        guard let direction = activeSortDirection else { return warnings }
        let rows = warnings.map { warning in
            CanonicalWarningDateRow(id: warning.resolutionKey, dayKey: coverageDayKey(for: warning))
        }
        guard let sorted = CanonicalBusinessEngine.sortWarningsByDate(rows, direction: direction) else {
            return warnings
        }
        var indexById: [String: Int] = [:]
        for (index, warning) in warnings.enumerated() where indexById[warning.resolutionKey] == nil {
            indexById[warning.resolutionKey] = index
        }
        var ordered: [Warning] = []
        var seen = Set<String>()
        for row in sorted {
            guard seen.insert(row.id).inserted, let index = indexById[row.id] else { continue }
            ordered.append(warnings[index])
        }
        if ordered.count < warnings.count {
            for warning in warnings where seen.insert(warning.resolutionKey).inserted {
                ordered.append(warning)
            }
        }
        return ordered
    }

    /// One card per day, with every unbooked person on that day in the list.
    /// The hero and the Unbooked chip still count people, not cards.
    private func groupUnbookedLabourByDay(_ warnings: [Warning]) -> [Warning] {
        var grouped: [Warning] = []
        var indexByDay: [String: Int] = [:]
        for warning in warnings {
            guard warning.type == .unbookedLabour,
                  let day = warning.occurrenceDate ?? warning.unbookedLabour?.date else {
                grouped.append(warning)
                continue
            }
            let key = londonDayKey(day)
            if let index = indexByDay[key] {
                grouped[index] = mergeUnbooked(grouped[index], warning)
            } else {
                indexByDay[key] = grouped.count
                grouped.append(warning)
            }
        }
        return grouped
    }

    private func mergeUnbooked(_ existing: Warning, _ incoming: Warning) -> Warning {
        var merged = existing
        var names = existing.unbookedLabour?.names ?? []
        var keys = existing.unbookedLabour?.personKeys ?? []
        let incomingNames = incoming.unbookedLabour?.names ?? []
        let incomingKeys = incoming.unbookedLabour?.personKeys ?? []
        for (offset, name) in incomingNames.enumerated() {
            let personKey = offset < incomingKeys.count ? incomingKeys[offset] : ""
            if !personKey.isEmpty, keys.contains(personKey) { continue }
            names.append(name)
            keys.append(personKey)
        }
        while keys.count < names.count { keys.append("") }
        let pairs = zip(names, keys).sorted {
            unbookedPersonSortName($0.0).localizedCaseInsensitiveCompare(unbookedPersonSortName($1.0)) == .orderedAscending
        }
        let date = existing.unbookedLabour?.date ?? incoming.unbookedLabour?.date ?? existing.occurrenceDate ?? Date()
        merged.unbookedLabour = Warning.UnbookedLabourWarningDetails(
            date: date,
            names: pairs.map(\.0),
            personKeys: pairs.map(\.1).filter { !$0.isEmpty }
        )
        return merged
    }

    private func unbookedPersonSortName(_ line: String) -> String {
        guard let range = line.range(of: " (missing") else { return line }
        return String(line[..<range.lowerBound])
    }

    private func londonDayKey(_ date: Date) -> String {
        let parts = CanonicalBusinessEngine.businessCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @ViewBuilder
    private func warningCard(_ warning: Warning) -> some View {
        switch warning.type {
        case .operativeBookingClash:
            OperativeClashWarningCard(
                warning: warning,
                onRemove: { removeClashEntry(warning, entry: $0) },
                onApprove: { warningsService.approveWarning(warning) },
                onOpenDay: { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) },
                onRemoveWarning: { requestRemoveWarning(warning) }
            )
        case .managerLocationClash:
            ManagerClashWarningCard(
                warning: warning,
                onRemove: { removeClashEntry(warning, entry: $0) },
                onApprove: { warningsService.approveWarning(warning) },
                onOpenDay: { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) },
                onRemoveWarning: { requestRemoveWarning(warning) }
            )
        case .unbookedLabour:
            unbookedCard(warning)
        case .annualLeave:
            annualLeaveCard(warning)
        case .materialsCutoff:
            materialsCard(warning)
        case .qualificationExpiry:
            qualificationCard(warning)
        case .operativeNotVerified:
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
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: .high)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WarningsUI.highHeader)

            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if people.isEmpty {
                        Text(warning.message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WarningsUI.textBody)
                    } else {
                        (
                            Text("\(people.count) \(people.count == 1 ? "person is" : "people are") not booked on ")
                            + Text(dateText.isEmpty ? "this day" : dateText).fontWeight(.bold)
                            + Text(".")
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WarningsUI.textBody)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 13)

                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    HStack(spacing: 10) {
                        Text(PlannerUIInitials.from(person.name))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: PPMetrics.menuIcon + 3, height: PPMetrics.menuIcon + 3)
                            .background(WarningsUI.avatarColor(for: person.name))
                            .clipShape(Circle())
                        Text(person.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WarningsUI.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let badge = person.badge {
                            Text(badge)
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(WarningsUI.red)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(WarningsUI.red.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(Color(.separator)).frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 4)

            VStack(spacing: 9) {
                if canBookLabourFromWarning, let warningDay = warning.occurrenceDate ?? warning.unbookedLabour?.date {
                    Button {
                        presentedFullScreen = .bookLabour(
                            date: warningDay,
                            focusedUserIds: warning.unbookedLabour?.personKeys ?? []
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.body.weight(.semibold))
                            Text("Book labour for this day")
                                .font(.body.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(WarningsUI.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: WarningsUI.blue.opacity(0.25), radius: 10, x: 0, y: 4)
                    }
                    .accessibilityIdentifier("warnings.calendarBadgePlus")
                    .buttonStyle(.plain)
                }

                HStack(spacing: 0) {
                    Button {
                        openDayDate = warning.occurrenceDate.map(IdentifiableDay.init)
                    } label: {
                        Text("Open daily overview")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WarningsUI.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .accessibilityIdentifier("warnings.openDailyOverview")
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 0.5)
                        .padding(.vertical, 8)

                    Button {
                        requestRemoveWarning(warning)
                    } label: {
                        Text("Dismiss")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .accessibilityIdentifier("warnings.dismiss")
                    .buttonStyle(.plain)
                }
                .background(PPColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 14)
            .background(WarningsUI.footerFill)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func annualLeaveCard(_ warning: Warning) -> some View {
        let detail = warning.annualLeave
        let isClash = detail?.kind == "leave_clash" || warning.severity == .high
        let headerColors: [Color] = isClash
            ? [PPFamily.alert.top, PPFamily.alert.bottom]
            : [PPFamily.trade.top, PPFamily.trade.bottom]
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: warning.severity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: headerColors, startPoint: .top, endPoint: .bottom)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(warning.message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WarningsUI.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, detail.missingHours > 0, !detail.missingRanges.isEmpty {
                    Text("Not booked: \(detail.missingRanges.joined(separator: ", ")) (\(formatMissingHours(detail.missingHours)))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WarningsUI.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Button { requestRemoveWarning(warning) } label: {
                Text("Dismiss")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .background(WarningsUI.footerFill)
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func formatMissingHours(_ hours: Double) -> String {
        let rounded = (hours * 4).rounded() / 4
        let text = abs(rounded - rounded.rounded()) < 0.001
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
        return "\(text) \(rounded == 1 ? "hour" : "hours")"
    }

    private func materialsCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: .low)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(WarningsUI.lowHeader)

            VStack(alignment: .leading, spacing: 10) {
                Text(warning.message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WarningsUI.textBody)
                if let m = warning.materialsCutoff {
                    Text("\(m.jobNumber) · \(m.siteName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WarningsUI.textPrimary)
                }
                Text("Managers should confirm material lists with site teams.")
                    .font(.footnote)
                    .foregroundStyle(WarningsUI.textMuted)
            }
            .padding(16)

            HStack(spacing: 0) {
                Button { requestRemoveWarning(warning) } label: {
                    Text("Dismiss")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .accessibilityIdentifier("warnings.dismiss2")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .background(WarningsUI.footerFill)
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func qualificationCard(_ warning: Warning) -> some View {
        let canDismiss = warning.qualificationExpiry?.canDismiss == true
        let openUser = openOperativeTarget(for: warning)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: .low)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(WarningsUI.lowHeader)

            Text(warning.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WarningsUI.textBody)
                .padding(16)

            if openUser != nil || canDismiss {
                HStack(spacing: 0) {
                    if let openUser {
                        Button {
                            operativeUserToEdit = openUser
                        } label: {
                            Text("Open operative")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(WarningsUI.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .accessibilityIdentifier("warnings.openOperative")
                        .buttonStyle(.plain)
                    }
                    if canDismiss {
                        Button { dismissExpiredQualification(warning) } label: {
                            Text("Dismiss")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .accessibilityIdentifier("warnings.dismissQualification")
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .background(WarningsUI.footerFill)
            }
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func openOperativeTarget(for warning: Warning) -> AppUser? {
        guard let actor = userStore.displayUser ?? userStore.currentUser,
              let detail = warning.qualificationExpiry else { return nil }
        guard let target = loginUser(forOperativeId: detail.operativeId) else { return nil }
        guard WarningOperativeAccess.destination(actor: actor, target: target) != nil else { return nil }
        return target
    }

    private func loginUser(forOperativeId operativeId: String) -> AppUser? {
        let needle = operativeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let direct = userStore.organizationUsers.first(where: { $0.id.lowercased() == needle && $0.isStoredUserDocument }) {
            return direct
        }
        guard let operative = operativeStore.allOperatives.first(where: { $0.id.uuidString.lowercased() == needle }) else {
            return nil
        }
        let email = operative.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return nil }
        return userStore.organizationUsers.first {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email && $0.isStoredUserDocument
        }
    }

    private func dismissExpiredQualification(_ warning: Warning) {
        guard let detail = warning.qualificationExpiry, detail.canDismiss else { return }
        Task { @MainActor in
            do {
                try await firebaseBackend.dismissExpiredQualification(
                    operativeId: detail.operativeId,
                    qualificationId: detail.qualificationId,
                    expiryDayKey: detail.expiryDayKey,
                    dismissKey: detail.dismissKey
                )
                await refreshWarningsTodayOnly()
            } catch {
                refreshMessage = error.localizedDescription
            }
        }
    }

    private func legacyCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(warning.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: .low)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(WarningsUI.lowHeader)

            Text(warning.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WarningsUI.textBody)
                .padding(16)

            Button { requestRemoveWarning(warning) } label: {
                Text("Dismiss")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("warnings.dismiss3")
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .background(WarningsUI.footerFill)
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func requestRemoveWarning(_ warning: Warning) {
        warningPendingDismiss = warning
    }

    private func confirmRemoveWarning(_ warning: Warning) {
        warningPendingDismiss = nil
        let removedBy = userStore.currentUser?.fullName
            ?? userStore.currentUser?.email
            ?? "An admin"
        for item in warningsToDismiss(warning) {
            warningsService.dismissWarning(item)
        }
        Task {
            await notificationService.notifyWarningRemoved(warning: warning, removedBy: removedBy)
        }
    }

    /// A grouped unbooked card lists every person on that day, so dismiss clears each of those rows.
    private func warningsToDismiss(_ warning: Warning) -> [Warning] {
        guard warning.type == .unbookedLabour,
              let day = warning.occurrenceDate ?? warning.unbookedLabour?.date else {
            return [warning]
        }
        let key = londonDayKey(day)
        let matches = warningsService.activeWarnings.filter { other in
            guard other.type == .unbookedLabour,
                  let otherDay = other.occurrenceDate ?? other.unbookedLabour?.date else { return false }
            return londonDayKey(otherDay) == key
        }
        return matches.isEmpty ? [warning] : matches
    }

    private func removeClashEntry(_ warning: Warning, entry: Warning.ClashTimelineEntry) {
        if entry.managerBookingId != nil {
            removeManagerBooking(warning, entry: entry)
        } else {
            removeOperativeBooking(warning, bookingId: entry.bookingId)
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

    private func startManualRefresh() {
        Task { @MainActor in
            await refreshWarningsTodayOnly()
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
        if did {
            let detection = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
            let invoicing = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
            let bounds = CanonicalBusinessEngine.warningBounds(detection: detection, invoicing: invoicing)
            let start = bounds.start
            let end = bounds.end
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            let mode = detection.clashLookaheadMode.displayName
            let window = "\(formatter.string(from: start))–\(formatter.string(from: end))"
            refreshMessage = "Updated · \(warningsService.activeWarnings.count) active · \(mode) · \(window)"
        } else {
            refreshMessage = "Could not refresh yet (still loading). Try again in a few seconds."
        }
        print("🔥🔥🔥 DEBUG: WARNINGS_MANUAL_REFRESH_DONE did=\(did) active=\(warningsService.activeWarnings.count)")
        NotificationCenter.default.post(name: .warningsDidRecompute, object: nil, userInfo: ["count": warningsService.warningCount])
    }
}


/// Polished confirmation for permanently dismissing a warning.
private struct WarningDismissConfirmationSheet: View {
    let warning: Warning
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let accent = PPColor.danger
    private let ink = Color.primary
    private let muted = Color.secondary

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            PPIconTile(symbol: "exclamationmark.triangle.fill", family: .alert, size: 64, lifted: true)
                .padding(.bottom, 16)

            Text("Dismiss this warning?")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("Are you sure you would like to dismiss this warning? Any warnings that are dismissed will not reappear again.")
                .font(.subheadline)
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 10)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 10) {
                Text(warning.title)
                    .font(.headline)
                    .foregroundStyle(ink)
                Text(warning.removalNotificationDetail)
                    .font(.subheadline)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PPColor.brand)
                        .padding(.top, 1)
                    Text("All admins will get a notification with who dismissed it and what was dismissed. It also appears in the notification centre on Home.")
                        .font(.footnote)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous)
                    .fill(PPColor.card)
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text("Dismiss permanently")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(PPFamily.alert.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityIdentifier("warningDismissConfirmation.dismissPermanently")
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text("Keep warning")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(PPColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityIdentifier("warningDismissConfirmation.keepWarning")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(PPColor.page.ignoresSafeArea())
    }
}

/// Sheet/item identity for a calendar day without making `Date` globally Identifiable.
nonisolated private struct IdentifiableDay: Identifiable, Hashable, Sendable {
    let date: Date
    var id: TimeInterval { Calendar.current.startOfDay(for: date).timeIntervalSince1970 }

    nonisolated init(_ date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
    }
}

/// Single full-screen destination. Two `.fullScreenCover` modifiers on the same
/// view fight each other on iOS, so settings and book-labour share this enum.
private enum WarningsFullScreenCover: Identifiable {
    case settings
    case bookLabour(date: Date, focusedUserIds: [String])

    var id: String {
        switch self {
        case .settings:
            return "settings"
        case .bookLabour(let date, _):
            return "book-\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"
        }
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
