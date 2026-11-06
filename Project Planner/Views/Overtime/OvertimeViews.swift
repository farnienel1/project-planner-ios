//
//  OvertimeViews.swift
//  Project Planner
//
//  RULEBOOK 1.29.0 §25: Timesheets → "Overtime, Expenses & Price Work" — the same screens and flow as web
//  `components/overtime/OvertimeScreen.tsx`: the hub (My… / Users'…), Users' list with search and filter, the person's
//  Overtime / Expenses / Price work tiles (Expenses and Price work: `PayeClaimsViews.swift`, 1.30.0), Current PAYE payrun / Past PAYE payruns / Custom date range, the lines with
//  tick / X / cog, Send for approval, Approve (1.32.0: one button, partial approval with per-line outcomes), Generate
//  overtime report. Every figure, state,
//  permission and write shape comes from `CanonicalBusinessEngine` (`Rulebook+PayeOvertime.swift`); these views only pass
//  inputs and show results. Online only.
//

import SwiftUI
import UIKit
import FirebaseAuth

// MARK: - Shared helpers (inputs only, no rule)

extension UserStore {
    /// RULEBOOK 1.29.0 §25 `overtimeHubAccess({ viewer, roster })` for the signed-in (display) user.
    func overtimeHubAccess() -> OvertimeHubAccess {
        CanonicalBusinessEngine.overtimeHubAccess(
            viewer: displayUser.map { RulebookPeople.person($0) },
            roster: RulebookPeople.roster(organizationUsers)
        )
    }
}

/// Whose overtime a screen shows: the signed-in PAYE person's own (`mine`) or a person under Users' (`review`).
enum OvertimeScope: Hashable {
    case mine
    case review
}

/// An inclusive range of organisation-zone day keys.
struct OvertimeDayRange: Hashable {
    var start: String
    var end: String
}

/// A deep link into the Overtime screens (`notificationDestination` kinds `overtimeMine` / `overtimeUser`).
enum OvertimeDeepLink: Hashable {
    case mine
    case user(String)
}

@MainActor
enum OvertimeScreenSupport {
    static func todayKey() -> String { OrganizationRulebookContext.dayKey(Date()) }

    static func name(_ user: AppUser?) -> String {
        guard let user else { return "Unknown person" }
        let full = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? (user.email.isEmpty ? "Unknown person" : user.email) : full
    }

    /// RULEBOOK 1.32.0 `overtimePersonIds({ person, roster, operatives })`: all records for this person (every id they
    /// go by plus every operatives row on their email), for overtime loading, sending and approving, as web.
    /// Only the person's own id when the script did not answer.
    static func personIds(for user: AppUser, users: [AppUser], operatives: [Operative]) -> [String] {
        let rows: [[String: Any]] = operatives.map { ["id": $0.documentId, "email": $0.email] as [String: Any] }
        let ids = CanonicalBusinessEngine.overtimePersonIds(
            person: RulebookPeople.person(user),
            roster: RulebookPeople.roster(users),
            operatives: rows
        )
        return ids.isEmpty ? [user.id] : ids
    }

    /// Manager site bookings belong to managers and admins; an operative has none (and may not query them).
    static func managerSiteIds(for user: AppUser, users: [AppUser]) -> [String] {
        if user.permissions.operativeMode && !user.permissions.adminAccess && !user.isSuperAdmin { return [] }
        return RulebookPeople.ownerIds(for: user, users: users)
    }

    static func hours(_ value: Double) -> String { "\(ScheduleCoverageFormat.hours(value))h" }

    static func rangeTitle(_ range: OvertimeDayRange) -> String {
        "\(CanonicalBusinessEngine.formatPayePayrunDay(range.start)) – \(CanonicalBusinessEngine.formatPayePayrunDay(range.end))"
    }
}

/// A tappable card row used across the Overtime screens.
struct OvertimeTile: View {
    let title: String
    var subtitle: String? = nil
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .opacity(disabled ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

struct OvertimeScreenScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
    }
}

// MARK: - Hub

/// "Overtime, Expenses & Price Work" (`overtimeHubAccess`): My… for a PAYE person, Users'… for admins and line managers.
struct OvertimeHubView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    private var hubAccess: OvertimeHubAccess {
        CanonicalBusinessEngine.overtimeHubAccess(
            viewer: userStore.displayUser.map { RulebookPeople.person($0) },
            roster: RulebookPeople.roster(userStore.organizationUsers)
        )
    }

    /// RULEBOOK 1.32.0 §4.5 `payePaydayBanner`, as web's Overtime hub: shown while no PAYE payday is set; the admin
    /// wording for an admin outside operative mode (`isAdminOutsideOperativeMode`).
    private var payePaydayBanner: String? {
        CanonicalBusinessEngine.payePaydayBanner(
            organization: OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization),
            loaded: firebaseBackend.currentOrganization != nil,
            viewerIsAdmin: userStore.displayUser.map { CanonicalBusinessEngine.overtimeDeciderIsAdmin(RulebookPeople.person($0)) } ?? false
        )
    }

    var body: some View {
        let access = hubAccess
        OvertimeScreenScaffold(title: CanonicalBusinessEngine.overtimeText("OVERTIME_HUB_LABEL", fallback: "Overtime, Expenses & Price Work")) {
            if let banner = payePaydayBanner {
                PayePaydayBannerText(text: banner)
                    .accessibilityIdentifier("overtime.hub.payePaydayBanner")
            }
            if !access.showButton {
                Text("This section is for PAYE staff, admins and line managers.")
                    .foregroundStyle(.secondary)
            }
            if access.mine, let me = userStore.displayUser {
                NavigationLink {
                    OvertimePersonView(subjectId: me.id, scope: .mine)
                } label: {
                    OvertimeTile(
                        title: CanonicalBusinessEngine.overtimeText("OVERTIME_MINE_LABEL", fallback: "My Overtime, Expenses & Price Work"),
                        subtitle: "Your overtime, expenses and price work as PAYE."
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overtime.hub.mine")
            }
            if access.users {
                NavigationLink {
                    OvertimeUsersListView()
                } label: {
                    OvertimeTile(
                        title: CanonicalBusinessEngine.overtimeText("OVERTIME_USERS_LABEL", fallback: "Users' Overtime, Expenses & Price Work"),
                        subtitle: access.mine ? "The people you manage." : "Everyone you can see. Read-only except approvals."
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overtime.hub.users")
            }
        }
    }
}

/// A deep link's landing: the person's Overtime page (`overtimeMine`) or Users' → that person → Overtime (`overtimeUser`).
struct OvertimeDeepLinkView: View {
    @EnvironmentObject var userStore: UserStore
    let link: OvertimeDeepLink

    var body: some View {
        switch link {
        case .mine:
            if let me = userStore.displayUser {
                OvertimeRangesView(subjectId: me.id, scope: .mine)
            } else {
                ProgressView()
            }
        case .user(let id):
            OvertimeRangesView(subjectId: id, scope: .review)
        }
    }
}

// MARK: - Users' list

/// Users' Overtime, Expenses & Price Work: `overtimeUserSubjects` with search and a PAYE / self-employed filter.
struct OvertimeUsersListView: View {
    @EnvironmentObject var userStore: UserStore
    @State private var search = ""
    @State private var filter = 0

    private var subjects: [AppUser] {
        guard let viewer = userStore.displayUser else { return [] }
        let ids = Set(CanonicalBusinessEngine.overtimeUserSubjects(
            viewer: RulebookPeople.person(viewer),
            roster: RulebookPeople.roster(userStore.organizationUsers)
        ).map { $0.lowercased() })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return userStore.organizationUsers
            .filter { ids.contains($0.id.lowercased()) }
            .filter { filter == 0 || (filter == 1 ? $0.isPayeEmployment : !$0.isPayeEmployment) }
            .filter { query.isEmpty || OvertimeScreenSupport.name($0).lowercased().contains(query) }
            .sorted { OvertimeScreenSupport.name($0).localizedCaseInsensitiveCompare(OvertimeScreenSupport.name($1)) == .orderedAscending }
    }

    var body: some View {
        OvertimeScreenScaffold(title: CanonicalBusinessEngine.overtimeText("OVERTIME_USERS_LABEL", fallback: "Users' Overtime, Expenses & Price Work")) {
            TextField("Search people", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("overtime.users.search")
            Picker("Filter", selection: $filter) {
                Text("Everyone").tag(0)
                Text("PAYE").tag(1)
                Text("Self-employed").tag(2)
            }
            .pickerStyle(.segmented)
            let rows = subjects
            if rows.isEmpty {
                Text("Nobody to show.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { user in
                NavigationLink {
                    OvertimePersonView(subjectId: user.id, scope: .review)
                } label: {
                    OvertimeTile(title: OvertimeScreenSupport.name(user), subtitle: user.isPayeEmployment ? "PAYE" : "Self-employed")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Person: Overtime / Expenses / Price work

struct OvertimePersonView: View {
    @EnvironmentObject var userStore: UserStore
    let subjectId: String
    let scope: OvertimeScope

    private var subject: AppUser? { userStore.organizationUsers.first { $0.id == subjectId } ?? (userStore.displayUser?.id == subjectId ? userStore.displayUser : nil) }

    var body: some View {
        OvertimeScreenScaffold(title: scope == .mine
            ? CanonicalBusinessEngine.overtimeText("OVERTIME_MINE_LABEL", fallback: "My Overtime, Expenses & Price Work")
            : OvertimeScreenSupport.name(subject)) {
            NavigationLink {
                OvertimeRangesView(subjectId: subjectId, scope: scope)
            } label: {
                OvertimeTile(title: "Overtime")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overtime.person.overtime")
            NavigationLink {
                PayeClaimsSectionView(kind: .expense, subjectId: subjectId, scope: scope)
            } label: {
                OvertimeTile(title: "Expenses")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overtime.person.expenses")
            NavigationLink {
                PayeClaimsSectionView(kind: .priceWork, subjectId: subjectId, scope: scope)
            } label: {
                OvertimeTile(title: "Price work")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overtime.person.priceWork")
        }
    }
}

// MARK: - Ranges

/// Overtime: Current PAYE payrun / Past PAYE payruns / Custom date range, and the person's pending requests.
struct OvertimeRangesView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let subjectId: String
    let scope: OvertimeScope

    @State private var requests: [OvertimeRequestRecord] = []
    @State private var listener = OvertimeListeners()

    private var subject: AppUser? { userStore.organizationUsers.first { $0.id == subjectId } ?? (userStore.displayUser?.id == subjectId ? userStore.displayUser : nil) }
    private var organization: [String: Any] { OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization) }

    private var visible: Bool {
        guard scope == .review else { return true }
        guard let viewer = userStore.displayUser else { return false }
        return CanonicalBusinessEngine.overtimeUserSubjects(
            viewer: RulebookPeople.person(viewer),
            roster: RulebookPeople.roster(userStore.organizationUsers)
        ).contains { $0.caseInsensitiveCompare(subjectId) == .orderedSame }
    }

    var body: some View {
        let today = OvertimeScreenSupport.todayKey()
        let org = organization
        let current = CanonicalBusinessEngine.payePayrunPeriod(org, dayKey: today)
        let past = CanonicalBusinessEngine.payePastPayruns(org, todayKey: today)
        OvertimeScreenScaffold(title: "Overtime") {
            if let subject, visible {
                if scope == .review && !subject.isPayeEmployment {
                    Text("\(OvertimeScreenSupport.name(subject)) is self-employed: their overtime is on their timesheet. Open User Timesheets.")
                } else {
                    Text(current.map { CanonicalBusinessEngine.payePayrunLabel($0) }
                        ?? CanonicalBusinessEngine.overtimeText("PAYE_PAYDAY_NOT_SET_MESSAGE", fallback: "Ask an admin to set the PAYE payday"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let current {
                        NavigationLink {
                            OvertimeLinesView(subjectId: subjectId, scope: scope, range: OvertimeDayRange(start: current.start, end: current.end))
                        } label: {
                            OvertimeTile(title: "Current PAYE payrun")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("overtime.range.current")
                    } else {
                        OvertimeTile(title: "Current PAYE payrun", disabled: true)
                    }
                    NavigationLink {
                        OvertimePastPayrunsView(subjectId: subjectId, scope: scope)
                    } label: {
                        OvertimeTile(title: "Past PAYE payruns", disabled: current == nil && past.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("overtime.range.past")
                    NavigationLink {
                        OvertimeCustomRangeView(subjectId: subjectId, scope: scope)
                    } label: {
                        OvertimeTile(title: "Custom date range")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("overtime.range.custom")
                    let pending = requests.filter(\.isPending)
                    if !pending.isEmpty {
                        Text("WAITING FOR APPROVAL")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        ForEach(pending) { request in
                            NavigationLink {
                                OvertimeLinesView(
                                    subjectId: subjectId,
                                    scope: scope,
                                    range: OvertimeDayRange(start: request.rangeStart, end: request.rangeEnd)
                                )
                            } label: {
                                OvertimeTile(
                                    title: "Overtime request · \(OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: request.rangeStart, end: request.rangeEnd)))",
                                    subtitle: "\(request.lines.count) line(s)"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text(userStore.organizationUsers.isEmpty ? "Loading…" : "This person is not one you can see here.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            listener.stop()
            if let registration = firebaseBackend.listenOvertimeRequests(
                userId: subjectId,
                onChange: { requests = $0 },
                onError: { _ in requests = [] }
            ) {
                listener.add(registration)
            }
        }
        .onDisappear { listener.stop() }
    }
}

/// Past PAYE payruns (`payePastPayruns`, newest first) and the saved overtime reports (`overtimeReports`, read on open).
struct OvertimePastPayrunsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    let subjectId: String
    let scope: OvertimeScope

    @State private var reports: [OvertimeReportRecord] = []
    @State private var reportsError = false
    @State private var shareURL: URL?

    var body: some View {
        let today = OvertimeScreenSupport.todayKey()
        let org = OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization)
        let past = CanonicalBusinessEngine.payePastPayruns(org, todayKey: today)
        let current = CanonicalBusinessEngine.payePayrunPeriod(org, dayKey: today)
        OvertimeScreenScaffold(title: "Past PAYE payruns") {
            if past.isEmpty {
                Text(current != nil
                    ? "No past PAYE payruns yet."
                    : CanonicalBusinessEngine.overtimeText("PAYE_PAYDAY_NOT_SET_MESSAGE", fallback: "Ask an admin to set the PAYE payday"))
                    .foregroundStyle(.secondary)
            }
            ForEach(past) { run in
                NavigationLink {
                    OvertimeLinesView(subjectId: subjectId, scope: scope, range: OvertimeDayRange(start: run.start, end: run.end))
                } label: {
                    OvertimeTile(
                        title: OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: run.start, end: run.end)),
                        subtitle: "Paid \(CanonicalBusinessEngine.formatPayePayrunDay(run.payDate))"
                    )
                }
                .buttonStyle(.plain)
            }
            if reportsError {
                Text("Saved reports could not be loaded.").font(.footnote).foregroundStyle(.secondary)
            }
            if !reports.isEmpty {
                Text("SAVED OVERTIME REPORTS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                ForEach(reports) { report in
                    Button {
                        Task { await share(report) }
                    } label: {
                        OvertimeTile(
                            title: OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: report.rangeStart, end: report.rangeEnd)),
                            subtitle: "\(OvertimeScreenSupport.hours(report.overtimeHours)) overtime · \(generatedText(report)) · Share PDF"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            do {
                reports = try await firebaseBackend.loadOvertimeReports(userId: subjectId)
            } catch {
                reportsError = true
            }
        }
        .sheet(item: Binding(get: { shareURL.map(OvertimeShareItem.init) }, set: { shareURL = $0?.url })) { item in
            HSDocumentActivityView(activityItems: [item.url])
        }
    }

    private func generatedText(_ report: OvertimeReportRecord) -> String {
        guard let ms = report.generatedAtMs else { return "saving…" }
        return OvertimeReportPDFLayout.generatedText(ms: ms)
    }

    private func share(_ report: OvertimeReportRecord) async {
        let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
        shareURL = OvertimeReportPDF.makeFile(report: report, logo: logo)
    }
}

/// A share sheet item.
struct OvertimeShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Custom date range (`payeCustomRange`): reaches records older than the first payrun.
struct OvertimeCustomRangeView: View {
    let subjectId: String
    let scope: OvertimeScope
    @State private var start = Date()
    @State private var end = Date()
    @State private var picked: OvertimeDayRange?

    var body: some View {
        OvertimeScreenScaffold(title: "Custom date range") {
            DatePicker("Start", selection: $start, displayedComponents: .date)
            DatePicker("End", selection: $end, displayedComponents: .date)
            Button {
                if let range = CanonicalBusinessEngine.payeCustomRange(
                    start: OrganizationRulebookContext.dayKey(start),
                    end: OrganizationRulebookContext.dayKey(end)
                ) {
                    picked = OvertimeDayRange(start: range.start, end: range.end)
                }
            } label: {
                Text("View Overtime")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("overtime.custom.view")
        }
        .navigationDestination(item: $picked) { range in
            OvertimeLinesView(subjectId: subjectId, scope: scope, range: range)
        }
    }
}

// MARK: - The lines

struct OvertimeLinesView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var smartCache: SmartCacheService

    let subjectId: String
    let scope: OvertimeScope
    let range: OvertimeDayRange

    @State private var bookings: [OvertimeBookingInput] = []
    @State private var reviews: [OvertimeReviewRecord] = []
    @State private var requests: [OvertimeRequestRecord] = []
    @State private var loadError: String?
    @State private var draft: [String: OvertimeAction] = [:]
    @State private var decisions: [String: OvertimeAction] = [:]
    @State private var busy = false
    @State private var message: String?
    @State private var cog: OvertimeCogTarget?
    @State private var confirmCancel: OvertimeCancelPrompt?
    @State private var shareURL: URL?
    @State private var listeners = OvertimeListeners()

    private var subject: AppUser? {
        userStore.organizationUsers.first { $0.id == subjectId } ?? (userStore.displayUser?.id == subjectId ? userStore.displayUser : nil)
    }
    private var viewerUser: AppUser? { userStore.displayUser }
    private var organization: [String: Any] { OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization) }
    private var jobs: [Project] { projectStore.projects + projectStore.smallWorks }
    private var personIds: [String] {
        guard let subject else { return [subjectId] }
        return OvertimeScreenSupport.personIds(for: subject, users: userStore.organizationUsers, operatives: operativeStore.allOperatives)
    }
    private var roster: [[String: Any]] { RulebookPeople.roster(userStore.organizationUsers) }
    private var isOnline: Bool { smartCache.isOnline }

    var body: some View {
        let org = organization
        let ids = personIds
        let lines = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ids,
            bookings: bookings,
            organization: org,
            range: (range.start, range.end),
            reviews: reviews,
            requests: requests
        )
        let bookingById = Dictionary(bookings.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let pending = requests.filter { $0.isPending && $0.rangeStart <= range.end && $0.rangeEnd >= range.start }
        let today = OvertimeScreenSupport.todayKey()
        // RULEBOOK 1.32.0 (option 2): tick, cross and cog up to the end of the current PAYE payrun.
        let editableUntil = CanonicalBusinessEngine.overtimeEditableUntil(org, todayKey: today)
        let modes = Dictionary(
            lines.map { ($0.id, editMode($0, todayKey: today, editableUntilKey: editableUntil)) },
            uniquingKeysWith: { first, _ in first }
        )

        OvertimeScreenScaffold(title: "Overtime · \(OvertimeScreenSupport.rangeTitle(range))") {
            if let loadError {
                Text("Some overtime data could not be loaded: \(loadError)")
                    .font(.footnote)
                    .foregroundStyle(PPColor.danger)
            }
            if !isOnline {
                Text(OfflinePolicy.onlineOnlyMessage).font(.footnote).foregroundStyle(.secondary)
            }
            if lines.isEmpty {
                Text(CanonicalBusinessEngine.overtimeText("OVERTIME_NO_LINES_MESSAGE", fallback: "There is no overtime in this range."))
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                lineCard(line, booking: bookingById[line.bookingId.lowercased()], mode: modes[line.id] ?? .readOnly, organization: org)
            }
            if !lines.isEmpty {
                Text("\(CanonicalBusinessEngine.overtimeText("OVERTIME_REPORT_TOTAL_LABEL", fallback: "Total overtime")): \(OvertimeScreenSupport.hours(CanonicalBusinessEngine.overtimeLinesTotal(lines)))")
                    .font(.subheadline.weight(.bold))
            }

            if scope == .review {
                ForEach(pending) { request in
                    requestReviewCard(request, bookingById: bookingById, organization: org, requesterIds: ids)
                }
            }

            if scope == .mine {
                if lines.contains(where: { modes[$0.id] == .request }) {
                    Button {
                        Task { await sendForApproval(lines: lines, bookingById: bookingById, organization: org, modes: modes) }
                    } label: {
                        primaryLabel(CanonicalBusinessEngine.overtimeText("OVERTIME_SEND_FOR_APPROVAL_LABEL", fallback: "Send for approval"), color: .green)
                    }
                    .disabled(busy || !isOnline)
                    .accessibilityIdentifier("overtime.sendForApproval")
                }
                let canReport = CanonicalBusinessEngine.canGenerateOvertimeReport(lines)
                Button {
                    Task { await generateReport(lines: lines) }
                } label: {
                    primaryLabel(
                        CanonicalBusinessEngine.overtimeText("OVERTIME_GENERATE_REPORT_LABEL", fallback: "Generate overtime report"),
                        color: canReport ? .green : .gray
                    )
                }
                .disabled(busy || !canReport || !isOnline)
                .accessibilityIdentifier("overtime.generateReport")
                ForEach(pending) { request in
                    Button("Withdraw request (\(OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: request.rangeStart, end: request.rangeEnd))))") {
                        Task { await run { try await firebaseBackend.withdrawOvertimeRequest(request) } }
                    }
                    .disabled(busy || !isOnline)
                }
            }
            if let message {
                Text(message).font(.footnote)
            }
        }
        .onAppear(perform: startListening)
        .onDisappear { listeners.stop() }
        .sheet(item: $cog) { target in
            OvertimeCogSheet(booking: target.booking, organization: org) { start, end, multiplier in
                cog = nil
                let action = OvertimeAction.edit(start: start, end: end, multiplier: multiplier)
                switch target.kind {
                case .direct: Task { await direct(target.booking, action: action, organization: org) }
                case .draft: draft[target.booking.id] = action
                case .decision: decisions[target.booking.id] = action
                }
            } onCancel: {
                cog = nil
            }
        }
        .alert(
            confirmCancel?.warning.title ?? "Remove this booking?",
            isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
            presenting: confirmCancel
        ) { prompt in
            Button(prompt.warning.back, role: .cancel) { confirmCancel = nil }
            Button(prompt.warning.confirm, role: .destructive) {
                confirmCancel = nil
                prompt.apply()
            }
        } message: { prompt in
            Text("\(prompt.warning.summary)\n\n\(prompt.warning.body)\n\n\(prompt.warning.footnote)")
        }
        .sheet(item: Binding(get: { shareURL.map(OvertimeShareItem.init) }, set: { shareURL = $0?.url })) { item in
            HSDocumentActivityView(activityItems: [item.url])
        }
    }

    // MARK: Line card

    @ViewBuilder
    private func lineCard(_ line: OvertimeLine, booking: OvertimeBookingInput?, mode: OvertimeEditMode, organization: [String: Any]) -> some View {
        let proposal = draft[line.bookingId]
        let preview: OvertimeRequestLine? = {
            guard let booking, let proposal, proposal != .keep, proposal != .approve else { return nil }
            return CanonicalBusinessEngine.overtimeRequestLineFields(booking, organization: organization, proposal: proposal, personIds: nil)?.line
        }()
        let cancelled = line.state == "cancelled"
        // Look only: the picked choice is the unsent proposal, else the sent request line while it is still waiting,
        // else a tick for a line the rulebook already reads as approved.
        let sentLine: OvertimeRequestLine? = line.state == "waiting" ? line.requestLine : nil
        let chosen = OvertimeLinesView.choice(proposal: proposal, sentLine: sentLine, state: line.state)
        let afterLine: OvertimeRequestLine? = preview ?? ((proposal == nil && sentLine?.action != "keep") ? sentLine : nil)
        let struck = afterLine != nil || chosen == .cross
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.title)
                        .font(.body.weight(.semibold))
                        .strikethrough(cancelled)
                    Text(lineDetail(line))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // The old figure struck through on its own line, the new one under it (never overlapping on a phone).
                OvertimeLineFigureStack(
                    current: line.figures?.text,
                    struck: struck,
                    replacement: afterLine.map { $0.cancel ? "Booking cancelled" : OvertimeScreenSupport.hours($0.overtimeHoursAfter) }
                )
                .accessibilityIdentifier("overtime.line.figure")
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.stateLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(stateColor(line.state).opacity(0.15), in: Capsule())
                        .foregroundStyle(stateColor(line.state))
                    if let proposal {
                        Text("\(proposal.shortLabel) (not sent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let booking, mode != .readOnly {
                    OvertimeLineDecisionButtons(
                        chosen: chosen,
                        crossLabel: "I didn't work these overtime hours",
                        tickLabel: "Approve this line",
                        cogLabel: "Change start, finish or rate",
                        identifierPrefix: "overtime.line",
                        onCross: { onCross(line, booking: booking, mode: mode, organization: organization) },
                        onTick: { onTick(line, booking: booking, mode: mode, organization: organization) },
                        onCog: { cog = OvertimeCogTarget(booking: booking, kind: mode == .direct ? .direct : .draft) }
                    )
                    .disabled(busy || !isOnline)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .opacity(cancelled ? 0.6 : 1)
    }

    /// The choice a line shows as picked (look only): the unsent proposal, else the sent request line while it is
    /// still waiting, else a tick when the rulebook reads the line as approved.
    static func choice(proposal: OvertimeAction?, sentLine: OvertimeRequestLine?, state: String) -> OvertimeLineChoice? {
        if let proposal { return OvertimeLineChoice(proposal) }
        if let sentLine, let sent = OvertimeLineChoice(requestAction: sentLine.action) { return sent }
        return state == "approved" ? .tick : nil
    }

    private func lineDetail(_ line: OvertimeLine) -> String {
        var text = "\(line.dayLabel) · \(line.start.isEmpty || line.end.isEmpty ? line.timeSlot : "\(line.start)–\(line.end)")"
        if let requested = line.requestLine, requested.action == "edit", let start = requested.proposedStart, let end = requested.proposedEnd {
            text += " (asked \(start)–\(end))"
        }
        if let window = line.figures?.dayWindow { text += " · day \(window)" }
        return text
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "approved": return .green
        case "needsReview": return .orange
        case "changedSinceRequest": return PPColor.danger
        case "cancelled": return .secondary
        default: return .blue
        }
    }

    private func primaryLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
    }

    // MARK: Request review (Users' → person → Overtime)

    @ViewBuilder
    private func requestReviewCard(
        _ request: OvertimeRequestRecord,
        bookingById: [String: OvertimeBookingInput],
        organization: [String: Any],
        requesterIds: [String]
    ) -> some View {
        let mayDecide = self.canDecide
        // RULEBOOK 1.32.0: one Approve, enabled once any line is decided; it applies what this decider may.
        let ready = CanonicalBusinessEngine.overtimeRequestAnyDecided(request, decisions: decisions)
        // The same rule the approval transaction (and the security rules) apply, run on what this screen can read, so
        // the button is never offered for an approval that would apply nothing, and each line shows its outcome.
        let dryRun: OvertimeApprovalPlan? = {
            guard ready else { return nil }
            var live: [String: OvertimeBookingInput] = [:]
            var unreadable: [String] = []
            for line in request.lines {
                if let booking = bookingById[line.bookingId.lowercased()] { live[line.bookingId] = booking } else { unreadable.append(line.bookingId) }
            }
            return CanonicalBusinessEngine.overtimeApprovalWrites(
                request: request,
                decisions: decisions,
                bookings: live,
                organization: organization,
                deciderId: "preview",
                requesterIds: requesterIds,
                deciderIsAdmin: deciderIsAdmin,
                writableBookingIds: live.values.filter { deciderCanWrite($0) }.map(\.id),
                unreadableBookingIds: unreadable
            )
        }()
        let blocked = dryRun?.refusalMessage
        let outcomes = dryRun?.lineOutcomes ?? [:]
        let applied = Set(request.appliedBookingIds.map { $0.lowercased() })
        let openLines = request.lines.filter { !applied.contains($0.bookingId.lowercased()) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Overtime request · \(OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: request.rangeStart, end: request.rangeEnd)))")
                .font(.body.weight(.semibold))
            ForEach(openLines, id: \.bookingId) { line in
                let booking = bookingById[line.bookingId.lowercased()]
                let outcomeLabel = lineOutcomeLabel(line, booking: booking, outcomes: outcomes, requesterIds: requesterIds)
                let decision = decisions[line.bookingId]
                let chosen = decision.map { OvertimeLineChoice($0) }
                // The decider's ✕ or ⚙ as the hours it leaves (the same `overtimeRequestLineFields` the person's own
                // lines preview with), under the asked figure struck through.
                let decided: OvertimeRequestLine? = {
                    guard let booking, let decision, decision != .keep, decision != .approve else { return nil }
                    return CanonicalBusinessEngine.overtimeRequestLineFields(booking, organization: organization, proposal: decision, personIds: nil)?.line
                }()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(describe(line) + decisionSuffix(line) + bookingNote(booking, requesterIds: requesterIds))
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        OvertimeLineFigureStack(
                            current: line.cancel ? nil : OvertimeScreenSupport.hours(line.overtimeHoursAfter),
                            struck: decided != nil || chosen == .cross,
                            replacement: decided.map { $0.cancel ? "Booking cancelled" : OvertimeScreenSupport.hours($0.overtimeHoursAfter) }
                        )
                        .accessibilityIdentifier("overtime.review.figure")
                    }
                    if let outcomeLabel {
                        Text(outcomeLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("overtime.lineOutcome")
                    }
                    if mayDecide {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            if let booking {
                                OvertimeLineDecisionButtons(
                                    chosen: chosen,
                                    crossLabel: "Remove the overtime",
                                    tickLabel: "Approve as asked",
                                    cogLabel: "Counter-change",
                                    identifierPrefix: "overtime.review",
                                    onCross: { strike(booking, organization: organization) { decisions[line.bookingId] = .strike } },
                                    onTick: { decisions[line.bookingId] = .approve },
                                    onCog: { cog = OvertimeCogTarget(booking: booking, kind: .decision) }
                                )
                            } else {
                                Button("OK") { decisions[line.bookingId] = .approve }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .disabled(busy || !isOnline)
                    }
                }
            }
            if mayDecide {
                if let blocked {
                    Text(blocked).font(.footnote).foregroundStyle(PPColor.danger)
                }
                Button {
                    Task { await approve(request, organization: organization, requesterIds: requesterIds, bookingById: bookingById) }
                } label: {
                    primaryLabel(
                        CanonicalBusinessEngine.overtimeText("OVERTIME_APPROVE_LABEL", fallback: "Approve"),
                        color: ready && blocked == nil ? .green : .gray
                    )
                }
                .disabled(!ready || busy || blocked != nil || !isOnline)
                .accessibilityIdentifier("overtime.approveRequest")
            } else {
                Text("Waiting for their line manager or an admin.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func describe(_ line: OvertimeRequestLine) -> String {
        let day = CanonicalBusinessEngine.formatPayePayrunDay(line.dayKey)
        let before = OvertimeScreenSupport.hours(line.overtimeHoursBefore)
        let after = OvertimeScreenSupport.hours(line.overtimeHoursAfter)
        if line.cancel { return "\(day) · Asks to remove the booking" }
        if line.action == "edit" {
            let rate = line.proposedMultiplier.map { " at ×\(ScheduleCoverageFormat.hours($0))" } ?? ""
            return "\(day) · Asks \(line.proposedStart ?? "")–\(line.proposedEnd ?? "")\(rate): \(before) → \(after)"
        }
        if line.action == "strike" {
            return "\(day) · Asks to trim to \(line.proposedStart ?? "")–\(line.proposedEnd ?? ""): \(before) → \(after)"
        }
        return "\(day) · Approve as booked: \(before)"
    }

    private func decisionSuffix(_ line: OvertimeRequestLine) -> String {
        guard let decision = decisions[line.bookingId] else { return "" }
        switch decision {
        case .keep, .approve: return " · ticked"
        case .strike: return " · crossed"
        case .edit(let start, let end, _): return " · changed to \(start)–\(end)"
        }
    }

    /// `overtimeLineOutcomeLabel` ("Needs an admin", "Changed since the request — …") of the approval dry run, on a
    /// decided line of the requester's (unreadable and not-theirs lines already say so in `bookingNote`), as web.
    private func lineOutcomeLabel(
        _ line: OvertimeRequestLine,
        booking: OvertimeBookingInput?,
        outcomes: [String: String],
        requesterIds: [String]
    ) -> String? {
        guard decisions[line.bookingId] != nil, let booking,
              CanonicalBusinessEngine.overtimeBookingIsTheirs(booking, personIds: requesterIds) else { return nil }
        return CanonicalBusinessEngine.overtimeLineOutcomeLabel(outcomes[line.bookingId])
    }

    private func bookingNote(_ booking: OvertimeBookingInput?, requesterIds: [String]) -> String {
        guard let booking else {
            return " · " + CanonicalBusinessEngine.overtimeText("OVERTIME_BOOKING_UNREADABLE_MESSAGE", fallback: "Can't read this booking — it is left out of this approval.")
        }
        if !CanonicalBusinessEngine.overtimeBookingIsTheirs(booking, personIds: requesterIds) {
            return " · " + CanonicalBusinessEngine.overtimeText("OVERTIME_NOT_THEIR_BOOKING_MESSAGE", fallback: "This booking is not theirs — it is left out.")
        }
        return ""
    }

    // MARK: Who (rulebook answers)

    private func editMode(_ line: OvertimeLine, todayKey: String, editableUntilKey: String) -> OvertimeEditMode {
        guard scope == .mine, line.state != "cancelled", let viewer = viewerUser, let subject else { return .readOnly }
        var booking: [String: Any] = ["collection": line.collection, "dayKey": line.dayKey]
        if line.collection == "managerSiteBookings" {
            booking["userId"] = subjectId
            booking["locationType"] = line.jobId == nil ? "office" : "project"
            booking["locationId"] = RulebookJSON.orNull(line.jobId)
        } else {
            booking["projectId"] = RulebookJSON.orNull(line.jobId)
        }
        return CanonicalBusinessEngine.canEditOwnBookingOvertime(
            viewer: userStore.jobAccessViewer(for: viewer),
            isPaye: true,
            booking: booking,
            job: line.jobId.flatMap { JobAccessContext.jobFieldsById[$0.lowercased()] },
            managers: JobAccessContext.managers,
            todayKey: todayKey,
            editableUntilKey: editableUntilKey,
            // 1.32.0: a request when the person has an active line manager; direct for the Super Admin or none.
            person: RulebookPeople.person(subject),
            roster: roster
        )
    }

    private var canDecide: Bool {
        guard scope == .review, let viewer = viewerUser, let subject else { return false }
        return CanonicalBusinessEngine.canDecideOvertimeRequest(
            viewer: RulebookPeople.person(viewer),
            requester: RulebookPeople.person(subject),
            roster: roster
        )
    }

    private var deciderIsAdmin: Bool {
        guard let viewer = viewerUser else { return false }
        return CanonicalBusinessEngine.overtimeDeciderIsAdmin(RulebookPeople.person(viewer))
    }

    /// `canWriteBooking` for the decider (§16: an admin writes every booking; a line manager the jobs they manage).
    private func deciderCanWrite(_ booking: OvertimeBookingInput) -> Bool {
        guard let viewer = viewerUser else { return false }
        var row: [String: Any] = ["collection": booking.collection]
        if booking.collection == "managerSiteBookings" {
            row["userId"] = booking.personId
            row["locationType"] = booking.jobId == nil ? "office" : "project"
            row["locationId"] = RulebookJSON.orNull(booking.jobId)
        } else {
            row["projectId"] = RulebookJSON.orNull(booking.jobId)
        }
        return CanonicalBusinessEngine.canWriteBooking(
            userStore.jobAccessViewer(for: viewer),
            booking: row,
            job: booking.jobId.flatMap { JobAccessContext.jobFieldsById[$0.lowercased()] },
            managers: JobAccessContext.managers
        )
    }

    // MARK: Actions

    private func startListening() {
        listeners.stop()
        loadError = nil
        let onError: (Error) -> Void = { error in loadError = error.localizedDescription }
        let ids = personIds
        let managerIds = subject.map { OvertimeScreenSupport.managerSiteIds(for: $0, users: userStore.organizationUsers) } ?? []
        let store = projectStore
        firebaseBackend.listenPersonOvertimeBookings(
            operativeIds: ids,
            userIds: managerIds,
            jobs: { store.projects + store.smallWorks },
            into: listeners,
            onChange: { bookings = $0 },
            onError: onError
        )
        if let registration = firebaseBackend.listenOvertimeReviews(userId: subjectId, onChange: { reviews = $0 }, onError: onError) {
            listeners.add(registration)
        }
        if let registration = firebaseBackend.listenOvertimeRequests(userId: subjectId, onChange: { requests = $0 }, onError: onError) {
            listeners.add(registration)
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        message = nil
        do {
            try await work()
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }

    /// The red X: `overtimeStrikeOutcome` — trim, cancel after `OVERTIME_CANCEL_WARNING`, or not allowed.
    private func strike(_ booking: OvertimeBookingInput, organization: [String: Any], apply: @escaping () -> Void) {
        guard let outcome = CanonicalBusinessEngine.overtimeStrikeOutcome(booking, organization: organization) else { return }
        switch outcome.kind {
        case "notAllowed":
            message = outcome.message
        case "none":
            message = "Nothing on this booking is outside the working day."
        case "cancel":
            if let warning = outcome.warning ?? CanonicalBusinessEngine.overtimeCancelWarning {
                confirmCancel = OvertimeCancelPrompt(warning: warning, apply: apply)
            }
        default:
            apply()
        }
    }

    private func onTick(_ line: OvertimeLine, booking: OvertimeBookingInput, mode: OvertimeEditMode, organization: [String: Any]) {
        switch mode {
        case .direct: Task { await direct(booking, action: .approve, organization: organization) }
        case .request: draft[line.bookingId] = .keep
        case .readOnly: break
        }
    }

    private func onCross(_ line: OvertimeLine, booking: OvertimeBookingInput, mode: OvertimeEditMode, organization: [String: Any]) {
        switch mode {
        case .direct:
            strike(booking, organization: organization) { Task { await direct(booking, action: .strike, organization: organization) } }
        case .request:
            strike(booking, organization: organization) { draft[line.bookingId] = .strike }
        case .readOnly: break
        }
    }

    /// A direct change (`overtimeDirectWrites`); `booking_hours_changed_by_owner` when the booking changed.
    private func direct(_ booking: OvertimeBookingInput, action: OvertimeAction, organization: [String: Any]) async {
        guard let subject else { return }
        await run {
            guard let changed = try await firebaseBackend.applyDirectOvertime(
                booking: booking,
                action: action,
                person: subject,
                organization: organization
            ) else {
                message = "That change is not allowed on this booking."
                return
            }
            if changed {
                let job = booking.jobId.flatMap { JobAccessContext.jobFieldsById[$0.lowercased()] }
                await notificationService.notifyBookingHoursChangedByOwner(
                    owner: subject,
                    booking: booking,
                    jobManagerIds: CanonicalBusinessEngine.overtimeJobManagerIds(job)
                )
            }
        }
    }

    private func sendForApproval(
        lines: [OvertimeLine],
        bookingById: [String: OvertimeBookingInput],
        organization: [String: Any],
        modes: [String: OvertimeEditMode]
    ) async {
        guard let subject else { return }
        let ids = personIds
        var requestLines: [[String: Any]] = []
        for line in lines where modes[line.id] == .request {
            guard let booking = bookingById[line.bookingId.lowercased()] else { continue }
            if let built = CanonicalBusinessEngine.overtimeRequestLineFields(
                booking,
                organization: organization,
                proposal: draft[line.bookingId] ?? .keep,
                personIds: ids
            ) {
                requestLines.append(built.raw)
            }
        }
        guard !requestLines.isEmpty else {
            message = CanonicalBusinessEngine.overtimeText("OVERTIME_NO_LINES_MESSAGE", fallback: "There is no overtime in this range.")
            return
        }
        await run {
            guard let requestId = try await firebaseBackend.sendOvertimeRequest(
                requester: subject,
                rangeStart: range.start,
                rangeEnd: range.end,
                lines: requestLines,
                existing: requests,
                personIds: ids,
                bookings: bookings
            ) else {
                message = CanonicalBusinessEngine.overtimeText("OVERTIME_NO_LINES_MESSAGE", fallback: "There is no overtime in this range.")
                return
            }
            draft = [:]
            await notificationService.notifyOvertimeRequestSubmitted(
                requester: subject,
                requestId: requestId,
                rangeStart: range.start,
                rangeEnd: range.end
            )
            message = "Sent for approval."
        }
    }

    private func approve(
        _ request: OvertimeRequestRecord,
        organization: [String: Any],
        requesterIds: [String],
        bookingById: [String: OvertimeBookingInput]
    ) async {
        guard let viewer = viewerUser else { return }
        let writable = Set(bookingById.values.filter { deciderCanWrite($0) }.map { $0.id.lowercased() })
        let isAdmin = deciderIsAdmin
        let chosen = decisions
        await run {
            let result = try await firebaseBackend.approveOvertimeRequest(
                requestId: request.id,
                decisions: chosen,
                organization: organization,
                deciderId: viewer.id,
                requesterIds: requesterIds,
                deciderIsAdmin: isAdmin,
                canWriteBooking: { writable.contains($0.id.lowercased()) }
            )
            decisions = [:]
            await notificationService.notifyOvertimeRequestReviewed(
                requesterId: result.requesterUserId.isEmpty ? request.userId : result.requesterUserId,
                requestId: request.id,
                complete: result.complete,
                summary: result.message
            )
            // RULEBOOK 1.32.0 `reviewApprovalMessage`: "Approved 2 of 5. …".
            message = result.message
        }
    }

    /// Generate overtime report: the saved copy (`overtimeReportSnapshot`), then the PDF through the share sheet.
    private func generateReport(lines: [OvertimeLine]) async {
        guard let subject else { return }
        await run {
            guard let report = try await firebaseBackend.saveOvertimeReport(
                person: subject,
                companyName: firebaseBackend.currentOrganization?.name ?? "",
                rangeStart: range.start,
                rangeEnd: range.end,
                lines: lines
            ) else { return }
            let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
            shareURL = OvertimeReportPDF.makeFile(report: report, logo: logo)
            message = "Report saved. Send it to payroll yourself."
        }
    }
}

/// Which change the cog makes: the person's own booking directly, a request proposal, or the decider's counter-change.
struct OvertimeCogTarget: Identifiable {
    enum Kind { case direct, draft, decision }
    let booking: OvertimeBookingInput
    let kind: Kind
    var id: String { "\(booking.lookupKey)|\(kind)" }
}

/// The red X cancel warning waiting for "Remove booking".
struct OvertimeCancelPrompt {
    let warning: OvertimeStrikeOutcome.Warning
    let apply: () -> Void
}

// MARK: - The cog

/// Change start, finish and the overtime rate (1–3 in 0.25 steps) with the live figures (`overtimeCogPreview`): the old
/// figure struck through on its own line, the new one under it.
struct OvertimeCogSheet: View {
    let booking: OvertimeBookingInput
    let organization: [String: Any]
    let onSave: (String, String, Double?) -> Void
    let onCancel: () -> Void

    @State private var start: String
    @State private var end: String
    @State private var multiplier: Double?

    init(
        booking: OvertimeBookingInput,
        organization: [String: Any],
        onSave: @escaping (String, String, Double?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.booking = booking
        self.organization = organization
        self.onSave = onSave
        self.onCancel = onCancel
        _start = State(initialValue: (booking.workStartTime?.isEmpty == false ? booking.workStartTime : nil) ?? "07:30")
        _end = State(initialValue: (booking.workEndTime?.isEmpty == false ? booking.workEndTime : nil) ?? "16:00")
        _multiplier = State(initialValue: booking.otMultiplierOverride)
    }

    private static let quarterHours: [String] = (0..<96).map { String(format: "%02d:%02d", $0 / 4, ($0 % 4) * 15) }

    private func clockChoices(including value: String) -> [String] {
        Self.quarterHours.contains(value) ? Self.quarterHours : ([value] + Self.quarterHours)
    }

    private var rateChoices: [Double] {
        var steps = CanonicalBusinessEngine.overtimeMultiplierSteps
        if let stored = booking.otMultiplierOverride, !steps.contains(where: { abs($0 - stored) < 0.0001 }) { steps.append(stored) }
        return steps
    }

    var body: some View {
        let preview = CanonicalBusinessEngine.overtimeCogPreview(booking, organization: organization, start: start, end: end, multiplier: multiplier)
        let orgRate = CanonicalBusinessEngine.organizationOvertimeMultiplier(organization, dayKey: booking.dayKey) ?? 1.5
        let saveDisabled = preview == nil || preview?.error != nil || preview?.changed != true
        let changed = preview?.changed == true
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    bookingCard
                        .padding(.top, 4)

                    PPGroupLabel(text: "Hours and rate")
                    PPGroupedCard {
                        pickerRow(title: "Start", symbol: "play.fill", family: .plan, identifier: "overtime.cog.start") {
                            Picker("Start", selection: $start) {
                                ForEach(clockChoices(including: start), id: \.self) { Text($0).tag($0) }
                            }
                        }
                        PPRowDivider()
                        pickerRow(title: "Finish", symbol: "stop.fill", family: .plan, identifier: "overtime.cog.finish") {
                            Picker("Finish", selection: $end) {
                                ForEach(clockChoices(including: end), id: \.self) { Text($0).tag($0) }
                            }
                        }
                        PPRowDivider()
                        pickerRow(title: "Overtime rate", symbol: "bolt.fill", family: .trade, identifier: "overtime.cog.rate") {
                            Picker("Overtime rate", selection: $multiplier) {
                                Text("Organisation (×\(ScheduleCoverageFormat.hours(orgRate)))").tag(Double?.none)
                                ForEach(rateChoices, id: \.self) { step in
                                    Text("Custom ×\(ScheduleCoverageFormat.hours(step))").tag(Double?.some(step))
                                }
                            }
                        }
                    }

                    PPGroupLabel(text: "Overtime hours")
                    hoursBlock(preview: preview, changed: changed)
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.bottom, 24)
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Change hours or overtime rate")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(PPOnNavyPillButtonStyle())
                        .accessibilityIdentifier("overtime.cog.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(start, end, multiplier) }
                        .buttonStyle(PPOnNavyPillButtonStyle())
                        .disabled(saveDisabled)
                        .opacity(saveDisabled ? 0.5 : 1)
                        .accessibilityIdentifier("overtime.cog.save")
                }
            }
        }
    }

    /// The booking as a heading card: the day, then the job.
    private var bookingCard: some View {
        let job = [booking.jobNumber, booking.jobName].filter { !$0.isEmpty }.joined(separator: " ")
        return HStack(alignment: .top, spacing: 12) {
            PPIconTile(symbol: "clock.fill", family: .trade, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(CanonicalBusinessEngine.formatPayePayrunDay(booking.dayKey))
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                if !job.isEmpty {
                    Text(job)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overtime.cog.booking")
    }

    /// One labelled row of the grouped card: icon, label, and the menu picker on the right.
    private func pickerRow<Control: View>(
        title: String,
        symbol: String,
        family: PPFamily,
        identifier: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 13) {
            PPIconTile(symbol: symbol, family: family, size: PPMetrics.menuIcon)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            control()
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(PPColor.brand)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    /// The hours before and after: old struck through, new in bold. Unchanged shows the current figure only.
    private func hoursBlock(preview: OvertimeCogPreview?, changed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = preview?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PPColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overtime.cog.error")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(changed ? "Before" : "Now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(preview?.beforeText ?? "")
                    .font(.body.monospacedDigit())
                    .strikethrough(changed)
                    .foregroundStyle(changed ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overtime.cog.before")
            }
            if changed {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 0.5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("After")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.brand)
                    Text(preview?.afterText ?? "")
                        .font(.body.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("overtime.cog.after")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }
}

// MARK: - Report PDF

/// The overtime report PDF, rebuilt from the saved copy (`overtimeReportRows`): company name and logo, the person, the
/// range, one row per day and job (final figures, hours only) and the total. Drawn by `OvertimeReportPDFBuilder` in the
/// invoice / timesheet PDF style.
enum OvertimeReportPDF {
    static func loadLogo(_ urlString: String?) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        guard let result = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: result.0)
    }

    static func makeFile(report: OvertimeReportRecord, logo: UIImage?) -> URL? {
        guard let rows = CanonicalBusinessEngine.overtimeReportRows(report.raw) else { return nil }
        let savedLines = (report.raw["lines"] as? [Any])?.compactMap { $0 as? [String: Any] }
        let total = OvertimeReportPDFLayout.splitTotal(rows.total)
        let data = OvertimeReportPDFBuilder.makeData(OvertimeReportPDFBuilder.Content(
            title: OvertimeReportPDFLayout.documentTitle(rows.title),
            companyName: report.companyName,
            personName: report.userName,
            period: rows.subtitle,
            generated: OvertimeReportPDFLayout.generatedText(ms: report.generatedAtMs),
            rows: OvertimeReportPDFLayout.tableRows(savedLines: savedLines, rulebookRows: rows.rows),
            totalLabel: total.label,
            totalValue: total.value,
            emptyMessage: CanonicalBusinessEngine.overtimeText("OVERTIME_NO_LINES_MESSAGE", fallback: "There is no overtime in this range."),
            logo: logo
        ))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overtime-\(report.rangeStart)-\(report.rangeEnd).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
