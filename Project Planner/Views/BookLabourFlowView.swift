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
        guard let op = linkedOperative else { return nil }
        let label = StaffTradeType.displayLabel(presetRaw: op.tradeTypePreset ?? "", custom: op.tradeTypeCustom ?? "")
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var canBookOtherLocations: Bool {
        !user.permissions.operativeMode && (user.permissions.manager || user.permissions.adminAccess || user.isSuperAdmin)
    }
}

struct BookLabourFlowView: View {
    let bookDate: Date

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    @State private var phase: Phase = .pickPerson
    @State private var errorBanner: String?
    @State private var isSaving = false
    @State private var projectListSearchText = ""
    @State private var bookLabourOperativeClockEdit: BookLabourOperativeClockEdit?
    @State private var pendingOperativeOverlap: PendingOperativeBookLabourOverlap?

    private let calendar = Calendar.current

    private struct PendingOperativeBookLabourOverlap {
        let message: String
        let detailLines: [String]
        let onConfirm: () -> Void
    }

    private var day: Date { calendar.startOfDay(for: bookDate) }

    private var scheduleOptions: MyScheduleOptions { appSettings.settings.myScheduleOptions }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var canBookStandardDayWindow: Bool {
        let p = payrollTimePolicy
        guard let s = ManagerScheduleInterval.parseMinutes(p.standardDayStart),
              let e = ManagerScheduleInterval.parseMinutes(p.standardDayEnd) else { return false }
        return e > s
    }

    private var liveProjects: [Project] {
        projectStore.projects.filter { $0.isLive && $0.jobType != .smallWorks }
    }

    private var liveSmallWorks: [Project] {
        projectStore.projects.filter { $0.isLive && $0.jobType == .smallWorks }
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

    private var bookFlowNavigationStack: some View {
        NavigationStack {
            phaseContent
                .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
                .navigationTitle("Book labour")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(ProjectWorksRevampColors.canvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
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
                .alert("Could not book", isPresented: Binding(
                    get: { errorBanner != nil },
                    set: { if !$0 { errorBanner = nil } }
                )) {
                    Button("OK") { errorBanner = nil }
                } message: {
                    Text(errorBanner ?? "")
                }
                .sheet(item: $bookLabourOperativeClockEdit) { ctx in
                    BookLabourOperativeHoursSheet(
                        policy: payrollTimePolicy,
                        onSave: { start, end, breakRemoved in
                            bookLabourOperativeClockEdit = nil
                            saveOperativeBooking(
                                operative: ctx.operative,
                                project: ctx.project,
                                slot: .customHours,
                                workStart: start,
                                workEnd: end,
                                breakRemoved: breakRemoved
                            )
                        },
                        onCancel: { bookLabourOperativeClockEdit = nil }
                    )
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
        case .pickSlotManager(let person, let locType, let locId, let customName, _):
            pickSlotManagerView(person: person, locationType: locType, locationId: locId, customLocationName: customName)
        case .pickSlotOperative(let person, let project):
            pickSlotOperativeView(person: person, project: project)
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
                    description: Text("No unbooked team members for this day, or only weekdays show unbooked labour.")
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
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(ProjectWorksRevampColors.requiredPillBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        bookLabourSectionLabel("Select a person")

                        VStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, person in
                                Button {
                                    phase = .pickDestination(person)
                                } label: {
                                    HStack(spacing: 12) {
                                        bookLabourAvatar(initials: PlannerUIInitials.from(person.displayName), isOperative: person.user.permissions.operativeMode)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(person.displayName)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(ProjectWorksRevampColors.ink)
                                            BookLabourRoleChipRow(person: person)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                                    }
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                if idx < candidates.count - 1 {
                                    Divider().overlay(ProjectWorksRevampColors.border)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )

                        Text("Tap a person to choose where to book them.")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.horizontal, 4)
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Step 2: Destination type

    private func pickDestinationView(person: BookLabourCandidate) -> some View {
        let otherEnabled = person.canBookOtherLocations && !scheduleOptions.enabledScheduleLocationPicks().isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                bookLabourPersonSummaryCard(person: person)
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
                if person.canBookOtherLocations && scheduleOptions.enabledScheduleLocationPicks().isEmpty {
                    Text("Enable at least one location under App & account → General → My schedule to use Other.")
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
                        bookLabourPersonSummaryCard(person: person)
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
                        .background(Color.white)
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
        let otherEnabled = person.canBookOtherLocations && !scheduleOptions.enabledScheduleLocationPicks().isEmpty
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
                        bookLabourPersonSummaryCard(person: person)
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
                                        if person.usesOperativeProjectBookings {
                                            guard person.linkedOperative != nil else {
                                                errorBanner = "No operative profile is linked to this user."
                                                return
                                            }
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
                        .background(Color.white)
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
        customLocationName: String?
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
                bookLabourPersonSummaryCard(person: person)
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
                            saveManagerBooking(
                                person: person,
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
                        .disabled(isSaving)
                    }
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func pickSlotOperativeView(person: BookLabourCandidate, project: Project) -> some View {
        if let op = person.linkedOperative {
            ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bookLabourPersonSummaryCard(person: person)
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
                    bookLabourSectionLabel("Select slot")
                    HStack(spacing: 10) {
                        ForEach([TimeSlot.fullDay, .morning, .afternoon], id: \.self) { slot in
                            Button {
                                saveOperativeBooking(operative: op, project: project, slot: slot)
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
                            .disabled(isSaving)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            saveOperativeBooking(
                                operative: op,
                                project: project,
                                slot: .customHours,
                                workStart: payrollTimePolicy.standardDayStart,
                                workEnd: payrollTimePolicy.standardDayEnd,
                                breakRemoved: false
                            )
                        } label: {
                            Text("Standard day")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(red: 0.902, green: 0.961, blue: 0.933))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .disabled(isSaving || !canBookStandardDayWindow)

                        Button {
                            bookLabourOperativeClockEdit = BookLabourOperativeClockEdit(operative: op, project: project)
                        } label: {
                            Text("Custom…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(red: 0.996, green: 0.949, blue: 0.878))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .disabled(isSaving)
                    }
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)

                if let pending = pendingOperativeOverlap {
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
                }
            }
        } else {
            Text("No operative profile for this user.")
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .padding()
        }
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

    private func bookLabourPersonSummaryCard(person: BookLabourCandidate) -> some View {
        HStack(spacing: 12) {
            bookLabourAvatar(initials: PlannerUIInitials.from(person.displayName), isOperative: person.user.permissions.operativeMode)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(bookFlowDayLine)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .padding(.horizontal, 2)
        .background(Color.white)
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

    private func saveManagerBooking(
        person: BookLabourCandidate,
        slot: ManagerTimeSlot,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?
    ) {
        let uid = person.user.id
        if duplicateManagerBooking(userId: uid, slot: slot, locationType: locationType, locationId: locationId, custom: customLocationName) {
            errorBanner = "That slot is already booked for this person."
            return
        }
        if managerWouldClash(userId: uid, date: day, newSlot: slot) {
            errorBanner = "This booking overlaps another in time on that day."
            return
        }
        let booking = ManagerSiteBooking(
            userId: uid,
            date: day,
            timeSlot: slot,
            locationType: locationType,
            locationId: locationId,
            customLocationName: customLocationName
        )
        isSaving = true
        Task {
            await managerScheduleStore.saveBooking(booking)
            await MainActor.run {
                isSaving = false
                dismiss()
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
                isBreakRemoved: breakRemoved
            )
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

    private func managerWouldClash(userId: String, date: Date, newSlot: ManagerTimeSlot) -> Bool {
        let existing = managerScheduleStore.bookings(for: userId, on: date)
        if existing.isEmpty { return false }
        let policy = payrollTimePolicy
        let probe = ManagerSiteBooking(
            userId: userId,
            date: date,
            timeSlot: newSlot,
            locationType: .office,
            locationId: nil
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

    private func buildCandidates() -> [BookLabourCandidate] {
        let weekday = calendar.component(.weekday, from: day)
        guard weekday >= 2 && weekday <= 6 else { return [] }

        let operativeUsers = userStore.organizationUsers.filter { $0.permissions.operativeMode && $0.isActive }
        let managerUsers = userStore.organizationUsers.filter {
            !$0.permissions.operativeMode &&
                !$0.isSuperAdmin &&
                !$0.permissions.adminAccess &&
                $0.permissions.manager &&
                $0.isActive
        }

        var out: [BookLabourCandidate] = []

        for user in operativeUsers {
            let linked = operativeStore.allOperatives.first { $0.email.lowercased() == user.email.lowercased() }
            if hasApprovedHoliday(userId: user.id, operativeId: linked?.id) { continue }
            guard let linked else { continue }
            if operativeHasFullDayBooking(operativeId: linked.id) { continue }
            out.append(BookLabourCandidate(user: user, linkedOperative: linked, usesOperativeProjectBookings: true))
        }

        for user in managerUsers {
            if hasApprovedHoliday(userId: user.id, operativeId: nil) { continue }
            if managerHasFullDayProjectBooking(userId: user.id) { continue }
            let linked = operativeStore.allOperatives.first { $0.email.lowercased() == user.email.lowercased() }
            out.append(BookLabourCandidate(user: user, linkedOperative: linked, usesOperativeProjectBookings: false))
        }

        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

    private func operativeHasFullDayBooking(operativeId: UUID) -> Bool {
        let policy = payrollTimePolicy
        let bookings = bookingStore.bookings.filter {
            $0.operativeId == operativeId &&
                calendar.isDate($0.date, inSameDayAs: day) &&
                ($0.status == .confirmed || $0.status == .tentative)
        }
        if bookings.contains(where: { $0.timeSlot == .fullDay }) { return true }
        let hasAM = bookings.contains(where: { $0.timeSlot == .morning })
        let hasPM = bookings.contains(where: { $0.timeSlot == .afternoon })
        if hasAM && hasPM { return true }
        return bookings.contains { OperativeBookingInterval.coversFullStandardDay($0, policy: policy) }
    }

    private func managerHasFullDayProjectBooking(userId: String) -> Bool {
        let policy = payrollTimePolicy
        let bookings = managerScheduleStore.managerSiteBookings.filter { booking in
            let sameDay = calendar.isDate(booking.date, inSameDayAs: day)
            let sameUser = booking.userId == userId
            let isProject = booking.locationType == .project || booking.locationType == .smallWork
            return sameDay && sameUser && isProject
        }
        if bookings.contains(where: { $0.timeSlot == .fullDay }) { return true }
        let hasAM = bookings.contains(where: { $0.timeSlot == .morning })
        let hasPM = bookings.contains(where: { $0.timeSlot == .afternoon })
        if hasAM && hasPM { return true }
        return bookings.contains { ManagerScheduleInterval.coversFullStandardDay($0, policy: policy) }
    }
}

private struct BookLabourOperativeClockEdit: Identifiable {
    let id = UUID()
    let operative: Operative
    let project: Project
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
