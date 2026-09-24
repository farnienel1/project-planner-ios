//
//  BookLabourFlowView.swift
//  Project Planner
//
//  Multi-step flow: pick an unbooked person, then book to Other / Projects / Small works.
//

import SwiftUI
import FirebaseAuth

struct BookLabourCandidate: Identifiable {
    var id: String { user.id }
    let user: AppUser
    let linkedOperative: Operative?
    /// When true, project bookings use `Booking` + operative id; when false, use `ManagerSiteBooking`.
    let usesOperativeProjectBookings: Bool

    var displayName: String {
        user.fullName.isEmpty ? user.email : user.fullName
    }

    var roleChips: [String] {
        var chips: [String] = []
        if user.permissions.operativeMode { chips.append("Operative") }
        if user.permissions.manager { chips.append("Manager") }
        if user.permissions.adminAccess { chips.append("Admin") }
        if chips.isEmpty { chips.append("User") }
        return chips
    }

    /// Trade line for operative-linked users (matches book-labour HTML chip).
    var tradeDisplayString: String? {
        let userTrade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
        let normalizedUserTrade = userTrade.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedUserTrade != "—", !normalizedUserTrade.isEmpty {
            return normalizedUserTrade
        }
        guard let op = linkedOperative else { return nil }
        let label = StaffTradeType.displayLabel(presetRaw: op.tradeTypePreset, custom: op.tradeTypeCustom)
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "—" || t.isEmpty ? nil : t
    }

    var canBookOtherLocations: Bool {
        !user.permissions.operativeMode && (user.permissions.manager || user.permissions.adminAccess || user.isSuperAdmin)
    }
}

struct BookLabourFlowView: View {
    let bookDate: Date
    /// User ids from an unbooked-labour warning — always listed first so the flow
    /// opened from Warnings is never empty for the people on that card.
    var focusedUserIds: [String] = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    @State private var phase: Phase = .pickPerson
    @State private var errorBanner: String?
    @State private var isSaving = false
    @State private var projectListSearchText = ""
    @State private var pendingOperativeOverlap: PendingOperativeBookLabourOverlap?
    @State private var operativeDraftByProjectId: [UUID: OperativeRectifyDraft] = [:]
    @State private var isMultiSelectMode = false
    @State private var selectedPersonIds: Set<String> = []
    @State private var bookingParty: [BookLabourCandidate] = []

    private let calendar = Calendar.current

    private struct PendingOperativeBookLabourOverlap {
        let message: String
        let detailLines: [String]
        let onConfirm: () -> Void
    }

    private struct OperativeRectifyDraft {
        var startMinutes: Int
        var endMinutes: Int
        var breakRemoved: Bool
        var timeSlot: TimeSlot = .customHours
    }

    private var day: Date { calendar.startOfDay(for: bookDate) }

    private var scheduleOptions: MyScheduleOptions { appSettings.settings.myScheduleOptions }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var dayPayrollPolicy: OrgPayrollTimePolicy {
        firebaseBackend.payrollPolicy(for: day)
    }

    private var canBookStandardDayWindow: Bool {
        let p = dayPayrollPolicy
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: p)
        if timeline.allHoursAtMultiplier { return true }
        guard let s = timeline.standardWindowStartMinutes,
              let e = timeline.standardWindowEndMinutes else { return false }
        return e > s
    }

    private var liveProjects: [Project] {
        WorkAccess.visibleWorks(
            from: projectStore.projects,
            catalogue: .projects,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerBookings: managerScheduleStore.managerSiteBookings,
            taskStore: nil,
            deadlineAssignedProjectIds: []
        ).filter(\.isLive)
    }

    private var liveSmallWorks: [Project] {
        WorkAccess.visibleWorks(
            from: projectStore.projects,
            catalogue: .smallWorks,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerBookings: managerScheduleStore.managerSiteBookings,
            taskStore: nil,
            deadlineAssignedProjectIds: []
        ).filter(\.isLive)
    }

    enum ManagerSlotReturn: Hashable {
        case other
        case projectList(smallWorks: Bool)
    }

    enum Phase {
        case pickPerson
        case pickDestination(BookLabourCandidate)
        case pickOtherLocation(BookLabourCandidate)
        case pickProject(BookLabourCandidate, smallWorks: Bool)
        case pickSlotManager(
            BookLabourCandidate,
            locationType: ManagerLocationType,
            locationId: UUID?,
            customLocationName: String?,
            returnRoute: ManagerSlotReturn
        )
        case pickSlotOperative(BookLabourCandidate, project: Project)
        case pickCustomManager(
            BookLabourCandidate,
            locationType: ManagerLocationType,
            locationId: UUID?,
            customLocationName: String?,
            returnRoute: ManagerSlotReturn
        )
        case pickCustomOperative(BookLabourCandidate, project: Project)
    }

    private enum BookToTab: Hashable {
        case other, projects, smallWorks
    }

    var body: some View {
        bookFlowNavigationStack
    }

    private var isAtRootPhase: Bool {
        if case .pickPerson = phase { return true }
        return false
    }

    private var isCustomHoursPhase: Bool {
        switch phase {
        case .pickCustomManager, .pickCustomOperative: return true
        default: return false
        }
    }

    private var bookFlowNavigationStack: some View {
        NavigationStack {
            phaseContent
                .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
                .navigationTitle(isCustomHoursPhase ? "Custom hours" : "Book labour")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(ProjectWorksRevampColors.canvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    if !isCustomHoursPhase {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(isAtRootPhase ? "Close" : "Back") {
                                if isAtRootPhase {
                                    dismiss()
                                } else {
                                    goBack()
                                }
                            }
                        }
                    }
                }
                .alert("Could not book", isPresented: Binding(
                    get: { errorBanner != nil },
                    set: { if !$0 { errorBanner = nil } }
                )) {
                    Button("OK") { errorBanner = nil }
                } message: {
                    Text(errorBanner ?? "")
                }
                .overlay {
                    if let pending = pendingOperativeOverlap {
                        ZStack {
                            Color.black.opacity(0.28).ignoresSafeArea()
                            ScheduleOverlapWarningPanel(
                                message: pending.message,
                                detailLines: pending.detailLines,
                                onCancel: { pendingOperativeOverlap = nil },
                                onConfirm: {
                                    let run = pending.onConfirm
                                    pendingOperativeOverlap = nil
                                    run()
                                }
                            )
                            .padding(18)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .pickPerson:
            pickPersonView
        case .pickDestination(let person):
            pickDestinationView(person: person)
        case .pickOtherLocation(let person):
            pickOtherLocationView(person: person)
        case .pickProject(let person, let smallWorks):
            pickProjectListView(person: person, smallWorks: smallWorks)
        case .pickSlotManager(let person, let locType, let locId, let customName, let back):
            pickSlotManagerView(
                person: person,
                locationType: locType,
                locationId: locId,
                customLocationName: customName,
                returnRoute: back
            )
        case .pickSlotOperative(let person, let project):
            pickSlotOperativeView(person: person, project: project)
        case .pickCustomManager(let person, let locType, let locId, let customName, _):
            pickCustomManagerHoursView(
                person: person,
                locationType: locType,
                locationId: locId,
                customLocationName: customName
            )
        case .pickCustomOperative(let person, let project):
            pickCustomOperativeHoursView(person: person, project: project)
        }
    }

    private func goBack() {
        switch phase {
        case .pickPerson:
            break
        case .pickDestination:
            phase = .pickPerson
        case .pickOtherLocation(let p):
            phase = .pickDestination(p)
        case .pickProject(let p, _):
            projectListSearchText = ""
            phase = .pickDestination(p)
        case .pickSlotManager(let p, _, _, _, let back):
            switch back {
            case .other:
                phase = .pickOtherLocation(p)
            case .projectList(let smallWorks):
                phase = .pickProject(p, smallWorks: smallWorks)
            }
        case .pickSlotOperative(let p, let project):
            phase = .pickProject(p, smallWorks: project.jobType == .smallWorks)
        case .pickCustomManager(let p, let locType, let locId, let customName, let back):
            phase = .pickSlotManager(
                p,
                locationType: locType,
                locationId: locId,
                customLocationName: customName,
                returnRoute: back
            )
        case .pickCustomOperative(let p, let project):
            phase = .pickSlotOperative(p, project: project)
        }
    }

    // MARK: - Step 1: People

    private var candidates: [BookLabourCandidate] {
        buildCandidates()
    }

    private var bookFlowDayLine: String {
        day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var unbookedCount: Int { candidates.count }

    private var pickPersonView: some View {
        Group {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "Everyone is booked",
                    systemImage: "checkmark.circle",
                    description: Text("No unbooked team members for this day.")
                )
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "person.fill.questionmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                            Text("\(bookFlowDayLine) · \(unbookedCount) unbooked")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                            Spacer(minLength: 0)
                            Button {
                                isMultiSelectMode.toggle()
                                if !isMultiSelectMode {
                                    selectedPersonIds.removeAll()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isMultiSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(isMultiSelectMode ? "Multi-select on" : "Multi-select")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(isMultiSelectMode ? Color.white : ProjectWorksRevampColors.requiredPillFg)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isMultiSelectMode ? ProjectWorksRevampColors.blue : Color.white.opacity(0.7))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isMultiSelectMode ? "Turn off multi-select" : "Multi-select")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(ProjectWorksRevampColors.requiredPillBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        bookLabourSectionLabel(isMultiSelectMode ? "Select people" : "Select a person")

                        VStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, person in
                                Button {
                                    if isMultiSelectMode {
                                        if selectedPersonIds.contains(person.id) {
                                            selectedPersonIds.remove(person.id)
                                        } else {
                                            selectedPersonIds.insert(person.id)
                                        }
                                    } else {
                                        beginBooking(people: [person])
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        if isMultiSelectMode {
                                            Image(systemName: selectedPersonIds.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20, weight: .medium))
                                                .foregroundStyle(selectedPersonIds.contains(person.id) ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.placeholderInk)
                                        }
                                        bookLabourAvatar(initials: PlannerUIInitials.from(person.displayName), isOperative: person.user.permissions.operativeMode)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(person.displayName)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(ProjectWorksRevampColors.ink)
                                            BookLabourRoleChipRow(person: person)
                                        }
                                        Spacer(minLength: 0)
                                        if !isMultiSelectMode {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                                        }
                                    }
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if idx < candidates.count - 1 {
                                    Divider().overlay(ProjectWorksRevampColors.border)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(ProjectWorksRevampColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )

                        Text(isMultiSelectMode
                             ? "Tick everyone to book, then Continue."
                             : "Tap anywhere on a row to choose where to book them.")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.horizontal, 4)
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) {
                    if isMultiSelectMode {
                        Button {
                            let people = candidates.filter { selectedPersonIds.contains($0.id) }
                            beginBooking(people: people)
                        } label: {
                            Text(selectedPersonIds.isEmpty
                                 ? "Continue"
                                 : "Continue · \(selectedPersonIds.count)")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(selectedPersonIds.isEmpty ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedPersonIds.isEmpty)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .background(ProjectWorksRevampColors.canvas)
                    }
                }
            }
        }
    }

    private func beginBooking(people: [BookLabourCandidate]) {
        guard let first = people.first else { return }
        bookingParty = people
        phase = .pickDestination(first)
    }

    private func activeParty(fallback: BookLabourCandidate) -> [BookLabourCandidate] {
        bookingParty.isEmpty ? [fallback] : bookingParty
    }

    // MARK: - Step 2: Destination type

    private func pickDestinationView(person: BookLabourCandidate) -> some View {
        let people = activeParty(fallback: person)
        let otherEnabled = people.allSatisfy(\.canBookOtherLocations) && !scheduleOptions.enabledScheduleLocationPicks().isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                bookLabourPersonSummaryCard(people: people)
                bookLabourSectionLabel("Book to")
                bookLabourBookToSelector(
                    otherEnabled: otherEnabled,
                    selected: nil,
                    onOther: {
                        guard otherEnabled else { return }
                        phase = .pickOtherLocation(person)
                    },
                    onProjects: {
                        projectListSearchText = ""
                        phase = .pickProject(person, smallWorks: false)
                    },
                    onSmallWorks: {
                        projectListSearchText = ""
                        phase = .pickProject(person, smallWorks: true)
                    }
                )
                if people.contains(where: \.canBookOtherLocations) && scheduleOptions.enabledScheduleLocationPicks().isEmpty {
                    Text("Enable at least one location under App & account → General → My schedule to use Other.")
                        .font(.system(size: 11))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .padding(.horizontal, 4)
                } else if !otherEnabled, people.contains(where: { !$0.canBookOtherLocations }) {
                    Text("Other is only available when every selected person can be booked to office / WFH locations.")
                        .font(.system(size: 11))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .padding(.horizontal, 4)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Other locations

    private func pickOtherLocationView(person: BookLabourCandidate) -> some View {
        let picks = scheduleOptions.enabledScheduleLocationPicks()
        return Group {
            if picks.isEmpty {
                ContentUnavailableView(
                    "No locations",
                    systemImage: "slider.horizontal.3",
                    description: Text("Configure My schedule under General in app settings.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        bookLabourPersonSummaryCard(people: activeParty(fallback: person))
                        bookLabourSectionLabel("Book to")
                        bookLabourBookToSelector(
                            otherEnabled: true,
                            selected: .other,
                            onOther: {},
                            onProjects: {
                                projectListSearchText = ""
                                phase = .pickProject(person, smallWorks: false)
                            },
                            onSmallWorks: {
                                projectListSearchText = ""
                                phase = .pickProject(person, smallWorks: true)
                            }
                        )
                        bookLabourSectionLabel("Select location")
                        VStack(spacing: 0) {
                            ForEach(Array(picks.enumerated()), id: \.offset) { idx, pick in
                                Button {
                                    phase = .pickSlotManager(
                                        person,
                                        locationType: pick.managerLocationType,
                                        locationId: nil,
                                        customLocationName: pick.customLocationName,
                                        returnRoute: .other
                                    )
                                } label: {
                                    let meta = scheduleLocationPickVisuals(pick)
                                    bookLabourLocationRow(
                                        icon: meta.symbol,
                                        title: pick.title,
                                        iconBackground: meta.background,
                                        iconForeground: meta.foreground
                                    )
                                }
                                .buttonStyle(.plain)
                                if idx < picks.count - 1 {
                                    Divider().overlay(ProjectWorksRevampColors.border)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(ProjectWorksRevampColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Project lists

    private func pickProjectListView(person: BookLabourCandidate, smallWorks: Bool) -> some View {
        let rawList = smallWorks ? liveSmallWorks : liveProjects
        let q = projectListSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list: [Project] = {
            guard !q.isEmpty else { return rawList }
            return rawList.filter { p in
                [p.jobNumber, p.siteName, p.siteAddress, p.townCity, p.postcode]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(q)
            }
        }()
        let otherEnabled = activeParty(fallback: person).allSatisfy(\.canBookOtherLocations)
            && !scheduleOptions.enabledScheduleLocationPicks().isEmpty
        return Group {
            if rawList.isEmpty {
                ContentUnavailableView(
                    "No live \(smallWorks ? "small works" : "projects")",
                    systemImage: smallWorks ? "hammer" : "folder",
                    description: Text("Create or activate work to book here.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        bookLabourPersonSummaryCard(people: activeParty(fallback: person))
                        bookLabourSectionLabel("Book to")
                        bookLabourBookToSelector(
                            otherEnabled: otherEnabled,
                            selected: smallWorks ? .smallWorks : .projects,
                            onOther: {
                                guard otherEnabled else { return }
                                phase = .pickOtherLocation(person)
                            },
                            onProjects: {
                                if smallWorks {
                                    projectListSearchText = ""
                                    phase = .pickProject(person, smallWorks: false)
                                }
                            },
                            onSmallWorks: {
                                if !smallWorks {
                                    projectListSearchText = ""
                                    phase = .pickProject(person, smallWorks: true)
                                }
                            }
                        )
                        WorksListSearchRow(text: $projectListSearchText, placeholder: smallWorks ? "Search small works…" : "Search projects…") {
                            EmptyView()
                        }
                        bookLabourSectionLabel("\(smallWorks ? "Active small works" : "Active projects") · \(list.count)")
                        VStack(spacing: 0) {
                            if list.isEmpty {
                                Text("No matches")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, project in
                                    Button {
                                        let party = activeParty(fallback: person)
                                        if party.contains(where: { $0.usesOperativeProjectBookings && $0.linkedOperative == nil }) {
                                            errorBanner = party.count == 1
                                                ? "No operative profile is linked to this user."
                                                : "No operative profile is linked to one of the selected users."
                                            return
                                        }
                                        // Single operative keeps the daily-overview clock UI.
                                        // Multiple people use the same Full Day / AM / PM / Custom buttons for everyone.
                                        if party.count == 1, person.usesOperativeProjectBookings {
                                            phase = .pickSlotOperative(person, project: project)
                                        } else {
                                            phase = .pickSlotManager(
                                                person,
                                                locationType: smallWorks ? .smallWork : .project,
                                                locationId: project.id,
                                                customLocationName: nil,
                                                returnRoute: .projectList(smallWorks: smallWorks)
                                            )
                                        }
                                    } label: {
                                        bookLabourProjectRow(project: project, smallWorks: smallWorks)
                                    }
                                    .buttonStyle(.plain)
                                    if idx < list.count - 1 {
                                        Divider().overlay(ProjectWorksRevampColors.border)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(ProjectWorksRevampColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Slots

    private func pickSlotManagerView(
        person: BookLabourCandidate,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?,
        returnRoute: ManagerSlotReturn
    ) -> some View {
        let locationLabel: String = {
            if locationType == .office || locationType == .workingFromHome || locationType == .siteSurvey {
                return locationType.displayName
            }
            if locationType == .custom {
                return customLocationName?.isEmpty == false ? (customLocationName ?? "Custom") : "Custom"
            }
            if let id = locationId,
               let p = projectStore.projects.first(where: { $0.id == id }) {
                return "\(p.jobNumber) \(p.siteName)"
            }
            return "Site"
        }()

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                bookLabourPersonSummaryCard(people: activeParty(fallback: person))
                Text(locationLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(bookFlowDayLine)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                bookLabourSectionLabel("Select slot")
                HStack(spacing: 10) {
                    ForEach([ManagerTimeSlot.fullDay, .morning, .afternoon], id: \.self) { slot in
                        Button {
                            savePartyBookings(
                                fallbackPerson: person,
                                slot: slot,
                                locationType: locationType,
                                locationId: locationId,
                                customLocationName: customLocationName
                            )
                        } label: {
                            Text(slot.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(red: 0.902, green: 0.945, blue: 0.984))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                }
                Button {
                    phase = .pickCustomManager(
                        person,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName,
                        returnRoute: returnRoute
                    )
                } label: {
                    Text("Custom")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.902, green: 0.945, blue: 0.984))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
    }

    private func partyHeaderName(fallback: BookLabourCandidate) -> String {
        let people = activeParty(fallback: fallback)
        if people.count <= 1 { return fallback.displayName }
        if people.count <= 3 { return people.map(\.displayName).joined(separator: ", ") }
        return "\(people.count) people"
    }

    private func pickCustomManagerHoursView(
        person: BookLabourCandidate,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?
    ) -> some View {
        let header = partyHeaderName(fallback: person)
        return OperativeCustomHoursSheet(
            policy: dayPayrollPolicy,
            referenceDay: day,
            title: "Custom hours",
            subtitle: bookFlowDayLine,
            headerName: header,
            headerInitials: PlannerUIInitials.from(header),
            allowsOtMultiplierOverride: false,
            embedsNavigation: false,
            initialChoice: OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: dayPayrollPolicy.standardDayStart,
                workEndTime: dayPayrollPolicy.standardDayEnd,
                isBreakRemoved: false
            ),
            onSave: { start, end, breakRemoved, _ in
                savePartyBookings(
                    fallbackPerson: person,
                    slot: .customHours,
                    locationType: locationType,
                    locationId: locationId,
                    customLocationName: customLocationName,
                    workStart: start,
                    workEnd: end,
                    breakRemoved: breakRemoved
                )
            },
            onCancel: { goBack() }
        )
    }

    @ViewBuilder
    private func pickCustomOperativeHoursView(person: BookLabourCandidate, project: Project) -> some View {
        Group {
            if let op = person.linkedOperative {
                let draft = operativeDraft(for: project.id, operativeId: op.id)
                let header = partyHeaderName(fallback: person)
                OperativeCustomHoursSheet(
                    policy: dayPayrollPolicy,
                    referenceDay: day,
                    title: "Custom hours",
                    subtitle: bookFlowDayLine,
                    headerName: header,
                    headerInitials: PlannerUIInitials.from(header),
                    allowsOtMultiplierOverride: true,
                    embedsNavigation: false,
                    initialChoice: OperativeDayBookingChoice(
                        timeSlot: .customHours,
                        workStartTime: timeText(from: draft.startMinutes),
                        workEndTime: timeText(from: draft.endMinutes),
                        isBreakRemoved: draft.breakRemoved
                    ),
                    onSave: { start, end, breakRemoved, otMult in
                        saveOperativeProjectSlot(
                            person: person,
                            project: project,
                            slot: .customHours,
                            workStart: start,
                            workEnd: end,
                            breakRemoved: breakRemoved,
                            otMultiplierOverride: otMult
                        )
                    },
                    onCancel: { goBack() }
                )
            } else {
                Text("No operative profile for this user.")
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func pickSlotOperativeView(person: BookLabourCandidate, project: Project) -> some View {
        if let op = person.linkedOperative {
            let draft = operativeDraft(for: project.id, operativeId: op.id)
            let existingPaidHours = existingPaidHoursForOperative(op.id)
            let newPaidHours = paidHours(startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, breakRemoved: draft.breakRemoved)
            let combinedPaidHours = existingPaidHours + newPaidHours
            let remainingHours = max(0, max(dayPayrollPolicy.standardPaidHours, 0) - combinedPaidHours)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bookLabourPersonSummaryCard(people: activeParty(fallback: person))
                    HStack(spacing: 8) {
                        Text(project.jobNumber)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                        Text(project.siteName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                    Text(bookFlowDayLine)
                        .font(.system(size: 11))
                        .foregroundStyle(ProjectWorksRevampColors.muted)

                    bookLabourSectionLabel("Quick options")
                    HStack(spacing: 10) {
                        Button {
                            applyQuickTimeSlot(.fullDay, projectId: project.id, currentBreakRemoved: draft.breakRemoved)
                        } label: {
                            quickDraftButtonLabel("FULL DAY")
                        }
                        Button {
                            applyQuickTimeSlot(.morning, projectId: project.id, currentBreakRemoved: draft.breakRemoved)
                        } label: {
                            quickDraftButtonLabel("AM")
                        }
                        Button {
                            applyQuickTimeSlot(.afternoon, projectId: project.id, currentBreakRemoved: draft.breakRemoved)
                        } label: {
                            quickDraftButtonLabel("PM")
                        }
                    }

                    bookLabourSectionLabel("Custom hours")
                    HStack(spacing: 8) {
                        draftTimePicker(
                            title: "Start",
                            value: draft.startMinutes,
                            allowedRange: 0...(max(0, draft.endMinutes - 30))
                        ) { value in
                            setOperativeDraft(
                                for: project.id,
                                draft: .init(startMinutes: value, endMinutes: draft.endMinutes, breakRemoved: draft.breakRemoved)
                            )
                        }
                        draftTimePicker(
                            title: "End",
                            value: draft.endMinutes,
                            allowedRange: (draft.startMinutes + 30)...(24 * 60)
                        ) { value in
                            setOperativeDraft(
                                for: project.id,
                                draft: .init(startMinutes: draft.startMinutes, endMinutes: value, breakRemoved: draft.breakRemoved)
                            )
                        }
                    }

                    Toggle("No break on this booking", isOn: Binding(
                        get: { draft.breakRemoved },
                        set: { value in
                            setOperativeDraft(
                                for: project.id,
                                draft: .init(startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, breakRemoved: value)
                            )
                        }
                    ))
                    .font(.system(size: 12, weight: .medium))
                    .tint(ProjectWorksRevampColors.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Breakdown")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Existing booked: \(ScheduleCoverageFormat.hours(existingPaidHours))h")
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        Text("New booking: \(ScheduleCoverageFormat.hours(newPaidHours))h")
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                        Text("Total booked: \(ScheduleCoverageFormat.hours(combinedPaidHours))h")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        if remainingHours > 0.05 {
                            Text("Missing to standard day: \(ScheduleCoverageFormat.hours(remainingHours))h")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                        }
                    }
                    .padding(10)
                    .background(ProjectWorksRevampColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )

                    Button {
                        saveOperativeBooking(
                            operative: op,
                            project: project,
                            slot: .customHours,
                            workStart: timeText(from: draft.startMinutes),
                            workEnd: timeText(from: draft.endMinutes),
                            breakRemoved: draft.breakRemoved
                        )
                    } label: {
                        Text("Save booking")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(ProjectWorksRevampColors.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .disabled(isSaving || draft.endMinutes <= draft.startMinutes)

                    Button {
                        phase = .pickCustomOperative(person, project: project)
                    } label: {
                        Text("Advanced editor")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(ProjectWorksRevampColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
        } else {
            Text("No operative profile for this user.")
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .padding()
        }
    }

    private func operativeSlotChipTitle(_ slot: TimeSlot) -> String {
        switch slot {
        case .fullDay: return "FULL DAY"
        case .morning: return "AM"
        case .afternoon: return "PM"
        default: return "CUSTOM"
        }
    }

    private func saveOperativeProjectSlot(
        person: BookLabourCandidate,
        project: Project,
        slot: TimeSlot,
        workStart: String? = nil,
        workEnd: String? = nil,
        breakRemoved: Bool = false,
        otMultiplierOverride: Double? = nil
    ) {
        let locationType: ManagerLocationType = project.jobType == .smallWorks ? .smallWork : .project
        savePartyBookings(
            fallbackPerson: person,
            slot: managerSlot(from: slot),
            locationType: locationType,
            locationId: project.id,
            customLocationName: nil,
            workStart: workStart,
            workEnd: workEnd,
            breakRemoved: breakRemoved,
            otMultiplierOverride: otMultiplierOverride
        )
    }

    private func managerSlot(from slot: TimeSlot) -> ManagerTimeSlot {
        switch slot {
        case .morning: return .morning
        case .afternoon: return .afternoon
        case .customHours: return .customHours
        default: return .fullDay
        }
    }

    private func operativeDraft(for projectId: UUID, operativeId: UUID) -> OperativeRectifyDraft {
        if let existing = operativeDraftByProjectId[projectId] {
            return existing
        }
        return defaultOperativeDraft(operativeId: operativeId)
    }

    private func setOperativeDraft(for projectId: UUID, draft: OperativeRectifyDraft) {
        var adjusted = draft
        adjusted.startMinutes = max(0, min(adjusted.startMinutes, 24 * 60))
        adjusted.endMinutes = max(adjusted.startMinutes + 30, min(adjusted.endMinutes, 24 * 60))
        operativeDraftByProjectId[projectId] = adjusted
    }

    private func defaultOperativeDraft(operativeId: UUID) -> OperativeRectifyDraft {
        let policy = dayPayrollPolicy
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
        let defaultStart = timeline.standardWindowStartMinutes ?? 450
        let defaultEnd = timeline.standardWindowEndMinutes ?? 960
        let intervals = existingIntervalsForOperative(operativeId)
        let latestEnd = intervals.map(\.1).max() ?? defaultStart
        let start = max(defaultStart, latestEnd)
        let end = start < defaultEnd ? defaultEnd : min(24 * 60, start + 60)
        return .init(startMinutes: start, endMinutes: max(start + 30, end), breakRemoved: timeline.allHoursAtMultiplier)
    }

    private func existingIntervalsForOperative(_ operativeId: UUID) -> [(Int, Int)] {
        bookingStore.bookings
            .filter {
                $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                ($0.status == .confirmed || $0.status == .tentative)
            }
            .compactMap { OperativeBookingInterval.clashInterval(for: $0, policy: dayPayrollPolicy) }
            .sorted { $0.0 < $1.0 }
    }

    private func timeText(from minutes: Int) -> String {
        if minutes >= 24 * 60 { return "24:00" }
        let clamped = max(0, min(minutes, 24 * 60 - 1))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    private func quickDraftButtonLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ProjectWorksRevampColors.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(red: 0.902, green: 0.945, blue: 0.984))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 0.5)
            )
    }

    private func draftTimePicker(
        title: String,
        value: Int,
        allowedRange: ClosedRange<Int>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        let safeValue = min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            Picker(title, selection: Binding(
                get: { safeValue },
                set: { onChange($0) }
            )) {
                ForEach(Array(stride(from: 0, through: 24 * 60, by: 30)), id: \.self) { minute in
                    if minute >= allowedRange.lowerBound && minute <= allowedRange.upperBound {
                        Text(timeText(from: minute)).tag(minute)
                    }
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .clipped()
        }
        .padding(8)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func existingPaidHoursForOperative(_ operativeId: UUID) -> Double {
        bookingStore.bookings
            .filter {
                $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                ($0.status == .confirmed || $0.status == .tentative)
            }
            .reduce(0.0) { $0 + $1.paidBookedHours(policy: dayPayrollPolicy) }
    }

    private func paidHours(startMinutes: Int, endMinutes: Int, breakRemoved: Bool) -> Double {
        guard endMinutes > startMinutes else { return 0 }
        var wall = Double(endMinutes - startMinutes) / 60.0
        if !breakRemoved {
            wall = max(0, wall - payrollTimePolicy.standardUnpaidBreakHours)
        }
        return wall
    }

    private func applyQuickTimeSlot(_ slot: TimeSlot, projectId: UUID, currentBreakRemoved: Bool) {
        let policy = dayPayrollPolicy
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
        guard let ds = timeline.standardWindowStartMinutes,
              let de = timeline.standardWindowEndMinutes,
              de > ds else { return }
        let windows = PayrollTimePolicyCatalog.weekdayHalfDayWindows(policy: policy)
        let breakRemoved = timeline.allHoursAtMultiplier ? true : currentBreakRemoved
        let next: OperativeRectifyDraft
        switch slot {
        case .fullDay:
            next = .init(startMinutes: ds, endMinutes: de, breakRemoved: breakRemoved)
        case .morning:
            let start = windows?.morningStart ?? ds
            let end = windows?.morningEnd ?? (ds + ((de - ds) / 2))
            next = .init(startMinutes: start, endMinutes: end, breakRemoved: breakRemoved)
        case .afternoon:
            let start = windows?.afternoonStart ?? (ds + ((de - ds) / 2))
            let end = windows?.afternoonEnd ?? de
            next = .init(startMinutes: start, endMinutes: end, breakRemoved: breakRemoved)
        default:
            next = .init(startMinutes: ds, endMinutes: de, breakRemoved: breakRemoved)
        }
        setOperativeDraft(for: projectId, draft: next)
    }

    // MARK: - Revamp layout (HTML reference)

    private func scheduleLocationPickVisuals(_ pick: ScheduleLocationPick) -> (symbol: String, background: Color, foreground: Color) {
        switch pick {
        case .office:
            return ("building.2.fill", Color(red: 0.902, green: 0.945, blue: 0.984), ProjectWorksRevampColors.blue)
        case .workingFromHome:
            return ("house.fill", Color(red: 0.882, green: 0.961, blue: 0.933), ProjectWorksRevampColors.activeGreen)
        case .siteSurvey:
            return ("mappin.and.ellipse", ProjectWorksRevampColors.pinRoseBg, ProjectWorksRevampColors.pinRoseFg)
        case .custom:
            return ("mappin.circle.fill", ProjectWorksRevampColors.endDateBg, ProjectWorksRevampColors.upcomingAmber)
        }
    }

    private func bookLabourSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }

    private func bookLabourAvatar(initials: String, isOperative: Bool) -> some View {
        let colors: [Color] = isOperative
            ? [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight]
            : [Color(red: 0.325, green: 0.290, blue: 0.718), Color(red: 0.498, green: 0.467, blue: 0.867)]
        return Text(initials)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: 38, height: 38)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Circle())
    }

    private func bookLabourPersonSummaryCard(people: [BookLabourCandidate]) -> some View {
        let first = people.first
        let title: String
        let subtitle: String
        if people.isEmpty {
            title = "No one selected"
            subtitle = bookFlowDayLine
        } else if people.count == 1 {
            title = people[0].displayName
            subtitle = bookFlowDayLine
        } else if people.count <= 3 {
            title = people.map(\.displayName).joined(separator: ", ")
            subtitle = "\(people.count) people · \(bookFlowDayLine)"
        } else {
            title = "\(people.count) people"
            let extra = people.count - 2
            subtitle = people.prefix(2).map(\.displayName).joined(separator: ", ") + " +\(extra) · \(bookFlowDayLine)"
        }
        return HStack(spacing: 12) {
            bookLabourAvatar(
                initials: PlannerUIInitials.from(first?.displayName ?? "P"),
                isOperative: first?.user.permissions.operativeMode ?? false
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .padding(.horizontal, 2)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func bookLabourBookToSelector(
        otherEnabled: Bool,
        selected: BookToTab?,
        onOther: @escaping () -> Void,
        onProjects: @escaping () -> Void,
        onSmallWorks: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            bookLabourBookToCell(column: .other, selected: selected, enabled: otherEnabled, action: onOther)
            bookLabourBookToCell(column: .projects, selected: selected, enabled: true, action: onProjects)
            bookLabourBookToCell(column: .smallWorks, selected: selected, enabled: true, action: onSmallWorks)
        }
    }

    private func bookLabourBookToCell(
        column: BookToTab,
        selected: BookToTab?,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let accent: Color = {
            switch column {
            case .other: return ProjectWorksRevampColors.blue
            case .projects: return ProjectWorksRevampColors.activeGreen
            case .smallWorks: return ProjectWorksRevampColors.upcomingAmber
            }
        }()
        let isOn = selected == column
        let fill: Color = {
            guard isOn else { return Color.white }
            switch column {
            case .other: return Color(red: 0.902, green: 0.945, blue: 0.984)
            case .projects: return Color(red: 0.882, green: 0.961, blue: 0.933)
            case .smallWorks: return Color(red: 0.980, green: 0.933, blue: 0.855)
            }
        }()
        let iconName: String = {
            switch column {
            case .other: return "ellipsis.circle"
            case .projects: return "folder.fill"
            case .smallWorks: return "hammer.fill"
            }
        }()
        let label: String = {
            switch column {
            case .other: return "Other"
            case .projects: return "Projects"
            case .smallWorks: return "Small works"
            }
        }()
        return Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isOn ? accent : ProjectWorksRevampColors.ink.opacity(enabled ? 1 : 0.35))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn ? accent : ProjectWorksRevampColors.ink.opacity(enabled ? 1 : 0.35))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isOn ? accent : ProjectWorksRevampColors.searchBorder, lineWidth: isOn ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func bookLabourLocationRow(icon: String, title: String, iconBackground: Color, iconForeground: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconForeground)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
        }
        .padding(.vertical, 12)
    }

    private func projectLocalitySubtitle(_ project: Project) -> String {
        let town = project.townCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let pc = project.postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = [town, pc].filter { !$0.isEmpty }.joined(separator: " ")
        if !line.isEmpty { return line }
        let a = project.siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? " " : a
    }

    private func bookLabourProjectRow(project: Project, smallWorks: Bool) -> some View {
        let iconBg = smallWorks ? Color(red: 0.980, green: 0.933, blue: 0.855) : Color(red: 0.882, green: 0.961, blue: 0.933)
        let iconFg = smallWorks ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen
        let jobColor = smallWorks ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.blue
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 32, height: 32)
                Image(systemName: smallWorks ? "hammer.fill" : "folder.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconFg)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.jobNumber)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(jobColor)
                    Text(project.siteName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .lineLimit(1)
                }
                Text(projectLocalitySubtitle(project))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Save

    private func managerSlotToTimeSlot(_ slot: ManagerTimeSlot) -> TimeSlot {
        switch slot {
        case .fullDay: return .fullDay
        case .morning: return .morning
        case .afternoon: return .afternoon
        case .customHours: return .customHours
        }
    }

    private func projectForManagerLocation(locationType: ManagerLocationType, locationId: UUID?) -> Project? {
        guard locationType == .project || locationType == .smallWork, let id = locationId else { return nil }
        return projectStore.projects.first(where: { $0.id == id })
            ?? projectStore.smallWorks.first(where: { $0.id == id })
    }

    private func personUsesOperativeProjectPath(_ person: BookLabourCandidate, locationType: ManagerLocationType, project: Project?) -> Bool {
        person.usesOperativeProjectBookings && project != nil && (locationType == .project || locationType == .smallWork)
    }

    private func duplicateOperativeBooking(
        operativeId: UUID,
        projectId: UUID,
        slot: TimeSlot,
        workStart: String?,
        workEnd: String?,
        breakRemoved: Bool,
        otMultiplierOverride: Double?
    ) -> Bool {
        bookingStore.bookings.contains {
            $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                $0.projectId == projectId &&
                $0.timeSlot == slot &&
                $0.workStartTime == workStart &&
                $0.workEndTime == workEnd &&
                $0.isBreakRemoved == breakRemoved &&
                $0.otMultiplierOverride == otMultiplierOverride &&
                $0.status != .cancelled
        }
    }

    /// Books every selected person to the same location and slot (multi-select or single).
    private func savePartyBookings(
        fallbackPerson: BookLabourCandidate,
        slot: ManagerTimeSlot,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?,
        workStart: String? = nil,
        workEnd: String? = nil,
        breakRemoved: Bool = false,
        otMultiplierOverride: Double? = nil,
        allowOperativeOverlap: Bool = false
    ) {
        let people = activeParty(fallback: fallbackPerson)
        guard !people.isEmpty else { return }
        let resolvedProject = projectForManagerLocation(locationType: locationType, locationId: locationId)
        let operativeSlot = managerSlotToTimeSlot(slot)

        var managerClashNames: [String] = []
        for person in people {
            if personUsesOperativeProjectPath(person, locationType: locationType, project: resolvedProject) { continue }
            if duplicateManagerBooking(
                userId: person.user.id,
                slot: slot,
                locationType: locationType,
                locationId: locationId,
                custom: customLocationName
            ) { continue }
            if managerWouldClash(
                userId: person.user.id,
                date: day,
                newSlot: slot,
                workStart: workStart,
                workEnd: workEnd
            ) {
                managerClashNames.append(person.displayName)
            }
        }
        if !managerClashNames.isEmpty {
            errorBanner = managerClashNames.count == 1
                ? "This booking overlaps another in time on that day."
                : "Overlapping bookings for: \(managerClashNames.joined(separator: ", "))."
            return
        }

        if !allowOperativeOverlap {
            var clashLines: [String] = []
            for person in people {
                guard personUsesOperativeProjectPath(person, locationType: locationType, project: resolvedProject),
                      let project = resolvedProject,
                      let op = person.linkedOperative else { continue }
                if let lines = operativeClashDetailLines(
                    operativeId: op.id,
                    projectId: project.id,
                    slot: operativeSlot,
                    workStart: workStart,
                    workEnd: workEnd,
                    breakRemoved: breakRemoved
                ) {
                    clashLines.append(contentsOf: lines.map { "\(person.displayName) · \($0)" })
                }
            }
            if !clashLines.isEmpty {
                pendingOperativeOverlap = PendingOperativeBookLabourOverlap(
                    message: people.count > 1
                        ? "One or more bookings overlap another in time on \(bookFlowDayLine)."
                        : "This booking overlaps another in time on \(bookFlowDayLine).",
                    detailLines: clashLines,
                    onConfirm: {
                        savePartyBookings(
                            fallbackPerson: fallbackPerson,
                            slot: slot,
                            locationType: locationType,
                            locationId: locationId,
                            customLocationName: customLocationName,
                            workStart: workStart,
                            workEnd: workEnd,
                            breakRemoved: breakRemoved,
                            otMultiplierOverride: otMultiplierOverride,
                            allowOperativeOverlap: true
                        )
                    }
                )
                return
            }
        }

        if people.contains(where: { personUsesOperativeProjectPath($0, locationType: locationType, project: resolvedProject) }),
           firebaseBackend.currentUser?.uid == nil {
            errorBanner = "Not signed in."
            return
        }

        isSaving = true
        Task {
            var firstError: String?
            let bookedBy = firebaseBackend.currentUser?.uid
            let bookedByName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
            for person in people {
                if personUsesOperativeProjectPath(person, locationType: locationType, project: resolvedProject) {
                    guard let op = person.linkedOperative, let project = resolvedProject, let bookedBy else {
                        if firstError == nil {
                            firstError = "No operative profile is linked to \(person.displayName)."
                        }
                        continue
                    }
                    if duplicateOperativeBooking(
                        operativeId: op.id,
                        projectId: project.id,
                        slot: operativeSlot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        otMultiplierOverride: otMultiplierOverride
                    ) {
                        continue
                    }
                    await bookingStore.bookOperative(
                        op,
                        on: day,
                        timeSlot: operativeSlot,
                        for: project,
                        bookedBy: bookedBy,
                        workStartTime: workStart,
                        workEndTime: workEnd,
                        isBreakRemoved: breakRemoved,
                        otMultiplierOverride: otMultiplierOverride
                    )
                    await notificationService.notifyBookedUsers(
                        projectName: project.siteName,
                        bookedBy: bookedByName,
                        recipients: [.init(operativeId: op.id, dates: [day])]
                    )
                } else {
                    if duplicateManagerBooking(
                        userId: person.user.id,
                        slot: slot,
                        locationType: locationType,
                        locationId: locationId,
                        custom: customLocationName
                    ) {
                        continue
                    }
                    let booking = ManagerSiteBooking(
                        userId: person.user.id,
                        date: day,
                        timeSlot: slot,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName,
                        workStartTime: workStart,
                        workEndTime: workEnd,
                        isBreakRemoved: breakRemoved
                    )
                    await managerScheduleStore.saveBooking(booking)
                }
            }
            ScheduleChangeNotifier.postBookingStoreDidChange()
            await MainActor.run {
                isSaving = false
                if let firstError {
                    errorBanner = firstError
                } else {
                    dismiss()
                }
            }
        }
    }

    private func saveOperativeBooking(
        operative: Operative,
        project: Project,
        slot: TimeSlot,
        workStart: String? = nil,
        workEnd: String? = nil,
        breakRemoved: Bool = false,
        otMultiplierOverride: Double? = nil,
        allowOverlap: Bool = false
    ) {
        guard let bookedBy = firebaseBackend.currentUser?.uid else {
            errorBanner = "Not signed in."
            return
        }
        if bookingStore.bookings.contains(where: {
            $0.operativeId == operative.id &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                $0.projectId == project.id &&
                $0.timeSlot == slot &&
                $0.workStartTime == workStart &&
                $0.workEndTime == workEnd &&
                $0.isBreakRemoved == breakRemoved &&
                $0.otMultiplierOverride == otMultiplierOverride &&
                $0.status != .cancelled
        }) {
            errorBanner = "That booking already exists."
            return
        }
        if !allowOverlap,
           let clashLines = operativeClashDetailLines(
                operativeId: operative.id,
                projectId: project.id,
                slot: slot,
                workStart: workStart,
                workEnd: workEnd,
                breakRemoved: breakRemoved
           ) {
            pendingOperativeOverlap = PendingOperativeBookLabourOverlap(
                message: "This booking overlaps another in time on \(bookFlowDayLine).",
                detailLines: clashLines,
                onConfirm: {
                    saveOperativeBooking(
                        operative: operative,
                        project: project,
                        slot: slot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        otMultiplierOverride: otMultiplierOverride,
                        allowOverlap: true
                    )
                }
            )
            return
        }
        isSaving = true
        Task {
            await bookingStore.bookOperative(
                operative,
                on: day,
                timeSlot: slot,
                for: project,
                bookedBy: bookedBy,
                workStartTime: workStart,
                workEndTime: workEnd,
                isBreakRemoved: breakRemoved,
                otMultiplierOverride: otMultiplierOverride
            )
            await notificationService.notifyBookedUsers(
                projectName: project.siteName,
                bookedBy: userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User",
                recipients: [.init(operativeId: operative.id, dates: [day])]
            )
            ScheduleChangeNotifier.postBookingStoreDidChange()
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }

    private func operativeClashDetailLines(
        operativeId: UUID,
        projectId: UUID,
        slot: TimeSlot,
        workStart: String?,
        workEnd: String?,
        breakRemoved: Bool
    ) -> [String]? {
        let existing = bookingStore.bookings.filter {
            $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                $0.status != .cancelled &&
                $0.status != .completed
        }
        guard !existing.isEmpty else { return nil }
        let policy = payrollTimePolicy
        let probe = Booking(
            operativeId: operativeId,
            projectId: projectId,
            date: day,
            timeSlot: slot,
            bookedBy: "",
            workStartTime: workStart,
            workEndTime: workEnd,
            isBreakRemoved: breakRemoved
        )
        let overlapping = existing.filter { OperativeBookingInterval.bookingsOverlap(probe, $0, policy: policy) }
        guard !overlapping.isEmpty else { return nil }
        return overlapping.map { booking in
            let p = projectStore.projects.first(where: { $0.id == booking.projectId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let label = p.map { "\($0.jobNumber) \($0.siteName)" } ?? "Another job"
            return "\(booking.scheduleLabel(policy: policy)) · \(label)"
        }
    }

    private func duplicateManagerBooking(
        userId: String,
        slot: ManagerTimeSlot,
        locationType: ManagerLocationType,
        locationId: UUID?,
        custom: String?
    ) -> Bool {
        managerScheduleStore.bookings(for: userId, on: day).contains { existing in
            existing.timeSlot == slot &&
                existing.locationType == locationType &&
                existing.locationId == locationId &&
                (existing.customLocationName ?? "") == (custom ?? "")
        }
    }

    private func managerWouldClash(
        userId: String,
        date: Date,
        newSlot: ManagerTimeSlot,
        workStart: String? = nil,
        workEnd: String? = nil
    ) -> Bool {
        let existing = managerScheduleStore.bookings(for: userId, on: date)
        if existing.isEmpty { return false }
        let policy = payrollTimePolicy
        let probe = ManagerSiteBooking(
            userId: userId,
            date: date,
            timeSlot: newSlot,
            locationType: .office,
            locationId: nil,
            workStartTime: workStart,
            workEndTime: workEnd
        )
        return existing.contains { ManagerScheduleInterval.bookingsOverlap(probe, $0, policy: policy) }
    }

    private func operativeWouldClash(
        operativeId: UUID,
        projectId: UUID,
        slot: TimeSlot,
        workStart: String? = nil,
        workEnd: String? = nil,
        breakRemoved: Bool = false
    ) -> Bool {
        let existing = bookingStore.bookings.filter {
            $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                $0.status != .cancelled &&
                $0.status != .completed
        }
        if existing.isEmpty { return false }
        let policy = payrollTimePolicy
        let probe = Booking(
            operativeId: operativeId,
            projectId: projectId,
            date: day,
            timeSlot: slot,
            bookedBy: "",
            workStartTime: workStart,
            workEndTime: workEnd,
            isBreakRemoved: breakRemoved
        )
        return existing.contains { OperativeBookingInterval.bookingsOverlap(probe, $0, policy: policy) }
    }

    // MARK: - Candidate building (aligned with DailyOverviewView)

    private var includeWeekendsForUnbookedLabour: Bool {
        firebaseBackend.currentOrganization?.settings.warningDetection.includeWeekendsForUnbookedLabour == true
    }

    private var canBookLabourOnThisDay: Bool {
        let weekday = calendar.component(.weekday, from: day)
        if weekday >= 2 && weekday <= 6 { return true }
        if !focusedUserIds.isEmpty { return true }
        return includeWeekendsForUnbookedLabour
    }

    private func buildCandidates() -> [BookLabourCandidate] {
        guard canBookLabourOnThisDay else { return [] }

        let policy = dayPayrollPolicy
        let required = max(policy.standardPaidHours, 0)
        let focused = Set(focusedUserIds)

        func isWarningFocus(_ candidate: BookLabourCandidate) -> Bool {
            if focused.contains(candidate.user.id) { return true }
            if let op = candidate.linkedOperative, focused.contains(op.id.uuidString) { return true }
            return false
        }

        let operativeUsers = userStore.organizationUsers.filter {
            $0.permissions.operativeMode && $0.isActive && ($0.passwordSet || focused.contains($0.id))
        }
        let managerUsers = userStore.organizationUsers.filter {
            $0.isActive &&
                ($0.passwordSet || focused.contains($0.id)) &&
                ($0.permissions.manager || $0.permissions.adminAccess || $0.isSuperAdmin || $0.role == .admin)
        }
        let operativeOnlyUsers = operativeUsers.filter {
            !$0.permissions.manager &&
                !$0.permissions.adminAccess &&
                !$0.isSuperAdmin &&
                $0.role != .admin
        }

        var out: [BookLabourCandidate] = []
        var seenUserIds: Set<String> = []

        func appendCandidate(_ candidate: BookLabourCandidate, paid: Double) {
            guard seenUserIds.insert(candidate.user.id).inserted else { return }
            let isFocused = isWarningFocus(candidate)
            // Always keep people named on the warning. Otherwise skip a full paid day.
            if !isFocused, paid + 0.08 >= required { return }
            out.append(candidate)
        }

        for user in operativeOnlyUsers {
            let linked = operativeStore.allOperatives.first { $0.email.lowercased() == user.email.lowercased() }
            if hasApprovedHoliday(userId: user.id, operativeId: linked?.id) { continue }
            guard let linked else { continue }
            let paid = operativePaidHours(operativeId: linked.id) + managerScheduledPaidHours(userId: user.id)
            appendCandidate(
                BookLabourCandidate(user: user, linkedOperative: linked, usesOperativeProjectBookings: true),
                paid: paid
            )
        }

        for user in managerUsers {
            let linked = operativeStore.allOperatives.first { $0.email.lowercased() == user.email.lowercased() }
            if hasApprovedHoliday(userId: user.id, operativeId: linked?.id) { continue }
            let paid = managerScheduledPaidHours(userId: user.id) + (linked.map { operativePaidHours(operativeId: $0.id) } ?? 0)
            appendCandidate(
                BookLabourCandidate(user: user, linkedOperative: linked, usesOperativeProjectBookings: false),
                paid: paid
            )
        }

        return out.sorted { a, b in
            let aFocus = isWarningFocus(a)
            let bFocus = isWarningFocus(b)
            if aFocus != bFocus { return aFocus }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func hasApprovedHoliday(userId: String, operativeId: UUID?) -> Bool {
        let approved = holidayStore.approvedBookings(covering: day)
        return approved.contains { holiday in
            if holiday.status != .approved { return false }
            if holiday.userId == userId { return true }
            if let operativeId, holiday.operativeId == operativeId { return true }
            return false
        }
    }

    private func operativePaidHours(operativeId: UUID) -> Double {
        let policy = dayPayrollPolicy
        let bookings = bookingStore.bookings.filter {
            $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                ($0.status == .confirmed || $0.status == .tentative)
        }
        return bookings.reduce(0.0) { $0 + $1.paidBookedHours(policy: policy) }
    }

    private func managerScheduledPaidHours(userId: String) -> Double {
        let policy = dayPayrollPolicy
        let bookings = managerScheduleStore.managerSiteBookings.filter { booking in
            calendar.isDate(booking.date, inSameDayAs: day) && booking.userId == userId
        }
        return ManagerScheduleInterval.combinedPaidBookedHours(for: bookings, policy: policy)
    }
}

private struct BookLabourOperativeHoursSheet: View {
    let policy: OrgPayrollTimePolicy
    let onSave: (String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var startText: String
    @State private var endText: String
    @State private var breakRemoved = false
    @State private var errorMessage: String?

    init(policy: OrgPayrollTimePolicy, onSave: @escaping (String, String, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.policy = policy
        self.onSave = onSave
        self.onCancel = onCancel
        _startText = State(initialValue: policy.standardDayStart)
        _endText = State(initialValue: policy.standardDayEnd)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Start (HH:mm)", text: $startText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("End (HH:mm)", text: $endText)
                        .keyboardType(.numbersAndPunctuation)
                    Toggle("No break (on this booking)", isOn: $breakRemoved)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Custom hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                }
            }
        }
    }

    private func validateAndSave() {
        errorMessage = nil
        let s = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = endText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sm = ManagerScheduleInterval.parseMinutes(s),
              let em = ManagerScheduleInterval.parseMinutes(e),
              em > sm else {
            errorMessage = "Enter valid times (HH:mm) with end after start."
            return
        }
        onSave(s, e, breakRemoved)
    }
}

private struct BookLabourRoleChipRow: View {
    let person: BookLabourCandidate

    var body: some View {
        HStack(spacing: 4) {
            if person.user.permissions.operativeMode {
                chip("Operative", bg: Color(red: 0.902, green: 0.945, blue: 0.984), fg: ProjectWorksRevampColors.blue)
                if let trade = person.tradeDisplayString {
                    chip(trade, bg: ProjectWorksRevampColors.pinRoseBg, fg: ProjectWorksRevampColors.pinRoseFg)
                }
            } else {
                if person.user.permissions.manager {
                    chip("Manager", bg: ProjectWorksRevampColors.jobTypePillBg, fg: ProjectWorksRevampColors.jobTypePillInk)
                }
                if person.user.permissions.adminAccess {
                    chip("Admin", bg: ProjectWorksRevampColors.jobTypePillBg, fg: ProjectWorksRevampColors.jobTypePillInk)
                }
                if let trade = person.tradeDisplayString {
                    chip(trade, bg: ProjectWorksRevampColors.pinRoseBg, fg: ProjectWorksRevampColors.pinRoseFg)
                }
                if !person.user.permissions.manager && !person.user.permissions.adminAccess {
                    chip("User", bg: Color(red: 0.933, green: 0.937, blue: 0.941), fg: ProjectWorksRevampColors.muted)
                }
            }
        }
    }

    private func chip(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg)
            .clipShape(Capsule())
    }
}

private struct BookLabourRectifyTimeline: View {
    let day: Date
    let policy: OrgPayrollTimePolicy
    let existingIntervals: [(Int, Int)]
    let proposedStart: Int
    let proposedEnd: Int

    private var timeline: PayrollTimePolicyCatalog.DayTimelinePolicy {
        PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
    }

    private var standardStart: Int {
        timeline.standardWindowStartMinutes ?? 450
    }

    private var standardEnd: Int {
        timeline.standardWindowEndMinutes ?? 960
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.949, green: 0.953, blue: 0.961))

                    if !timeline.allHoursAtMultiplier {
                        segment(
                            color: Color.white.opacity(0.55),
                            start: standardStart,
                            end: standardEnd,
                            totalWidth: width
                        )
                    }

                    ForEach(Array(existingIntervals.enumerated()), id: \.offset) { _, iv in
                        segment(
                            color: ProjectWorksRevampColors.blue,
                            start: iv.0,
                            end: iv.1,
                            totalWidth: width
                        )
                    }

                    if proposedEnd > proposedStart {
                        if timeline.allHoursAtMultiplier {
                            segment(
                                color: ProjectWorksRevampColors.upcomingAmber,
                                start: proposedStart,
                                end: proposedEnd,
                                totalWidth: width
                            )
                        } else {
                            let standardCapEnd = min(proposedEnd, standardEnd)
                            if standardCapEnd > proposedStart {
                                segment(
                                    color: ProjectWorksRevampColors.activeGreen,
                                    start: proposedStart,
                                    end: standardCapEnd,
                                    totalWidth: width
                                )
                            }
                            if proposedStart < standardStart {
                                segment(
                                    color: ProjectWorksRevampColors.upcomingAmber,
                                    start: proposedStart,
                                    end: min(proposedEnd, standardStart),
                                    totalWidth: width
                                )
                            }
                            if proposedEnd > standardEnd {
                                segment(
                                    color: ProjectWorksRevampColors.upcomingAmber,
                                    start: max(standardEnd, proposedStart),
                                    end: proposedEnd,
                                    totalWidth: width
                                )
                            }
                        }
                    }
                }
            }
            .frame(height: 24)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(hour == 24 ? "24" : String(format: "%02d", hour))
                        .font(.system(size: 9))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    if hour != 24 { Spacer(minLength: 0) }
                }
            }
        }
        .padding(10)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func segment(color: Color, start: Int, end: Int, totalWidth: CGFloat) -> some View {
        let clampedStart = CGFloat(max(0, min(start, 24 * 60)))
        let clampedEnd = CGFloat(max(0, min(end, 24 * 60)))
        let left = (clampedStart / CGFloat(24 * 60)) * totalWidth
        let width = max(2, ((clampedEnd - clampedStart) / CGFloat(24 * 60)) * totalWidth)
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .frame(width: width, height: 24)
            .offset(x: left)
    }
}
