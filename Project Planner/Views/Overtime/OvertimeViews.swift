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
//  RULEBOOK 1.33.0 (§25): Send → Return. ✓ ✕ ⚙ through `overtimeChoiceAfter` / `overtimeChoiceView` (person and decider);
//  Send for approval (`overtimeSubmitReady`, `overtimeSubmitLines`), Return overtime (`overtimeReturnReady`,
//  `overtimeReturnWrites`) and Generate overtime report (`overtimeGenerateReady`); saved reports marked Out of date
//  (`overtimeReportOutOfDate`); a notice opens the payrun it names (`overtimeNotificationRange`).
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

/// A deep link into the Overtime screens (`notificationDestination` kinds `overtimeMine` / `overtimeUser`). 1.33.0: the
/// notice's request id and `dayKey` pick the payrun to open (`overtimeNotificationRange`).
enum OvertimeDeepLink: Hashable {
    case mine(requestId: String?, dayKey: String?)
    case user(String, requestId: String?, dayKey: String?)
}

/// The request id and day of an overtime notice tap, held while Timesheets opens (`NotificationDeepLink` sets it,
/// `InvoicingView` takes it). Plumbing only.
@MainActor
enum OvertimeDeepLinkContext {
    static var pending: (requestId: String?, dayKey: String?)?

    static func take() -> (requestId: String?, dayKey: String?) {
        defer { pending = nil }
        return pending ?? (nil, nil)
    }
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

    /// The generator's name from the roster (the report's `generatedBy`), for `reportGeneratedText`.
    static func generatorName(_ generatedBy: String?, users: [AppUser]) -> String? {
        guard let id = generatedBy, !id.isEmpty, let user = users.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
        return name(user)
    }

    /// 1.33.0 `reportGeneratedText`: "6 Nov 2026, 14:05 by Sam Smith" in the organisation zone; "saving…" until the saved
    /// time is back.
    static func generatedText(_ report: OvertimeReportRecord, users: [AppUser]) -> String {
        guard report.generatedAtMs != nil else { return "saving…" }
        let generatedBy = report.raw["generatedBy"] as? String
        return CanonicalBusinessEngine.reportGeneratedText(
            generatedAtMs: report.generatedAtMs,
            generatedBy: generatedBy,
            userId: report.raw["userId"] as? String,
            userName: report.userName,
            generatedByName: generatorName(generatedBy, users: users),
            now: nil
        ).generated
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

/// A deep link's landing (1.33.0): the payrun the notice names (`overtimeNotificationRange` over the request's range or the
/// notice's day) on the person's Overtime page (`overtimeMine`) or Users' → that person → Overtime (`overtimeUser`); the
/// person's Overtime ranges when nothing usable is given.
struct OvertimeDeepLinkView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let link: OvertimeDeepLink

    @State private var requests: [OvertimeRequestRecord]?
    @State private var listener = OvertimeListeners()

    private var target: (subjectId: String?, scope: OvertimeScope, requestId: String?, dayKey: String?) {
        switch link {
        case .mine(let requestId, let dayKey): return (userStore.displayUser?.id, .mine, requestId, dayKey)
        case .user(let id, let requestId, let dayKey): return (id, .review, requestId, dayKey)
        }
    }

    var body: some View {
        let target = self.target
        Group {
            if let subjectId = target.subjectId {
                if let requests {
                    let request = target.requestId.flatMap { id in requests.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }
                    if let range = CanonicalBusinessEngine.overtimeNotificationRange(
                        organization: OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization),
                        todayKey: OvertimeScreenSupport.todayKey(),
                        rangeStart: request?.rangeStart,
                        rangeEnd: request?.rangeEnd,
                        dayKey: target.dayKey
                    ) {
                        OvertimeLinesView(subjectId: subjectId, scope: target.scope, range: OvertimeDayRange(start: range.start, end: range.end))
                    } else {
                        OvertimeRangesView(subjectId: subjectId, scope: target.scope)
                    }
                } else {
                    ProgressView("Opening overtime…")
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            listener.stop()
            guard let subjectId = target.subjectId else { return }
            if let registration = firebaseBackend.listenOvertimeRequests(
                userId: subjectId,
                onChange: { requests = $0 },
                onError: { _ in requests = [] }
            ) {
                listener.add(registration)
            } else {
                requests = []
            }
        }
        .onDisappear { listener.stop() }
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
    @EnvironmentObject var userStore: UserStore
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
                            subtitle: "\(OvertimeScreenSupport.hours(report.overtimeHours)) overtime · \(OvertimeScreenSupport.generatedText(report, users: userStore.organizationUsers)) · Share PDF"
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

    private func share(_ report: OvertimeReportRecord) async {
        let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
        shareURL = OvertimeReportPDF.makeFile(report: report, logo: logo, users: userStore.organizationUsers)
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
    @State private var reports: [OvertimeReportRecord] = []
    @State private var loadError: String?
    /// RULEBOOK 1.33.0 (Q-A7): the person's ✓ ✕ ⚙ before sending, and the decider's before returning, stay on this
    /// screen only (`overtimeChoiceAfter`).
    @State private var choices: [String: OvertimeChoice] = [:]
    @State private var deciderChoices: [String: OvertimeChoice] = [:]
    @State private var busy = false
    @State private var message: String?
    @State private var cog: OvertimeCogTarget?
    @State private var confirmDelete: OvertimeDeletePrompt?
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
    /// 1.33.0 `payeOvertimeLines` names: the decider's name on a returned line ("Changed by {name}").
    private var names: [String: String] {
        Dictionary(userStore.organizationUsers.map { ($0.id, OvertimeScreenSupport.name($0)) }, uniquingKeysWith: { first, _ in first })
    }
    /// 1.33.0 `payeOvertimeLines` jobs: the job of a deleted line (its booking is gone).
    private var jobRows: [[String: Any]] {
        jobs.map { ["id": $0.documentId, "jobNumber": $0.jobNumber, "jobName": $0.siteName] as [String: Any] }
    }
    /// `hasActiveLineManager(person, roster)`: Generate needs every line returned when there is a line manager.
    private var hasLineManager: Bool {
        guard let subject else { return false }
        return CanonicalBusinessEngine.overtimeHasActiveLineManager(person: RulebookPeople.person(subject), roster: roster)
    }

    var body: some View {
        let org = organization
        let ids = personIds
        let lines = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ids,
            bookings: bookings,
            organization: org,
            range: (range.start, range.end),
            reviews: reviews,
            requests: requests,
            names: names,
            jobs: jobRows
        )
        let bookingById = Dictionary(bookings.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let pending = requests
            .filter { $0.isPending && $0.rangeStart <= range.end && $0.rangeEnd >= range.start }
            .sorted { ($0.createdAtMs ?? 0) > ($1.createdAtMs ?? 0) }
        let rangeReports = reports.filter { $0.rangeStart == range.start && $0.rangeEnd == range.end }
        let today = OvertimeScreenSupport.todayKey()
        // RULEBOOK 1.32.0 (option 2): tick, cross and cog up to the end of the current PAYE payrun.
        let editableUntil = CanonicalBusinessEngine.overtimeEditableUntil(org, todayKey: today)
        let modes = Dictionary(
            lines.map { ($0.id, editMode($0, todayKey: today, editableUntilKey: editableUntil)) },
            uniquingKeysWith: { first, _ in first }
        )
        let requestLines = lines.filter { modes[$0.id] == .request }
        // RULEBOOK 1.33.0 button readiness: Send for approval and Generate overtime report.
        let submit = CanonicalBusinessEngine.overtimeSubmitReady(lines: requestLines, choices: choices)
        let generate = CanonicalBusinessEngine.overtimeGenerateReady(
            lines: lines,
            hasLineManager: hasLineManager,
            choices: choices,
            reports: rangeReports
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
                lineCard(
                    line,
                    booking: bookingById[line.bookingId.lowercased()],
                    mode: modes[line.id] ?? .readOnly,
                    organization: org,
                    pendingSend: submit.bookingIds ?? []
                )
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
                if !requestLines.isEmpty {
                    Button {
                        Task { await sendForApproval(lines: requestLines, organization: org, fallback: submit.message) }
                    } label: {
                        primaryLabel(
                            CanonicalBusinessEngine.overtimeText("OVERTIME_SEND_FOR_APPROVAL_LABEL", fallback: "Send for approval"),
                            color: submit.ready ? .green : .gray
                        )
                    }
                    .disabled(busy || !submit.ready || !isOnline)
                    .accessibilityIdentifier("overtime.sendForApproval")
                    if !submit.ready, let note = submit.message, !lines.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await generateReport(lines: lines) }
                } label: {
                    primaryLabel(
                        CanonicalBusinessEngine.overtimeText("OVERTIME_GENERATE_REPORT_LABEL", fallback: "Generate overtime report"),
                        color: generate.ready ? .green : .gray
                    )
                }
                .disabled(busy || !generate.ready || !isOnline)
                .accessibilityIdentifier("overtime.generateReport")
                if !generate.ready, let note = generate.message, !lines.isEmpty {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
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
            if !rangeReports.isEmpty {
                savedReports(rangeReports, lines: lines)
            }
        }
        .onAppear(perform: startListening)
        .onDisappear { listeners.stop() }
        .task(id: subjectId) { await loadReports() }
        .sheet(item: $cog) { target in
            OvertimeCogSheet(booking: target.booking, organization: org) { start, end, multiplier in
                cog = nil
                let event = OvertimeChoiceEvent.cog(start: start, end: end, multiplier: multiplier)
                switch target.kind {
                case .direct:
                    Task { await direct(target.booking, action: .edit(start: start, end: end, multiplier: multiplier), organization: org) }
                case .choice:
                    if let line = lines.first(where: { $0.bookingId.caseInsensitiveCompare(target.booking.id) == .orderedSame }) {
                        choose(line, event: event)
                    }
                case .decision:
                    if let next = CanonicalBusinessEngine.overtimeChoiceAfter(deciderChoices[target.booking.id], event: event) {
                        deciderChoices[target.booking.id] = next
                    }
                }
            } onCancel: {
                cog = nil
            }
        }
        .alert(
            confirmDelete?.warning.title ?? "Remove this booking?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { prompt in
            Button(prompt.warning.back, role: .cancel) { confirmDelete = nil }
            Button(prompt.warning.confirm, role: .destructive) {
                confirmDelete = nil
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
    private func lineCard(
        _ line: OvertimeLine,
        booking: OvertimeBookingInput?,
        mode: OvertimeEditMode,
        organization: [String: Any],
        pendingSend: [String]
    ) -> some View {
        let choice: OvertimeChoice? = mode == .request ? CanonicalBusinessEngine.overtimeLineChoice(line, choices: choices) : nil
        let look: OvertimeChoiceLook? = (booking != nil && choice != nil)
            ? CanonicalBusinessEngine.overtimeChoiceView(choice, booking: booking, organization: organization, role: "person")
            : nil
        let locked = line.state == "waiting"
        let gone = line.state == "cancelled" || line.state == "deleted"
        let struck = gone || line.state == "returnedDeclined"
        let returned = ["returnedApproved", "returnedChanged", "returnedDeclined"].contains(line.state)
        let unsent = look.map { !$0.label.isEmpty && !locked && (!returned || pendingSend.contains(line.bookingId)) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.title)
                        .font(.body.weight(.semibold))
                        .strikethrough(gone)
                    Text(lineDetail(line))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // The old figure struck through on its own line, the new one under it (`overtimeChoiceView`).
                OvertimeLineFigureStack(
                    current: line.figures?.text ?? "0h",
                    struck: struck || (look?.figureStruck ?? false) || line.figures == nil,
                    replacement: look?.newFigure
                )
                .accessibilityIdentifier("overtime.line.figure")
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    OvertimePill(text: line.stateLabel, color: stateColor(line.state))
                    if unsent, let look {
                        Text("\(look.label) (not sent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let booking, mode == .direct {
                    OvertimeLineDecisionButtons(
                        look: CanonicalBusinessEngine.overtimeChoiceView(nil, booking: booking, organization: organization, role: "person"),
                        crossLabel: "I didn't work these overtime hours",
                        tickLabel: "Confirm this line",
                        cogLabel: "Change start, finish or rate",
                        identifierPrefix: "overtime.line",
                        onCross: { onCross(line, booking: booking, mode: mode, organization: organization) },
                        onTick: { onTick(line, booking: booking, mode: mode, organization: organization) },
                        onCog: { cog = OvertimeCogTarget(booking: booking, kind: .direct) }
                    )
                    .disabled(busy || !isOnline)
                } else if let booking, mode == .request, let look {
                    OvertimeLineDecisionButtons(
                        look: look,
                        crossLabel: "I didn't work these overtime hours",
                        tickLabel: "Confirm this line",
                        cogLabel: "Change start, finish or rate",
                        identifierPrefix: "overtime.line",
                        onCross: { onCross(line, booking: booking, mode: mode, organization: organization) },
                        onTick: { onTick(line, booking: booking, mode: mode, organization: organization) },
                        onCog: { cog = OvertimeCogTarget(booking: booking, kind: .choice) }
                    )
                    .disabled(busy || locked || !isOnline)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .opacity(gone ? 0.6 : 1)
    }

    private func lineDetail(_ line: OvertimeLine) -> String {
        var text = "\(line.dayLabel) · \(line.start.isEmpty || line.end.isEmpty ? line.timeSlot : "\(line.start)–\(line.end)")"
        if let requested = line.requestLine, requested.action == "edit", let start = requested.proposedStart, let end = requested.proposedEnd {
            text += " (asked \(start)–\(end))"
        }
        if let window = line.figures?.dayWindow { text += " · day \(window)" }
        return text
    }

    /// The pill colour of a line state (as web `stateHue`): look only.
    private func stateColor(_ state: String) -> Color {
        switch state {
        case "returnedApproved", "returnedChanged", "confirmed": return .green
        case "returnedDeclined", "deleted", "cancelled": return PPColor.danger
        case "needsReview", "reopened", "changedSinceRequest": return .orange
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

    // MARK: Saved reports of this range (1.33.0: Out of date)

    @ViewBuilder
    private func savedReports(_ rangeReports: [OvertimeReportRecord], lines: [OvertimeLine]) -> some View {
        Text("SAVED REPORTS FOR THIS RANGE")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        ForEach(rangeReports) { report in
            let outOfDate = CanonicalBusinessEngine.overtimeReportOutOfDate(report, lines: lines)
            Button {
                Task { await share(report) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    OvertimeTile(
                        title: "\(OvertimeScreenSupport.hours(report.overtimeHours)) overtime",
                        subtitle: "\(OvertimeScreenSupport.generatedText(report, users: userStore.organizationUsers)) · Share PDF"
                    )
                    if outOfDate {
                        OvertimePill(
                            text: CanonicalBusinessEngine.overtimeText("OVERTIME_REPORT_OUT_OF_DATE_LABEL", fallback: "Out of date"),
                            color: .orange
                        )
                        .padding(.leading, 14)
                        .accessibilityIdentifier("overtime.report.outOfDate")
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func share(_ report: OvertimeReportRecord) async {
        let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
        shareURL = OvertimeReportPDF.makeFile(report: report, logo: logo, users: userStore.organizationUsers)
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
        let done = Set((request.appliedBookingIds + request.droppedBookingIds).map { $0.lowercased() })
        let openLines = request.lines.filter { !done.contains($0.bookingId.lowercased()) }
        // Bookings this screen cannot read, or that are not theirs, are left out of the Return (named) and never block it.
        let skip = request.lines.filter { line in
            guard let booking = bookingById[line.bookingId.lowercased()] else { return true }
            return !CanonicalBusinessEngine.overtimeBookingIsTheirs(booking, personIds: requesterIds)
        }.map(\.bookingId)
        let decisions = deciderDecisions(request)
        // RULEBOOK 1.33.0: Return overtime is green only once every waiting line is decided.
        let ready = CanonicalBusinessEngine.overtimeReturnReady(request, decisions: decisions, skipBookingIds: skip)
        VStack(alignment: .leading, spacing: 10) {
            Text("Overtime request · \(OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: request.rangeStart, end: request.rangeEnd)))")
                .font(.body.weight(.semibold))
            ForEach(openLines, id: \.bookingId) { line in
                let booking = bookingById[line.bookingId.lowercased()]
                let theirs = booking.map { CanonicalBusinessEngine.overtimeBookingIsTheirs($0, personIds: requesterIds) } ?? false
                let look: OvertimeChoiceLook? = booking.map {
                    CanonicalBusinessEngine.overtimeChoiceView(deciderChoices[line.bookingId], booking: $0, organization: organization, role: "decider")
                }
                let stale = booking.map { CanonicalBusinessEngine.overtimeLineIsStale(storedFingerprint: line.fingerprint, booking: $0) } ?? false
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(describe(line) + bookingNote(booking, theirs: theirs))
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let look, look.cog == "filled", let newFigure = look.newFigure {
                            OvertimeLineFigureStack(current: look.oldFigure, struck: true, replacement: newFigure)
                                .accessibilityIdentifier("overtime.review.figure")
                        }
                    }
                    HStack(spacing: 8) {
                        if let look, !look.label.isEmpty {
                            OvertimePill(
                                text: look.label,
                                color: look.cross == "filled" ? PPColor.danger : (look.tick == "filled" ? .green : .orange)
                            )
                        }
                        if stale && theirs, let label = CanonicalBusinessEngine.overtimeLineOutcomeLabel("stale") {
                            OvertimePill(text: label, color: .orange)
                                .accessibilityIdentifier("overtime.lineOutcome")
                        }
                        Spacer(minLength: 0)
                        if mayDecide, let booking, theirs, let look {
                            OvertimeLineDecisionButtons(
                                look: look,
                                crossLabel: "Decline this line",
                                tickLabel: "Approve this line",
                                cogLabel: "Change start, finish or rate",
                                identifierPrefix: "overtime.review",
                                onCross: { decide(line.bookingId, event: .cross) },
                                onTick: { decide(line.bookingId, event: .tick) },
                                onCog: { cog = OvertimeCogTarget(booking: booking, kind: .decision) }
                            )
                            .disabled(busy || !isOnline)
                        }
                    }
                }
            }
            if mayDecide {
                if !ready.ready, let note = ready.message {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await returnRequest(request, decisions: decisions, organization: organization, requesterIds: requesterIds) }
                } label: {
                    primaryLabel(
                        CanonicalBusinessEngine.overtimeText("OVERTIME_RETURN_LABEL", fallback: "Return overtime"),
                        color: ready.ready ? .green : .gray
                    )
                }
                .disabled(!ready.ready || busy || !isOnline)
                .accessibilityIdentifier("overtime.returnRequest")
            } else {
                Text("Waiting for their line manager or an admin.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    /// The decider's finished choices as decisions (`overtimeChoiceDecision`: ✓ approve, ⚙ + ✓ edit, ✕ strike).
    private func deciderDecisions(_ request: OvertimeRequestRecord) -> [String: OvertimeAction] {
        var decisions: [String: OvertimeAction] = [:]
        for line in request.lines {
            if let decision = CanonicalBusinessEngine.overtimeChoiceDecision(deciderChoices[line.bookingId]) {
                decisions[line.bookingId] = decision
            }
        }
        return decisions
    }

    /// The person's request line in words (as web `RequestReview`'s describe): the figures are the stored line's.
    private func describe(_ line: OvertimeRequestLine) -> String {
        let day = CanonicalBusinessEngine.formatPayePayrunDay(line.dayKey)
        let before = OvertimeScreenSupport.hours(line.overtimeHoursBefore)
        let after = OvertimeScreenSupport.hours(line.overtimeHoursAfter)
        if line.cancel { return "\(day) · Not worked — asks to remove the booking" }
        if line.action == "edit" {
            let rate = line.proposedMultiplier.map { " at ×\(ScheduleCoverageFormat.hours($0))" } ?? ""
            return "\(day) · Changed to \(line.proposedStart ?? "")–\(line.proposedEnd ?? "")\(rate): \(before) → \(after)"
        }
        if line.action == "strike" {
            return "\(day) · Not worked — trim to \(line.proposedStart ?? "")–\(line.proposedEnd ?? ""): \(before) → \(after)"
        }
        return "\(day) · Confirmed as booked: \(before)"
    }

    private func bookingNote(_ booking: OvertimeBookingInput?, theirs: Bool) -> String {
        guard booking != nil else {
            return " · " + CanonicalBusinessEngine.overtimeText("OVERTIME_BOOKING_UNREADABLE_MESSAGE", fallback: "Can't read this booking — it is left out of this Return.")
        }
        if !theirs {
            return " · " + CanonicalBusinessEngine.overtimeText("OVERTIME_NOT_THEIR_BOOKING_MESSAGE", fallback: "This booking is not theirs — it is left out.")
        }
        return ""
    }

    // MARK: Who (rulebook answers)

    private func editMode(_ line: OvertimeLine, todayKey: String, editableUntilKey: String) -> OvertimeEditMode {
        guard scope == .mine, line.state != "cancelled", line.state != "deleted", let viewer = viewerUser, let subject else { return .readOnly }
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

    private func loadReports() async {
        reports = (try? await firebaseBackend.loadOvertimeReports(userId: subjectId)) ?? []
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

    /// The person's red X: `overtimeStrikeOutcome` — trim, delete after `OVERTIME_DELETE_WARNING` (1.33.0), or not allowed.
    private func strike(_ booking: OvertimeBookingInput, organization: [String: Any], apply: @escaping () -> Void) {
        guard let outcome = CanonicalBusinessEngine.overtimeStrikeOutcome(booking, organization: organization) else { return }
        switch outcome.kind {
        case "notAllowed":
            message = outcome.message
        case "none":
            message = "Nothing on this booking is outside the working day."
        case "delete":
            if let warning = outcome.warning ?? CanonicalBusinessEngine.overtimeDeleteWarning {
                confirmDelete = OvertimeDeletePrompt(warning: warning, apply: apply)
            }
        default:
            apply()
        }
    }

    /// One ✓ ✕ ⚙ event on the person's line (`overtimeChoiceAfter` from `overtimeLineChoice`).
    private func choose(_ line: OvertimeLine, event: OvertimeChoiceEvent) {
        let current = CanonicalBusinessEngine.overtimeLineChoice(line, choices: choices)
        if let next = CanonicalBusinessEngine.overtimeChoiceAfter(current, event: event) {
            choices[line.bookingId] = next
        }
    }

    /// One ✓ ✕ ⚙ event on a decider's line.
    private func decide(_ bookingId: String, event: OvertimeChoiceEvent) {
        if let next = CanonicalBusinessEngine.overtimeChoiceAfter(deciderChoices[bookingId], event: event) {
            deciderChoices[bookingId] = next
        }
    }

    private func onTick(_ line: OvertimeLine, booking: OvertimeBookingInput, mode: OvertimeEditMode, organization: [String: Any]) {
        switch mode {
        case .direct: Task { await direct(booking, action: .approve, organization: organization) }
        case .request: choose(line, event: .tick)
        case .readOnly: break
        }
    }

    private func onCross(_ line: OvertimeLine, booking: OvertimeBookingInput, mode: OvertimeEditMode, organization: [String: Any]) {
        switch mode {
        case .direct:
            strike(booking, organization: organization) { Task { await direct(booking, action: .strike, organization: organization) } }
        case .request:
            // Clearing a ✕ needs no warning; setting one on an all-overtime day does.
            if CanonicalBusinessEngine.overtimeLineChoice(line, choices: choices)?.mark == "cross" {
                choose(line, event: .cross)
            } else {
                strike(booking, organization: organization) { choose(line, event: .cross) }
            }
        case .readOnly: break
        }
    }

    /// A direct change (`overtimeDirectWrites`); `booking_hours_changed_by_owner` when the booking changed or was deleted.
    private func direct(_ booking: OvertimeBookingInput, action: OvertimeAction, organization: [String: Any]) async {
        guard let subject else { return }
        await run {
            guard let plan = try await firebaseBackend.applyDirectOvertime(
                booking: booking,
                action: action,
                person: subject,
                organization: organization
            ) else {
                message = "That change is not allowed on this booking."
                return
            }
            if plan.hoursChanged {
                let job = booking.jobId.flatMap { JobAccessContext.jobFieldsById[$0.lowercased()] }
                await notificationService.notifyBookingHoursChangedByOwner(
                    owner: subject,
                    booking: booking,
                    jobManagerIds: CanonicalBusinessEngine.overtimeJobManagerIds(job),
                    removed: plan.bookingDelete != nil
                )
            }
        }
    }

    /// Send for approval (1.33.0): the request lines are `overtimeSubmitLines` (only lines marked or changed since the
    /// Return); then `overtime_request_submitted` to the line managers and admins.
    private func sendForApproval(lines: [OvertimeLine], organization: [String: Any], fallback: String?) async {
        guard let subject else { return }
        let ids = personIds
        let built = CanonicalBusinessEngine.overtimeSubmitLines(
            lines: lines,
            choices: choices,
            bookings: bookings,
            organization: organization,
            personIds: ids
        )
        guard !built.lines.isEmpty else {
            message = fallback ?? CanonicalBusinessEngine.overtimeText("OVERTIME_NO_LINES_MESSAGE", fallback: "There is no overtime in this range.")
            return
        }
        await run {
            guard let requestId = try await firebaseBackend.sendOvertimeRequest(
                requester: subject,
                rangeStart: range.start,
                rangeEnd: range.end,
                lines: built.lines,
                existing: requests,
                personIds: ids,
                bookings: bookings
            ) else {
                message = CanonicalBusinessEngine.overtimeText("OVERTIME_NO_LINES_MESSAGE", fallback: "There is no overtime in this range.")
                return
            }
            choices = [:]
            await notificationService.notifyOvertimeRequestSubmitted(
                requester: subject,
                requestId: requestId,
                rangeStart: range.start,
                rangeEnd: range.end
            )
            message = "Sent for approval."
        }
    }

    /// Return overtime (1.33.0, one transaction from `overtimeReturnWrites`), then "… has returned your overtime request".
    private func returnRequest(
        _ request: OvertimeRequestRecord,
        decisions: [String: OvertimeAction],
        organization: [String: Any],
        requesterIds: [String]
    ) async {
        guard let viewer = viewerUser else { return }
        await run {
            let result = try await firebaseBackend.returnOvertimeRequest(
                requestId: request.id,
                decisions: decisions,
                organization: organization,
                deciderId: firebaseBackend.auth.currentUser?.uid ?? viewer.id,
                requesterIds: requesterIds
            )
            deciderChoices = [:]
            await notificationService.notifyOvertimeReturned(
                requesterId: result.requesterUserId.isEmpty ? request.userId : result.requesterUserId,
                requestId: request.id,
                rangeStart: result.rangeStart.isEmpty ? request.rangeStart : result.rangeStart
            )
            // RULEBOOK 1.33.0 `overtimeReturnMessage`: "Returned 5 lines. …".
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
            reports.insert(report, at: 0)
            let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
            shareURL = OvertimeReportPDF.makeFile(report: report, logo: logo, users: userStore.organizationUsers)
            message = "Report saved. Send it to payroll yourself."
        }
    }
}

/// A small coloured state pill (look only).
struct OvertimePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which change the cog makes: the person's own booking directly, the person's choice, or the decider's choice.
struct OvertimeCogTarget: Identifiable {
    enum Kind { case direct, choice, decision }
    let booking: OvertimeBookingInput
    let kind: Kind
    var id: String { "\(booking.lookupKey)|\(kind)" }
}

/// The red X delete warning (`OVERTIME_DELETE_WARNING`) waiting for "Remove booking".
struct OvertimeDeletePrompt {
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

/// The overtime report PDF, rebuilt from the saved copy: RULEBOOK 1.33.0 every text is `overtimeReportRows` (header,
/// generated by / at, columns, rows, a declined line's note, total, footer, out-of-date note). Drawn by
/// `OvertimeReportPDFBuilder` in the invoice / timesheet PDF style.
enum OvertimeReportPDF {
    static func loadLogo(_ urlString: String?) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        guard let result = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: result.0)
    }

    @MainActor
    static func makeFile(report: OvertimeReportRecord, logo: UIImage?, users: [AppUser]) -> URL? {
        let generatorName = OvertimeScreenSupport.generatorName(report.raw["generatedBy"] as? String, users: users)
        guard let rows = CanonicalBusinessEngine.overtimeReportRows(report.raw, generatedByName: generatorName) else { return nil }
        let data = OvertimeReportPDFBuilder.makeData(OvertimeReportPDFBuilder.Content(rows, logo: logo))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overtime-\(report.rangeStart)-\(report.rangeEnd).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
