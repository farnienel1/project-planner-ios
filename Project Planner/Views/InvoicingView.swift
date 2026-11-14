//
//  InvoicingView.swift
//  Project Planner
//

import SwiftUI
import UIKit
import PencilKit
import FirebaseFirestore
import FirebaseAuth
import PhotosUI

struct InvoicingView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss
    @State private var landingVersion = 0
    @State private var pendingReviewUserId: String?
    @State private var pendingReviewWeek: WeekRange?
    @State private var didConsumeDeepLink = false
    @State private var pushMyTimesheets = false
    @State private var pushTeamTimesheets = false
    @State private var teamListSurface = "awaiting"
    /// RULEBOOK 1.29.0 §25: a notification tap into the Overtime screens (`overtimeMine` / `overtimeUser`).
    @State private var overtimeDeepLink: OvertimeDeepLink?
    /// Scope the landing sync last ran for. Nil until the first sync.
    @State private var landingScopeIds: [String]?

    @Binding var initialReviewUserId: String?
    @Binding var initialReviewWeekStart: Date?
    @Binding var initialSurface: String?

    private var settings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    private var canShowMyTimesheets: Bool { userStore.canAccessMyTimesheets() }
    private var canShowOperativeTimesheets: Bool { userStore.canAccessOperativeTimesheets() }
    private var showTimesheetsDisabledMessage: Bool { userStore.shouldShowTimesheetsDisabledMessage() }
    private var isAdminViewer: Bool {
        guard let u = userStore.displayUser else { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.role == .admin
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hubNavyHeader

                    VStack(alignment: .leading, spacing: 14) {
                        if showTimesheetsDisabledMessage && !canShowMyTimesheets && !canShowOperativeTimesheets {
                            timesheetsDisabledMessageCard
                            overtimeHubCard
                        } else if !userStore.canAccessTimesheetsSurface() {
                            if overtimeAccess.showButton {
                                overtimeHubCard
                            } else {
                            ContentUnavailableView(
                                "Timesheets unavailable",
                                systemImage: "lock.fill",
                                description: Text("No timesheet section is available for this account.")
                            )
                            }
                        } else {
                            if canShowOperativeTimesheets {
                                managerLandingCards
                            } else if canShowMyTimesheets {
                                operativeLandingCard
                                overtimeHubCard
                            } else if showTimesheetsDisabledMessage {
                                timesheetsDisabledMessageCard
                                overtimeHubCard
                            } else {
                                overtimeHubCard
                            }
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Timesheets")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                // Home presents Timesheets full screen; Done closes it.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("invoicing.done")
                }
            }
            .navigationDestination(isPresented: $pushMyTimesheets) {
                MyTimesheetsHubView(settings: settings)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(projectStore)
                    .environmentObject(managerScheduleStore)
                    .environmentObject(notificationService)
            }
            .navigationDestination(item: $overtimeDeepLink) { link in
                OvertimeDeepLinkView(link: link)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(projectStore)
                    .environmentObject(managerScheduleStore)
                    .environmentObject(notificationService)
            }
            .navigationDestination(isPresented: $pushTeamTimesheets) {
                OperativeTimesheetsView(
                    settings: settings,
                    week: pendingReviewWeek,
                    initialReviewUserId: pendingReviewUserId,
                    initialList: teamListSurface
                )
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(projectStore)
                    .environmentObject(managerScheduleStore)
                    .environmentObject(notificationService)
            }
            .task {
                captureTimesheetDeepLink()
                if firebaseBackend.noteScheduleNeedsFullHistory() {
                    bookingStore.loadData()
                    managerScheduleStore.loadData(force: true)
                }
                await syncLandingDraftsFromCloud()
            }
            // The first sync can run on an empty or cached roster. Fetch again for the people who arrive later.
            .task(id: usersForManagerTimesheetScope.map(\.id)) {
                let ids = usersForManagerTimesheetScope.map(\.id)
                guard let previous = landingScopeIds else {
                    landingScopeIds = ids
                    return
                }
                guard ids != previous else { return }
                landingScopeIds = ids
                guard canShowOperativeTimesheets, !ids.isEmpty else { return }
                await syncLandingDraftsFromCloud()
            }
        }
    }

    init(
        initialReviewUserId: Binding<String?> = .constant(nil),
        initialReviewWeekStart: Binding<Date?> = .constant(nil),
        initialSurface: Binding<String?> = .constant(nil)
    ) {
        _initialReviewUserId = initialReviewUserId
        _initialReviewWeekStart = initialReviewWeekStart
        _initialSurface = initialSurface
    }

    /// Home-style navy header. Shows the current payment run when the timesheet surface is available,
    /// following the same branches as the sheet below it.
    private var hubNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTimesheetsDisabledMessage && !canShowMyTimesheets && !canShowOperativeTimesheets {
                PPNavyPageTitle(title: "Timesheets")
            } else if !userStore.canAccessTimesheetsSurface() {
                PPNavyPageTitle(title: "Timesheets")
            } else {
                paymentSummaryCard
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var paymentRunTitle: String {
        if settings.paymentRunMode == .dateRanges, let first = settings.normalizedRanges.first {
            return "Day \(first.startDay) - Day \(first.endDay)"
        }
        return settings.recurringRunDisplaySummary
    }

    private var paymentDateLine: String {
        if settings.paymentDateMode == .specificDates {
            return "Paid on day \(settings.normalizedPaymentDates.map(String.init).joined(separator: " & "))"
        }
        return "Paid every \(settings.recurringPaymentDay.title)"
    }

    private var paymentSummaryCard: some View {
        let note = settings.normalizedUserNote
        return VStack(alignment: .leading, spacing: 0) {
            Text("CURRENT PAYMENT RUN")
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(PPColor.onNavySecondary)

            Text(paymentRunTitle)
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)

            PPOnNavyPill(text: paymentDateLine, symbol: "banknote")
                .padding(.top, 12)

            if !note.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.quote")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PPColor.onNavySecondary)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PPColor.onNavyFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
                )
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func timesheetEntryCard(title: String, detail: String, symbol: String) -> some View {
        PPGroupedCard {
            PPMenuRowLabel(title: title, symbol: symbol, family: .plan, subtitle: detail)
                .padding(.vertical, 4)
        }
    }

    private var timesheetsDisabledMessageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PPIconTile(symbol: "clock.badge.xmark", family: .trade, size: 38)
                Text("Timesheets follow employment type")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Text("My Timesheets is for self-employed pay. PAYE accounts keep the current pay run until it is paid, then schedule hours no longer fill the next timesheet. Switch the person back to self-employed if they need timesheets again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    /// RULEBOOK 1.29.0 §25: `overtimeHubAccess` — My… for a PAYE person, Users'… for admins and line managers.
    private var overtimeAccess: OvertimeHubAccess {
        userStore.overtimeHubAccess()
    }

    private var overtimeHubSubtitle: String {
        let access = overtimeAccess
        if access.mine && access.users { return "Your PAYE overtime, and your team's" }
        if access.mine { return "Your PAYE overtime" }
        return "Your team's overtime, expenses and price work"
    }

    private var overtimeHubDestination: some View {
        OvertimeHubView()
            .environmentObject(firebaseBackend)
            .environmentObject(userStore)
            .environmentObject(bookingStore)
            .environmentObject(operativeStore)
            .environmentObject(projectStore)
            .environmentObject(managerScheduleStore)
            .environmentObject(notificationService)
    }

    /// The hub card on the landings that have no manager tiles (PAYE operative, self-employed operative).
    @ViewBuilder
    private var overtimeHubCard: some View {
        if overtimeAccess.showButton {
            NavigationLink {
                overtimeHubDestination
            } label: {
                timesheetEntryCard(
                    title: CanonicalBusinessEngine.overtimeText("OVERTIME_HUB_LABEL", fallback: "Overtime, Expenses & Price Work"),
                    detail: overtimeHubSubtitle,
                    symbol: "clock.badge.checkmark"
                )
            }
            .accessibilityIdentifier("invoicing.overtimeCard")
            .buttonStyle(PPPressableButtonStyle())
        }
    }

    @ViewBuilder
    private var operativeLandingCard: some View {
        NavigationLink {
            MyTimesheetsHubView(settings: settings)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(notificationService)
        } label: {
            timesheetEntryCard(
                title: "My Timesheets",
                detail: "Current pay run, pending sign-off, and past timesheets.",
                symbol: "clock.fill"
            )
        }
        .accessibilityIdentifier("invoicing.myTimesheets")
        .buttonStyle(PPPressableButtonStyle())
    }

    @ViewBuilder
    private var previousTimesheetsCard: some View {
        NavigationLink {
            PreviousTimesheetsView(settings: settings)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(managerScheduleStore)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous Timesheets")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("View previous payment runs and statuses.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .accessibilityIdentifier("invoicing.clockArrowCirclepath")
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var managerLandingCards: some View {
        let _ = landingVersion
        let reviewUsers = managerReviewUsersIncludingPending()
        let openWeek = pendingReviewWeek ?? WeekRange.current(settings: settings)
        let awaiting = landingAwaitingTimesheetCount(users: reviewUsers)
        let signed = reviewUsers.filter {
            let draft = TimesheetDraftStore.load(userId: $0.id, weekStart: openWeek.start)
            return TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: $0) && !TimesheetApprovalPolicy.isExported(draft)
        }.count
        let exported = reviewUsers.filter {
            TimesheetApprovalPolicy.isExported(TimesheetDraftStore.load(userId: $0.id, weekStart: openWeek.start))
        }.count

        VStack(alignment: .leading, spacing: 14) {
            PPGroupedCard {
                if canShowMyTimesheets {
                    NavigationLink {
                        MyTimesheetsHubView(settings: settings)
                            .environmentObject(firebaseBackend)
                            .environmentObject(userStore)
                            .environmentObject(bookingStore)
                            .environmentObject(operativeStore)
                            .environmentObject(projectStore)
                            .environmentObject(managerScheduleStore)
                            .environmentObject(notificationService)
                    } label: {
                        managerTile(title: "My Timesheets", subtitle: "Your own hours, expenses and price work", symbol: "clock.fill", badge: nil)
                    }
                    .accessibilityIdentifier("invoicing.myTimesheets2")
                    .buttonStyle(PPMenuRowButtonStyle())
                    PPRowDivider()
                }
                // RULEBOOK 1.29.0 §25 `overtimeHubAccess`: below My Timesheets, above User Timesheets.
                if overtimeAccess.showButton {
                    NavigationLink {
                        overtimeHubDestination
                    } label: {
                        managerTile(
                            title: CanonicalBusinessEngine.overtimeText("OVERTIME_HUB_LABEL", fallback: "Overtime, Expenses & Price Work"),
                            subtitle: overtimeHubSubtitle,
                            symbol: "clock.badge.checkmark",
                            badge: nil
                        )
                    }
                    .accessibilityIdentifier("invoicing.overtime")
                    .buttonStyle(PPMenuRowButtonStyle())
                    PPRowDivider()
                }
                NavigationLink {
                    OperativeTimesheetsView(
                        settings: settings,
                        week: pendingReviewWeek,
                        initialReviewUserId: pendingReviewUserId
                    )
                        .environmentObject(firebaseBackend)
                        .environmentObject(userStore)
                        .environmentObject(bookingStore)
                        .environmentObject(operativeStore)
                        .environmentObject(projectStore)
                        .environmentObject(managerScheduleStore)
                        .environmentObject(notificationService)
                } label: {
                    managerTile(
                        title: isAdminViewer ? "User Timesheets" : "Operative Timesheets",
                        subtitle: isAdminViewer
                            ? "Review, sign off and export company timesheets"
                            : "Review, sign off and export your team's sheets",
                        symbol: "person.3.fill",
                        badge: awaiting > 0 ? "\(awaiting) new" : nil,
                        family: .people
                    )
                }
                .accessibilityIdentifier("invoicing.userTimesheets")
                .buttonStyle(PPMenuRowButtonStyle())
            }
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))

            HStack(alignment: .top, spacing: 0) {
                statMiniCard(value: "\(awaiting)", label: "Awaiting sign-off", color: PPFamily.trade.bottom)
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 0.5)
                    .padding(.vertical, 12)
                    .accessibilityHidden(true)
                statMiniCard(value: "\(signed)", label: "Signed off", color: PPFamily.sites.bottom)
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 0.5)
                    .padding(.vertical, 12)
                    .accessibilityHidden(true)
                statMiniCard(value: "\(exported)", label: "Exported", color: .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private func managerTile(title: String, subtitle: String, symbol: String, badge: String?, family: PPFamily = .plan) -> some View {
        HStack(spacing: 13) {
            PPIconTile(symbol: symbol, family: family, size: PPMetrics.menuIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PPColor.brand, in: Capsule())
                    .foregroundStyle(.white)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statMiniCard(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var usersForManagerTimesheetScope: [AppUser] {
        userStore.userTimesheetSubjectUsers()
    }

    private var usersForManagerReview: [AppUser] {
        let week = pendingReviewWeek ?? WeekRange.current(settings: settings)
        return usersForManagerTimesheetScope.filter {
            TimesheetPayrollPolicy.shouldAppearInOperativeTimesheetRoster(user: $0, week: week, settings: settings)
        }
    }

    private func managerReviewUsersIncludingPending() -> [AppUser] {
        var users = usersForManagerTimesheetScope
        if let extraId = pendingReviewUserId,
           let extra = userStore.organizationUsers.first(where: { $0.id == extraId }),
           !users.contains(where: { $0.id == extra.id }) {
            users.append(extra)
        }
        return users
    }

    private func landingAwaitingTimesheetCount(users: [AppUser]) -> Int {
        var seen = Set<String>()
        for user in users {
            let documentStarts = TimesheetDraftStore.discoverStoredWeekStarts(userId: user.id)
            for periodStart in TimesheetApprovalPolicy.awaitingPayPeriodStarts(
                user: user,
                documentStarts: documentStarts,
                settings: settings
            ) {
                seen.insert("\(user.id)|\(Int(periodStart.timeIntervalSince1970))")
            }
        }
        return seen.count
    }

    private func syncLandingDraftsFromCloud() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        var ids = Set(usersForManagerTimesheetScope.map(\.id) + (userStore.displayUser.map { [$0.id] } ?? []))
        if let pendingReviewUserId, !pendingReviewUserId.isEmpty {
            ids.insert(pendingReviewUserId)
        }
        let weekStarts = TimesheetDraftStore.weeksToPrefetchForManagerReview(
            settings: settings,
            extraWeekStart: pendingReviewWeek?.start
        )
        for userId in ids {
            for weekStart in weekStarts {
                _ = await TimesheetDraftStore.refreshFromCloud(
                    userId: userId,
                    weekStart: weekStart,
                    firebaseBackend: firebaseBackend,
                    organizationId: orgId
                )
            }
        }
        let listIds: Set<String>
        if isAdminViewer && ids.count > 25 {
            listIds = pendingReviewUserId.map { Set([$0]) } ?? []
        } else {
            listIds = ids
        }
        for userId in listIds {
            if let rows = try? await firebaseBackend.listTimesheetStates(
                organizationId: orgId,
                userId: userId,
                limit: 200
            ) {
                for row in rows {
                    _ = TimesheetDraftStore.ingestCloudRow(row, userId: userId, organizationId: orgId)
                }
            }
        }
        await MainActor.run { landingVersion += 1 }
    }

    private func captureTimesheetDeepLink() {
        guard !didConsumeDeepLink else { return }
        didConsumeDeepLink = true
        let rawId = initialReviewUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let weekStart = initialReviewWeekStart
        let surface = initialSurface
        initialReviewUserId = nil
        initialReviewWeekStart = nil
        initialSurface = nil
        if !rawId.isEmpty {
            pendingReviewUserId = rawId
        }
        if let weekStart {
            let storedEnd = pendingReviewUserId.flatMap {
                TimesheetDraftStore.storedPeriodEnd(userId: $0, weekStart: weekStart)
            }
            pendingReviewWeek = TimesheetPayrollPolicy.periodMatchingStoredStart(
                weekStart,
                storedEnd: storedEnd,
                settings: settings
            )
        }
        switch surface {
        case "mine":
            pushMyTimesheets = true
        case "teamAwaiting":
            teamListSurface = "awaiting"
            pushTeamTimesheets = true
        case "teamSigned":
            teamListSurface = "signed"
            pushTeamTimesheets = true
        case "overtimeMine":
            let notice = OvertimeDeepLinkContext.take()
            overtimeDeepLink = .mine(requestId: notice.requestId, dayKey: notice.dayKey)
        case "overtimeUser":
            let notice = OvertimeDeepLinkContext.take()
            overtimeDeepLink = rawId.isEmpty ? nil : .user(rawId, requestId: notice.requestId, dayKey: notice.dayKey)
        default:
            break
        }
    }
}

enum TimesheetApprovalPolicy {
    static func lineManagerUserIds(for user: AppUser) -> [String] {
        user.lineManagerUserIds
    }

    /// RULEBOOK §8: the sheet waits for a line manager (or, with none, an admin) unless it is self-signed —
    /// `timesheetSelfSigned(user, roster)` (RULEBOOK 1.28.0): an admin with Timesheet self-sign on, or the
    /// organisation's Super Admin, line manager or not. Every operative and manager needs a counter-signature. When
    /// the script did not answer the sheet is not self-signed (it waits for a counter-signature): having no line
    /// manager has not self-signed anyone since 1.28.0, and no Swift copy of the rule decides it.
    static func requiresLineManagerCounterSign(for user: AppUser) -> Bool {
        guard let selfSigned = RulebookRosterSnapshot.timesheetSelfSigned(user) else { return true }
        return !selfSigned
    }

    /// `timesheetWriterIsReviewer`: whether this save is the reviewer's (line manager or admin), the
    /// same test as firestore.rules `isTimesheetReviewer`. RULEBOOK 1.30.2: never the subject under any of
    /// their ids (`writerAliasIds`, and `personIdSet` over the live roster) — an admin's own sheet is the
    /// owner's, and a self-signed owner signs through the owner path. Without the subject's profile (or when
    /// the script did not answer) a write by anyone other than the subject counts as the reviewer's, as
    /// web's `saveTimesheetDraft` does, since only a reviewer may write someone else's sheet.
    static func writerIsReviewer(writerId: String, writer: AppUser?, subjectUserId: String, subject: AppUser?) -> Bool {
        let writerIds = Set(([writerId] + (writer.map { [$0.id] + $0.formerUserIds + $0.sameEmailUserIds } ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let fallback = !writerId.isEmpty
            && !writerIds.contains(subjectUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let answer = CanonicalBusinessEngine.timesheetWriterIsReviewer(
            writerUserId: writerId,
            subjectUserId: subjectUserId,
            writerIsAdmin: writer?.isRosterAdmin ?? false,
            writerFormerIds: writer?.formerUserIds ?? [],
            writerAliasIds: writer?.sameEmailUserIds ?? [],
            subjectLineManagerIds: subject?.lineManagerUserIds ?? [],
            roster: RulebookRosterSnapshot.roster
        )
        if answer == true { return true }
        if subject == nil || answer == nil { return fallback }
        return false
    }

    /// A stored instant the script still treats as a signature. Nil when the script did not answer.
    static func recordedSignatureDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        var probe = TimesheetDraft()
        probe.managerSignedAt = date
        probe.managerSignedByName = "Manager"
        guard let fields = TimesheetDraftStore.statusFields(for: probe),
              let ms = fields.managerSignedAtMs else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func operativeHasSigned(_ draft: TimesheetDraft) -> Bool {
        guard let fields = TimesheetDraftStore.statusFields(for: draft) else { return false }
        let signedWithoutManager = CanonicalBusinessEngine.isTimesheetFullySigned(fields, hasLineManager: false) == true
        let waitingForManager = CanonicalBusinessEngine.isTimesheetAwaitingSignOff(fields, hasLineManager: true) == true
        return signedWithoutManager || waitingForManager
    }

    static func isExported(_ draft: TimesheetDraft) -> Bool {
        guard let fields = TimesheetDraftStore.statusFields(for: draft) else { return false }
        return CanonicalBusinessEngine.isTimesheetExported(fields) == true
    }

    static func isTimesheetFullyApproved(draft: TimesheetDraft, user: AppUser) -> Bool {
        guard let fields = TimesheetDraftStore.statusFields(for: draft) else { return false }
        return CanonicalBusinessEngine.isTimesheetFullySigned(fields, hasLineManager: requiresLineManagerCounterSign(for: user)) == true
    }

    static func awaitingManagerSignOff(draft: TimesheetDraft, user: AppUser) -> Bool {
        TimesheetDraftStore.listBucket(for: draft, hasLineManager: requiresLineManagerCounterSign(for: user)) == "awaiting"
    }

    /// One row per pay period. An exported copy of that period never waits for sign-off.
    /// A signature on a spare week key cannot promote the period when the period-start sheet is unsigned.
    static func awaitingPayPeriodStarts(
        user: AppUser,
        documentStarts: [Date],
        settings: OrganizationInvoicingSettings
    ) -> [Date] {
        struct Candidate {
            var weekStart: Date
            var startKey: String
            var endKey: String
            var hasActivity: Bool
            var periodStart: Date
        }
        var candidates: [Candidate] = []
        for start in documentStarts {
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: start)
            let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: user.id, weekStart: start)
            let period = TimesheetPayrollPolicy.periodMatchingStoredStart(start, storedEnd: storedEnd, settings: settings)
            guard let startKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(period.start),
                  let endKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(period.end) else { continue }
            let hasActivity = draft.operativeSignedAt != nil
                || !draft.expenseEntries.isEmpty
                || !draft.priceWorkEntries.isEmpty
                || !draft.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            candidates.append(Candidate(
                weekStart: start,
                startKey: startKey,
                endKey: endKey,
                hasActivity: hasActivity,
                periodStart: period.start
            ))
        }
        var awaiting: [Date] = []
        var seen = Set<String>()
        for candidate in candidates {
            let key = "\(candidate.startKey)|\(candidate.endKey)"
            guard seen.insert(key).inserted else { continue }
            let period = CanonicalBusinessEngine.CanonicalTimesheetPeriod(
                startDayKey: candidate.startKey,
                endDayKey: candidate.endKey
            )
            let rows = candidates.map {
                CanonicalBusinessEngine.CanonicalTimesheetPeriodCandidate(
                    startDayKey: $0.startKey,
                    endDayKey: $0.endKey,
                    hasActivity: $0.hasActivity
                )
            }
            guard let index = CanonicalBusinessEngine.pickTimesheetRowForPeriod(rows: rows, period: period),
                  candidates.indices.contains(index) else { continue }
            let chosen = TimesheetDraftStore.load(userId: user.id, weekStart: candidates[index].weekStart)
            if awaitingManagerSignOff(draft: chosen, user: user) {
                awaiting.append(candidates[index].periodStart)
            }
        }
        return awaiting.sorted(by: >)
    }

    static func applySelfApprovalIfNoLineManager(draft: inout TimesheetDraft, user: AppUser) {
        // No line manager: operative signature alone completes approval.
        guard !requiresLineManagerCounterSign(for: user) else { return }
        guard operativeHasSigned(draft) else { return }
        // Clear any stale manager signature fields so UI doesn't imply a counter-sign is pending.
        if draft.managerSignedAt != nil
            || draft.managerSignedByName != nil
            || draft.managerSignedByUserId != nil
            || draft.managerSignatureImageBase64 != nil {
            draft.managerSignedAt = nil
            draft.managerSignedByName = nil
            draft.managerSignedByUserId = nil
            draft.managerSignatureImageBase64 = nil
        }
    }

    static func clearSignatures(draft: inout TimesheetDraft) {
        draft.operativeSignedAt = nil
        draft.operativeSignedByName = nil
        draft.operativeSignatureImageBase64 = nil
        draft.managerSignedAt = nil
        draft.managerSignedByName = nil
        draft.managerSignedByUserId = nil
        draft.managerSignatureImageBase64 = nil
        draft.exportedAt = nil
        draft.approvedAt = nil
        draft.weeklyReportOverride = nil
        draft.payrollLineReviews = [:]
        for index in draft.expenseEntries.indices {
            draft.expenseEntries[index].managerDecision = .approved
            draft.expenseEntries[index].managerRevisedAmount = nil
        }
        for index in draft.priceWorkEntries.indices {
            draft.priceWorkEntries[index].managerDecision = .approved
            draft.priceWorkEntries[index].managerRevisedAmount = nil
        }
    }

    static func wasFullyApprovedBeforeExtrasChange(draft: TimesheetDraft, user: AppUser) -> Bool {
        operativeHasSigned(draft) && isTimesheetFullyApproved(draft: draft, user: user)
    }
}

enum TimesheetDraftStore {
    private static let defaults = UserDefaults.standard
    /// RULEBOOK 1.43.0 (review r318): the period's sheet could not be read, so it is not opened as a new one.
    static let periodReadFailedMessage = "Couldn't check older timesheets — try again."
    /// RULEBOOK 1.43.0 (review r318, 3rd round): the bookings gate closed during a bulk export (web `EXPORT_STOPPED_MESSAGE`).
    static let exportStoppedMessage = "Export stopped: the bookings are reloading. Try again in a moment."

    static func load(userId: String, weekStart: Date, organizationId: String? = nil) -> TimesheetDraft {
        guard let storageKey = key(userId: userId, weekStart: weekStart, organizationId: organizationId),
              let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TimesheetDraft.self, from: data) else {
            return TimesheetDraft()
        }
        return decoded
    }

    static func save(_ draft: TimesheetDraft, userId: String, weekStart: Date, weekEnd: Date? = nil, organizationId: String? = nil) {
        guard let storageKey = key(userId: userId, weekStart: weekStart, organizationId: organizationId),
              let encoded = try? JSONEncoder().encode(draft) else { return }
        defaults.set(encoded, forKey: storageKey)
        if let weekEnd,
           let startKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
           let endKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekEnd),
           let boundsKey = periodBoundsKey(userId: userId, weekStart: weekStart, organizationId: organizationId) {
            defaults.set("\(startKey)|\(endKey)", forKey: boundsKey)
        }
    }

    /// Removes the local copy of one organisation's sheet for this person and period (draft, loaded copy and bounds).
    /// Used when the server reports no sheet: the device cache never outlives the server copy (§1).
    static func clear(userId: String, weekStart: Date, organizationId: String? = nil) {
        if let storageKey = key(userId: userId, weekStart: weekStart, organizationId: organizationId) {
            defaults.removeObject(forKey: storageKey)
            defaults.removeObject(forKey: storageKey + ".loaded")
        }
        if let boundsKey = periodBoundsKey(userId: userId, weekStart: weekStart, organizationId: organizationId) {
            defaults.removeObject(forKey: boundsKey)
        }
    }

    /// RULEBOOK 1.9.0 §8: the sheet as this device last loaded (or wrote) it — the `base` of `timesheetChangedFields`,
    /// so a save sends only what this editor changed and never resends fields another device wrote since.
    static func loadedCopy(userId: String, weekStart: Date, organizationId: String? = nil) -> TimesheetDraft? {
        guard let storageKey = key(userId: userId, weekStart: weekStart, organizationId: organizationId),
              let data = defaults.data(forKey: storageKey + ".loaded") else { return nil }
        return try? JSONDecoder().decode(TimesheetDraft.self, from: data)
    }

    static func rememberLoadedCopy(_ draft: TimesheetDraft, userId: String, weekStart: Date, organizationId: String? = nil) {
        guard let storageKey = key(userId: userId, weekStart: weekStart, organizationId: organizationId),
              let encoded = try? JSONEncoder().encode(draft) else { return }
        defaults.set(encoded, forKey: storageKey + ".loaded")
    }

    static func storedPeriodEnd(userId: String, weekStart: Date, organizationId: String? = nil) -> Date? {
        guard let boundsKey = periodBoundsKey(userId: userId, weekStart: weekStart, organizationId: organizationId),
              let stored = defaults.string(forKey: boundsKey) else { return nil }
        let parts = stored.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return nil }
        return CanonicalBusinessEngine.date(fromDayKey: parts[1])
    }

    static func rememberPeriodBounds(
        startDayKey: String,
        endDayKey: String,
        userId: String,
        weekStart: Date,
        organizationId: String? = nil
    ) {
        guard startDayKey.count == 10, endDayKey.count == 10,
              let boundsKey = periodBoundsKey(userId: userId, weekStart: weekStart, organizationId: organizationId) else { return }
        defaults.set("\(startDayKey)|\(endDayKey)", forKey: boundsKey)
    }

    static func statusPayload(for draft: TimesheetDraft) -> [String: Any] {
        var row: [String: Any] = [:]
        func put(_ key: String, _ date: Date?) {
            if let date { row[key] = date.timeIntervalSince1970 * 1000 }
        }
        put("operativeSignedAt", draft.operativeSignedAt)
        row["operativeSignedByName"] = draft.operativeSignedByName ?? ""
        row["operativeSignatureImageBase64"] = draft.operativeSignatureImageBase64 ?? ""
        put("managerSignedAt", draft.managerSignedAt)
        row["managerSignedByName"] = draft.managerSignedByName ?? ""
        row["managerSignedByUserId"] = draft.managerSignedByUserId ?? ""
        row["managerSignatureImageBase64"] = draft.managerSignatureImageBase64 ?? ""
        if let managerSignedAt = draft.managerSignedAt {
            row["approvedAt"] = managerSignedAt.timeIntervalSince1970 * 1000
            row["approvedByName"] = draft.managerSignedByName ?? ""
        }
        put("exportedAt", draft.exportedAt)
        return row
    }

    static func statusFields(for draft: TimesheetDraft) -> CanonicalBusinessEngine.CanonicalTimesheetStatusFields? {
        parseTimesheetStatusFields(statusPayload(for: draft))
    }

    static func listBucket(for draft: TimesheetDraft, hasLineManager: Bool) -> String? {
        guard let fields = statusFields(for: draft) else { return nil }
        return CanonicalBusinessEngine.timesheetListBucket(fields, hasLineManager: hasLineManager)
    }

    static func parseTimesheetStatusFields(_ data: [String: Any]) -> CanonicalBusinessEngine.CanonicalTimesheetStatusFields? {
        CanonicalBusinessEngine.parseTimesheetStatusFields(data)
    }

    @discardableResult
    static func applySignOff(
        to draft: inout TimesheetDraft,
        role: String,
        signedAt: Date,
        signedByName: String,
        signedByUserId: String? = nil,
        signatureImageBase64: String? = nil
    ) -> Bool {
        guard let fields = CanonicalBusinessEngine.timesheetSignOffWriteFields(
            role: role,
            signedAtMs: signedAt.timeIntervalSince1970 * 1000,
            signedByName: signedByName,
            signedByUserId: signedByUserId,
            signatureImageBase64: signatureImageBase64
        ) else { return false }
        if role == "operative" {
            guard let ms = fields.operativeSignedAtMs else { return false }
            draft.operativeSignedAt = Date(timeIntervalSince1970: ms / 1000)
            draft.operativeSignedByName = fields.operativeSignedByName
            draft.operativeSignatureImageBase64 = fields.operativeSignatureImageBase64
            return true
        }
        guard let ms = fields.managerSignedAtMs else { return false }
        draft.managerSignedAt = Date(timeIntervalSince1970: ms / 1000)
        draft.managerSignedByName = fields.managerSignedByName
        draft.managerSignedByUserId = fields.managerSignedByUserId
        draft.managerSignatureImageBase64 = fields.managerSignatureImageBase64
        return true
    }

    @discardableResult
    static func applyExport(to draft: inout TimesheetDraft, at: Date) -> Bool {
        guard let fields = CanonicalBusinessEngine.timesheetExportWriteFields(exportedAtMs: at.timeIntervalSince1970 * 1000),
              let ms = fields.exportedAtMs else { return false }
        draft.exportedAt = Date(timeIntervalSince1970: ms / 1000)
        return true
    }

    static func refreshFromCloud(
        userId: String,
        weekStart: Date,
        firebaseBackend: FirebaseBackend,
        organizationId: String
    ) async -> TimesheetDraft? {
        await refreshFromCloudReporting(
            userId: userId,
            weekStart: weekStart,
            firebaseBackend: firebaseBackend,
            organizationId: organizationId
        ).draft
    }

    /// RULEBOOK 1.43.0 (review r318): the period's sheet read at its expected document id. `failed` is true when that
    /// read did not answer — the screen then shows an error instead of opening the period as a new sheet. Only a read
    /// that answered "missing" opens it as new, and a new sheet is saved at that same expected id
    /// (`timesheetStateDocumentRef`), never over another document.
    static func refreshFromCloudReporting(
        userId: String,
        weekStart: Date,
        firebaseBackend: FirebaseBackend,
        organizationId: String
    ) async -> (draft: TimesheetDraft?, failed: Bool) {
        let raw: [String: Any]?
        do {
            raw = try await firebaseBackend.loadTimesheetState(
                organizationId: organizationId,
                userId: userId,
                weekStart: weekStart
            )
        } catch {
            NSLog("TIMESHEET_PERIOD_READ_FAILED org=%@ %@", organizationId, error.localizedDescription)
            return (nil, true)
        }
        guard let raw else {
            // The server has no sheet for this organisation, person and period: the local copy is stale
            // (or another company's) and is never shown or saved back.
            clear(userId: userId, weekStart: weekStart, organizationId: organizationId)
            return (nil, false)
        }
        guard let decoded = fromFirestoreMap(raw) else { return (nil, false) }
        let endKey = (raw["weekEndKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startKey = (raw["weekStartKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startKey, let endKey, !startKey.isEmpty, !endKey.isEmpty {
            rememberPeriodBounds(startDayKey: startKey, endDayKey: endKey, userId: userId, weekStart: weekStart, organizationId: organizationId)
        } else if let weekEnd = firestoreDate(raw["weekEnd"]),
                  let derivedStart = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
                  let derivedEnd = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekEnd) {
            rememberPeriodBounds(startDayKey: derivedStart, endDayKey: derivedEnd, userId: userId, weekStart: weekStart, organizationId: organizationId)
        }
        save(decoded, userId: userId, weekStart: weekStart, organizationId: organizationId)
        rememberLoadedCopy(decoded, userId: userId, weekStart: weekStart, organizationId: organizationId)
        return (decoded, false)
    }

    /// Manager counter-sign and export fields. The owner never sends them (firestore.rules
    /// `timesheetManagerFieldsUnchanged`); only the reviewer's save writes them.
    private static let managerSignOffKeys: [String] = [
        "managerSignedAt",
        "managerSignedByName",
        "managerSignedByUserId",
        "managerSignatureImageBase64",
        "approvedAt",
        "approvedByName",
        "exportedAt"
    ]

    /// Saves a timesheet (rulebook §6). Reloads the server copy first, decides owner or reviewer with
    /// `timesheetWriterIsReviewer`, passes an owner save through `timesheetOwnerWriteFields`, writes
    /// only the fields that changed (`updateData`), and for a reviewer also writes the changed entry
    /// decisions from `timesheetEntryReviewWriteFields` (inline values stay for older builds).
    /// Returns a message to show when the save failed; nil on success.
    @discardableResult
    static func saveToCloud(
        _ draft: TimesheetDraft,
        userId: String,
        weekStart: Date,
        weekEnd: Date? = nil,
        firebaseBackend: FirebaseBackend,
        organizationId: String,
        writer: AppUser? = nil,
        subject: AppUser? = nil
    ) async -> String? {
        let end = weekEnd ?? storedPeriodEnd(userId: userId, weekStart: weekStart, organizationId: organizationId) ?? weekStart
        let writerId = Auth.auth().currentUser?.uid ?? writer?.id ?? ""
        let server: [String: Any]?
        do {
            server = try await firebaseBackend.loadTimesheetState(
                organizationId: organizationId,
                userId: userId,
                weekStart: weekStart
            )
        } catch {
            return "Couldn't save your timesheet: \(error.localizedDescription)"
        }
        let reviewer = TimesheetApprovalPolicy.writerIsReviewer(
            writerId: writerId,
            writer: writer,
            subjectUserId: userId,
            subject: subject
        )
        // RULEBOOK 1.45.0 §8 (review #232): evidence is read only for the sheet's person under every id they go by
        // (`personIdSet`). Until the roster has loaded that set is incomplete, so no sheet is saved; and evidence the
        // stored sheet holds that this editor never saw (read before the roster loaded) is kept on the save.
        let prepared = preparedForSave(
            draft,
            server: server,
            loaded: loadedCopy(userId: userId, weekStart: weekStart, organizationId: organizationId),
            rosterLoaded: RulebookRosterSnapshot.hasLoaded
        )
        guard let draft = prepared.draft else { return prepared.refusal ?? rosterNotLoadedMessage }
        var fields = asFirestoreMap(draft)
        var frozenEntriesChanged = false
        if !reviewer {
            for key in managerSignOffKeys { fields.removeValue(forKey: key) }
            // RULEBOOK 1.9.0 §8: "manager signed" is read from the stored copy, never from this device's draft.
            let storedManagerSigned = server.flatMap { statusFields(fromFirestore: $0)?.managerSignedAtMs } != nil
            guard let keep = CanonicalBusinessEngine.timesheetOwnerWritableKeys(
                Array(fields.keys),
                // Unknown counts as having one: the snapshot is then left to the line manager (web).
                subjectHasLineManager: subject.map { TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0) } ?? true,
                managerSigned: storedManagerSigned
            ) else {
                return "Couldn't save your timesheet: the timesheet rules did not load. Try again."
            }
            // Signed-off price work / expenses are frozen for the owner; say so instead of dropping silently.
            frozenEntriesChanged = ["expenseEntries", "priceWorkEntries"].contains { key in
                guard !keep.contains(key), let value = fields[key] else { return false }
                return !firestoreValuesEqual(value, server?[key])
            }
            fields = fields.filter { keep.contains($0.key) }
            // RULEBOOK 1.30.1 / 1.45.0 §8 `timesheetOwnerEntriesError({ previous, next, organizationId, ownerUserIds })`:
            // the owner's added or edited entries are checked — price work needs a job number, an expense at least one
            // piece of evidence, and evidence must be in the owner's own claim folder. Entries they did not touch (older
            // ones without a job number or with only a receipt name) never block. Compared with the sheet as this editor
            // loaded it, else as stored. A reviewer's save never asks.
            let previous: (priceWork: [Any], expenses: [Any])?
            if let loaded = loadedCopy(userId: userId, weekStart: weekStart, organizationId: organizationId) {
                let map = asFirestoreMap(loaded)
                previous = (map["priceWorkEntries"] as? [Any] ?? [], map["expenseEntries"] as? [Any] ?? [])
            } else if let server {
                previous = (server["priceWorkEntries"] as? [Any] ?? [], server["expenseEntries"] as? [Any] ?? [])
            } else {
                previous = nil
            }
            let next = asFirestoreMap(draft)
            if let message = CanonicalBusinessEngine.timesheetOwnerEntriesError(
                previous: previous,
                next: (next["priceWorkEntries"] as? [Any] ?? [], next["expenseEntries"] as? [Any] ?? []),
                organizationId: organizationId,
                // The uploader is the signed-in owner; the sheet's own id counts as theirs too.
                ownerUserIds: CanonicalBusinessEngine.timesheetEvidenceOwnerIds(
                    sheetDocumentId: "",
                    userId: userId,
                    extra: [writerId].filter { !$0.isEmpty }
                )
            ) {
                return message
            }
        }
        // RULEBOOK 1.45.0 §8 / §24: the evidence on the entries before this save (as loaded, else as stored), so the
        // files an edit or delete removed can be tidied up after the save.
        let evidenceBefore: [PayeClaimEvidence] = {
            if let loaded = loadedCopy(userId: userId, weekStart: weekStart, organizationId: organizationId) {
                return loaded.expenseEntries.flatMap(\.evidence) + loaded.priceWorkEntries.flatMap(\.evidence)
            }
            guard let server, let stored = decodeFirestoreMap(server) else { return [] }
            return stored.expenseEntries.flatMap(\.evidence) + stored.priceWorkEntries.flatMap(\.evidence)
        }()
        var changed: [String: Any] = [:]
        if server != nil, let loaded = loadedCopy(userId: userId, weekStart: weekStart, organizationId: organizationId) {
            // RULEBOOK 1.9.0 §1, §8: `timesheetChangedFields(base, next)` — only what this editor changed since it
            // loaded the sheet. A reviewer never resends the owner's signature, expenses or price work, and the owner
            // never resends the manager's fields.
            let base = asFirestoreMap(loaded).filter { fields[$0.key] != nil }
            guard let write = CanonicalBusinessEngine.timesheetChangedFields(base: base, next: fields) else {
                return "Couldn't save your timesheet: the timesheet rules did not load. Try again."
            }
            changed = write.firestoreFields(from: fields)
        } else {
            // Never loaded on this device (or no stored sheet yet): the fields that differ from the server copy.
            for (key, value) in fields where server == nil || !firestoreValuesEqual(value, server?[key]) {
                changed[key] = value
            }
        }
        if reviewer {
            let storedIds = storedEntryIds(server)
            func entryId(_ id: UUID, _ stored: String?) -> String {
                stored ?? storedIds[id.uuidString.lowercased()] ?? WorkDocumentKeys.storedId(for: id)
            }
            let entries: [(id: String, amount: Double, managerDecision: String, managerRevisedAmount: Double?)] = draft.expenseEntries.map {
                (id: entryId($0.id, $0.storedId), amount: $0.amount, managerDecision: $0.managerDecision.rawValue, managerRevisedAmount: $0.managerRevisedAmount)
            } + draft.priceWorkEntries.map {
                (id: entryId($0.id, $0.storedId), amount: $0.amount, managerDecision: $0.managerDecision.rawValue, managerRevisedAmount: $0.managerRevisedAmount)
            }
            // RULEBOOK 1.45.0 §8 (review #322): each entry's stored-row fingerprint, so the review stores it.
            var reviewFingerprints: [String: String] = [:]
            for entry in draft.expenseEntries {
                if let fingerprint = entry.reviewFingerprint { reviewFingerprints[entryId(entry.id, entry.storedId)] = fingerprint }
            }
            for entry in draft.priceWorkEntries {
                if let fingerprint = entry.reviewFingerprint { reviewFingerprints[entryId(entry.id, entry.storedId)] = fingerprint }
            }
            if let reviewFields = CanonicalBusinessEngine.timesheetEntryReviewWriteFields(
                storedSheet: server,
                entries: entries,
                reviewedByUserId: writerId,
                reviewedAtMs: Date().timeIntervalSince1970 * 1000,
                reviewFingerprints: reviewFingerprints
            ) {
                for (key, value) in reviewFields { changed[key] = value }
            }
        }
        do {
            try await firebaseBackend.saveTimesheetState(
                organizationId: organizationId,
                userId: userId,
                weekStart: weekStart,
                weekEnd: end,
                payload: changed,
                storedDocument: server,
                documentExists: server != nil
            )
        } catch {
            return "Couldn't save your timesheet: \(error.localizedDescription)"
        }
        // What this device wrote is now its loaded copy (the base of the next save).
        rememberLoadedCopy(draft, userId: userId, weekStart: weekStart, organizationId: organizationId)
        if !reviewer && !frozenEntriesChanged {
            // RULEBOOK 1.45.0 §8 `timesheetEntryEvidenceToDelete`: removed files go only inside the §24 undo window.
            let evidenceAfter = draft.expenseEntries.flatMap(\.evidence) + draft.priceWorkEntries.flatMap(\.evidence)
            await firebaseBackend.discardRemovedTimesheetEvidence(before: evidenceBefore, after: evidenceAfter)
        }
        if frozenEntriesChanged {
            return "Price work and expenses can't be changed after your line manager has signed. Ask them to amend it."
        }
        return nil
    }

    /// Shown when a timesheet would be saved before the people list (and so every id of the sheet's person) has loaded.
    static let rosterNotLoadedMessage = "Couldn't save your timesheet: people are still loading. Try again in a moment."

    /// What `saveToCloud` writes, or why it refuses (RULEBOOK 1.45.0 §8, review #232): nothing is saved before the
    /// roster has loaded, and evidence the stored sheet holds that this editor never saw is kept (see
    /// `keepingEvidenceUnseenByEditor`). `server` is the stored sheet as read; `loaded` the copy this editor loaded.
    static func preparedForSave(
        _ draft: TimesheetDraft,
        server: [String: Any]?,
        loaded: TimesheetDraft?,
        rosterLoaded: Bool
    ) -> (draft: TimesheetDraft?, refusal: String?) {
        guard rosterLoaded else { return (nil, rosterNotLoadedMessage) }
        guard let server else { return (draft, nil) }
        return (keepingEvidenceUnseenByEditor(draft, storedEvidence: rawEntryEvidence(server), loaded: loaded), nil)
    }

    /// Every entry's stored `evidence` as the sheet holds it, by entry id (lower case) — read from the raw stored rows,
    /// NOT through `parseTimesheetEntries`' owner filter, so a file under an id the roster does not (yet) list is still
    /// seen. Used only to keep files on save, never to show or open them.
    static func rawEntryEvidence(_ sheet: [String: Any]) -> [String: [PayeClaimEvidence]] {
        var out: [String: [PayeClaimEvidence]] = [:]
        for key in ["expenseEntries", "priceWorkEntries"] {
            for row in (sheet[key] as? [[String: Any]]) ?? [] {
                guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                      let list = row["evidence"] as? [[String: Any]] else { continue }
                let evidence = list.compactMap { item -> PayeClaimEvidence? in
                    guard let path = (item["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                        return nil
                    }
                    let name = (item["name"] as? String) ?? ""
                    let contentType = (item["contentType"] as? String) ?? ""
                    let auditId = (item["auditId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    return PayeClaimEvidence(
                        path: path,
                        name: name.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? "Evidence") : name,
                        kind: (item["kind"] as? String) ?? "file",
                        contentType: contentType.isEmpty ? nil : contentType,
                        auditId: auditId
                    )
                }
                if !evidence.isEmpty { out[id.lowercased(), default: []] += evidence }
            }
        }
        return out
    }

    /// RULEBOOK 1.45.0 §8 (review #232): the draft with any evidence the stored sheet holds on an entry that this
    /// editor never saw — not in the copy it loaded (`loaded`) and not in the draft — added back, so a sheet decoded
    /// before every id of its person was known never loses files on save. Evidence the editor removed (in `loaded`,
    /// not in the draft) stays removed. Entries are matched by stored id without case. No rule is decided here.
    static func keepingEvidenceUnseenByEditor(
        _ draft: TimesheetDraft,
        storedEvidence: [String: [PayeClaimEvidence]],
        loaded: TimesheetDraft?
    ) -> TimesheetDraft {
        func key(_ storedId: String?, _ id: UUID) -> String {
            (storedId ?? WorkDocumentKeys.storedId(for: id)).lowercased()
        }
        var seenByEditor: [String: [PayeClaimEvidence]] = [:]
        for entry in loaded?.expenseEntries ?? [] { seenByEditor[key(entry.storedId, entry.id), default: []] += entry.evidence }
        for entry in loaded?.priceWorkEntries ?? [] { seenByEditor[key(entry.storedId, entry.id), default: []] += entry.evidence }
        func merged(_ current: [PayeClaimEvidence], key entryKey: String) -> [PayeClaimEvidence] {
            guard let stored = storedEvidence[entryKey], !stored.isEmpty else { return current }
            var known = Set(current.map(\.path)).union((seenByEditor[entryKey] ?? []).map(\.path))
            var out = current
            for item in stored where !known.contains(item.path) {
                known.insert(item.path)
                out.append(item)
            }
            return out
        }
        var out = draft
        for index in out.expenseEntries.indices {
            let entryKey = key(out.expenseEntries[index].storedId, out.expenseEntries[index].id)
            out.expenseEntries[index].evidence = merged(out.expenseEntries[index].evidence, key: entryKey)
        }
        for index in out.priceWorkEntries.indices {
            let entryKey = key(out.priceWorkEntries[index].storedId, out.priceWorkEntries[index].id)
            out.priceWorkEntries[index].evidence = merged(out.priceWorkEntries[index].evidence, key: entryKey)
        }
        return out
    }

    /// Stored entry ids by lowercased id, so a decision is written under the id the sheet stores.
    private static func storedEntryIds(_ server: [String: Any]?) -> [String: String] {
        var ids: [String: String] = [:]
        for key in ["expenseEntries", "priceWorkEntries"] {
            for row in (server?[key] as? [[String: Any]]) ?? [] {
                if let id = row["id"] as? String, !id.isEmpty { ids[id.lowercased()] = id }
            }
        }
        return ids
    }

    /// Whether a value about to be written equals the stored one (missing, null and nil are the same;
    /// instants within a millisecond are the same). A comparison for a partial update, not a rule.
    static func firestoreValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        let a = unwrapFirestoreValue(lhs)
        let b = unwrapFirestoreValue(rhs)
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        if let x = a as? Timestamp, let y = b as? Timestamp {
            return abs(x.dateValue().timeIntervalSince(y.dateValue())) < 0.001
        }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            for key in Set(x.keys).union(y.keys) where !firestoreValuesEqual(x[key], y[key]) {
                return false
            }
            return true
        }
        if let x = a as? [Any], let y = b as? [Any] {
            guard x.count == y.count else { return false }
            for index in x.indices where !firestoreValuesEqual(x[index], y[index]) {
                return false
            }
            return true
        }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        return false
    }

    private static func unwrapFirestoreValue(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return nil }
            return unwrapFirestoreValue(child.value)
        }
        return value
    }

    /// RULEBOOK 1.45.0 §8 `timesheetEntryEvidenceWriteFields(evidence)`: the stored evidence list, nil when the entry has
    /// none (then no `evidence` key is written). Without a script answer the entry's own evidence is written as read, so a
    /// save never drops a file.
    static func evidenceWriteFields(_ evidence: [PayeClaimEvidence]) -> [[String: Any]]? {
        guard !evidence.isEmpty else { return nil }
        if let fields = CanonicalBusinessEngine.timesheetEntryEvidenceWriteFields(evidence), fields.count == evidence.count {
            return fields
        }
        return evidence.map { item -> [String: Any] in
            var row: [String: Any] = ["path": item.path, "name": item.name, "kind": item.kind]
            if let contentType = item.contentType, !contentType.isEmpty { row["contentType"] = contentType }
            if let auditId = item.auditId, !auditId.isEmpty { row["auditId"] = auditId }
            return row
        }
    }

    /// RULEBOOK 1.45.0 §8 (review #322) `timesheetEntryFingerprintMap`: each entry's stored-row fingerprint (as
    /// `parseTimesheetEntries` computed it when the sheet was read), keyed for `entryFingerprints` on `timesheetTotals`
    /// / `timesheetInvoiceRows`. The rulebook never reads a fingerprint off a row, and none is ever written to Firestore.
    static func entryFingerprints(_ draft: TimesheetDraft) -> [String: Any] {
        let rows: [[String: Any]] =
            draft.expenseEntries.compactMap { entry in
                entry.reviewFingerprint.map { ["id": entry.storedId ?? WorkDocumentKeys.storedId(for: entry.id), "reviewFingerprint": $0] }
            } + draft.priceWorkEntries.compactMap { entry in
                entry.reviewFingerprint.map { ["id": entry.storedId ?? WorkDocumentKeys.storedId(for: entry.id), "reviewFingerprint": $0] }
            }
        guard !rows.isEmpty else { return [:] }
        return CanonicalBusinessEngine.timesheetEntryFingerprintMap(rows)
    }

    static func asFirestoreMap(_ draft: TimesheetDraft) -> [String: Any] {
        [
            "managerNote": draft.managerNote,
            "operativeSignedAt": draft.operativeSignedAt.map(Timestamp.init(date:)) as Any,
            "operativeSignedByName": draft.operativeSignedByName ?? "",
            "operativeSignatureImageBase64": draft.operativeSignatureImageBase64 ?? "",
            "managerSignedAt": draft.managerSignedAt.map(Timestamp.init(date:)) as Any,
            "managerSignedByName": draft.managerSignedByName ?? "",
            "managerSignedByUserId": draft.managerSignedByUserId ?? "",
            "managerSignatureImageBase64": draft.managerSignatureImageBase64 ?? "",
            "approvedAt": draft.managerSignedAt.map(Timestamp.init(date:)) as Any,
            "approvedByName": draft.managerSignedByName ?? "",
            "exportedAt": draft.exportedAt.map(Timestamp.init(date:)) as Any,
            "weeklyReportOverride": draft.weeklyReportOverride.map(weeklyReportOverrideMap) as Any,
            "expenseEntries": draft.expenseEntries.map { e -> [String: Any] in
                var row: [String: Any] = [
                    // RULEBOOK 1.7.0 §8: the id as stored (or `timesheetEntryId`), so a review keyed on it still matches.
                    "id": e.storedId ?? WorkDocumentKeys.storedId(for: e.id),
                    "title": e.title,
                    "details": e.details,
                    "jobNumber": e.jobNumber,
                    "date": Timestamp(date: e.date),
                    "amount": e.amount,
                    "receiptName": e.receiptName ?? "",
                    "managerDecision": e.managerDecision.rawValue,
                    "managerRevisedAmount": e.managerRevisedAmount as Any
                ]
                // RULEBOOK 1.45.0 §8: evidence is written only when the entry has some (web the same), so an older
                // entry keeps its stored shape and no save ever drops a file.
                if let evidence = evidenceWriteFields(e.evidence) { row["evidence"] = evidence }
                return row
            },
            "priceWorkEntries": draft.priceWorkEntries.map { p -> [String: Any] in
                var row: [String: Any] = [
                    "id": p.storedId ?? WorkDocumentKeys.storedId(for: p.id),
                    "title": p.title,
                    "details": p.details,
                    "jobNumber": p.jobNumber,
                    "agreedManagerName": p.agreedManagerName,
                    "startDate": Timestamp(date: p.startDate),
                    "endDate": p.endDate.map(Timestamp.init(date:)) as Any,
                    "amount": p.amount,
                    "managerDecision": p.managerDecision.rawValue,
                    "managerRevisedAmount": p.managerRevisedAmount as Any
                ]
                if let evidence = evidenceWriteFields(p.evidence) { row["evidence"] = evidence }
                return row
            },
            // RULEBOOK 1.46.0 §8: an Edit hours review keeps its hours, parts and booking fingerprint
            // (`PayrollLineEditReviewFields`, web `payrollLineEditFieldsOf`), so a save never drops them.
            "payrollLineReviews": draft.payrollLineReviews.mapValues { $0.storedFields }
        ]
    }

    /// RULEBOOK 1.45.0 §8: an entry's `evidence` as `parseTimesheetEntries` returned it (the sheet owner's own claim
    /// files only, `parsePayeClaimEvidence`); empty for an entry stored before 1.45.0.
    static func entryEvidence(_ row: CanonicalDocumentRow) -> [PayeClaimEvidence] {
        RulebookJSON.decode([PayeClaimEvidence].self, from: row.raw["evidence"]) ?? []
    }

    private static func fromFirestoreMap(_ map: [String: Any]) -> TimesheetDraft? {
        var output = TimesheetDraft()
        output.managerNote = map["managerNote"] as? String ?? ""
        output.operativeSignedAt = firestoreDate(map["operativeSignedAt"])
        let operativeSignedBy = (map["operativeSignedByName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.operativeSignedByName = operativeSignedBy.isEmpty ? nil : operativeSignedBy
        let operativeSignature = (map["operativeSignatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.operativeSignatureImageBase64 = operativeSignature.isEmpty ? nil : operativeSignature
        output.managerSignedAt = firestoreDate(map["managerSignedAt"])
        let signedBy = (map["managerSignedByName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignedByName = signedBy.isEmpty ? nil : signedBy
        let signedByUserId = (map["managerSignedByUserId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignedByUserId = signedByUserId.isEmpty ? nil : signedByUserId
        let managerSignature = (map["managerSignatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignatureImageBase64 = managerSignature.isEmpty ? nil : managerSignature
        output.exportedAt = firestoreDate(map["exportedAt"])
        output.approvedAt = firestoreDate(map["approvedAt"])
        if output.managerSignedAt == nil {
            output.managerSignedAt = firestoreDate(map["approvedAt"])
        }
        if output.managerSignedByName == nil {
            let approvedBy = (map["approvedByName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            output.managerSignedByName = approvedBy.isEmpty ? nil : approvedBy
        }
        if let fields = statusFields(fromFirestore: map) {
            output.operativeSignedAt = fields.operativeSignedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            output.operativeSignedByName = fields.operativeSignedByName.isEmpty ? nil : fields.operativeSignedByName
            output.operativeSignatureImageBase64 = fields.operativeSignatureImageBase64.isEmpty ? nil : fields.operativeSignatureImageBase64
            output.managerSignedAt = fields.managerSignedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            output.managerSignedByName = fields.managerSignedByName.isEmpty ? nil : fields.managerSignedByName
            output.managerSignedByUserId = fields.managerSignedByUserId.isEmpty ? output.managerSignedByUserId : fields.managerSignedByUserId
            output.managerSignatureImageBase64 = fields.managerSignatureImageBase64.isEmpty ? nil : fields.managerSignatureImageBase64
            output.exportedAt = fields.exportedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        // RULEBOOK 1.7.0 §8: entries are read only through `parseTimesheetEntries`. Every entry with a title is kept
        // under its stored id (any case, UUID or not); one stored without an id gets the deterministic
        // `timesheetEntryId`, so `extraEntryReviews[entryId]` matches on every platform and every read. The decision
        // in effect is `timesheetEntryDecision` for that id. Without the script the sheet is not decoded at all
        // (a save from a half-read sheet would drop entries).
        // RULEBOOK 1.45.0 §8 (review #322 F2): every id the sheet's person goes by, so evidence on a sheet filed under
        // an older id is kept.
        let sheetDocumentId = timesheetSheetDocumentId(map)
        let subjectId = (map["userId"] as? String) ?? CanonicalBusinessEngine.timesheetDocumentSubjectId(sheetDocumentId) ?? ""
        guard let entries = CanonicalBusinessEngine.parseTimesheetEntries(
            sheetDocumentId: sheetDocumentId,
            sheet: map,
            ownerUserIds: RulebookRosterSnapshot.personIds(forUserId: subjectId)
        ) else { return nil }
        output.expenseEntries = entries.rows("expenseEntries").map { row in
            TimesheetExpenseEntry(
                id: WorkDocumentKeys.inAppId(for: row.id),
                title: row.text("title"),
                details: row.raw["details"] as? String ?? "",
                jobNumber: row.text("jobNumber"),
                date: row.date("dateMs") ?? Date(),
                amount: row.number("amount") ?? 0,
                receiptName: row.optionalText("receiptName"),
                managerDecision: TimesheetManagerDecision(rawValue: row.text("managerDecision")) ?? .approved,
                managerRevisedAmount: row.number("managerRevisedAmount"),
                storedId: row.id,
                evidence: Self.entryEvidence(row),
                reviewFingerprint: row.optionalText("reviewFingerprint")
            )
        }

        output.priceWorkEntries = entries.rows("priceWorkEntries").map { row in
            TimesheetPriceWorkEntry(
                id: WorkDocumentKeys.inAppId(for: row.id),
                title: row.text("title"),
                details: row.raw["details"] as? String ?? "",
                jobNumber: row.text("jobNumber"),
                agreedManagerName: row.optionalText("agreedManagerName") ?? "Manager",
                startDate: row.date("startMs") ?? Date(),
                endDate: row.date("endMs"),
                amount: row.number("amount") ?? 0,
                managerDecision: TimesheetManagerDecision(rawValue: row.text("managerDecision")) ?? .approved,
                managerRevisedAmount: row.number("managerRevisedAmount"),
                storedId: row.id,
                evidence: Self.entryEvidence(row),
                reviewFingerprint: row.optionalText("reviewFingerprint")
            )
        }

        if let reviewMap = map["payrollLineReviews"] as? [String: [String: Any]] {
            var reviews: [String: TimesheetPayrollLineReview] = [:]
            for (lineId, payload) in reviewMap {
                // RULEBOOK 1.46.0: every stored review field, numbers read as NSNumber.
                reviews[lineId] = TimesheetPayrollLineReview(stored: payload)
            }
            output.payrollLineReviews = reviews
        }

        if let overrideMap = map["weeklyReportOverride"] as? [String: Any] {
            output.weeklyReportOverride = weeklyReportOverride(from: overrideMap)
        }

        return output
    }

    /// The sheet document id entry ids derive from: the id a read attached (`__documentId`), else
    /// `timesheetDocumentId(userId, weekStartKey)` from the stored period fields.
    private static func timesheetSheetDocumentId(_ map: [String: Any]) -> String {
        if let id = (map["__documentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let userId = (map["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedKey = (map["weekStartKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startKey = storedKey.isEmpty
            ? (firestoreDate(map["weekStart"]).flatMap { CanonicalBusinessEngine.dayKeyInOrganizationZone($0) } ?? "")
            : storedKey
        guard !userId.isEmpty, !startKey.isEmpty else { return "" }
        return CanonicalBusinessEngine.timesheetDocumentId(userId: userId, startDayKey: startKey) ?? ""
    }

    static func decodeFirestoreMap(_ map: [String: Any]) -> TimesheetDraft? {
        fromFirestoreMap(map)
    }

    nonisolated private static func weeklyReportOverrideMap(_ override: TimesheetWeeklyReportOverride) -> [String: Any] {
        [
            "approvedAt": Timestamp(date: override.approvedAt),
            "approvedByUserId": override.approvedByUserId,
            "approvedByName": override.approvedByName,
            "selfSigned": override.selfSigned,
            "lines": override.lines.map { line -> [String: Any] in
                var row: [String: Any] = [
                    "id": line.id,
                    "date": Timestamp(date: line.date),
                    "jobNumber": line.jobNumber,
                    "projectName": line.projectName,
                    "locationKind": line.locationKind,
                    "details": line.details,
                    "paidHours": line.paidHours,
                    "days": line.days,
                    "amount": line.amount,
                    "isOvertime": line.isOvertime,
                    "decision": line.decision.rawValue,
                    "bookingId": line.bookingId ?? ""
                ]
                // RULEBOOK 1.44.0 §8 (web `weeklyReportOverride.ts` `payBasis`: 'day' | 'hourly'), only when known: a line
                // signed before it was stored keeps its stored shape.
                if let basis = line.payBasis { row["payBasis"] = basis }
                // RULEBOOK 1.46.0 §8 (web `weeklyReportOverrideToFirestore`): the booking as signed, and an overtime line's
                // multiplier, only when known.
                if let signed = line.bookingFingerprint, !signed.isEmpty { row["bookingFingerprint"] = signed }
                if line.isOvertime, let multiplier = line.otMultiplier { row["otMultiplier"] = multiplier }
                if let had = line.bookingHadOvertimeLine { row["bookingHadOvertimeLine"] = had }
                if let key = line.appliedReviewKey { row["appliedReviewKey"] = key }
                if let part = line.reviewPartOf, !part.isEmpty { row["reviewPartOf"] = part }
                // RULEBOOK 1.46.0 §8 (web `weeklyReportOverrideToFirestore`): the signed row's own PAYE / leave flags, on
                // every line written (false when not stored).
                row["isPayeDay"] = line.isPayeDay == true
                row["isLeave"] = line.isLeave == true
                return row
            },
            "priceWork": override.priceWork.map(moneyLineMap),
            "expenses": override.expenses.map(moneyLineMap)
        ]
    }

    nonisolated private static func moneyLineMap(_ line: TimesheetWeeklyReportMoneyLine) -> [String: Any] {
        [
            "id": line.id,
            "title": line.title,
            "details": line.details,
            "jobNumber": line.jobNumber,
            "date": Timestamp(date: line.date),
            "amount": line.amount,
            "decision": line.decision.rawValue
        ]
    }

    private static func weeklyReportOverride(from map: [String: Any]) -> TimesheetWeeklyReportOverride? {
        let lines = ((map["lines"] as? [[String: Any]]) ?? []).compactMap { row -> TimesheetWeeklyReportLabourLine? in
            guard let id = row["id"] as? String else { return nil }
            let bookingId = (row["bookingId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TimesheetWeeklyReportLabourLine(
                id: id,
                date: (row["date"] as? Timestamp)?.dateValue() ?? Date(),
                jobNumber: row["jobNumber"] as? String ?? "",
                projectName: row["projectName"] as? String ?? "",
                locationKind: row["locationKind"] as? String ?? ManagerLocationType.project.rawValue,
                details: row["details"] as? String ?? "",
                paidHours: row["paidHours"] as? Double ?? 0,
                days: row["days"] as? Double ?? 0,
                amount: row["amount"] as? Double ?? 0,
                isOvertime: row["isOvertime"] as? Bool ?? false,
                decision: TimesheetManagerDecision(rawValue: row["decision"] as? String ?? "") ?? .approved,
                bookingId: (bookingId?.isEmpty == false) ? bookingId : nil,
                payBasis: TimesheetSignedLineRate.storedBasis(row["payBasis"]),
                bookingFingerprint: (row["bookingFingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                otMultiplier: (row["otMultiplier"] as? NSNumber)?.doubleValue,
                bookingHadOvertimeLine: row["bookingHadOvertimeLine"] as? Bool,
                appliedReviewKey: row["appliedReviewKey"] as? String,
                reviewPartOf: (row["reviewPartOf"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isPayeDay: row["isPayeDay"] as? Bool,
                isLeave: row["isLeave"] as? Bool
            )
        }
        func moneyLines(_ key: String) -> [TimesheetWeeklyReportMoneyLine] {
            ((map[key] as? [[String: Any]]) ?? []).compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return TimesheetWeeklyReportMoneyLine(
                    id: id,
                    title: row["title"] as? String ?? "",
                    details: row["details"] as? String ?? "",
                    jobNumber: row["jobNumber"] as? String ?? "",
                    date: (row["date"] as? Timestamp)?.dateValue() ?? Date(),
                    amount: row["amount"] as? Double ?? 0,
                    decision: TimesheetManagerDecision(rawValue: row["decision"] as? String ?? "") ?? .approved
                )
            }
        }
        return TimesheetWeeklyReportOverride(
            approvedAt: (map["approvedAt"] as? Timestamp)?.dateValue() ?? Date(),
            approvedByUserId: map["approvedByUserId"] as? String ?? "",
            approvedByName: map["approvedByName"] as? String ?? "",
            selfSigned: map["selfSigned"] as? Bool ?? false,
            lines: lines,
            priceWork: moneyLines("priceWork"),
            expenses: moneyLines("expenses")
        )
    }

    /// `timesheet-draft.v2-{organisationId}-{userId}-{stamp}`. Nil without an open organisation, so a sheet
    /// is never cached or read outside the company it belongs to. `organizationId` nil means the open one.
    static func key(userId: String, weekStart: Date, organizationId: String? = nil) -> String? {
        guard let prefix = draftKeyPrefix(userId: userId, organizationId: organizationId),
              let stamp = organizationPeriodStamp(for: weekStart) else { return nil }
        return "\(prefix)\(stamp)"
    }

    private static func periodBoundsKey(userId: String, weekStart: Date, organizationId: String? = nil) -> String? {
        guard let org = cacheOrganizationKey(organizationId),
              let stamp = organizationPeriodStamp(for: weekStart) else { return nil }
        return "timesheet-period.v2-\(org)-\(userId)-\(stamp)"
    }

    private static func draftKeyPrefix(userId: String, organizationId: String?) -> String? {
        guard let org = cacheOrganizationKey(organizationId) else { return nil }
        return "timesheet-draft.v2-\(org)-\(userId)-"
    }

    /// The organisation part of a cache key: the given id, else the open organisation; lower case so a
    /// stored id in another letter case is the same company. Nil when neither is known.
    private static func cacheOrganizationKey(_ organizationId: String?) -> String? {
        purgeLegacyKeysOnce()
        let raw = (organizationId ?? OrganizationRulebookContext.organizationId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw.lowercased()
    }

    private static var legacyKeysPurged = false

    /// Drafts cached before keys carried the organisation (`timesheet-draft-{userId}-{stamp}`,
    /// `timesheet-period-{userId}-{stamp}`) cannot be told apart by company, so they are removed.
    private static func purgeLegacyKeysOnce() {
        guard !legacyKeysPurged else { return }
        legacyKeysPurged = true
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("timesheet-draft-") || key.hasPrefix("timesheet-period-") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes every cached sheet (all organisations and people). Called on sign-out.
    static func clearAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("timesheet-draft") || key.hasPrefix("timesheet-period") {
            defaults.removeObject(forKey: key)
        }
    }

    static func organizationDay(_ date: Date) -> Date? {
        guard let key = CanonicalBusinessEngine.dayKeyInOrganizationZone(date) else { return nil }
        return CanonicalBusinessEngine.date(fromDayKey: key)
    }

    static func rememberBounds(from row: [String: Any], userId: String, weekStart: Date, organizationId: String? = nil) {
        let endKey = (row["weekEndKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startKey = (row["weekStartKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startKey, let endKey, startKey.count == 10, endKey.count == 10 {
            rememberPeriodBounds(startDayKey: startKey, endDayKey: endKey, userId: userId, weekStart: weekStart, organizationId: organizationId)
            return
        }
        if let weekEnd = firestoreDate(row["weekEnd"]),
           let derivedStart = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
           let derivedEnd = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekEnd) {
            rememberPeriodBounds(startDayKey: derivedStart, endDayKey: derivedEnd, userId: userId, weekStart: weekStart, organizationId: organizationId)
        }
    }

    /// Unix start of the organisation-zone day, taken from `timesheetDocumentId`. Nil when the script did not answer.
    static func organizationPeriodStamp(for weekStart: Date) -> Int? {
        guard let startDayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
              let documentId = CanonicalBusinessEngine.timesheetDocumentId(userId: "u", startDayKey: startDayKey) else {
            return nil
        }
        guard let stamp = documentId.split(separator: "_").last, let value = Int(stamp), value > 0 else { return nil }
        return value
    }

    static func statusFields(fromFirestore map: [String: Any]) -> CanonicalBusinessEngine.CanonicalTimesheetStatusFields? {
        var row: [String: Any] = [:]
        for key in ["operativeSignedAt", "managerSignedAt", "approvedAt", "exportedAt", "invoiceGeneratedAt"] {
            if let date = firestoreDate(map[key]) {
                row[key] = date.timeIntervalSince1970 * 1000
            }
        }
        for key in [
            "operativeSignedByName",
            "operativeSignatureImageBase64",
            "managerSignedByName",
            "managerSignedByUserId",
            "managerSignatureImageBase64",
            "approvedByName",
        ] {
            if let text = map[key] as? String { row[key] = text }
        }
        return CanonicalBusinessEngine.parseTimesheetStatusFields(row)
    }

    /// Local cache keys — used so past pay runs appear before cloud sync finishes.
    static func discoverStoredWeekStarts(userId: String, organizationId: String? = nil) -> [Date] {
        guard let prefix = draftKeyPrefix(userId: userId, organizationId: organizationId) else { return [] }
        let stamps = UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key -> Date? in
            guard key.hasPrefix(prefix) else { return nil }
            guard let stamp = Int(key.dropFirst(prefix.count)) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(stamp))
        }
        return stamps.sorted(by: >)
    }

    static func ingestCloudRow(_ row: [String: Any], userId: String, organizationId: String? = nil) -> Date? {
        guard let weekStart = firestoreDate(row["weekStart"]) else { return nil }
        guard let storedStart = CanonicalBusinessEngine.date(
            fromDayKey: CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart) ?? ""
        ) else { return nil }
        guard let draft = decodeFirestoreMap(row) else { return nil }
        let endKey = (row["weekEndKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startKey = (row["weekStartKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startKey, let endKey, !startKey.isEmpty, !endKey.isEmpty {
            rememberPeriodBounds(startDayKey: startKey, endDayKey: endKey, userId: userId, weekStart: storedStart, organizationId: organizationId)
        } else if let weekEnd = firestoreDate(row["weekEnd"]),
                  let derivedStart = CanonicalBusinessEngine.dayKeyInOrganizationZone(storedStart),
                  let derivedEnd = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekEnd) {
            rememberPeriodBounds(startDayKey: derivedStart, endDayKey: derivedEnd, userId: userId, weekStart: storedStart, organizationId: organizationId)
        }
        save(draft, userId: userId, weekStart: storedStart, organizationId: organizationId)
        return storedStart
    }

    /// Current pay run plus the previous completed run (timesheets are often signed in arrears).
    static func weeksToPrefetchForManagerReview(
        settings: OrganizationInvoicingSettings,
        extraWeekStart: Date? = nil
    ) -> [Date] {
        var starts = Set<Date>()
        starts.insert(WeekRange.current(settings: settings).start)
        starts.insert(TimesheetPayrollPolicy.timesheetWeekRange(for: settings).start)
        if let extraWeekStart, let day = organizationDay(extraWeekStart) {
            starts.insert(day)
        }
        return Array(starts)
    }
}

private struct MyTimesheetsHubView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService

    let settings: OrganizationInvoicingSettings

    @State private var pastWeeks: [WeekRange] = []
    @State private var isLoadingPastWeeks = false

    private var organizationId: String? {
        firebaseBackend.currentOrganization?.firestoreDocumentId
    }

    private var currentWeek: WeekRange {
        TimesheetPayrollPolicy.payPeriodContaining(settings: settings)
    }

    private var pendingWeeks: [WeekRange] {
        guard let user = userStore.displayUser else { return [] }
        guard TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user) else { return [] }
        var weeks: [WeekRange] = [currentWeek]
        weeks.append(contentsOf: TimesheetPayrollPolicy.previousPayPeriods(count: 24, settings: settings))
        return weeks.filter { week in
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
            return TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user)
        }
    }

    private func draftHasPastContent(_ draft: TimesheetDraft) -> Bool {
        draft.operativeSignedAt != nil
            || draft.managerSignedAt != nil
            || !draft.expenseEntries.isEmpty
            || !draft.priceWorkEntries.isEmpty
            || !draft.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshPastWeeksFromLocalCache(userId: String) {
        let current = currentWeek
        var byPeriod: [String: WeekRange] = [:]
        func keep(_ week: WeekRange) {
            guard week.start != current.start || week.end != current.end else { return }
            byPeriod[periodIdentity(week)] = week
        }
        for weekStart in TimesheetDraftStore.discoverStoredWeekStarts(userId: userId) {
            let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: userId, weekStart: weekStart)
            keep(TimesheetPayrollPolicy.periodMatchingStoredStart(weekStart, storedEnd: storedEnd, settings: settings))
        }
        for week in TimesheetPayrollPolicy.selectablePayPeriods(settings: settings) {
            keep(week)
        }
        let sorted = byPeriod.values.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.end > rhs.end
        }
        if !sorted.isEmpty {
            pastWeeks = sorted
        }
    }

    private func periodIdentity(_ week: WeekRange) -> String {
        let start = CanonicalBusinessEngine.dayKeyInOrganizationZone(week.start) ?? ""
        let end = CanonicalBusinessEngine.dayKeyInOrganizationZone(week.end) ?? ""
        return "\(start)|\(end)"
    }

    private func loadPastWeeks() async {
        guard let userId = userStore.displayUser?.id else { return }

        await MainActor.run {
            refreshPastWeeksFromLocalCache(userId: userId)
            isLoadingPastWeeks = true
        }
        defer { Task { @MainActor in isLoadingPastWeeks = false } }

        let current = currentWeek
        var byPeriod: [String: WeekRange] = [:]
        func keep(_ week: WeekRange) {
            guard week.start != current.start || week.end != current.end else { return }
            byPeriod[periodIdentity(week)] = week
        }

        for weekStart in TimesheetDraftStore.discoverStoredWeekStarts(userId: userId) {
            let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: userId, weekStart: weekStart)
            keep(TimesheetPayrollPolicy.periodMatchingStoredStart(weekStart, storedEnd: storedEnd, settings: settings))
        }

        if let orgId = organizationId {
            if let rows = try? await firebaseBackend.listTimesheetStates(
                organizationId: orgId,
                userId: userId,
                limit: 200
            ) {
                for row in rows {
                    guard let weekStart = firestoreDate(row["weekStart"]),
                          let storedStart = TimesheetDraftStore.organizationDay(weekStart) else { continue }
                    TimesheetDraftStore.rememberBounds(from: row, userId: userId, weekStart: storedStart)
                    let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: userId, weekStart: storedStart)
                    let week = TimesheetPayrollPolicy.periodMatchingStoredStart(storedStart, storedEnd: storedEnd, settings: settings)
                    guard let draft = TimesheetDraftStore.decodeFirestoreMap(row) else { continue }
                    TimesheetDraftStore.save(draft, userId: userId, weekStart: storedStart, weekEnd: week.end)
                    keep(week)
                }
            }

            for week in TimesheetPayrollPolicy.selectablePayPeriods(settings: settings) {
                keep(week)
            }

            // Soft-refresh only the most recent periods from cloud (listing is local/policy; avoid 120 network hits).
            let recentToRefresh = byPeriod.values.sorted(by: { $0.start > $1.start }).prefix(24)
            for week in recentToRefresh {
                _ = await TimesheetDraftStore.refreshFromCloud(
                    userId: userId,
                    weekStart: week.start,
                    firebaseBackend: firebaseBackend,
                    organizationId: orgId
                )
            }
        }

        let sorted = byPeriod.values.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.end > rhs.end
        }
        await MainActor.run { pastWeeks = sorted }
    }

    var body: some View {
        let pending = pendingWeeks
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                myTimesheetsNavyHeader(pendingCount: pending.count)

                VStack(alignment: .leading, spacing: 0) {
                    hubCard(
                        title: "Current pay run period",
                        subtitle: currentWeek.title,
                        detail: "Review bookings, add extras, and sign your timesheet.",
                        symbol: "calendar",
                        tint: PPColor.brand,
                        family: .plan
                    ) {
                        MyTimesheetView(settings: settings, week: currentWeek)
                            .environmentObject(firebaseBackend)
                            .environmentObject(userStore)
                            .environmentObject(bookingStore)
                            .environmentObject(operativeStore)
                            .environmentObject(projectStore)
                            .environmentObject(managerScheduleStore)
                            .environmentObject(notificationService)
                    }
                    .padding(.top, 20)

                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            PPGroupLabel(text: "Pending timesheets")
                                .padding(.bottom, -10)
                            ForEach(pending, id: \.start) { week in
                                hubCard(
                                    title: week.title,
                                    subtitle: "Timesheet pending manager signature",
                                    detail: "You signed — waiting for your line manager to counter-sign.",
                                    symbol: "clock.fill",
                                    tint: PPFamily.trade.bottom,
                                    family: .trade
                                ) {
                                    MyTimesheetView(settings: settings, week: week)
                                        .environmentObject(firebaseBackend)
                                        .environmentObject(userStore)
                                        .environmentObject(bookingStore)
                                        .environmentObject(operativeStore)
                                        .environmentObject(projectStore)
                                        .environmentObject(managerScheduleStore)
                                        .environmentObject(notificationService)
                                }
                            }
                        }
                    }

                    if isLoadingPastWeeks && pastWeeks.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading past pay runs…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }

                    if !pastWeeks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            PPGroupLabel(text: "Past timesheets")
                                .padding(.bottom, -10)
                            ForEach(pastWeeks, id: \.self) { week in
                                hubCard(
                                    title: week.title,
                                    subtitle: pastSubtitle(for: week),
                                    detail: "View breakdown, signatures, and generate invoice again.",
                                    symbol: "clock.arrow.circlepath",
                                    tint: .secondary,
                                    family: .system
                                ) {
                                    MyTimesheetView(settings: settings, week: week)
                                        .environmentObject(firebaseBackend)
                                        .environmentObject(userStore)
                                        .environmentObject(bookingStore)
                                        .environmentObject(operativeStore)
                                        .environmentObject(projectStore)
                                        .environmentObject(managerScheduleStore)
                                        .environmentObject(notificationService)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("My Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .onAppear {
            if let userId = userStore.displayUser?.id {
                refreshPastWeeksFromLocalCache(userId: userId)
            }
        }
        .task(id: organizationId) {
            await loadPastWeeks()
        }
    }

    private func pastSubtitle(for week: WeekRange) -> String {
        guard let user = userStore.displayUser else { return "Previous period" }
        let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
        if TimesheetApprovalPolicy.isExported(draft) { return "Exported" }
        if TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) { return "Signed off" }
        if TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user) {
            return "Timesheet pending manager signature"
        }
        if TimesheetApprovalPolicy.operativeHasSigned(draft) { return "Partially signed" }
        return "Saved draft"
    }

    /// Home-style navy header: the current pay run and counts the hub already lists.
    private func myTimesheetsNavyHeader(pendingCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(eyebrow: "Current pay run period", title: currentWeek.title)

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(pendingCount)", label: "Pending manager signature", highlight: pendingCount > 0)
                PPStatDivider()
                PPStat(value: "\(pastWeeks.count)", label: "Past timesheets")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    @ViewBuilder
    private func hubCard<Destination: View>(
        title: String,
        subtitle: String,
        detail: String,
        symbol: String,
        tint: Color,
        family: PPFamily,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(alignment: .center, spacing: 13) {
                PPIconTile(symbol: symbol, family: family, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        }
        .accessibilityIdentifier("timesheets.chevronRight")
        .buttonStyle(PPPressableButtonStyle())
    }
}

/// RULEBOOK 1.45.0 §8: the owner's price work or expense entry a Delete asks about.
enum TimesheetEntryTarget: Equatable {
    case priceWork(UUID)
    case expense(UUID)
}

private struct MyTimesheetView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    /// RULEBOOK 1.43.0 §8 (review r318): the period's bookings are asked for again when the app becomes active.
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var holidayStore: HolidayStore

    let settings: OrganizationInvoicingSettings

    @State private var week: WeekRange
    @State private var draft = TimesheetDraft()
    @State private var showAddExpense = false
    @State private var showAddPriceWork = false
    @State private var showPostSignExtraWarning = false
    @State private var pendingExtraMode: TimesheetExtraMode?
    @State private var showPriceWorkSheet = false
    @State private var showExpenseSheet = false
    /// RULEBOOK 1.45.0 §8: the owner's entry being edited or deleted (`canEditTimesheetEntry`).
    @State private var editingPriceWorkEntry: TimesheetPriceWorkEntry?
    @State private var editingExpenseEntry: TimesheetExpenseEntry?
    @State private var deletingEntry: TimesheetEntryTarget?
    /// A server copy of this sheet arrived while an edit sheet was open; it loads when that sheet closes.
    @State private var serverTimesheetChangedWhileEditing = false
    /// The "Note to manager" box has the keyboard. Each keystroke saves, and the live listener would
    /// otherwise reload the server copy over the box mid-typing and drop what was just typed.
    @FocusState private var managerNoteFocused: Bool
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    /// Pay-rate history read state: a failed read blocks sign-off, the agreed snapshot, invoices and exports.
    @State private var payInputsState: PayInputsLoadState = .loading
    /// Why pay cannot be worked out yet, else nil (`PayInputsLoad.blockMessage`).
    private var payInputsBlockMessage: String? {
        if periodLoadFailed { return TimesheetDraftStore.periodReadFailedMessage }
        return PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: periodBookingsState
        )
    }

    /// RULEBOOK 1.43.0 §8 `timesheetSnapshotReady`: the period's labour and manager site bookings have arrived
    /// (`PayInputsLoad.periodBookings`). Sign-off, the counter-signature, the agreed snapshot and invoices wait for them.
    private var periodBookingsState: (loaded: Bool, failed: Bool) {
        PayInputsLoad.periodBookings(
            firebaseBackend: firebaseBackend,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            from: week.start
        )
    }

    /// Asks for the period's bookings when the download does not reach it, or when the last read failed (Retry).
    private func ensurePeriodBookings() {
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            from: week.start,
            retryFailed: true
        )
    }
    @State private var showInvoiceUTRWarning = false
    /// Off each time the screen opens (`SENSITIVE_EXPORT_OPTION_LABEL`).
    @State private var includeTaxIds = false
    @State private var invoiceTaxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile?
    @State private var showInvoiceSuccess = false
    @State private var generatedInvoiceURL: URL?
    @State private var isGeneratingInvoice = false
    @State private var invoiceErrorMessage: String?
    /// Shown when the cloud save failed (it used to fail silently).
    @State private var saveErrorMessage: String?
    /// RULEBOOK 1.43.0 §8: the empty-snapshot rebuild runs once per visit.
    @State private var snapshotRebuildTried = false
    /// RULEBOOK 1.43.0 (review r318, 2nd round): the period's sheet could not be read. Nothing is saved, signed or
    /// invoiced and no blank sheet is opened until a Retry reads it.
    @State private var periodLoadFailed = false

    /// RULEBOOK 1.43.0 §8 `timesheetSnapshotNeedsRebuild`: the stored snapshot has no labour lines, the period's live
    /// bookings (loaded) have some, and the sheet was not exported.
    private var snapshotNeedsRebuild: Bool {
        guard payInputsBlockMessage == nil, let stored = draft.weeklyReportOverride, stored.lines.isEmpty else { return false }
        return CanonicalBusinessEngine.timesheetSnapshotNeedsRebuild(
            storedOverrideLineCount: stored.lines.count,
            overrideApprovedAt: stored.approvedAt,
            exportedAt: draft.exportedAt,
            managerSignedAt: draft.managerSignedAt,
            liveLabourLines: TimesheetPayrollCollector.snapshotRebuildLines(payrollLines)
        )
    }

    private enum TimesheetExtraMode {
        case priceWork, expense
    }

    init(settings: OrganizationInvoicingSettings, week: WeekRange? = nil) {
        self.settings = settings
        _week = State(initialValue: week ?? TimesheetPayrollPolicy.payPeriodContaining(settings: settings))
    }

    private var currentUserId: String {
        userStore.displayUser?.id ?? "unknown"
    }

    private var shiftCount: Int {
        invoiceRows.count
    }

    private var managerHasSigned: Bool { draft.managerSignedAt != nil }

    /// RULEBOOK 1.22.0 §8 `CanonicalBusinessEngine.timesheetTotals`: this sheet's totals as the invoice will have them
    /// — review decisions apply once the line manager has signed (web `draftTimesheetTotals`).
    private var ownerTotals: RulebookTimesheetTotals? {
        TimesheetTotalsSource.totals(lines: payrollLines, draft: draft, decided: managerHasSigned, subject: userStore.displayUser, period: week.start...week.end)
    }

    /// The same sheet at the amounts the person entered (`timesheetTotals` in `raw` mode, no labour reviews), for the
    /// "before line manager adjustments" figures and the sign sheet.
    private var submittedTotals: RulebookTimesheetTotals? {
        var unreviewed = draft
        unreviewed.payrollLineReviews = [:]
        return TimesheetTotalsSource.totals(lines: payrollLines, draft: unreviewed, decided: false, subject: userStore.displayUser, period: week.start...week.end)
    }

    private var weekInvoicePeriod: InvoicePeriodOption {
        InvoicePeriodOption(
            id: "timesheet-\(Int(week.start.timeIntervalSince1970))",
            title: "Signed timesheet period",
            dateRangeText: week.title,
            startDate: week.start,
            endDate: week.end
        )
    }

    private var invoiceRows: [InvoiceLineItem] {
        payrollLines.map { InvoiceLineItem(payrollLine: $0) }
    }

    private var payrollLines: [TimesheetPayrollLineItem] {
        guard let currentUser = userStore.displayUser else { return [] }
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let summary = TimesheetPayrollCollector.collect(
            for: currentUser,
            week: week,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            policy: policy,
            organization: firebaseBackend.currentOrganization,
            scheduleOptions: scheduleOptions,
            relatedUsers: userStore.organizationUsers
        )
        return summary.lineItems
    }

    /// Approved annual leave in this period (`timesheetLeaveLines`): information rows only.
    private var leaveLines: [CanonicalTimesheetLeaveLine] {
        guard let currentUser = userStore.displayUser else { return [] }
        return TimesheetPayrollCollector.leaveLines(
            for: currentUser,
            in: week.start...week.end,
            holidays: holidayStore.bookings,
            operatives: operativeStore.allOperatives,
            organization: firebaseBackend.currentOrganization
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(week.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let saveErrorMessage {
                    Label(saveErrorMessage, systemImage: "exclamationmark.icloud.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("timesheets.saveError")
                }

                if managerHasSigned, TimesheetDraftAdjustments.managerAdjustmentCount(draft: draft) > 0 {
                    TimesheetManagerAdjustmentSummaryCard(
                        draft: draft,
                        managerName: draft.managerSignedByName ?? "Line manager"
                    )
                }

                sectionHeader("This period")

                VStack(alignment: .leading, spacing: 0) {
                    if invoiceRows.isEmpty && leaveLines.isEmpty {
                        Text("No bookings found for this payment period yet. Hours from site, office, site survey and other schedule entries will appear here automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    } else {
                        ForEach(Array(invoiceRows.enumerated()), id: \.offset) { index, row in
                        let removed = TimesheetDraftAdjustments.isPayrollLineRemoved(
                            line: row.payrollLine,
                            draft: draft,
                            managerHasSigned: managerHasSigned
                        )
                        let review = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: row.payrollLine.id, live: row.payrollLine)
                        let decision = review?.decision ?? .approved
                        let effective = TimesheetDraftAdjustments.effectivePayrollAmount(
                            line: row.payrollLine,
                            draft: draft,
                            managerHasSigned: managerHasSigned
                        )
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.subheadline.weight(.bold))
                                    .strikethrough(removed)
                                Text("\(row.jobNumber) \(row.projectName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .strikethrough(removed)
                                // RULEBOOK 1.43.0 §8 `timesheetLineClockText`: the line's own clock times only (standard
                                // or overtime part); the hours and any multiplied text are on the rate line below.
                                if let clock = TimesheetPayrollCollector.lineClockLabel(row.details) {
                                    Text(clock)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .strikethrough(removed)
                                }
                                Text(timesheetHoursRateLine(for: row))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(row.shouldHighlightRateInOrange ? Color.orange : Color.primary)
                                    .strikethrough(removed)
                                if row.isOverlapping {
                                    Text(CanonicalBusinessEngine.overlappingBookingNote)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PPColor.warningAmber)
                                }
                            }
                            Spacer()
                            TimesheetAdjustedAmountText(
                                original: row.amount,
                                effective: effective,
                                decision: decision,
                                managerHasSigned: managerHasSigned
                            )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(row.isOverlapping ? PPColor.warningAmber.opacity(0.12) : Color.clear)
                        .opacity(removed ? 0.55 : 1)
                        if index < invoiceRows.count - 1 { Divider().padding(.horizontal, 14) }
                    }
                    }
                    if !leaveLines.isEmpty {
                        if !invoiceRows.isEmpty { Divider().padding(.horizontal, 14) }
                        TimesheetLeaveInfoRows(lines: leaveLines)
                    }
                    // RULEBOOK 1.22.0 §8: every figure is `CanonicalBusinessEngine.timesheetTotals` (the invoice's rows).
                    let totals = ownerTotals
                    let submitted = submittedTotals
                    HStack {
                        Text("Hours subtotal")
                            .font(.headline)
                        Spacer()
                        Text(totals.map { OrgMoney.format($0.labour) } ?? "—")
                            .font(.headline)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    if let totals, totals.extras > 0 || totals.submittedExtras > 0 {
                        HStack {
                            Text(managerHasSigned ? "Approved extras" : "Extras (price work & expenses)")
                                .font(.subheadline)
                            Spacer()
                            if managerHasSigned && abs(totals.extras - totals.submittedExtras) >= 0.005 {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(OrgMoney.format(totals.submittedExtras))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .strikethrough()
                                    Text(OrgMoney.format(totals.extras))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Text(OrgMoney.format(totals.extras))
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                    }
                    Divider().padding(.horizontal, 14)
                    HStack {
                        Text("Total")
                            .font(.headline)
                        Spacer()
                        Text(totals.map { OrgMoney.format($0.total) } ?? "—")
                            .font(.title3.weight(.bold))
                        if managerHasSigned, let totals, let submitted, abs(totals.total - submitted.total) >= 0.005 {
                            Text("Includes line manager adjustments")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                paymentSummary(settings: settings)

                if !draft.priceWorkEntries.isEmpty {
                    sectionCard(title: managerHasSigned ? "Price work (after review)" : "Price Work") {
                        ForEach(draft.priceWorkEntries) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .fontWeight(.semibold)
                                        .strikethrough(managerHasSigned && item.managerDecision == .declined)
                                    Text(item.details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    // RULEBOOK 1.45.0 §8: the evidence count (`claimEvidenceCountText`) and each file.
                                    let evidenceCount = CanonicalBusinessEngine.claimEvidenceCountText(item.evidence.count)
                                    if !evidenceCount.isEmpty {
                                        Text(evidenceCount)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    ClaimEvidenceLinks(evidence: item.evidence)
                                    if managerHasSigned && item.managerDecision != .pending {
                                        Text(item.managerDecision.label)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(item.managerDecision.tint)
                                    }
                                    entryActions(
                                        edit: { editingPriceWorkEntry = item },
                                        delete: { deletingEntry = .priceWork(item.id) }
                                    )
                                }
                                Spacer()
                                TimesheetAdjustedAmountText(
                                    original: item.amount,
                                    effective: TimesheetDraftAdjustments.effectivePriceWorkAmount(item, managerHasSigned: managerHasSigned),
                                    decision: item.managerDecision,
                                    managerHasSigned: managerHasSigned
                                )
                            }
                        }
                    }
                }

                if !draft.expenseEntries.isEmpty {
                    sectionCard(title: managerHasSigned ? "Expenses (after review)" : "Expenses") {
                        ForEach(draft.expenseEntries) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .fontWeight(.semibold)
                                        .strikethrough(managerHasSigned && item.managerDecision == .declined)
                                    Text(item.details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    // RULEBOOK 1.45.0 §8: the evidence count, each file, and the older-receipt note.
                                    let evidenceCount = CanonicalBusinessEngine.claimEvidenceCountText(item.evidence.count)
                                    if !evidenceCount.isEmpty {
                                        Text(evidenceCount)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    ClaimEvidenceLinks(evidence: item.evidence, legacyReceiptName: item.receiptName)
                                    if managerHasSigned && item.managerDecision != .pending {
                                        Text(item.managerDecision.label)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(item.managerDecision.tint)
                                    }
                                    entryActions(
                                        edit: { editingExpenseEntry = item },
                                        delete: { deletingEntry = .expense(item.id) }
                                    )
                                }
                                Spacer()
                                TimesheetAdjustedAmountText(
                                    original: item.amount,
                                    effective: TimesheetDraftAdjustments.effectiveExpenseAmount(item, managerHasSigned: managerHasSigned),
                                    decision: item.managerDecision,
                                    managerHasSigned: managerHasSigned
                                )
                            }
                        }
                    }
                }

                sectionHeader("Add to this timesheet")
                // RULEBOOK 1.43.0 §8 `timesheetOwnerCanAddExtras`: nothing is added once the line manager has signed
                // (a self-signed sheet stays open; adding asks the person to sign again).
                let extras = extrasPermission
                if !extras.allowed, let message = extras.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(PPColor.warningAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("timesheets.extrasLocked")
                }
                HStack(spacing: 10) {
                    Button {
                        beginAddingExtra(.priceWork)
                    } label: {
                        addonTile(title: "Price Work", subtitle: "Agreed extras", symbol: "bolt.fill", tint: Color(red: 0.329, green: 0.29, blue: 0.718))
                    }
                    .accessibilityIdentifier("timesheets.priceWork")
                    .buttonStyle(.plain)
                    .disabled(!extras.allowed)
                    .opacity(extras.allowed ? 1 : 0.5)
                    Button {
                        beginAddingExtra(.expense)
                    } label: {
                        addonTile(title: "Expenses", subtitle: "+ receipts", symbol: "sterlingsign.circle.fill", tint: Color(red: 0.706, green: 0.325, blue: 0.035))
                    }
                    .accessibilityIdentifier("timesheets.expenses")
                    .buttonStyle(.plain)
                    .disabled(!extras.allowed)
                    .opacity(extras.allowed ? 1 : 0.5)
                }

                // RULEBOOK §8: no "note to manager" on a self-signed sheet (`timesheetSelfSigned`).
                if let user = userStore.displayUser, TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Note to manager")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $draft.managerNote)
                            .accessibilityIdentifier("timesheets.textEditor")
                            .focused($managerNoteFocused)
                            .frame(minHeight: 74)
                            .padding(8)
                            .background(ProjectWorksRevampColors.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: draft.managerNote) { _, _ in _ = saveDraft() }
                    }
                    .padding(14)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(
                        (userStore.displayUser.map { TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0) } == true)
                        ? "If you don't agree with the hours shown, contact your line manager to amend your booking schedule before signing. Agreed changes appear on a new timesheet."
                        : "If you don't agree with the hours shown, amend your booking schedule before signing. Agreed changes appear on a new timesheet."
                    )
                        .font(.footnote)
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                }
                .padding(12)
                .background(ProjectWorksRevampColors.requiredPillBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let blocked = payInputsBlockMessage, draft.operativeSignedAt == nil {
                    PayInputsFailureBanner(message: blocked) {
                        Task { await loadDayRateHistory() }
                    }
                }
                if draft.operativeSignedAt == nil && payInputsBlockMessage == nil {
                    NavigationLink {
                        SignTimesheetView(
                            week: week,
                            // `CanonicalBusinessEngine.timesheetTotals` at the amounts entered (raw, before review).
                            hoursAmount: submittedTotals?.labour ?? 0,
                            priceWorkAmount: submittedTotals?.priceWork ?? 0,
                            expensesAmount: submittedTotals?.expenses ?? 0,
                            signerName: userStore.displayUser?.fullName.isEmpty == false
                                ? (userStore.displayUser?.fullName ?? "Operative")
                                : (userStore.displayUser?.email ?? "Operative"),
                            requiresLineManagerCounterSign: userStore.displayUser.map {
                                TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0)
                            } ?? false,
                            onApprove: { signatureImageData in
                                markTimesheetSigned(signatureImageData: signatureImageData)
                            }
                        )
                    } label: {
                        Label("Continue to sign", systemImage: "pencil.and.scribble")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("timesheets.operative")
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 8) {
                        if let base64 = draft.operativeSignatureImageBase64,
                           let data = Data(base64Encoded: base64),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 88)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color(.separator), lineWidth: 0.8)
                                )
                        }
                        Text("Signed by \(draft.operativeSignedByName ?? "Operative") on \(draft.operativeSignedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                if let currentUser = userStore.displayUser,
                   TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: currentUser),
                   let managerSignedAt = draft.managerSignedAt {
                    VStack(spacing: 8) {
                        if let base64 = draft.managerSignatureImageBase64,
                           let data = Data(base64Encoded: base64),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 88)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color(.separator), lineWidth: 0.8)
                                )
                        }
                        Text("Manager: \(draft.managerSignedByName ?? "Line manager") · \(managerSignedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                if let currentUser = userStore.displayUser,
                   TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: currentUser) {
                    if TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: currentUser) {
                        Text("To edit this timesheet, please go to the signed off timesheets page, export it and then edit within the exported timesheets tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    InvoiceTaxIdsOption(subject: currentUser, isOn: $includeTaxIds)
                    Button {
                        beginInvoiceGeneration(for: currentUser)
                    } label: {
                        HStack {
                            Spacer()
                            if isGeneratingInvoice {
                                ProgressView().tint(.white)
                            } else {
                                Text("Generate Invoice")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("timesheets.generateInvoice")
                    .buttonStyle(.plain)
                    .disabled(isGeneratingInvoice)

                    if let invoiceErrorMessage {
                        Text(invoiceErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    // Always visible: grey until fully approved (self-sign if no LM, else manager counter-sign).
                    Text("Generate Invoice")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray4))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let currentUser = userStore.displayUser {
                        if draft.operativeSignedAt == nil {
                            Text(
                                TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: currentUser)
                                ? "Add any expenses or price work, then sign your timesheet. Your line manager will counter-sign before you can invoice."
                                : "Add any expenses or price work, then confirm and approve your timesheet to unlock Generate Invoice."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else if TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: currentUser) {
                            Text("Timesheet pending manager signature — Generate Invoice unlocks after your line manager counter-signs.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Re-sign your timesheet to generate an invoice.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }

                if false {
                    Button("Add price work") {
                        showAddPriceWork = true
                    }
                    .accessibilityIdentifier("timesheets.addPriceWork")
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Add expense") {
                        showAddExpense = true
                    }
                    .accessibilityIdentifier("timesheets.addExpense")
                    .buttonStyle(.bordered)

                    if draft.operativeSignedAt == nil {
                        Button("Sign timesheet") {
                            draft.operativeSignedAt = Date()
                            saveDraft()
                        }
                        .accessibilityIdentifier("timesheets.signTimesheet")
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        // RULEBOOK §2: timesheet signing is online only.
                        .onlineOnly(isOnline: smartCache.isOnline)
                    } else {
                        Text("Signed on \(draft.operativeSignedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Timesheet")
        .navigationBarTitleDisplayMode(.inline)
        // RULEBOOK 1.43.0 (review r318, 3rd round): while the sheet cannot be read, only the message and Retry — no
        // blank sheet to edit, sign or add to.
        .overlay {
            if periodLoadFailed {
                TimesheetPeriodLoadFailedView { Task { await refreshDraftFromCloud() } }
            }
        }
        .onAppear { loadDraft() }
        .task { await loadDayRateHistory() }
        // RULEBOOK 1.43.0 §8 (review r318): the period gate re-checks (and reloads the bookings if no server answer
        // covers the period) when the app comes back to the foreground or the connection returns.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ensurePeriodBookings() }
        }
        .onChange(of: smartCache.isOnline) { _, online in
            if online { ensurePeriodBookings() }
        }
        // RULEBOOK 1.43.0 §8 `timesheetSnapshotNeedsRebuild`: a self-signed sheet whose snapshot froze empty is rebuilt
        // from the live bookings once they have loaded (signatures unchanged), once per visit.
        .onChange(of: snapshotNeedsRebuild, initial: true) { _, needs in
            guard needs, !snapshotRebuildTried, !isEditingTimesheet,
                  let user = userStore.displayUser,
                  !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user) else { return }
            snapshotRebuildTried = true
            saveDraft()
        }
        // RULEBOOK 1.26.0 §8 `CanonicalBusinessEngine.rateHistoryQueryPlan`: the whole collection while `privatePay` is
        // off, else this person's rows.
        .listensWhileOpen("operativeDayRateHistory", key: "operativeDayRateHistory.myTimesheet",
                          targetSuffix: firebaseBackend.rateHistoryListenSuffix, firebaseBackend: firebaseBackend,
                          query: firebaseBackend.rateHistoryListenQuery(subjectId: firebaseBackend.currentUser?.uid ?? "")) { await loadDayRateHistory() }
        // Approved leave rows read the holiday list (read only); load it when nothing is cached yet.
        .task { if holidayStore.bookings.isEmpty { await holidayStore.loadData() } }
        // Live sheet while open: a line manager's sign-off or review on web shows here. An edit sheet that is
        // open is never overwritten — the server copy loads when it closes.
        .task(id: week.start) { listenToServerTimesheet() }
        .onDisappear { firebaseBackend.stopLiveListener(key: Self.liveTimesheetKey) }
        .onChange(of: isEditingTimesheet) { _, editing in
            if !editing && serverTimesheetChangedWhileEditing {
                serverTimesheetChangedWhileEditing = false
                Task { await refreshDraftFromCloud() }
            }
        }
        .confirmationDialog(
            "Re-sign required",
            isPresented: $showPostSignExtraWarning,
            titleVisibility: .visible
        ) {
            Button("Accept — add anyway") {
                // RULEBOOK 1.43.0: never once the line manager has signed (that left the sheet half signed).
                guard extrasPermission.allowed else {
                    pendingExtraMode = nil
                    saveErrorMessage = extrasPermission.message
                    return
                }
                TimesheetApprovalPolicy.clearSignatures(draft: &draft)
                saveDraft()
                openPendingExtraSheet()
            }
                .accessibilityIdentifier("timesheets.acceptAddAnyway")
            Button("Decline", role: .cancel) {
                pendingExtraMode = nil
            }
                .accessibilityIdentifier("timesheets.decline")
        } message: {
            Text(postSignWarningMessage)
        }
        .sheet(isPresented: $showPriceWorkSheet) {
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .priceWork, editing: nil as TimesheetPriceWorkEntry?) { (entry: TimesheetPriceWorkEntry) async -> String? in
                    await applyEntryChange { $0.priceWorkEntries.append(entry) }
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
            }
        }
        .sheet(isPresented: $showExpenseSheet) {
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .expense, editing: nil as TimesheetExpenseEntry?) { (entry: TimesheetExpenseEntry) async -> String? in
                    await applyEntryChange { $0.expenseEntries.append(entry) }
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
            }
        }
        // RULEBOOK 1.45.0 §8: Edit opens the same sheet prefilled; the entry keeps its id.
        .sheet(item: $editingPriceWorkEntry) { editing in
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .priceWork, editing: editing) { (entry: TimesheetPriceWorkEntry) async -> String? in
                    await applyEntryChange(clearingSignatures: entryEditClearsSignatures) { sheet in
                        if let index = sheet.priceWorkEntries.firstIndex(where: { $0.id == entry.id }) {
                            sheet.priceWorkEntries[index] = entry
                        }
                    }
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
            }
        }
        .sheet(item: $editingExpenseEntry) { editing in
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .expense, editing: editing) { (entry: TimesheetExpenseEntry) async -> String? in
                    await applyEntryChange(clearingSignatures: entryEditClearsSignatures) { sheet in
                        if let index = sheet.expenseEntries.firstIndex(where: { $0.id == entry.id }) {
                            sheet.expenseEntries[index] = entry
                        }
                    }
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
            }
        }
        .confirmationDialog(
            CanonicalBusinessEngine.timesheetEntryDeleteLabel,
            isPresented: Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }),
            titleVisibility: .visible
        ) {
            Button(CanonicalBusinessEngine.timesheetEntryDeleteLabel, role: .destructive) {
                guard let target = deletingEntry else { return }
                deletingEntry = nil
                Task { await deleteEntry(target) }
            }
            .accessibilityIdentifier("timesheets.entry.deleteConfirm")
            Button("Cancel", role: .cancel) { deletingEntry = nil }
        } message: {
            Text(entryEditClearsSignatures
                ? "\(CanonicalBusinessEngine.timesheetEntryDeleteConfirmMessage)\n\n\(postSignWarningMessage)"
                : CanonicalBusinessEngine.timesheetEntryDeleteConfirmMessage)
        }
        .sheet(isPresented: $showInvoiceUTRWarning) {
            InvoiceUTRBlankWarningSheet(
                onBack: { showInvoiceUTRWarning = false },
                onAccept: {
                    showInvoiceUTRWarning = false
                    Task { await runInvoiceGeneration() }
                }
            )
        }
        .sheet(isPresented: $showInvoiceSuccess) {
            if let generatedInvoiceURL {
                InvoiceGeneratedSuccessSheet(pdfURL: generatedInvoiceURL) {
                    showInvoiceSuccess = false
                    self.generatedInvoiceURL = nil
                }
            }
        }
    }

    private func beginInvoiceGeneration(for user: AppUser) {
        invoiceErrorMessage = nil
        Task {
            invoiceTaxIds = await InvoicePDFGenerationSupport.taxIdsForExport(subject: user, requested: includeTaxIds, userStore: userStore)
            if InvoicePDFGenerationSupport.shouldWarnBlankUTR(requested: includeTaxIds, taxIds: invoiceTaxIds) {
                showInvoiceUTRWarning = true
            } else {
                await runInvoiceGeneration()
            }
        }
    }

    private func runInvoiceGeneration() async {
        guard !isGeneratingInvoice else { return }
        await MainActor.run { isGeneratingInvoice = true; invoiceErrorMessage = nil }
        defer { Task { await MainActor.run { isGeneratingInvoice = false } } }

        if payInputsState != .loaded {
            await loadDayRateHistory()
        }
        if let blocked = payInputsBlockMessage {
            await MainActor.run { invoiceErrorMessage = blocked }
            return
        }

        let pdfURL = await InvoicePDFGenerationSupport.generatePDF(
            period: weekInvoicePeriod,
            settings: settings,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection,
            taxIds: invoiceTaxIds
        )

        await MainActor.run {
            if let pdfURL {
                generatedInvoiceURL = pdfURL
                showInvoiceSuccess = true
            } else {
                invoiceErrorMessage = "Failed to generate the invoice PDF."
            }
        }
    }

    private var postSignWarningMessage: String {
        guard let user = userStore.displayUser else {
            return "You have already signed your timesheet. Adding price work or expenses will require you to sign again."
        }
        if TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user), draft.managerSignedAt != nil {
            return "You have already signed your timesheet and your line manager has signed it off. If you add price work or expenses, you will need to have your timesheet signed again by yourself and your line manager."
        }
        return "You have already signed your timesheet. If you add price work or expenses, you will need to sign it again before generating an invoice."
    }

    /// RULEBOOK 1.43.0 §8 `timesheetOwnerCanAddExtras(sheet, { selfSigned: timesheetSelfSigned })`: whether the person
    /// may still add price work or expenses (not once their line manager has signed).
    private var extrasPermission: RulebookTimesheetExtrasPermission {
        let selfSigned = userStore.displayUser.map { !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0) } ?? false
        return CanonicalBusinessEngine.timesheetOwnerCanAddExtras(
            managerSignedAt: draft.managerSignedAt,
            approvedAt: draft.approvedAt,
            selfSigned: selfSigned
        )
    }

    private func beginAddingExtra(_ mode: TimesheetExtraMode) {
        // RULEBOOK 1.43.0: no add control and no signature cleared once the line manager has signed.
        let extras = extrasPermission
        guard extras.allowed else {
            saveErrorMessage = extras.message
            return
        }
        guard let user = userStore.displayUser else {
            pendingExtraMode = mode
            openPendingExtraSheet()
            return
        }
        if draft.operativeSignedAt != nil,
           TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) {
            pendingExtraMode = mode
            showPostSignExtraWarning = true
            return
        }
        pendingExtraMode = mode
        openPendingExtraSheet()
    }

    private func openPendingExtraSheet() {
        switch pendingExtraMode {
        case .priceWork:
            showPriceWorkSheet = true
        case .expense:
            showExpenseSheet = true
        case .none:
            break
        }
        pendingExtraMode = nil
    }

    @ViewBuilder
    private func metricChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.blue.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func addonTile(title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func sectionHeader(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    @ViewBuilder
    private func paymentSummary(settings: OrganizationInvoicingSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment Runs and Payouts")
                .font(.headline)
            if settings.paymentRunMode == .dateRanges {
                ForEach(Array(settings.normalizedRanges.enumerated()), id: \.element.id) { index, range in
                    Text("• Run: \(range.startDay) - \(range.endDay)")
                        .font(.subheadline)
                    if let payout = interleavedPayoutLine(settings: settings, runIndex: index) {
                        Text(payout)
                            .font(.subheadline)
                    }
                }
            } else {
                Text("• \(settings.recurringRunDisplaySummary)")
                    .font(.subheadline)
                if let payout = interleavedPayoutLine(settings: settings, runIndex: 0) {
                    Text(payout)
                        .font(.subheadline)
                }
            }
            if !settings.normalizedUserNote.isEmpty {
                Divider()
                Text("Note")
                    .font(.subheadline.weight(.semibold))
                Text(settings.normalizedUserNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private func interleavedPayoutLine(settings: OrganizationInvoicingSettings, runIndex: Int) -> String? {
        if settings.paymentDateMode == .specificDates {
            let dates = settings.normalizedPaymentDates
            guard runIndex < dates.count else { return nil }
            return "• Payout day \(dates[runIndex])"
        }
        return "• Payout every \(settings.recurringPaymentDay.title)"
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func loadDraft() {
        draft = TimesheetDraftStore.load(userId: currentUserId, weekStart: week.start)
        Task { await refreshDraftFromCloud() }
    }

    private static let liveTimesheetKey = "timesheet.owner"

    /// An add / edit sheet or the re-sign prompt is open: the person may be part-way through a change.
    private var isEditingTimesheet: Bool {
        showAddExpense || showAddPriceWork || showPriceWorkSheet || showExpenseSheet || showPostSignExtraWarning
            || managerNoteFocused
    }

    private func listenToServerTimesheet() {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        firebaseBackend.listenTimesheetState(
            key: Self.liveTimesheetKey,
            organizationId: orgId,
            userId: currentUserId,
            weekStart: week.start
        ) {
            if isEditingTimesheet {
                serverTimesheetChangedWhileEditing = true
            } else {
                Task { await refreshDraftFromCloud() }
            }
        }
    }

    private func markTimesheetSigned(signatureImageData: Data) {
        // RULEBOOK 1.43.0 §8 (review r318): signing re-checks the period's bookings (reloads them when no server answer
        // covers the period), as the counter-signature does.
        ensurePeriodBookings()
        // Nothing is signed (or frozen) until pay can be worked out from loaded inputs.
        if let blocked = payInputsBlockMessage {
            saveErrorMessage = blocked
            return
        }
        let signedByName = userStore.displayUser?.fullName.isEmpty == false
            ? (userStore.displayUser?.fullName ?? "")
            : (userStore.displayUser?.email ?? "")
        guard TimesheetDraftStore.applySignOff(
            to: &draft,
            role: "operative",
            signedAt: Date(),
            signedByName: signedByName,
            signedByUserId: userStore.displayUser?.id,
            signatureImageBase64: signatureImageData.base64EncodedString()
        ) else { return }
        if let current = userStore.displayUser {
            TimesheetApprovalPolicy.applySelfApprovalIfNoLineManager(draft: &draft, user: current)
        }
        saveDraft()
        guard let current = userStore.displayUser else { return }
        guard TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: current) else { return }
        // `timesheetSubmittedRecipients(subject, roster)`: active line managers, else the admins; never the owner.
        let weekStart = week.start
        Task {
            await notificationService.notifyTimesheetSubmitted(
                signedByUser: current,
                weekStart: weekStart
            )
        }
    }

    /// RULEBOOK 1.45.0 §8 `canEditTimesheetEntry(sheet, { viewerIsOwner, selfSigned })`: the owner edits or deletes a
    /// price work or expense entry only while they may add one (never once the line manager has signed).
    private var entryEditPermission: RulebookTimesheetExtrasPermission {
        let selfSigned = userStore.displayUser.map { !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0) } ?? false
        return CanonicalBusinessEngine.canEditTimesheetEntry(
            managerSignedAt: draft.managerSignedAt,
            approvedAt: draft.approvedAt,
            viewerIsOwner: true,
            selfSigned: selfSigned
        )
    }

    /// A signed self-signed sheet asks the person to sign again after an edit or delete, as adding does.
    private var entryEditClearsSignatures: Bool {
        draft.operativeSignedAt != nil
    }

    /// Edit / Delete on one owner entry row (only when `canEditTimesheetEntry` allows).
    @ViewBuilder
    private func entryActions(edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        if entryEditPermission.allowed {
            HStack(spacing: 16) {
                Button(CanonicalBusinessEngine.timesheetEntryEditLabel, action: edit)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("timesheets.entry.edit")
                Button(CanonicalBusinessEngine.timesheetEntryDeleteLabel, role: .destructive, action: delete)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("timesheets.entry.delete")
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
    }

    private func deleteEntry(_ target: TimesheetEntryTarget) async {
        if let message = await applyEntryChange(clearingSignatures: entryEditClearsSignatures, { sheet in
            switch target {
            case .priceWork(let id): sheet.priceWorkEntries.removeAll { $0.id == id }
            case .expense(let id): sheet.expenseEntries.removeAll { $0.id == id }
            }
        }) {
            saveErrorMessage = message
        }
    }

    /// Applies an entry change, saves the sheet and waits for the save. On a refusal the sheet goes back to how it was
    /// and the message is returned (the entry sheet then discards any file it just uploaded).
    private func applyEntryChange(
        clearingSignatures: Bool = false,
        _ change: (inout TimesheetDraft) -> Void
    ) async -> String? {
        guard !periodLoadFailed else { return TimesheetDraftStore.periodReadFailedMessage }
        let previous = draft
        if clearingSignatures { TimesheetApprovalPolicy.clearSignatures(draft: &draft) }
        change(&draft)
        guard let task = saveDraft() else { return saveErrorMessage }
        let message = await task.value
        if let message {
            draft = previous
            TimesheetDraftStore.save(previous, userId: currentUserId, weekStart: week.start, weekEnd: week.end)
            return message
        }
        return nil
    }

    @discardableResult
    private func saveDraft() -> Task<String?, Never>? {
        // RULEBOOK 1.43.0 (review r318, 2nd round): nothing is saved while the period's sheet could not be read.
        guard !periodLoadFailed else {
            saveErrorMessage = TimesheetDraftStore.periodReadFailedMessage
            return nil
        }
        // The agreed snapshot is never frozen from inputs that did not load (`PayInputsLoad`).
        if let current = userStore.displayUser, payInputsBlockMessage == nil || draft.weeklyReportOverride != nil {
            // The owner's own save: with a line manager it never builds the approved snapshot.
            TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
                to: &draft,
                user: current,
                week: week,
                bookings: bookingStore.bookings,
                managerBookings: managerScheduleStore.managerSiteBookings,
                operatives: operativeStore.allOperatives,
                projects: projectStore.projects,
                smallWorks: projectStore.smallWorks,
                history: dayRateHistoryCollection,
                policy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
                organization: firebaseBackend.currentOrganization,
                scheduleOptions: firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions(),
                viewer: current,
                relatedUsers: userStore.organizationUsers,
                writerIsReviewer: TimesheetApprovalPolicy.writerIsReviewer(
                    writerId: current.id,
                    writer: current,
                    subjectUserId: current.id,
                    subject: current
                ),
                // RULEBOOK 1.43.0 §8: an empty frozen snapshot is rebuilt only from loaded bookings and pay inputs.
                snapshotInputsReady: payInputsBlockMessage == nil
            )
        }
        TimesheetDraftStore.save(draft, userId: currentUserId, weekStart: week.start, weekEnd: week.end)
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return nil }
        let snapshot = draft
        let current = userStore.displayUser
        return Task {
            let message = await TimesheetDraftStore.saveToCloud(
                snapshot,
                userId: currentUserId,
                weekStart: week.start,
                weekEnd: week.end,
                firebaseBackend: firebaseBackend,
                organizationId: orgId,
                writer: current,
                subject: current
            )
            saveErrorMessage = message
            return message
        }
    }

    private func projectLabel(for id: UUID) -> (jobNumber: String, siteName: String) {
        if let project = projectStore.projects.first(where: { $0.id == id }) {
            return (project.jobNumber, project.siteName)
        }
        if let project = projectStore.smallWorks.first(where: { $0.id == id }) {
            return (project.jobNumber, project.siteName)
        }
        return ("—", "Unknown Project")
    }

    private func refreshDraftFromCloud() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let read = await TimesheetDraftStore.refreshFromCloudReporting(
            userId: currentUserId,
            weekStart: week.start,
            firebaseBackend: firebaseBackend,
            organizationId: orgId
        )
        // RULEBOOK 1.43.0 (review r318): a read that did not answer is an error, never a new sheet.
        if read.failed {
            await MainActor.run {
                periodLoadFailed = true
                saveErrorMessage = TimesheetDraftStore.periodReadFailedMessage
            }
            return
        }
        await MainActor.run {
            if periodLoadFailed { saveErrorMessage = nil }
            periodLoadFailed = false
        }
        guard let remote = read.draft else {
            // No server sheet clears the local copy; show what is left (nothing) unless a change is open.
            await MainActor.run {
                guard !isEditingTimesheet,
                      organizationIdsMatch(firebaseBackend.currentOrganization?.firestoreDocumentId, orgId) else { return }
                draft = TimesheetDraftStore.load(userId: currentUserId, weekStart: week.start, organizationId: orgId)
            }
            return
        }
        await MainActor.run {
            var updated = remote
            if let current = userStore.displayUser {
                TimesheetApprovalPolicy.applySelfApprovalIfNoLineManager(draft: &updated, user: current)
            }
            if updated.managerSignedAt != remote.managerSignedAt {
                draft = updated
                saveDraft()
            } else {
                draft = remote
            }
        }
    }

    /// A failed read is a failure (`PayInputsLoad`), never an empty history.
    private func loadDayRateHistory() async {
        ensurePeriodBookings()
        // The Retry of a failed period read reads the sheet again.
        if periodLoadFailed { await refreshDraftFromCloud() }
        let result = await PayInputsLoad.loadHistory(firebaseBackend)
        await MainActor.run {
            if let history = result.history { dayRateHistoryCollection = history }
            payInputsState = result.state
        }
    }

    /// RULEBOOK 1.20.4: an overtime line with a break shows "6.5h × 2 − 0.5h break = 12.5h" (`multipliedHoursText`,
    /// a signed line's stored text read back with `parseMultipliedHoursText`), never the back-calculated 6.25h.
    /// RULEBOOK 1.43.0: the details line above now shows only the clock part (`timesheetLineClockText`), so the
    /// multiplied text is shown here, once.
    private func timesheetHoursRateLine(for row: InvoiceLineItem) -> String {
        let hours = CanonicalBusinessEngine.payLineHoursText(
            details: row.details, paidHours: row.paidHours, isOvertimeLine: row.isOvertimeLine
        )
        return "\(hours) · \(row.timesheetRateAnnotation)"
    }

    private func formatTimesheetHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.01 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    private func managerBookingLabels(for booking: ManagerSiteBooking) -> (jobNumber: String, siteName: String) {
        switch booking.locationType {
        case .project, .smallWork:
            if let locationId = booking.locationId {
                return projectLabel(for: locationId)
            }
            return ("—", "Site")
        case .office:
            return ("—", "Office")
        case .workingFromHome:
            return ("—", "Working from home")
        case .siteSurvey:
            return ("—", "Site survey")
        case .custom:
            let name = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ("—", name.isEmpty ? "Custom location" : name)
        }
    }
}

private struct PreviousTimesheetsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore

    let settings: OrganizationInvoicingSettings

    @State private var runs: [PreviousTimesheetRun] = []
    @State private var selectedRunId: String = ""
    @State private var isLoading = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    /// Pay-rate history read state: a failed read blocks sign-off, the agreed snapshot, invoices and exports.
    @State private var payInputsState: PayInputsLoadState = .loading
    /// Why pay cannot be worked out yet, else nil (`PayInputsLoad.blockMessage`).
    private var payInputsBlockMessage: String? {
        PayInputsLoad.blockMessage(state: payInputsState, organization: firebaseBackend.currentOrganization)
    }
    @State private var showInvoiceUTRWarning = false
    /// Off each time the screen opens (`SENSITIVE_EXPORT_OPTION_LABEL`).
    @State private var includeTaxIds = false
    @State private var invoiceTaxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile?
    @State private var showInvoiceSuccess = false
    @State private var generatedInvoiceURL: URL?
    @State private var isGeneratingInvoice = false
    @State private var invoiceErrorMessage: String?
    @State private var pendingInvoicePeriod: InvoicePeriodOption?

    private var selectedRun: PreviousTimesheetRun? {
        runs.first(where: { $0.id == selectedRunId }) ?? runs.first
    }

    private var selectedPeriod: InvoicePeriodOption? {
        guard let selectedRun else { return nil }
        return InvoicePeriodOption(
            id: selectedRun.id,
            title: "Signed timesheet period",
            dateRangeText: selectedRun.week.title,
            startDate: selectedRun.week.start,
            endDate: selectedRun.week.end
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Previous payment runs")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if runs.isEmpty {
                    if isLoading {
                        ProgressView("Loading previous timesheets...")
                    } else {
                        ContentUnavailableView(
                            "No Previous Timesheets",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Previous runs appear here once submitted.")
                        )
                    }
                } else {
                    Menu {
                        ForEach(runs) { run in
                            Button {
                                selectedRunId = run.id
                            } label: {
                                Text(run.week.title)
                            }
                                .accessibilityIdentifier("timesheets.row.\(run.id)")
                        }
                    } label: {
                        HStack {
                            Text("Select previous payment run")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(selectedRun?.week.title ?? "Choose")
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.blue)
                        }
                        .padding(14)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                        .accessibilityIdentifier("timesheets.selectPreviousPaymentRun")

                    if let run = selectedRun {
                        summaryCard(run)
                        signatureCard(run)
                        if run.isCompleted,
                           let selectedPeriod,
                           let currentUser = userStore.displayUser {
                            InvoiceTaxIdsOption(subject: currentUser, isOn: $includeTaxIds)
                            Button {
                                beginInvoiceGeneration(for: currentUser, period: selectedPeriod)
                            } label: {
                                HStack {
                                    Spacer()
                                    if isGeneratingInvoice {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text("Generate Invoice")
                                            .fontWeight(.semibold)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 14)
                                .background(Color.green)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .accessibilityIdentifier("timesheets.generateInvoice")
                            .buttonStyle(.plain)
                            .disabled(isGeneratingInvoice)

                            if let invoiceErrorMessage {
                                Text(invoiceErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Previous Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDayRateHistory()
            await loadRuns()
        }
        .sheet(isPresented: $showInvoiceUTRWarning) {
            InvoiceUTRBlankWarningSheet(
                onBack: { showInvoiceUTRWarning = false },
                onAccept: {
                    showInvoiceUTRWarning = false
                    Task { await runPendingInvoiceGeneration() }
                }
            )
        }
        .sheet(isPresented: $showInvoiceSuccess) {
            if let generatedInvoiceURL {
                InvoiceGeneratedSuccessSheet(pdfURL: generatedInvoiceURL) {
                    showInvoiceSuccess = false
                    self.generatedInvoiceURL = nil
                }
            }
        }
    }

    private func beginInvoiceGeneration(for user: AppUser, period: InvoicePeriodOption) {
        invoiceErrorMessage = nil
        pendingInvoicePeriod = period
        Task {
            invoiceTaxIds = await InvoicePDFGenerationSupport.taxIdsForExport(subject: user, requested: includeTaxIds, userStore: userStore)
            if InvoicePDFGenerationSupport.shouldWarnBlankUTR(requested: includeTaxIds, taxIds: invoiceTaxIds) {
                showInvoiceUTRWarning = true
            } else {
                await runPendingInvoiceGeneration()
            }
        }
    }

    private func runPendingInvoiceGeneration() async {
        guard let period = pendingInvoicePeriod else { return }
        guard !isGeneratingInvoice else { return }
        if payInputsState != .loaded { await loadDayRateHistory() }
        if let blocked = payInputsBlockMessage {
            invoiceErrorMessage = blocked
            return
        }
        // RULEBOOK 1.43.0 §8 `timesheetSnapshotReady`: the invoice waits for the period's bookings.
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
            from: period.startDate, retryFailed: true
        )
        if let blocked = PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: PayInputsLoad.periodBookings(
                firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
                from: period.startDate
            )
        ) {
            invoiceErrorMessage = blocked
            return
        }
        isGeneratingInvoice = true
        invoiceErrorMessage = nil
        defer { isGeneratingInvoice = false }

        let pdfURL = await InvoicePDFGenerationSupport.generatePDF(
            period: period,
            settings: settings,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection,
            taxIds: invoiceTaxIds
        )

        if let pdfURL {
            generatedInvoiceURL = pdfURL
            showInvoiceSuccess = true
        } else {
            invoiceErrorMessage = "Failed to generate the invoice PDF."
        }
    }

    /// A failed read is a failure (`PayInputsLoad`), never an empty history.
    private func loadDayRateHistory() async {
        let result = await PayInputsLoad.loadHistory(firebaseBackend)
        await MainActor.run {
            if let history = result.history { dayRateHistoryCollection = history }
            payInputsState = result.state
        }
    }

    @ViewBuilder
    private func summaryCard(_ run: PreviousTimesheetRun) -> some View {
        // RULEBOOK 1.22.0 §8: `CanonicalBusinessEngine.timesheetTotals` — the summary total is the invoice total.
        let summary = bookingSummary(for: run.week, draft: run.draft)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(run.isCompleted ? "Completed" : "Sign Off Pending")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((run.isCompleted ? Color.green : Color.orange).opacity(0.16))
                    .foregroundStyle(run.isCompleted ? .green : .orange)
                    .clipShape(Capsule())
                Spacer()
                Text(run.week.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            row("Hours", summary.map { "\(formatHours($0.hours))h" } ?? "—")
            row("Overtime", summary.map { "\(formatHours($0.overtimeHours))h" } ?? "—")
            row("Price work", summary.map { OrgMoney.format($0.priceWork) } ?? "—")
            row("Expenses", summary.map { OrgMoney.format($0.expenses) } ?? "—")
            Divider()
            row("Summary total", summary.map { OrgMoney.format($0.total) } ?? "—")
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func signatureCard(_ run: PreviousTimesheetRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signature Status")
                .font(.headline)
            Text("Operative signed: \(run.draft.operativeSignedAt?.formatted(date: .abbreviated, time: .shortened) ?? "No")")
                .font(.footnote)
                .foregroundStyle(run.draft.operativeSignedAt == nil ? .orange : .green)
            Text("Manager signed: \(run.draft.managerSignedAt?.formatted(date: .abbreviated, time: .shortened) ?? "No")")
                .font(.footnote)
                .foregroundStyle(run.draft.managerSignedAt == nil ? .orange : .green)
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.subheadline)
    }

    private func loadRuns() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        guard let userId = userStore.displayUser?.id else { return }
        await MainActor.run { isLoading = true }
        var output: [PreviousTimesheetRun] = []
        if let rows = try? await firebaseBackend.listTimesheetStates(
            organizationId: orgId,
            userId: userId,
            limit: 200
        ) {
            for row in rows {
                guard let weekStart = firestoreDate(row["weekStart"]),
                      let storedStart = TimesheetDraftStore.organizationDay(weekStart) else { continue }
                TimesheetDraftStore.rememberBounds(from: row, userId: userId, weekStart: storedStart, organizationId: orgId)
                let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: userId, weekStart: storedStart, organizationId: orgId)
                let week = TimesheetPayrollPolicy.periodMatchingStoredStart(
                    storedStart,
                    storedEnd: storedEnd,
                    settings: settings
                )
                guard let draft = TimesheetDraftStore.decodeFirestoreMap(row) else { continue }
                var adjusted = draft
                if let user = userStore.displayUser {
                    TimesheetApprovalPolicy.applySelfApprovalIfNoLineManager(draft: &adjusted, user: user)
                }
                let hasAnyContent = !adjusted.expenseEntries.isEmpty
                    || !adjusted.priceWorkEntries.isEmpty
                    || adjusted.operativeSignedAt != nil
                    || adjusted.managerSignedAt != nil
                    || !adjusted.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard hasAnyContent else { continue }
                TimesheetDraftStore.save(adjusted, userId: userId, weekStart: storedStart, organizationId: orgId)
                output.append(
                    PreviousTimesheetRun(
                        id: "prev-\(Int(week.start.timeIntervalSince1970))",
                        week: week,
                        draft: adjusted,
                        owner: userStore.displayUser
                    )
                )
            }
        }
        if output.isEmpty {
            let current = TimesheetPayrollPolicy.payPeriodContaining(settings: settings)
            for week in TimesheetPayrollPolicy.previousPayPeriods(count: 32, settings: settings) {
                guard week.start != current.start else { continue }
                let local = TimesheetDraftStore.load(userId: userId, weekStart: week.start)
                _ = await TimesheetDraftStore.refreshFromCloud(
                    userId: userId,
                    weekStart: week.start,
                    firebaseBackend: firebaseBackend,
                    organizationId: orgId
                )
                let merged = TimesheetDraftStore.load(userId: userId, weekStart: week.start)
                let hasAnyContent = !merged.expenseEntries.isEmpty
                    || !merged.priceWorkEntries.isEmpty
                    || merged.operativeSignedAt != nil
                    || merged.managerSignedAt != nil
                    || !merged.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || local.operativeSignedAt != nil
                if hasAnyContent {
                    output.append(
                        PreviousTimesheetRun(
                            id: "prev-\(Int(week.start.timeIntervalSince1970))",
                            week: week,
                            draft: merged,
                            owner: userStore.displayUser
                        )
                    )
                }
            }
        }
        await MainActor.run {
            runs = output.sorted(by: { $0.week.start > $1.week.start })
            selectedRunId = runs.first?.id ?? ""
            isLoading = false
        }
    }

    /// RULEBOOK 1.22.0 §8 `CanonicalBusinessEngine.timesheetTotals` for one past run: decided, as the export invoice.
    private func bookingSummary(for week: WeekRange, draft: TimesheetDraft) -> RulebookTimesheetTotals? {
        guard let currentUser = userStore.displayUser else { return nil }
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let summary = TimesheetPayrollCollector.collect(
            for: currentUser,
            week: week,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            policy: policy,
            organization: firebaseBackend.currentOrganization,
            scheduleOptions: scheduleOptions,
            relatedUsers: userStore.organizationUsers
        )
        return TimesheetTotalsSource.totals(lines: summary.lineItems, draft: draft, decided: true, subject: currentUser, period: week.start...week.end)
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}

private struct TimesheetAutoOpenTarget: Identifiable, Hashable {
    let userId: String
    let weekStart: Date

    var id: String {
        "\(userId)|\(Int(Calendar.current.startOfDay(for: weekStart).timeIntervalSince1970))"
    }
}

/// Survives SwiftUI view recreation so backing out of a deep-linked review cannot re-push it.
private enum TimesheetSignoffDeepLinkGate {
    static var consumedKeys = Set<String>()

    static func consume(userId: String, weekStart: Date) -> Bool {
        let key = "\(userId)|\(Int(Calendar.current.startOfDay(for: weekStart).timeIntervalSince1970))"
        return consumedKeys.insert(key).inserted
    }
}

private struct ManagerTimesheetRow: Identifiable, Hashable {
    let id: String
    let user: AppUser
    let week: WeekRange
}

private struct PreviousTimesheetRun: Identifiable {
    let id: String
    let week: WeekRange
    let draft: TimesheetDraft
    /// RULEBOOK §8 `isTimesheetFullySigned(fields, hasLineManager)` for the owner (`timesheetSelfSigned`): a self-signed
    /// sheet is complete with the owner's signature alone. It used to need a manager signature too, so a self-signed
    /// admin's past runs read "Sign Off Pending" forever.
    let isCompleted: Bool

    init(id: String, week: WeekRange, draft: TimesheetDraft, owner: AppUser?) {
        self.id = id
        self.week = week
        self.draft = draft
        self.isCompleted = owner.map { TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: $0) } ?? false
    }
}

/// Internal (1.33.0) so the Payrun Snapshot can open a person's timesheet for a pay run.
struct OperativeTimesheetsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    let settings: OrganizationInvoicingSettings
    let week: WeekRange
    let initialReviewUserId: String?
    let initialList: String?
    @State private var selectedTab: ManagerTimesheetListTab = .awaiting
    @State private var refreshVersion = 0
    @State private var isExporting = false
    /// Off each time the screen opens (`SENSITIVE_EXPORT_OPTION_LABEL`).
    @State private var includeTaxIdsInExport = false
    @State private var exportMessage: String?
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    /// Pay-rate history read state: a failed read blocks sign-off, the agreed snapshot, invoices and exports.
    @State private var payInputsState: PayInputsLoadState = .loading
    /// Why pay cannot be worked out yet, else nil (`PayInputsLoad.blockMessage`).
    private var payInputsBlockMessage: String? {
        PayInputsLoad.blockMessage(state: payInputsState, organization: firebaseBackend.currentOrganization)
    }
    @State private var exportedHistory: [ExportedTimesheetHistoryRow] = []
    /// RULEBOOK 1.43.0 (review r318): the Exported tab's Download PDF.
    @State private var exportedShareFile: ExportedPDFShareFile?
    @State private var rebuiltExportConfirmRow: ExportedTimesheetHistoryRow?
    @State private var isLoadingExportedHistory = false
    @State private var exportedSearch = ""
    @State private var exportedSort = "dateNewest"
    @State private var exportedRunKey = "all"
    @State private var awaitingRows: [ManagerTimesheetRow] = []
    @State private var autoOpenReview: TimesheetAutoOpenTarget?
    @State private var didAutoOpenReview = false
    /// Scope the list was last built and fetched for. Nil until the first appear.
    @State private var listScopeIds: [String]?
    /// RULEBOOK 1.32.0 §8 `timesheetExportOwnSheetNotice`: shown on Signed off while the viewer's own sheet for this
    /// period is signed and not exported (the export never includes it).
    @State private var ownSheetExportNotice: String?

    private var isAdminViewer: Bool {
        guard let u = userStore.displayUser else { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.role == .admin
    }

    private var seesEveryTimesheet: Bool {
        guard let user = userStore.displayUser else { return false }
        return CanonicalBusinessEngine.seesEveryUserTimesheet(UserStore.staffAccountRole(for: user)) == true
    }

    init(
        settings: OrganizationInvoicingSettings,
        week: WeekRange? = nil,
        initialReviewUserId: String? = nil,
        initialList: String? = nil
    ) {
        self.settings = settings
        self.week = week ?? TimesheetPayrollPolicy.payPeriodContaining(settings: settings)
        self.initialReviewUserId = initialReviewUserId
        self.initialList = initialList
        if initialList == "signed" {
            _selectedTab = State(initialValue: .signedOff)
        }
    }

    private var extraReviewUser: AppUser? {
        guard let id = initialReviewUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == id })
    }

    /// `UserStore.userTimesheetSubjectUsers` — the one list the hub, this screen and its counts use.
    private var managerScopeUsers: [AppUser] {
        var users = userStore.userTimesheetSubjectUsers()
        if let extra = extraReviewUser, !users.contains(where: { $0.id == extra.id }) {
            users.append(extra)
        }
        return users.sorted(by: { $0.fullName < $1.fullName })
    }

    private var directReports: [AppUser] {
        var users = userStore.userTimesheetSubjectUsers().filter { user in
            TimesheetPayrollPolicy.shouldAppearInOperativeTimesheetRoster(user: user, week: week, settings: settings)
        }
        if let extra = extraReviewUser, !users.contains(where: { $0.id == extra.id }) {
            users.append(extra)
        }
        return users.sorted(by: { $0.fullName < $1.fullName })
    }

    private var filteredReports: [AppUser] {
        let _ = refreshVersion
        return directReports.filter { user in
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
            let bucket = TimesheetDraftStore.listBucket(for: draft, hasLineManager: TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user))
            switch selectedTab {
            case .awaiting:
                return bucket == "awaiting"
            case .signedOff:
                return bucket == "signed"
            case .exported:
                return bucket == "exported"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                userTimesheetsNavyHeader

            VStack(alignment: .leading, spacing: 12) {
                Picker("Status", selection: $selectedTab) {
                    Text("Awaiting sign-off").tag(ManagerTimesheetListTab.awaiting)
                    Text("Signed off").tag(ManagerTimesheetListTab.signedOff)
                    Text("Exported").tag(ManagerTimesheetListTab.exported)
                }
                .accessibilityIdentifier("timesheets.status")
                .pickerStyle(.segmented)

                Text(selectedTab.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(exportMessage.contains("Failed") ? .red : .green)
                }

                VStack(spacing: 0) {
                    if selectedTab == .exported {
                        exportedFilterCard
                        if isLoadingExportedHistory && exportedHistory.isEmpty {
                            ProgressView("Loading exported timesheets…")
                                .padding()
                        } else if exportedHistory.isEmpty {
                            ContentUnavailableView(
                                "No Exported Timesheets",
                                systemImage: "tray",
                                description: Text("Exported timesheets stay here for years after you email them.")
                            )
                            .padding()
                        } else if filteredExportedHistory.isEmpty {
                            ContentUnavailableView(
                                "No matching exported timesheets",
                                systemImage: "magnifyingglass",
                                description: Text("Try another name, sort, or payment run.")
                            )
                            .padding()
                        } else {
                            ForEach(filteredExportedHistory) { row in
                                NavigationLink {
                                    OperativeTimesheetReviewView(operative: row.user, settings: settings, week: row.week)
                                        .environmentObject(firebaseBackend)
                                        .environmentObject(userStore)
                                        .environmentObject(bookingStore)
                                        .environmentObject(operativeStore)
                                        .environmentObject(projectStore)
                                        .environmentObject(managerScheduleStore)
                                        .environmentObject(notificationService)
                                } label: {
                                    HStack(spacing: 12) {
                                        initialsAvatar(for: row.user)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.user.fullName.isEmpty ? row.user.email : row.user.fullName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(row.week.title)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let exportedAt = row.draft.exportedAt {
                                                Text("Exported \(exportedAt.formatted(date: .abbreviated, time: .shortened))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        statusPill(for: row.draft, user: row.user)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("timesheets.row.\(row.id).exported")
                                .buttonStyle(PPMenuRowButtonStyle())
                                // RULEBOOK 1.43.0 (review r318): rebuild this exported sheet's PDF from its saved
                                // snapshot (never re-stamped), so an undelivered sheet is always recoverable.
                                .contextMenu {
                                    Button {
                                        Task { await downloadExportedPDF(row, confirmedRebuild: false) }
                                    } label: {
                                        Label("Download PDF", systemImage: "arrow.down.doc")
                                    }
                                    .accessibilityIdentifier("timesheets.row.\(row.id).downloadPDF")
                                }
                                // Review r318: the same action, visible on every row (not long-press only).
                                HStack {
                                    Spacer()
                                    Button {
                                        Task { await downloadExportedPDF(row, confirmedRebuild: false) }
                                    } label: {
                                        Label("Download PDF", systemImage: "arrow.down.doc")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("timesheets.row.\(row.id).downloadPDFButton")
                                }
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                                if row.id != filteredExportedHistory.last?.id {
                                    Divider().padding(.leading, 66)
                                }
                            }
                        }
                    } else if selectedTab == .awaiting {
                    if awaitingRows.isEmpty {
                        ContentUnavailableView(
                            "No timesheets awaiting sign-off",
                            systemImage: "checkmark.circle",
                            description: Text("When someone signs a timesheet that needs your counter-signature, it appears here.")
                        )
                        .padding()
                    } else {
                    ForEach(awaitingRows) { row in
                        NavigationLink {
                            OperativeTimesheetReviewView(operative: row.user, settings: settings, week: row.week)
                                .environmentObject(firebaseBackend)
                                .environmentObject(userStore)
                                .environmentObject(bookingStore)
                                .environmentObject(operativeStore)
                                .environmentObject(projectStore)
                                .environmentObject(managerScheduleStore)
                                .environmentObject(notificationService)
                        } label: {
                            HStack(spacing: 12) {
                                initialsAvatar(for: row.user)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.user.fullName.isEmpty ? row.user.email : row.user.fullName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    let draft = TimesheetDraftStore.load(userId: row.user.id, weekStart: row.week.start)
                                    let summary = operativeSummary(for: row.user, draft: draft, week: row.week)
                                    Text(summary.map { "\(row.week.title) · Hrs \(formatHours($0.hours)) · OT \(formatHours($0.overtimeHours)) · PW \(OrgMoney.format($0.priceWork)) · Exp \(OrgMoney.format($0.expenses))" } ?? row.week.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if isAdminViewer {
                                        Text("Line manager: \(lineManagerName(for: row.user))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                statusPill(
                                    for: TimesheetDraftStore.load(userId: row.user.id, weekStart: row.week.start),
                                    user: row.user
                                )
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("timesheets.row.\(row.id).hrsOTPWExp")
                        .buttonStyle(PPMenuRowButtonStyle())
                        if row.id != awaitingRows.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                    }
                    } else {
                    ForEach(filteredReports, id: \.id) { operative in
                        NavigationLink {
                            OperativeTimesheetReviewView(operative: operative, settings: settings, week: week)
                                .environmentObject(firebaseBackend)
                                .environmentObject(userStore)
                                .environmentObject(bookingStore)
                                .environmentObject(operativeStore)
                                .environmentObject(projectStore)
                                .environmentObject(managerScheduleStore)
                                .environmentObject(notificationService)
                        } label: {
                            HStack(spacing: 12) {
                                initialsAvatar(for: operative)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(operative.fullName.isEmpty ? operative.email : operative.fullName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    let draft = TimesheetDraftStore.load(userId: operative.id, weekStart: week.start)
                                    let summary = operativeSummary(for: operative, draft: draft, week: week)
                                    Text(summary.map { "\(week.title) · Hrs \(formatHours($0.hours)) · OT \(formatHours($0.overtimeHours)) · PW \(OrgMoney.format($0.priceWork)) · Exp \(OrgMoney.format($0.expenses))" } ?? week.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if isAdminViewer {
                                        Text("Line manager: \(lineManagerName(for: operative))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                statusPill(
                                    for: TimesheetDraftStore.load(userId: operative.id, weekStart: week.start),
                                    user: operative
                                )
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("timesheets.row.\(operative.id).hrsOTPWExp")
                        .buttonStyle(PPMenuRowButtonStyle())
                        if operative.id != filteredReports.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                    }
                }
                .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))

                if selectedTab == .signedOff && !filteredReports.isEmpty {
                    // Admins only: managers cannot see other people's tax identifiers.
                    if userStore.canViewSensitiveProfile(of: "") {
                        SensitiveExportToggle(isOn: $includeTaxIdsInExport, accessibilityToken: "signedTimesheetsExport")
                            .padding(14)
                            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    }
                    Button {
                        Task { await exportSignedTimesheets() }
                    } label: {
                        Label(
                            isExporting ? "Sending timesheets…" : "Email and export \(filteredReports.count) timesheets",
                            systemImage: "envelope.fill"
                        )
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .foregroundStyle(.white)
                            .background(PPColor.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .accessibilityIdentifier("timesheets.sendingTimesheets")
                    .buttonStyle(PPPressableButtonStyle())
                    .disabled(isExporting)
                    // RULEBOOK §2: timesheet sign-off and export are online only.
                    .onlineOnly(isOnline: smartCache.isOnline)
                }
                if selectedTab == .signedOff, let ownSheetExportNotice {
                    Label(ownSheetExportNotice, systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.primary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        .accessibilityIdentifier("timesheets.ownSheetExportNotice")
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 28)
            .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("User Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        // RULEBOOK 1.43.0 (review r318): Exported → Download PDF shares the PDF rebuilt from the stored, exported sheet.
        .sheet(item: $exportedShareFile) { file in
            InvoicingShareSheet(items: [file.url])
        }
        .alert("Rebuild this PDF?", isPresented: Binding(
            get: { rebuiltExportConfirmRow != nil },
            set: { if !$0 { rebuiltExportConfirmRow = nil } }
        )) {
            Button("Rebuild PDF") {
                if let row = rebuiltExportConfirmRow {
                    rebuiltExportConfirmRow = nil
                    Task { await downloadExportedPDF(row, confirmedRebuild: true) }
                }
            }
            Button("Cancel", role: .cancel) { rebuiltExportConfirmRow = nil }
        } message: {
            Text(TimesheetExportMessages.rebuiltExportConfirmMessage)
        }
        .navigationDestination(item: $autoOpenReview) { target in
            if let operative = userStore.organizationUsers.first(where: { $0.id == target.userId }) {
                let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: operative.id, weekStart: target.weekStart)
                let reviewWeek = TimesheetPayrollPolicy.periodMatchingStoredStart(
                    target.weekStart,
                    storedEnd: storedEnd,
                    settings: settings
                )
                OperativeTimesheetReviewView(operative: operative, settings: settings, week: reviewWeek)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(projectStore)
                    .environmentObject(managerScheduleStore)
                    .environmentObject(notificationService)
            }
        }
        .task {
            await refreshFromCloud()
            await loadDayRateHistory()
            await loadExportedHistory()
            openDeepLinkedTimesheetIfNeeded()
        }
        .onAppear {
            rebuildAwaitingRows()
        }
        // Rows were built only on appear and after the first fetch. When the roster arrives or is replaced
        // later, rebuild from the people now in scope and fetch their timesheets, instead of keeping the
        // first (empty or cached) list.
        .task(id: managerScopeUsers.map(\.id)) {
            let ids = managerScopeUsers.map(\.id)
            guard let previous = listScopeIds else {
                listScopeIds = ids
                return
            }
            guard ids != previous else { return }
            listScopeIds = ids
            rebuildAwaitingRows()
            guard !ids.isEmpty else { return }
            await refreshFromCloud()
        }
        .onChange(of: autoOpenReview) { _, newValue in
            if newValue == nil {
                didAutoOpenReview = true
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .exported {
                Task { await loadExportedHistory() }
            }
        }
        .task(id: selectedTab) {
            await refreshOwnSheetExportNotice()
        }
    }

    /// RULEBOOK 1.32.0 §8: reads the viewer's own sheet for this period (server copy, this organisation) while Signed off
    /// is open and asks `timesheetExportOwnSheetNotice` whether to say the export leaves it out. No notice when it
    /// cannot be read, as web.
    private func refreshOwnSheetExportNotice() async {
        guard selectedTab == .signedOff,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              let viewerId = userStore.currentUser?.id, !viewerId.isEmpty else {
            ownSheetExportNotice = nil
            return
        }
        let ownSheet = await TimesheetDraftStore.refreshFromCloud(
            userId: viewerId,
            weekStart: week.start,
            firebaseBackend: firebaseBackend,
            organizationId: orgId
        )
        guard selectedTab == .signedOff, let ownSheet else {
            ownSheetExportNotice = nil
            return
        }
        ownSheetExportNotice = CanonicalBusinessEngine.timesheetExportOwnSheetNotice(
            ownSheetSigned: ownSheet.operativeSignedAt != nil,
            ownSheetExported: ownSheet.exportedAt != nil
        )
    }

    private var filteredExportedHistory: [ExportedTimesheetHistoryRow] {
        let needle = exportedSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = exportedHistory.filter { row in
            if exportedRunKey != "all" {
                let key = periodKey(for: row.week)
                if key != exportedRunKey { return false }
            }
            if needle.isEmpty { return true }
            let name = "\(row.user.firstName) \(row.user.surname) \(row.user.email)".lowercased()
            return name.contains(needle) || row.week.title.lowercased().contains(needle)
        }
        return filtered.sorted { lhs, rhs in
            switch exportedSort {
            case "firstName":
                return lhs.user.firstName.localizedCaseInsensitiveCompare(rhs.user.firstName) == .orderedAscending
            case "lastName":
                return lhs.user.surname.localizedCaseInsensitiveCompare(rhs.user.surname) == .orderedAscending
            case "dateOldest":
                return (lhs.draft.exportedAt ?? .distantPast) < (rhs.draft.exportedAt ?? .distantPast)
            default:
                return (lhs.draft.exportedAt ?? .distantPast) > (rhs.draft.exportedAt ?? .distantPast)
            }
        }
    }

    private var exportedRunChoices: [WeekRange] {
        let observed = exportedHistory.compactMap { row -> CanonicalBusinessEngine.CanonicalTimesheetPeriod? in
            guard let start = CanonicalBusinessEngine.dayKeyInOrganizationZone(row.week.start),
                  let end = CanonicalBusinessEngine.dayKeyInOrganizationZone(row.week.end) else { return nil }
            return CanonicalBusinessEngine.CanonicalTimesheetPeriod(startDayKey: start, endDayKey: end)
        }
        return TimesheetPayrollPolicy.selectablePayPeriods(settings: settings, observed: observed)
    }

    private func periodKey(for week: WeekRange) -> String {
        let start = CanonicalBusinessEngine.dayKeyInOrganizationZone(week.start) ?? ""
        let end = CanonicalBusinessEngine.dayKeyInOrganizationZone(week.end) ?? ""
        return "\(start)|\(end)"
    }

    private var exportedFilterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name or payment run", text: $exportedSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("timesheets.exportedSearch")
            Picker("Sort", selection: $exportedSort) {
                Text("First name").tag("firstName")
                Text("Last name").tag("lastName")
                Text("Date newest").tag("dateNewest")
                Text("Date oldest").tag("dateOldest")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("timesheets.exportedSort")
            Picker("Payment run", selection: $exportedRunKey) {
                Text("All payment runs").tag("all")
                ForEach(exportedRunChoices, id: \.self) { period in
                    Text(period.title).tag(periodKey(for: period))
                }
            }
            .accessibilityIdentifier("timesheets.exportedRun")
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Home-style navy header: the pay period this list opens on and counts the screen already holds.
    private var userTimesheetsNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(eyebrow: "Pay period", title: week.title)

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(directReports.count)", label: "People")
                PPStatDivider()
                PPStat(value: "\(awaitingRows.count)", label: "Awaiting sign-off", highlight: !awaitingRows.isEmpty)
                PPStatDivider()
                PPStat(value: "\(exportedHistory.count)", label: "Exported, all runs")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    /// Gradient initials avatar for a person row.
    private func initialsAvatar(for user: AppUser) -> some View {
        Text(initials(for: user))
            .font(.system(.footnote, design: .rounded))
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(PPFamily.people.gradient, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private func statusPillLabel(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    @ViewBuilder
    private func statusPill(for draft: TimesheetDraft, user: AppUser) -> some View {
        if TimesheetApprovalPolicy.isExported(draft) {
            statusPillLabel("Exported", symbol: "tray.and.arrow.up.fill", color: .secondary)
        } else if TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) {
            statusPillLabel("Signed off", symbol: "checkmark.circle.fill", color: PPFamily.sites.bottom)
        } else if TimesheetApprovalPolicy.operativeHasSigned(draft) {
            statusPillLabel("Pending", symbol: "clock.fill", color: PPFamily.trade.bottom)
        } else {
            statusPillLabel("Not signed", symbol: "circle", color: .secondary)
        }
    }

    private func initials(for user: AppUser) -> String {
        let name = user.fullName.isEmpty ? user.email : user.fullName
        let chunks = name.split(separator: " ").prefix(2)
        let letters = chunks.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "U" : letters.uppercased()
    }

    private func refreshFromCloud() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        var users = managerScopeUsers
        if let extra = extraReviewUser, !users.contains(where: { $0.id == extra.id }) {
            users.append(extra)
        }
        let prefetchWeeks = TimesheetDraftStore.weeksToPrefetchForManagerReview(
            settings: settings,
            extraWeekStart: week.start
        )
        for user in users {
            for weekStart in prefetchWeeks {
                _ = await TimesheetDraftStore.refreshFromCloud(
                    userId: user.id,
                    weekStart: weekStart,
                    firebaseBackend: firebaseBackend,
                    organizationId: orgId
                )
            }
            if let rows = try? await firebaseBackend.listTimesheetStates(
                organizationId: orgId,
                userId: user.id,
                limit: 200
            ) {
                for row in rows {
                    _ = TimesheetDraftStore.ingestCloudRow(row, userId: user.id, organizationId: orgId)
                }
            }
        }
        await MainActor.run {
            rebuildAwaitingRows()
            refreshVersion += 1
        }
    }

    private func rebuildAwaitingRows() {
        let _ = refreshVersion
        var rows: [ManagerTimesheetRow] = []
        var seen = Set<String>()
        for user in managerScopeUsers {
            let documentStarts = TimesheetDraftStore.discoverStoredWeekStarts(userId: user.id)
            for periodStart in TimesheetApprovalPolicy.awaitingPayPeriodStarts(
                user: user,
                documentStarts: documentStarts,
                settings: settings
            ) {
                let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: user.id, weekStart: periodStart)
                let period = TimesheetPayrollPolicy.periodMatchingStoredStart(
                    periodStart,
                    storedEnd: storedEnd,
                    settings: settings
                )
                let id = "\(user.id)|\(Int(period.start.timeIntervalSince1970))"
                guard seen.insert(id).inserted else { continue }
                rows.append(ManagerTimesheetRow(id: id, user: user, week: period))
            }
        }
        awaitingRows = rows.sorted { lhs, rhs in
            if lhs.week.start != rhs.week.start { return lhs.week.start > rhs.week.start }
            return lhs.user.fullName.localizedCaseInsensitiveCompare(rhs.user.fullName) == .orderedAscending
        }
    }

    private func openDeepLinkedTimesheetIfNeeded() {
        guard !didAutoOpenReview else { return }
        guard let userId = initialReviewUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty else { return }
        guard extraReviewUser != nil || userStore.organizationUsers.contains(where: { $0.id == userId }) else { return }
        let weekStart = week.start
        guard TimesheetSignoffDeepLinkGate.consume(userId: userId, weekStart: weekStart) else {
            didAutoOpenReview = true
            return
        }
        didAutoOpenReview = true
        autoOpenReview = TimesheetAutoOpenTarget(userId: userId, weekStart: weekStart)
    }

    /// A failed read is a failure (`PayInputsLoad`), never an empty history.
    private func loadDayRateHistory() async {
        let result = await PayInputsLoad.loadHistory(firebaseBackend)
        await MainActor.run {
            if let history = result.history { dayRateHistoryCollection = history }
            payInputsState = result.state
        }
    }

    private func exportSignedTimesheets() async {
        guard !isExporting else { return }
        // Nothing is exported (or frozen) until pay can be worked out from loaded inputs.
        if payInputsState != .loaded { await loadDayRateHistory() }
        if let blocked = payInputsBlockMessage {
            exportMessage = blocked
            return
        }
        isExporting = true
        exportMessage = nil
        defer { isExporting = false }

        guard let exporter = userStore.displayUser else {
            exportMessage = "Failed: no signed-in manager/admin to receive the export email."
            return
        }
        let recipientEmail = exporter.email.trimmingCharacters(in: .whitespacesAndNewlines)

        let orgName = firebaseBackend.currentOrganization?.name ?? "Organization"
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let targets = filteredReports
        // RULEBOOK 1.43.0 §8 (review r318): an export waits for the same server-confirmed bookings gate as sign-off.
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
            from: week.start, retryFailed: true
        )
        if let blocked = PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: PayInputsLoad.periodBookings(
                firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
                from: week.start
            )
        ) {
            exportMessage = blocked
            return
        }
        guard let exportOrgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            exportMessage = "Failed: no organisation."
            return
        }
        func gateReady() -> Bool {
            PayInputsLoad.periodBookings(
                firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
                from: week.start
            ).loaded
        }
        func name(_ user: AppUser) -> String { user.fullName.isEmpty ? user.email : user.fullName }

        // Review r318 (web `runTimesheetExport`). 1. Prepare every sheet — fresh read, snapshot built (an empty frozen one
        // rebuilt) BEFORE `exportedAt` — checking the gate before each person. Nothing is written here, so a gate that
        // closes stops the export with nobody stamped. A sheet exported elsewhere, or not signed in its fresh copy, is left.
        var prepared: [(operative: AppUser, draft: TimesheetDraft)] = []
        var skippedElsewhere: [String] = []
        for op in targets {
            guard gateReady() else {
                exportMessage = TimesheetDraftStore.exportStoppedMessage
                return
            }
            let fresh = await TimesheetDraftStore.refreshFromCloudReporting(
                userId: op.id,
                weekStart: week.start,
                firebaseBackend: firebaseBackend,
                organizationId: exportOrgId
            )
            if fresh.failed {
                exportMessage = TimesheetDraftStore.periodReadFailedMessage
                return
            }
            guard var d = fresh.draft else { continue }
            if d.exportedAt != nil {
                skippedElsewhere.append(name(op))
                continue
            }
            guard d.operativeSignedAt != nil else { continue }
            TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
                to: &d,
                user: op,
                week: week,
                bookings: bookingStore.bookings,
                managerBookings: managerScheduleStore.managerSiteBookings,
                operatives: operativeStore.allOperatives,
                projects: projectStore.projects,
                smallWorks: projectStore.smallWorks,
                history: dayRateHistoryCollection,
                policy: policy,
                organization: firebaseBackend.currentOrganization,
                scheduleOptions: scheduleOptions,
                viewer: exporter,
                relatedUsers: userStore.organizationUsers,
                snapshotInputsReady: true
            )
            guard TimesheetDraftStore.applyExport(to: &d, at: Date()) else { continue }
            prepared.append((operative: op, draft: d))
        }
        // The gate once more after the last read, still before anything is written.
        if !prepared.isEmpty && !gateReady() {
            exportMessage = TimesheetDraftStore.exportStoppedMessage
            return
        }

        // 2. Stamp the prepared sheets exported, one by one; a failure stops the rest (those already stamped are kept).
        var stamped: [(operative: AppUser, draft: TimesheetDraft)] = []
        var stampError: String?
        for row in prepared {
            if let failure = await TimesheetDraftStore.saveToCloud(
                row.draft,
                userId: row.operative.id,
                weekStart: week.start,
                weekEnd: week.end,
                firebaseBackend: firebaseBackend,
                organizationId: exportOrgId,
                writer: exporter,
                subject: row.operative
            ) {
                stampError = failure
                break
            }
            TimesheetDraftStore.save(row.draft, userId: row.operative.id, weekStart: week.start, weekEnd: week.end)
            stamped.append(row)
        }

        // 3. Deliver every stamped sheet — PDF from the copy that was saved, backup, then one email — each person on
        // their own: one failure never skips the rest. Tax ids only for the people being delivered.
        var delivery = TimesheetExportHelper.Delivery()
        if !stamped.isEmpty {
            var taxIdsByUserId: [String: CanonicalBusinessEngine.CanonicalSensitiveProfile] = [:]
            for row in stamped {
                if let ids = await InvoicePDFGenerationSupport.taxIdsForExport(
                    subject: row.operative,
                    requested: includeTaxIdsInExport,
                    userStore: userStore
                ) {
                    taxIdsByUserId[row.operative.id] = ids
                }
            }
            delivery = await TimesheetExportHelper.deliver(
                stamped: stamped,
                week: week,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                operativeStore: operativeStore,
                projectStore: projectStore,
                dayRateHistory: dayRateHistoryCollection,
                payrollPolicy: policy,
                organization: firebaseBackend.currentOrganization,
                organizationName: orgName,
                scheduleOptions: scheduleOptions,
                organizationUsers: userStore.organizationUsers,
                recipientEmail: recipientEmail,
                recipientName: name(exporter),
                firebaseBackend: firebaseBackend,
                taxIdsByUserId: taxIdsByUserId
            )
            refreshVersion += 1
            rebuildAwaitingRows()
            await loadExportedHistory()
            selectedTab = .exported
        }
        exportMessage = TimesheetExportMessages.summaryMessage(
            stamped: stamped.map { name($0.operative) },
            notSent: delivery.notSent,
            emailProblem: delivery.emailProblem,
            recipientEmail: recipientEmail.isEmpty ? nil : recipientEmail,
            sentCount: delivery.sentCount,
            backupSkipped: delivery.backupSkipped,
            skipped: skippedElsewhere,
            stampError: stampError
        )
    }

    /// RULEBOOK 1.43.0 (review r318, web `downloadExportedPdf`): Exported → Download PDF rebuilds the PDF from the
    /// stored, exported sheet (a fresh read when it answers) — never re-stamps it. A sheet exported before signed copies
    /// were kept (no stored `weeklyReportOverride`) is rebuilt from today's bookings and rates, so the person confirms
    /// first and the PDF says so.
    private func downloadExportedPDF(_ row: ExportedTimesheetHistoryRow, confirmedRebuild: Bool) async {
        if payInputsState != .loaded { await loadDayRateHistory() }
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
            from: row.week.start, retryFailed: true
        )
        if let blocked = PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: PayInputsLoad.periodBookings(
                firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
                from: row.week.start
            )
        ) {
            exportMessage = blocked
            return
        }
        var sheet = row.draft
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            let fresh = await TimesheetDraftStore.refreshFromCloudReporting(
                userId: row.user.id,
                weekStart: row.week.start,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
            if let draft = fresh.draft, draft.exportedAt != nil { sheet = draft }
        }
        let rebuilt = sheet.weeklyReportOverride == nil
        if rebuilt && !confirmedRebuild {
            rebuiltExportConfirmRow = row
            return
        }
        let taxIds = await InvoicePDFGenerationSupport.taxIdsForExport(
            subject: row.user,
            requested: includeTaxIdsInExport,
            userStore: userStore
        )
        let name = row.user.fullName.isEmpty ? row.user.email : row.user.fullName
        let attachment: TimesheetExportHelper.PDFAttachment
        do {
            attachment = try TimesheetExportHelper.makeSheetPDF(
            operative: row.user,
            week: row.week,
            draft: sheet,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            dayRateHistory: dayRateHistoryCollection,
            payrollPolicy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
            organization: firebaseBackend.currentOrganization,
            organizationName: firebaseBackend.currentOrganization?.name ?? "Organization",
            scheduleOptions: firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions(),
            organizationUsers: userStore.organizationUsers,
            taxIds: taxIds,
            rebuiltNote: rebuilt ? TimesheetExportMessages.rebuiltExportNote() : nil
            )
        } catch {
            exportMessage = TimesheetExportHelper.pdfFailureMessage(name: name, error: error)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.fileName)
        do {
            try attachment.data.write(to: url, options: .atomic)
            exportedShareFile = ExportedPDFShareFile(url: url)
        } catch {
            exportMessage = "Couldn't build the PDF for \(name) (\(error.localizedDescription))."
        }
    }

    /// Keep exported timesheets discoverable across many pay periods (not just the current filter week).
    private func loadExportedHistory() async {
        await MainActor.run { isLoadingExportedHistory = true }

        let users = usersForExportedHistory()
        guard !users.isEmpty else {
            await MainActor.run {
                exportedHistory = []
                isLoadingExportedHistory = false
            }
            return
        }

        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
        var byId: [String: ExportedTimesheetHistoryRow] = [:]
        // RULEBOOK 1.31.0 §8: a sheet stored without `userId` is matched by its document id
        // (`timesheetDocumentSubjectId`) against every id of the person (`personIdSet`: own, former and same-email
        // ids), never dropped. Each such sheet is listed under one person only.
        let unownedRows: [[String: Any]] = orgId == nil ? [] :
            ((try? await firebaseBackend.listExportedTimesheetsWithoutUserId(organizationId: orgId!)) ?? [])
        var claimedUnowned = Set<String>()

        for user in users {
            var weekStarts = Set(TimesheetDraftStore.discoverStoredWeekStarts(userId: user.id))
            for period in TimesheetPayrollPolicy.previousPayPeriods(count: 260, settings: settings) {
                weekStarts.insert(period.start)
            }
            weekStarts.insert(week.start)

            if let orgId,
               let listed = try? await firebaseBackend.listTimesheetStates(
                   organizationId: orgId,
                   userId: user.id,
                   limit: 400
               ) {
                let personIds = Set(RulebookPeople.ownerIds(for: user, users: userStore.organizationUsers).map { $0.lowercased() })
                let unownedForUser = unownedRows.filter { row in
                    guard let subject = (row["__subjectId"] as? String)?.lowercased(),
                          let docId = row["__documentId"] as? String,
                          personIds.contains(subject), !claimedUnowned.contains(docId) else { return false }
                    claimedUnowned.insert(docId)
                    return true
                }
                let cloudRows = listed + unownedForUser
                for row in cloudRows {
                    guard let weekStart = firestoreDate(row["weekStart"]),
                          let day = TimesheetDraftStore.organizationDay(weekStart) else { continue }
                    TimesheetDraftStore.rememberBounds(from: row, userId: user.id, weekStart: day)
                    weekStarts.insert(day)
                    if let decoded = TimesheetDraftStore.decodeFirestoreMap(row),
                       TimesheetDraftStore.listBucket(for: decoded, hasLineManager: TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user)) == "exported" {
                        let end = TimesheetDraftStore.storedPeriodEnd(userId: user.id, weekStart: day)
                        TimesheetDraftStore.save(decoded, userId: user.id, weekStart: day, weekEnd: end)
                    }
                }
            }

            for start in weekStarts {
                let draft = TimesheetDraftStore.load(userId: user.id, weekStart: start)
                guard TimesheetDraftStore.listBucket(for: draft, hasLineManager: TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user)) == "exported" else { continue }
                let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: user.id, weekStart: start)
                let period = TimesheetPayrollPolicy.periodMatchingStoredStart(start, storedEnd: storedEnd, settings: settings)
                let startKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(period.start) ?? ""
                let endKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(period.end) ?? ""
                let rowId = "\(user.id)|\(startKey)|\(endKey)"
                byId[rowId] = ExportedTimesheetHistoryRow(
                    id: rowId,
                    user: user,
                    week: period,
                    draft: draft
                )
            }
        }

        let sorted = byId.values.sorted { lhs, rhs in
            let l = lhs.draft.exportedAt ?? .distantPast
            let r = rhs.draft.exportedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.user.fullName.localizedCaseInsensitiveCompare(rhs.user.fullName) == .orderedAscending
        }
        await MainActor.run {
            exportedHistory = sorted
            isLoadingExportedHistory = false
        }
    }

    /// RULEBOOK 1.31.0 §8 `exportedTimesheetHistorySubjects`: User Timesheets people, the viewer's own exported sheets
    /// (read-only: `timesheetWriterIsReviewer` still refuses a review of one's own sheet) and inactive or deleted people
    /// in scope. The Exported list and its "Exported, all runs" count both read this.
    private func usersForExportedHistory() -> [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        return userStore.exportedTimesheetHistoryUsers(viewer: currentUser)
    }

    /// RULEBOOK 1.22.0 §8 `CanonicalBusinessEngine.timesheetTotals` for a list row: decided, as the export invoice
    /// (a declined expense never counts). Nil when the script did not answer.
    private func operativeSummary(for user: AppUser, draft: TimesheetDraft, week reviewWeek: WeekRange? = nil) -> RulebookTimesheetTotals? {
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let range = reviewWeek ?? week
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            week: range,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            policy: policy,
            organization: firebaseBackend.currentOrganization,
            scheduleOptions: scheduleOptions,
            relatedUsers: userStore.organizationUsers
        )
        return TimesheetTotalsSource.totals(lines: summary.lineItems, draft: draft, decided: true, subject: user, period: range.start...range.end)
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    private func lineManagerName(for user: AppUser) -> String {
        guard let id = user.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Unassigned"
        }
        if let manager = userStore.organizationUsers.first(where: { $0.id == id }) {
            let name = manager.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? manager.email : name
        }
        return "Unknown"
    }
}

/// A PDF to share from the Exported tab.
private struct ExportedPDFShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ExportedTimesheetHistoryRow: Identifiable {
    let id: String
    let user: AppUser
    let week: WeekRange
    let draft: TimesheetDraft
}

private enum ManagerTimesheetListTab {
    case awaiting
    case signedOff
    case exported

    var helpText: String {
        switch self {
        case .awaiting:
            return "Operative signed — yellow pending clock until you counter-sign."
        case .signedOff:
            return "Counter-signed and ready. Email and export sends timesheet PDFs to your email for filing. To edit this timesheet, please go to the signed off timesheets page, export it and then edit within the exported timesheets tab."
        case .exported:
            return "Exported timesheets stay here for years. Open a row to edit agreed days, price work or expenses; those changes feed the weekly report."
        }
    }
}

private struct OperativeTimesheetReviewView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    /// RULEBOOK 1.43.0 §8 (review r318): the period's bookings are asked for again when the app becomes active.
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var holidayStore: HolidayStore
    let operative: AppUser
    let settings: OrganizationInvoicingSettings
    let week: WeekRange
    @State private var draft = TimesheetDraft()
    @State private var showingManagerSignSheet = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    /// Pay-rate history read state: a failed read blocks sign-off, the agreed snapshot, invoices and exports.
    @State private var payInputsState: PayInputsLoadState = .loading
    /// Why pay cannot be worked out yet, else nil (`PayInputsLoad.blockMessage`).
    private var payInputsBlockMessage: String? {
        if periodLoadFailed { return TimesheetDraftStore.periodReadFailedMessage }
        if let blocked = PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: periodBookingsState
        ) {
            return blocked
        }
        // A script call that did not answer is "could not calculate", never £0 (money audit #15).
        return payrollSummary.calculationFailed ? TimesheetPayrollSummary.calculationFailedMessage : nil
    }
    /// RULEBOOK 1.43.0 §8 `timesheetSnapshotReady`: the period's labour and manager site bookings have arrived
    /// (`PayInputsLoad.periodBookings`). Sign-off, the counter-signature, the agreed snapshot and invoices wait for them.
    private var periodBookingsState: (loaded: Bool, failed: Bool) {
        PayInputsLoad.periodBookings(
            firebaseBackend: firebaseBackend,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            from: week.start
        )
    }

    /// Asks for the period's bookings when the download does not reach it, or when the last read failed (Retry).
    private func ensurePeriodBookings() {
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            from: week.start,
            retryFailed: true
        )
    }
    @State private var editingPayrollLineId: String?
    @State private var editingExpenseId: UUID?
    @State private var editingPriceWorkId: UUID?
    /// A server copy of this sheet arrived while the reviewer was editing; it loads when they finish.
    @State private var serverTimesheetChangedWhileEditing = false
    @State private var showExtrasReviewRequiredAlert = false
    /// Shown when the cloud save failed.
    @State private var saveErrorMessage: String?
    /// RULEBOOK 1.43.0 §8: the empty-snapshot rebuild runs once per visit.
    @State private var snapshotRebuildTried = false
    /// RULEBOOK 1.43.0 (review r318, 2nd round): the period's sheet could not be read. Nothing is saved, signed or
    /// invoiced and no blank sheet is opened until a Retry reads it.
    @State private var periodLoadFailed = false

    /// RULEBOOK 1.43.0 §8 `timesheetSnapshotNeedsRebuild`: the stored snapshot has no labour lines, the period's live
    /// bookings (loaded) have some, and the sheet was not exported.
    private var snapshotNeedsRebuild: Bool {
        guard payInputsBlockMessage == nil, let stored = draft.weeklyReportOverride, stored.lines.isEmpty else { return false }
        return CanonicalBusinessEngine.timesheetSnapshotNeedsRebuild(
            storedOverrideLineCount: stored.lines.count,
            overrideApprovedAt: stored.approvedAt,
            exportedAt: draft.exportedAt,
            managerSignedAt: draft.managerSignedAt,
            liveLabourLines: TimesheetPayrollCollector.snapshotRebuildLines(payrollSummary.lineItems)
        )
    }

    /// RULEBOOK 1.30.2 `timesheetWriterIsReviewer`: the viewer reviews this sheet only as the subject's line manager
    /// or an admin, never their own under any of their ids (admins and the Super Admin included). Their own sheet is
    /// the owner flow (My Timesheets); the counter-signature is never offered on it.
    private var viewerIsReviewer: Bool {
        guard let viewer = userStore.displayUser else { return false }
        return TimesheetApprovalPolicy.writerIsReviewer(
            writerId: viewer.id,
            writer: viewer,
            subjectUserId: operative.id,
            subject: operative
        )
    }

    private var canManagerReview: Bool {
        guard viewerIsReviewer else { return false }
        if TimesheetApprovalPolicy.isExported(draft) {
            return TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative)
        }
        return TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: operative)
            && TimesheetApprovalPolicy.recordedSignatureDate(draft.managerSignedAt) == nil
            && TimesheetApprovalPolicy.operativeHasSigned(draft)
            && !TimesheetApprovalPolicy.isExported(draft)
    }

    private var managerHasSigned: Bool {
        TimesheetApprovalPolicy.recordedSignatureDate(draft.managerSignedAt) != nil
    }

    /// RULEBOOK 1.22.0 §8 `CanonicalBusinessEngine.timesheetTotals`: decided once signed or while this viewer reviews
    /// it; a reviewer before signing sees their own labour reviews and entry decisions (web `draftTimesheetTotals`).
    private var reviewTotals: RulebookTimesheetTotals? {
        TimesheetTotalsSource.totals(
            lines: payrollSummary.lineItems,
            draft: draft,
            decided: managerHasSigned || canManagerReview,
            reviewing: canManagerReview && !managerHasSigned,
            subject: operative,
            period: week.start...week.end
        )
    }

    var body: some View {
        reviewScrollContent
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Review Timesheet")
            .navigationBarTitleDisplayMode(.inline)
            // RULEBOOK 1.43.0 (review r318, 3rd round): while the sheet cannot be read, only the message and Retry.
            .overlay {
                if periodLoadFailed {
                    TimesheetPeriodLoadFailedView { Task { await refreshDraftFromCloud() } }
                }
            }
            .onAppear {
                draft = TimesheetDraftStore.load(userId: operative.id, weekStart: week.start)
                Task { await refreshDraftFromCloud() }
            }
            .task { await loadDayRateHistory() }
            // RULEBOOK 1.43.0 §8 (review r318): the period gate re-checks (and reloads the bookings if no server answer
            // covers the period) when the app comes back to the foreground or the connection returns.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { ensurePeriodBookings() }
            }
            .onChange(of: smartCache.isOnline) { _, online in
                if online { ensurePeriodBookings() }
            }
            // RULEBOOK 1.43.0 §8 `timesheetSnapshotNeedsRebuild`: a snapshot frozen with no labour lines (counter-signed
            // before the bookings loaded) is rebuilt by the reviewer once they have, signatures unchanged, once per visit.
            .onChange(of: snapshotNeedsRebuild, initial: true) { _, needs in
                guard needs, !snapshotRebuildTried, viewerIsReviewer, !serverTimesheetChangedWhileEditing else { return }
                snapshotRebuildTried = true
                saveDraft()
            }
            // RULEBOOK 1.26.0 §8 `CanonicalBusinessEngine.rateHistoryQueryPlan`: the subject's rows while `privatePay` is on.
            .listensWhileOpen("operativeDayRateHistory", key: "operativeDayRateHistory.review",
                              targetSuffix: firebaseBackend.rateHistoryListenSuffix, firebaseBackend: firebaseBackend,
                              query: firebaseBackend.rateHistoryListenQuery(subjectId: operative.id)) { await loadDayRateHistory() }
            .task { if holidayStore.bookings.isEmpty { await holidayStore.loadData() } }
            // Live sheet while open: the person's own edit or another reviewer's decision on web shows here.
            // An entry being edited, or the sign sheet, is never overwritten — the server copy loads after.
            .task(id: week.start) { listenToServerTimesheet() }
            .onDisappear { firebaseBackend.stopLiveListener(key: Self.liveTimesheetKey) }
            .onChange(of: isEditingReview) { _, editing in
                if !editing && serverTimesheetChangedWhileEditing {
                    serverTimesheetChangedWhileEditing = false
                    Task { await refreshDraftFromCloud() }
                }
            }
            .alert("Review required", isPresented: $showExtrasReviewRequiredAlert) {
                Button("OK", role: .cancel) {}
                    .accessibilityIdentifier("operativeTimesheetReview.ok")
            } message: {
                Text("Please approve, decline or edit each expense and price-work item using the buttons provided.")
            }
            .modifier(OperativeTimesheetReviewSheetsModifier(
                draft: $draft,
                operative: operative,
                week: week,
                payrollLines: payrollSummary.lineItems,
                policy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
                organization: firebaseBackend.currentOrganization,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                editingPayrollLineId: $editingPayrollLineId,
                editingExpenseId: $editingExpenseId,
                editingPriceWorkId: $editingPriceWorkId,
                showingManagerSignSheet: $showingManagerSignSheet,
                userStore: userStore,
                notificationService: notificationService,
                onSaveDraft: saveDraft
            ))
    }

    private var reviewScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                reviewHeaderCard
                reviewBreakdownCard
                reviewExpensesCard
                reviewPriceWorkCard
                reviewSignaturesCard
                reviewSignOffSection
            }
            .padding(16)
        }
    }

    private var reviewHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(operative.fullName.isEmpty ? operative.email : operative.fullName)
                .font(.title3.weight(.semibold))
            Text(week.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            statusLine
            if let saveErrorMessage {
                Label(saveErrorMessage, systemImage: "exclamationmark.icloud.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("operativeTimesheetReview.saveError")
            }
            if let blocked = payInputsBlockMessage {
                PayInputsFailureBanner(message: blocked) {
                    Task { await loadDayRateHistory() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var reviewBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Breakdown")
                .font(.headline)
            if canManagerReview {
                Text("Review each day, expense and price-work line. Use ✓ approve, ✕ decline, or ⚙ edit. Changes are shown to the operative when you sign off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(payrollSummary.lineItems) { row in
                managerPayrollLineRow(row)
            }
            if !leaveLines.isEmpty {
                TimesheetLeaveInfoRows(lines: leaveLines)
            }
            if payrollSummary.lineItems.isEmpty && leaveLines.isEmpty {
                Text("No bookings found for this period.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            let totals = reviewTotals
            rowLine(
                title: "Hours · \(shiftCount) shifts (\(formatHours(totals?.hours ?? 0))h)",
                amount: totals?.standardLabour ?? 0
            )
            rowLine(title: "Overtime", amount: totals?.overtimeLabour ?? 0)
            rowLine(title: "Price work · \(draft.priceWorkEntries.count)", amount: totals?.priceWork ?? 0)
            rowLine(title: "Expenses · \(draft.expenseEntries.count)", amount: totals?.expenses ?? 0)
            Divider()
            rowLine(title: managerHasSigned ? "Approved total" : "Total", amount: totals?.total ?? 0)
            if !draft.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Text("Note to manager")
                    .font(.subheadline.weight(.semibold))
                Text(draft.managerNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// RULEBOOK 1.45.0 §8 `claimEvidenceCountText`: "… · 2 pieces of evidence" (nothing added for none).
    private static func extraSubtitle(_ base: String, evidenceCount: Int) -> String {
        let count = CanonicalBusinessEngine.claimEvidenceCountText(evidenceCount)
        return count.isEmpty ? base : "\(base) · \(count)"
    }

    @ViewBuilder
    private var reviewExpensesCard: some View {
        if !draft.expenseEntries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(canManagerReview ? "Expenses — review required" : "Expenses")
                    .font(.headline)
                ForEach(Array(draft.expenseEntries.enumerated()), id: \.element.id) { index, entry in
                    // RULEBOOK 1.45.0 §8: the evidence count in the subtitle and a link to each file.
                    managerExtraRow(
                        title: entry.title,
                        subtitle: Self.extraSubtitle(
                            "\(entry.date.formatted(date: .abbreviated, time: .omitted)) · \(entry.jobNumber)",
                            evidenceCount: entry.evidence.count
                        ),
                        amount: entry.amount,
                        decision: entry.managerDecision,
                        revisedAmount: entry.managerRevisedAmount,
                        canReview: canManagerReview,
                        onApprove: { updateExpenseDecision(at: index, decision: .approved) },
                        onDecline: { updateExpenseDecision(at: index, decision: .declined) },
                        onEdit: { editingExpenseId = entry.id }
                    )
                    .id("\(entry.id)-\(entry.managerDecision.rawValue)-\(entry.managerRevisedAmount ?? -1)")
                    ClaimEvidenceLinks(evidence: entry.evidence, legacyReceiptName: entry.receiptName)
                }
            }
            .padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private var reviewPriceWorkCard: some View {
        if !draft.priceWorkEntries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(canManagerReview ? "Price work — review required" : "Price work")
                    .font(.headline)
                ForEach(Array(draft.priceWorkEntries.enumerated()), id: \.element.id) { index, row in
                    managerExtraRow(
                        title: row.title,
                        subtitle: Self.extraSubtitle(
                            "Agreed with: \(row.agreedManagerName) · \(row.startDate.formatted(date: .abbreviated, time: .omitted)) · \(CanonicalBusinessEngine.priceWorkJobNumberText(row.jobNumber))",
                            evidenceCount: row.evidence.count
                        ),
                        amount: row.amount,
                        decision: row.managerDecision,
                        revisedAmount: row.managerRevisedAmount,
                        canReview: canManagerReview,
                        onApprove: { updatePriceWorkDecision(at: index, decision: .approved) },
                        onDecline: { updatePriceWorkDecision(at: index, decision: .declined) },
                        onEdit: { editingPriceWorkId = row.id }
                    )
                    .id("\(row.id)-\(row.managerDecision.rawValue)-\(row.managerRevisedAmount ?? -1)")
                    ClaimEvidenceLinks(evidence: row.evidence)
                }
            }
            .padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var reviewSignaturesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signatures")
                .font(.headline)
            operativeSignatureBlock
            if TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: operative) {
                managerSignatureBlock
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var reviewSignOffSection: some View {
        if TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Signed off", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color.green)
                    .background(Color.green.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("To edit this timesheet, please go to the signed off timesheets page, export it and then edit within the exported timesheets tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if viewerIsReviewer,
                  TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: operative),
                  draft.managerSignedAt == nil {
            if needsExtrasReviewMessage {
                Text("Approve, decline or edit every expense and price-work line before signing off.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(action: handleSignOffTapped) {
                Label("Sign off & finalise", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityIdentifier("operativeTimesheetReview.signOffFinalise")
            .buttonStyle(.plain)
            .disabled(!TimesheetApprovalPolicy.operativeHasSigned(draft))
            .opacity(TimesheetApprovalPolicy.operativeHasSigned(draft) ? 1 : 0.5)
            // RULEBOOK §2: timesheet signing is online only.
            .onlineOnly(isOnline: smartCache.isOnline)
        }
    }

    private var needsExtrasReviewMessage: Bool {
        TimesheetDraftAdjustments.extrasPendingReview(in: draft)
            && (!draft.expenseEntries.isEmpty || !draft.priceWorkEntries.isEmpty)
    }

    private func handleSignOffTapped() {
        // RULEBOOK 1.30.2: nobody counter-signs their own sheet (`timesheetWriterIsReviewer`).
        guard viewerIsReviewer else { return }
        // RULEBOOK 1.43.0 §8 (review r318): tapping re-checks the period's bookings (reloads them when no server answer
        // covers the period), so a stuck "Loading bookings…" recovers.
        ensurePeriodBookings()
        // Nothing is counter-signed (and frozen) until pay can be worked out from loaded inputs.
        if let blocked = payInputsBlockMessage {
            saveErrorMessage = blocked
            return
        }
        if TimesheetDraftAdjustments.extrasPendingReview(in: draft)
            && (!draft.expenseEntries.isEmpty || !draft.priceWorkEntries.isEmpty) {
            showExtrasReviewRequiredAlert = true
        } else {
            showingManagerSignSheet = true
        }
    }

    private func updateExpenseDecision(at index: Int, decision: TimesheetManagerDecision) {
        var entries = draft.expenseEntries
        entries[index].managerDecision = decision
        entries[index].managerRevisedAmount = nil
        draft.expenseEntries = entries
        saveDraft()
    }

    private func updatePriceWorkDecision(at index: Int, decision: TimesheetManagerDecision) {
        var entries = draft.priceWorkEntries
        entries[index].managerDecision = decision
        entries[index].managerRevisedAmount = nil
        draft.priceWorkEntries = entries
        saveDraft()
    }

    @ViewBuilder
    private var operativeSignatureBlock: some View {
        if TimesheetApprovalPolicy.operativeHasSigned(draft), let signedAt = draft.operativeSignedAt {
            signatureImageView(base64: draft.operativeSignatureImageBase64)
            Text("Operative: \(draft.operativeSignedByName ?? (operative.fullName.isEmpty ? operative.email : operative.fullName)) · \(signedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            Text("Operative has not signed this week yet.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var managerSignatureBlock: some View {
        if let managerSignedAt = draft.managerSignedAt {
            signatureImageView(base64: draft.managerSignatureImageBase64)
            Text("Manager approved: \(draft.managerSignedByName ?? "Manager") · \(managerSignedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .frame(height: 82)
                .overlay(
                    Text("Manager signature")
                        .font(.system(size: 22, weight: .regular, design: .serif))
                        .italic()
                        .foregroundStyle(.primary.opacity(0.7))
                )
        }
    }

    @ViewBuilder
    private func signatureImageView(base64: String?) -> some View {
        if let base64,
           let data = Data(base64Encoded: base64),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 82)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.8)
                )
        }
    }

    @ViewBuilder
    private func managerPayrollLineRow(_ row: TimesheetPayrollLineItem) -> some View {
        let review = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: row.id, live: row)
        let removed = TimesheetDraftAdjustments.isPayrollLineRemoved(
            line: row,
            draft: draft,
            managerHasSigned: managerHasSigned,
            applyLiveReview: canManagerReview
        )
        let effective = TimesheetDraftAdjustments.effectivePayrollAmount(
            line: row,
            draft: draft,
            managerHasSigned: managerHasSigned,
            applyLiveReview: canManagerReview
        )

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(removed)
                Text("\(row.jobNumber) · \(row.projectName)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .strikethrough(removed)
                Text(row.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .strikethrough(removed)
                if row.isOverlapping {
                    // `overlappingBookingIds`: still paid; the line manager checks it.
                    Text(CanonicalBusinessEngine.overlappingBookingNote)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.warningAmber)
                }
            }
            Spacer()
            TimesheetAdjustedAmountText(
                original: row.amount,
                effective: effective,
                decision: review?.decision ?? .approved,
                managerHasSigned: managerHasSigned,
                applyLiveReview: canManagerReview
            )
            if canManagerReview {
                TimesheetManagerReviewActionBar(
                    decision: review?.decision ?? .approved,
                    canEdit: true,
                    onApprove: {
                        draft.payrollLineReviews[row.id] = TimesheetPayrollLineReview(decision: .approved, revisedAmount: nil)
                        saveDraft()
                    },
                    onDecline: {
                        draft.payrollLineReviews[row.id] = TimesheetPayrollLineReview(decision: .declined, revisedAmount: nil)
                        saveDraft()
                    },
                    onEdit: { editingPayrollLineId = row.id }
                )
            }
        }
        .padding(.vertical, 4)
        .background(row.isOverlapping ? PPColor.warningAmber.opacity(0.12) : Color.clear)
        .opacity(removed ? 0.55 : 1)
    }

    @ViewBuilder
    private func managerExtraRow(
        title: String,
        subtitle: String,
        amount: Double,
        decision: TimesheetManagerDecision,
        revisedAmount: Double?,
        canReview: Bool,
        onApprove: @escaping () -> Void,
        onDecline: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) -> some View {
        let displayDecision = decision.reviewSelection
        let declined = displayDecision == .declined
        // `timesheetEntryEffectiveAmount`: what the entry pays under the decision.
        let decidedAmount = CanonicalBusinessEngine.timesheetEntryEffectiveAmount(
            decision: decision.rawValue,
            revisedAmount: revisedAmount,
            amount: amount
        ) ?? amount
        let effectiveAmount: Double = canReview ? decidedAmount : amount
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(declined)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .strikethrough(declined)
            }
            Spacer()
            if canReview {
                VStack(alignment: .trailing, spacing: 2) {
                    if decision == .edited, let revised = revisedAmount, abs(revised - amount) >= 0.01 {
                        Text(OrgMoney.format(amount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .strikethrough(true, color: .secondary)
                        Text(OrgMoney.format(revised))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.blue)
                    } else if declined {
                        Text(OrgMoney.format(amount))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .strikethrough(true, color: .secondary)
                    } else {
                        Text(OrgMoney.format(effectiveAmount))
                            .font(.subheadline.weight(.bold))
                    }
                }
            } else {
                TimesheetAdjustedAmountText(
                    original: amount,
                    effective: decidedAmount,
                    decision: decision,
                    managerHasSigned: !canReview && decision != .pending
                )
            }
            if canReview {
                TimesheetManagerReviewActionBar(
                    decision: decision,
                    canEdit: true,
                    onApprove: onApprove,
                    onDecline: onDecline,
                    onEdit: onEdit
                )
            }
        }
        .padding(.vertical, 4)
        .opacity(declined ? 0.55 : 1)
    }

    @ViewBuilder
    private var statusLine: some View {
        if TimesheetApprovalPolicy.operativeHasSigned(draft) {
            Text("Operative signed")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else {
            Text("Awaiting operative signature")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func rowLine(title: String, amount: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(OrgMoney.format(amount))
                .fontWeight(.semibold)
        }
        .padding(.vertical, 2)
    }

    private func saveDraft() {
        // RULEBOOK 1.43.0 (review r318, 2nd round): nothing is saved while the period's sheet could not be read.
        guard !periodLoadFailed else {
            saveErrorMessage = TimesheetDraftStore.periodReadFailedMessage
            return
        }
        // The agreed snapshot is never frozen from inputs that did not load (`PayInputsLoad`).
        if payInputsBlockMessage == nil || draft.weeklyReportOverride != nil {
        TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
            to: &draft,
            user: operative,
            week: week,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            policy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
            organization: firebaseBackend.currentOrganization,
            scheduleOptions: firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions(),
            viewer: userStore.displayUser,
            relatedUsers: userStore.organizationUsers,
            writerIsReviewer: userStore.displayUser.map {
                TimesheetApprovalPolicy.writerIsReviewer(
                    writerId: $0.id,
                    writer: $0,
                    subjectUserId: operative.id,
                    subject: operative
                )
            },
            // RULEBOOK 1.43.0 §8: an empty frozen snapshot is rebuilt only from loaded bookings and pay inputs.
            snapshotInputsReady: payInputsBlockMessage == nil
        )
        }
        TimesheetDraftStore.save(draft, userId: operative.id, weekStart: week.start, weekEnd: week.end)
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let snapshot = draft
        let writer = userStore.displayUser
        let subject = operative
        Task {
            // Owner-or-reviewer partial write, plus changed `extraEntryReviews` (`timesheetEntryReviewWriteFields`).
            saveErrorMessage = await TimesheetDraftStore.saveToCloud(
                snapshot,
                userId: subject.id,
                weekStart: week.start,
                weekEnd: week.end,
                firebaseBackend: firebaseBackend,
                organizationId: orgId,
                writer: writer,
                subject: subject
            )
        }
    }

    private static let liveTimesheetKey = "timesheet.review"

    private var isEditingReview: Bool {
        showingManagerSignSheet || editingPayrollLineId != nil || editingExpenseId != nil || editingPriceWorkId != nil
    }

    private func listenToServerTimesheet() {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        firebaseBackend.listenTimesheetState(
            key: Self.liveTimesheetKey,
            organizationId: orgId,
            userId: operative.id,
            weekStart: week.start
        ) {
            if isEditingReview {
                serverTimesheetChangedWhileEditing = true
            } else {
                Task { await refreshDraftFromCloud() }
            }
        }
    }

    private func refreshDraftFromCloud() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let read = await TimesheetDraftStore.refreshFromCloudReporting(
            userId: operative.id,
            weekStart: week.start,
            firebaseBackend: firebaseBackend,
            organizationId: orgId
        )
        // RULEBOOK 1.43.0 (review r318): a read that did not answer is an error, never a new sheet.
        if read.failed {
            await MainActor.run {
                periodLoadFailed = true
                saveErrorMessage = TimesheetDraftStore.periodReadFailedMessage
            }
            return
        }
        await MainActor.run {
            if periodLoadFailed { saveErrorMessage = nil }
            periodLoadFailed = false
        }
        guard let remote = read.draft else {
            // No server sheet clears the local copy; show what is left (nothing) unless a review is open.
            await MainActor.run {
                guard !isEditingReview,
                      organizationIdsMatch(firebaseBackend.currentOrganization?.firestoreDocumentId, orgId) else { return }
                draft = TimesheetDraftStore.load(userId: operative.id, weekStart: week.start, organizationId: orgId)
            }
            return
        }
        await MainActor.run { draft = remote }
        var updated = remote
        TimesheetApprovalPolicy.applySelfApprovalIfNoLineManager(draft: &updated, user: operative)
        if updated.managerSignedAt != remote.managerSignedAt {
            draft = updated
            saveDraft()
        } else {
            draft = remote
        }
    }

    /// A failed read is a failure (`PayInputsLoad`), never an empty history.
    private func loadDayRateHistory() async {
        ensurePeriodBookings()
        // The Retry of a failed period read reads the sheet again.
        if periodLoadFailed { await refreshDraftFromCloud() }
        let result = await PayInputsLoad.loadHistory(firebaseBackend)
        await MainActor.run {
            if let history = result.history { dayRateHistoryCollection = history }
            payInputsState = result.state
        }
    }

    /// The person's approved leave in this period (`timesheetLeaveLines`), for the line manager.
    private var leaveLines: [CanonicalTimesheetLeaveLine] {
        TimesheetPayrollCollector.leaveLines(
            for: operative,
            in: week.start...week.end,
            holidays: holidayStore.bookings,
            operatives: operativeStore.allOperatives,
            organization: firebaseBackend.currentOrganization
        )
    }

    private var payrollSummary: TimesheetPayrollSummary {
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        return TimesheetPayrollCollector.collect(
            for: operative,
            week: week,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            policy: policy,
            organization: firebaseBackend.currentOrganization,
            scheduleOptions: scheduleOptions,
            relatedUsers: userStore.organizationUsers
        )
    }

    private var shiftCount: Int {
        payrollSummary.shiftCount
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}

private struct OperativeTimesheetReviewSheetsModifier: ViewModifier {
    @Binding var draft: TimesheetDraft
    let operative: AppUser
    let week: WeekRange
    let payrollLines: [TimesheetPayrollLineItem]
    let policy: OrgPayrollTimePolicy
    /// RULEBOOK 1.19.0 §4.3/§8: a line is reviewed under the working hours in effect on ITS day (history first).
    let organization: Organization?
    let bookingStore: BookingStore
    let managerScheduleStore: ManagerScheduleStore
    @Binding var editingPayrollLineId: String?
    @Binding var editingExpenseId: UUID?
    @Binding var editingPriceWorkId: UUID?
    @Binding var showingManagerSignSheet: Bool
    let userStore: UserStore
    let notificationService: NotificationService
    let onSaveDraft: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: payrollEditPresented) {
                payrollEditSheet
            }
            .sheet(isPresented: expenseEditPresented) {
                expenseEditSheet
            }
            .sheet(isPresented: priceWorkEditPresented) {
                priceWorkEditSheet
            }
            .sheet(isPresented: $showingManagerSignSheet) {
                managerSignSheet
            }
    }

    private var payrollEditPresented: Binding<Bool> {
        Binding(
            get: { editingPayrollLineId != nil },
            set: { if !$0 { editingPayrollLineId = nil } }
        )
    }

    private var expenseEditPresented: Binding<Bool> {
        Binding(
            get: { editingExpenseId != nil },
            set: { if !$0 { editingExpenseId = nil } }
        )
    }

    private var priceWorkEditPresented: Binding<Bool> {
        Binding(
            get: { editingPriceWorkId != nil },
            set: { if !$0 { editingPriceWorkId = nil } }
        )
    }

    /// RULEBOOK 1.46.0 §8: an Edit hours save stores, on each line of the booking, the review the rulebook priced
    /// (`revisedPayrollLineAmounts` → `PayrollLineEditReviewFields`, revised amounts in pennies), exactly web's fields.
    private func applyPayrollReviewSave(lineId: String, edit: TimesheetPayrollLineBookingLookup.Edit) {
        guard edit.error == nil, edit.amounts != nil else { return }
        draft.payrollLineReviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: lineId, draft: draft)
        editingPayrollLineId = nil
        onSaveDraft()
    }

    private func applyExtraReviewSave(
        expenseId: UUID?,
        priceWorkId: UUID?,
        revisedAmount enteredAmount: Double
    ) {
        // RULEBOOK 1.46.0 (web `extraReviewAfterSave`): a revised amount is stored in pennies (`roundPennies`).
        let revisedAmount = CanonicalBusinessEngine.roundPennies(enteredAmount)
        if let expenseId, let index = draft.expenseEntries.firstIndex(where: { $0.id == expenseId }) {
            var entries = draft.expenseEntries
            let prior = entries[index].managerDecision
            let original = entries[index].amount
            let unchanged = abs(revisedAmount - original) < 0.01
            if prior == .declined || unchanged {
                entries[index].managerDecision = .approved
                entries[index].managerRevisedAmount = unchanged ? nil : revisedAmount
            } else {
                entries[index].managerDecision = .edited
                entries[index].managerRevisedAmount = revisedAmount
            }
            draft.expenseEntries = entries
            editingExpenseId = nil
        }
        if let priceWorkId, let index = draft.priceWorkEntries.firstIndex(where: { $0.id == priceWorkId }) {
            var entries = draft.priceWorkEntries
            let prior = entries[index].managerDecision
            let original = entries[index].amount
            let unchanged = abs(revisedAmount - original) < 0.01
            if prior == .declined || unchanged {
                entries[index].managerDecision = .approved
                entries[index].managerRevisedAmount = unchanged ? nil : revisedAmount
            } else {
                entries[index].managerDecision = .edited
                entries[index].managerRevisedAmount = revisedAmount
            }
            draft.priceWorkEntries = entries
            editingPriceWorkId = nil
        }
        onSaveDraft()
    }

    @ViewBuilder
    private var payrollEditSheet: some View {
        if let lineId = editingPayrollLineId,
           let row = payrollLines.first(where: { $0.id == lineId }) {
            let bookingId = TimesheetPayrollLineBookingLookup.bookingId(from: lineId)
            let operativeBooking = bookingId.flatMap { id in bookingStore.bookings.first(where: { $0.id == id }) }
            let managerBooking = bookingId.flatMap { id in managerScheduleStore.managerSiteBookings.first(where: { $0.id == id }) }
            let linePolicy = organization.map { PayrollTimePolicyCatalog.policy(for: row.date, organization: $0) } ?? policy
            let initialChoice = TimesheetPayrollLineBookingLookup.initialChoice(
                for: row,
                operativeBooking: operativeBooking,
                managerBooking: managerBooking,
                policy: linePolicy
            )
            TimesheetPayrollLineEditHoursSheet(
                row: row,
                lines: payrollLines,
                policy: linePolicy,
                initialChoice: initialChoice,
                employment: CanonicalBusinessEngine.timesheetPerson(operative),
                onSave: { edit in
                    applyPayrollReviewSave(lineId: lineId, edit: edit)
                }
            )
        }
    }

    @ViewBuilder
    private var expenseEditSheet: some View {
        if let expenseId = editingExpenseId,
           let entry = draft.expenseEntries.first(where: { $0.id == expenseId }) {
            TimesheetManagerAmountEditSheet(
                title: "Edit expense",
                subtitle: entry.title,
                originalAmount: entry.managerRevisedAmount ?? entry.amount,
                onSave: { value in
                    applyExtraReviewSave(expenseId: expenseId, priceWorkId: nil, revisedAmount: value)
                },
                onDelete: nil
            )
        }
    }

    @ViewBuilder
    private var priceWorkEditSheet: some View {
        if let priceWorkId = editingPriceWorkId,
           let entry = draft.priceWorkEntries.first(where: { $0.id == priceWorkId }) {
            TimesheetManagerAmountEditSheet(
                title: "Edit price work",
                subtitle: entry.title,
                originalAmount: entry.managerRevisedAmount ?? entry.amount,
                onSave: { value in
                    applyExtraReviewSave(expenseId: nil, priceWorkId: priceWorkId, revisedAmount: value)
                },
                onDelete: nil
            )
        }
    }

    private var managerSignSheet: some View {
        NavigationStack {
            ManagerTimesheetSignOffView(
                signerName: userStore.displayUser?.fullName.isEmpty == false
                    ? (userStore.displayUser?.fullName ?? "Line manager")
                    : (userStore.displayUser?.email ?? "Line manager")
            ) { signatureImageData in
                let signedByName = userStore.displayUser?.fullName.isEmpty == false
                    ? (userStore.displayUser?.fullName ?? "")
                    : (userStore.displayUser?.email ?? "")
                guard TimesheetDraftStore.applySignOff(
                    to: &draft,
                    role: "manager",
                    signedAt: Date(),
                    signedByName: signedByName,
                    signedByUserId: userStore.displayUser?.id,
                    signatureImageBase64: signatureImageData.base64EncodedString()
                ) else { return }
                onSaveDraft()
                let signer = draft.managerSignedByName ?? "Line manager"
                let operativeName = operative.fullName.isEmpty ? operative.email : operative.fullName
                Task {
                    await notificationService.notifyTimesheetSignedByManager(
                        targetUserId: operative.id,
                        signedByName: signer,
                        weekStart: week.start
                    )
                    // `lineManagerPeerRecipients(operative, signer, roster)` picks the other line managers.
                    await notificationService.notifyLineManagerPeerAction(
                        actorName: signer,
                        actionSummary: "\(operativeName)'s timesheet (\(week.title))",
                        subject: operative,
                        actionVerb: "signed"
                    )
                }
                showingManagerSignSheet = false
            }
        }
        .presentationDetents([.large])
    }
}

/// Add / Edit Price Work and Add / Edit Expense on My Timesheets (RULEBOOK 1.30.1 / 1.43.0 / 1.45.0 §8). Evidence is
/// the shared claim control (`ClaimEvidenceEditor`: Take photo, Choose photo, Add site audit, Add file), uploaded into
/// the person's own claim folder on save; an expense needs at least one piece (`EXPENSE_EVIDENCE_REQUIRED_MESSAGE`),
/// price work's is optional. The amount reads `EXPENSE_AMOUNT_LABEL` ("Amount inc VAT") / `PRICE_WORK_AMOUNT_LABEL`.
/// The owner's save is checked by `timesheetOwnerEntriesError` (job number, evidence) in `TimesheetDraftStore.saveToCloud`;
/// when it is refused, the files just uploaded are discarded (`payeClaimEvidenceToDelete`) and the message is shown.
private struct TimesheetMoneyEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var projectStore: ProjectStore
    let mode: Mode
    /// The entry being edited (same id on save), nil to add.
    private let editingExpense: TimesheetExpenseEntry?
    private let editingPriceWork: TimesheetPriceWorkEntry?
    /// Saves the entry into the sheet; returns the message when the save was refused (nil = saved).
    private let onSaveExpense: (TimesheetExpenseEntry) async -> String?
    private let onSavePriceWork: (TimesheetPriceWorkEntry) async -> String?

    @State private var entryTitle = ""
    @State private var details = ""
    @State private var jobNumber = ""
    @State private var amountText = ""
    @State private var managerName = ""
    @State private var date = Date()
    @State private var endDate: Date?
    @State private var includeEndDate = false
    @State private var existingEvidence: [PayeClaimEvidence] = []
    @State private var pendingEvidence: [PendingPayeClaimEvidence] = []
    @State private var evidenceMessage: String?
    @State private var saveError: String?
    @State private var saving: String?
    @State private var didPrefill = false
    @FocusState private var managerFieldFocused: Bool

    private var isEditing: Bool { editingExpense != nil || editingPriceWork != nil }

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: OrgMoney.symbol(), with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// RULEBOOK 1.43.0 §8 `agreedManagerSuggestions`: the price work approvers' rule (`priceWorkApproverCandidates`:
    /// active admins and managers of this organisation, one per person, never the person), name containing the text, at
    /// most 6. The roster rows carry each users document's stored organisation (`PayeClaimPeople.approverRow`), as web
    /// passes `homeOrganizationId`. The field stays free text.
    private var managerSuggestions: [String] {
        guard let person = userStore.displayUser else { return [] }
        return CanonicalBusinessEngine.agreedManagerSuggestions(
            query: managerName,
            person: PayeClaimPeople.approverRow(person),
            roster: PayeClaimPeople.approverRoster(userStore.organizationUsers),
            organizationId: firebaseBackend.payeClaimsOrganizationId
        )
    }

    private var jobSuggestions: [String] {
        let query = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        return ProjectWorksMerge.uniqueWorks(projectStore.projects)
            .compactMap { project -> String? in
                let number = project.jobNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !number.isEmpty else { return nil }
                let haystack = "\(number) \(project.siteName)"
                guard haystack.localizedCaseInsensitiveContains(query),
                      number.caseInsensitiveCompare(query) != .orderedSame,
                      seen.insert(number.lowercased()).inserted else { return nil }
                return number
            }
            .prefix(6)
            .map { $0 }
    }

    init(mode: Mode, editing: TimesheetExpenseEntry? = nil, onSave: @escaping (TimesheetExpenseEntry) async -> String?) {
        self.mode = mode
        self.editingExpense = editing
        self.editingPriceWork = nil
        self.onSaveExpense = onSave
        self.onSavePriceWork = { _ in nil }
    }

    init(mode: Mode, editing: TimesheetPriceWorkEntry? = nil, onSave: @escaping (TimesheetPriceWorkEntry) async -> String?) {
        self.mode = mode
        self.editingExpense = nil
        self.editingPriceWork = editing
        self.onSaveExpense = { _ in nil }
        self.onSavePriceWork = onSave
    }

    /// RULEBOOK 1.30.1 `priceWorkJobNumberError`: price work only (an expense's job number stays optional).
    private var jobNumberError: String? {
        mode == .priceWork ? CanonicalBusinessEngine.priceWorkJobNumberError(jobNumber) : nil
    }

    /// RULEBOOK 1.45.0 §8: an expense needs at least one piece of evidence before it can be saved.
    private var evidenceMissing: Bool {
        mode == .expense && existingEvidence.isEmpty && pendingEvidence.isEmpty
    }

    private var canSave: Bool {
        guard let amount, amount > 0, jobNumberError == nil, !evidenceMissing, saving == nil else { return false }
        return true
    }

    private var saveTitle: String {
        if let saving { return saving }
        if isEditing { return CanonicalBusinessEngine.timesheetEntrySaveChangesLabel }
        return mode == .expense ? "Add expense" : "Add price work"
    }

    private var screenTitle: String {
        if isEditing { return CanonicalBusinessEngine.timesheetEntryEditTitle(isExpense: mode == .expense) }
        return mode == .expense ? "Add Expense" : "Add Price Work"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    moneyCard {
                        labeledField(mode == .expense ? "Expense name" : "Price work name", text: $entryTitle)
                        Divider().overlay(ProjectWorksRevampColors.border)
                        labeledMultiline("Description", text: $details)
                        Divider().overlay(ProjectWorksRevampColors.border)
                        labeledField(mode == .priceWork ? "Job number (required)" : "Job number", text: $jobNumber)
                        suggestionRow(jobSuggestions) { jobNumber = $0 }
                        // RULEBOOK 1.30.1: a new price work entry needs a job number (`priceWorkJobNumberError`).
                        if let jobNumberError, !(entryTitle.isEmpty && amountText.isEmpty) {
                            Text(jobNumberError)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                        Divider().overlay(ProjectWorksRevampColors.border)
                        // RULEBOOK 1.45.0: "Amount inc VAT" for an expense, "Amount" for price work.
                        labeledField(CanonicalBusinessEngine.claimAmountLabel(isExpense: mode == .expense), text: $amountText, keyboard: .decimalPad)
                    }

                    if mode == .priceWork {
                        moneyCard {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MANAGER WHO AGREED THIS")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                                    .tracking(0.4)
                                TextField("Manager who agreed this", text: $managerName)
                                    .focused($managerFieldFocused)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("timesheets.\(AccessibilityID.token("Manager who agreed this"))")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            // RULEBOOK 1.43.0 `agreedManagerSuggestions`: shown as the person types, right under the
                            // field, as a list (the horizontal chips sat under the keyboard and were missed).
                            managerSuggestionList
                        }
                        .id("managerCard")
                    }

                    moneyCard {
                        DatePicker(mode == .expense ? "Date" : "Start date", selection: $date, displayedComponents: .date)
                            .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                            .accessibilityIdentifier("timesheets.date")
                            .font(.system(size: 13, weight: .medium))
                        if mode == .priceWork {
                            Divider().overlay(ProjectWorksRevampColors.border)
                            Toggle("Add end date", isOn: $includeEndDate)
                                .accessibilityIdentifier("timesheets.addEndDate")
                                .font(.system(size: 13, weight: .medium))
                            if includeEndDate {
                                DatePicker("End date", selection: Binding(
                                    get: { endDate ?? date },
                                    set: { endDate = $0 }
                                ), displayedComponents: .date)
                                .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                                .accessibilityIdentifier("timesheets.endDate")
                                .font(.system(size: 13, weight: .medium))
                            }
                        }
                    }

                    ClaimEvidenceEditor(
                        existing: $existingEvidence,
                        pending: $pendingEvidence,
                        message: $evidenceMessage,
                        required: mode == .expense,
                        identifier: "timesheets.evidence"
                    )
                    .environmentObject(firebaseBackend)

                    if let saveError {
                        PayeClaimFieldMessage(text: saveError)
                            .accessibilityIdentifier("timesheets.entry.error")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: managerName) { _, _ in
                guard managerFieldFocused, !managerSuggestions.isEmpty else { return }
                withAnimation { proxy.scrollTo("managerCard", anchor: .top) }
            }
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(saving != nil)
                    .accessibilityIdentifier("timesheets.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    Task { await save() }
                }
                .accessibilityIdentifier("timesheets.addExpense")
                .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving != nil)
        .onAppear(perform: prefill)
    }

    @ViewBuilder
    private var managerSuggestionList: some View {
        let suggestions = managerSuggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        managerName = suggestion
                        managerFieldFocused = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                            Text(suggestion)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timesheets.managerSuggestion.\(AccessibilityID.token(suggestion))")
                    if suggestion != suggestions.last {
                        Divider().overlay(ProjectWorksRevampColors.border)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(ProjectWorksRevampColors.blue.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier("timesheets.managerSuggestions")
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let entry = editingExpense {
            entryTitle = entry.title
            details = entry.details
            jobNumber = entry.jobNumber
            amountText = Self.amountText(entry.amount)
            date = entry.date
            existingEvidence = entry.evidence
        } else if let entry = editingPriceWork {
            entryTitle = entry.title
            details = entry.details
            jobNumber = entry.jobNumber
            amountText = Self.amountText(entry.amount)
            managerName = entry.agreedManagerName
            date = entry.startDate
            endDate = entry.endDate
            includeEndDate = entry.endDate != nil
            existingEvidence = entry.evidence
        }
    }

    private static func amountText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func save() async {
        guard canSave, let amount else { return }
        saveError = nil
        var uploaded: [PayeClaimEvidence] = []
        do {
            uploaded = try await ClaimEvidenceUpload.upload(pendingEvidence, firebaseBackend: firebaseBackend) { step in
                saving = step
            }
        } catch {
            saving = nil
            saveError = error.localizedDescription
            return
        }
        saving = "Saving…"
        let evidence = existingEvidence + uploaded
        let refused: String?
        if mode == .expense {
            var entry = editingExpense ?? TimesheetExpenseEntry(
                id: UUID(), title: "", details: "", jobNumber: "", date: date, amount: amount, receiptName: nil
            )
            entry.title = entryTitle.isEmpty ? "Untitled expense" : entryTitle
            entry.details = details
            entry.jobNumber = jobNumber
            entry.date = date
            entry.amount = amount
            entry.evidence = evidence
            // The stored row changes with this save: its old fingerprint no longer describes it.
            entry.reviewFingerprint = nil
            refused = await onSaveExpense(entry)
        } else {
            var entry = editingPriceWork ?? TimesheetPriceWorkEntry(
                id: UUID(), title: "", details: "", jobNumber: "", agreedManagerName: "", startDate: date, endDate: nil, amount: amount
            )
            entry.title = entryTitle.isEmpty ? "Untitled price work" : entryTitle
            entry.details = details
            entry.jobNumber = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.agreedManagerName = managerName.isEmpty ? "Manager" : managerName
            entry.startDate = date
            entry.endDate = includeEndDate ? endDate : nil
            entry.amount = amount
            entry.evidence = evidence
            // The stored row changes with this save: its old fingerprint no longer describes it.
            entry.reviewFingerprint = nil
            refused = await onSavePriceWork(entry)
        }
        saving = nil
        if let refused {
            // RULEBOOK 1.45.0 §24: a refused save leaves no copy behind (the just-uploaded files only).
            // The picked files stay on the form, so another save uploads them again.
            await firebaseBackend.discardPayeClaimEvidence(uploaded)
            saveError = refused
            return
        }
        dismiss()
    }

    private func moneyCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func labeledField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
            TextField(title, text: text)
                .accessibilityIdentifier("timesheets.\(AccessibilityID.token(title))")
                .font(.system(size: 14, weight: .medium))
                .keyboardType(keyboard)
        }
    }

    private func labeledMultiline(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
            TextField(title, text: text, axis: .vertical)
                .accessibilityIdentifier("timesheets.\(AccessibilityID.token(title))2")
                .font(.system(size: 14))
                .lineLimit(3, reservesSpace: true)
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestions: [String], onSelect: @escaping (String) -> Void) -> some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(ProjectWorksRevampColors.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .accessibilityIdentifier("timesheets.row.\(suggestion).\(AccessibilityID.token(suggestion))")
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    enum Mode {
        case expense
        case priceWork
    }
}

private struct SignTimesheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var smartCache: SmartCacheService
    let week: WeekRange
    let hoursAmount: Double
    let priceWorkAmount: Double
    let expensesAmount: Double
    let signerName: String
    /// When true, confirm sends the timesheet to line managers for counter-sign.
    let requiresLineManagerCounterSign: Bool
    let onApprove: (Data) -> Void
    @State private var signatureImageData: Data?

    var total: Double { hoursAmount + priceWorkAmount + expensesAmount }

    private var confirmButtonTitle: String {
        requiresLineManagerCounterSign
            ? "Confirm and send to line managers"
            : "Confirm Signature and Approve"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You're approving")
                        .font(.headline)
                    Divider()
                    stat("Period", week.title)
                    stat("Hours", OrgMoney.format(hoursAmount))
                    stat("Price work", OrgMoney.format(priceWorkAmount))
                    stat("Expenses", OrgMoney.format(expensesAmount))
                    HStack {
                        Text("Timesheet total")
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(OrgMoney.format(total))
                            .foregroundStyle(.white)
                            .font(.title3.weight(.bold))
                    }
                    .padding(12)
                    .background(Color(red: 0.055, green: 0.122, blue: 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your signature")
                        .font(.headline)
                    Text("Signing as \(signerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TimesheetSignaturePad(imageData: $signatureImageData)
                        .frame(height: 120)
                    Text("Sign above · tap to clear")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("By signing you confirm these hours match the work you carried out.")
                        .font(.footnote)
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                }
                .padding(12)
                .background(ProjectWorksRevampColors.requiredPillBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    guard let signatureImageData else { return }
                    onApprove(signatureImageData)
                    dismiss()
                } label: {
                    Label(confirmButtonTitle, systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("timesheets.checkmark")
                .buttonStyle(.plain)
                .disabled(signatureImageData == nil)
                .opacity(signatureImageData == nil ? 0.5 : 1)
                // RULEBOOK §2: timesheet signing is online only.
                .onlineOnly(isOnline: smartCache.isOnline)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sign Timesheet")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func stat(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
    }
}

private struct ManagerTimesheetSignOffView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var smartCache: SmartCacheService
    let signerName: String
    let onApprove: (Data) -> Void
    @State private var signatureImageData: Data?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Manager sign-off")
                    .font(.title3.weight(.bold))
                Text("Sign as \(signerName) to finalise this timesheet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TimesheetSignaturePad(imageData: $signatureImageData)
                    .frame(height: 140)

                Button {
                    guard let signatureImageData else { return }
                    onApprove(signatureImageData)
                    dismiss()
                } label: {
                    Label("Sign off & finalise", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("timesheets.signOffFinalise")
                .buttonStyle(.plain)
                .disabled(signatureImageData == nil)
                .opacity(signatureImageData == nil ? 0.5 : 1)
                // RULEBOOK §2: timesheet signing is online only.
                .onlineOnly(isOnline: smartCache.isOnline)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sign Off")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("timesheets.cancel")
            }
        }
    }
}

/// `SENSITIVE_EXPORT_OPTION_LABEL` toggle, shown only when `canViewSensitiveProfile` is true for this subject.
private struct InvoiceTaxIdsOption: View {
    @EnvironmentObject var userStore: UserStore
    let subject: AppUser
    @Binding var isOn: Bool
    var token: String = "invoice"

    var body: some View {
        if userStore.canViewSensitiveProfile(of: subject.id) {
            SensitiveExportToggle(isOn: $isOn, accessibilityToken: token)
                .padding(14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct InvoiceUTRBlankWarningSheet: View {
    let onBack: () -> Void
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your UTR number is currently blank. Please fill this in via My Profile in Settings to ensure prompt payment.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Accept") { onAccept() }
                    .accessibilityIdentifier("invoiceUTRBlankWarning.accept")
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .navigationTitle("Before you invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { onBack() }
                        .accessibilityIdentifier("invoiceUTRBlankWarning.back")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct InvoiceGeneratedSuccessSheet: View {
    let pdfURL: URL
    let onDismiss: () -> Void
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.green)
                Text("Invoice generated successfully")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button {
                    showShare = true
                } label: {
                    Label("Share invoice", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .accessibilityIdentifier("invoiceGeneratedSuccess.shareInvoice")
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(24)
            .navigationTitle("Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                        .accessibilityIdentifier("invoiceGeneratedSuccess.done")
                }
            }
            .sheet(isPresented: $showShare) {
                InvoicingShareSheet(items: [pdfURL])
            }
        }
        .presentationDetents([.medium])
    }
}

private enum InvoicePDFGenerationSupport {
    /// UTR / VAT for one PDF, read only when `exportIncludesSensitiveFields` allows it. Nil leaves them off.
    @MainActor
    static func taxIdsForExport(
        subject: AppUser,
        requested: Bool,
        userStore: UserStore
    ) async -> CanonicalBusinessEngine.CanonicalSensitiveProfile? {
        let canView = userStore.canViewSensitiveProfile(of: subject.id)
        guard CanonicalBusinessEngine.exportIncludesSensitiveFields(requested: requested, canView: canView) else { return nil }
        return await userStore.loadSensitiveProfile(for: subject)
    }

    /// The blank-UTR warning only applies when the export option is on.
    static func shouldWarnBlankUTR(requested: Bool, taxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile?) -> Bool {
        requested && (taxIds?.utrNumber ?? "").isEmpty
    }

    @MainActor
    static func generatePDF(
        period: InvoicePeriodOption,
        settings _: OrganizationInvoicingSettings,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        managerScheduleStore: ManagerScheduleStore,
        dayRateHistoryCollection: OperativeDayRateHistoryCollection,
        taxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile?
    ) async -> URL? {
        guard let made = invoicePDF(
            period: period, firebaseBackend: firebaseBackend, userStore: userStore, bookingStore: bookingStore,
            operativeStore: operativeStore, projectStore: projectStore, managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection, taxIds: taxIds
        ) else { return nil }
        // RULEBOOK 1.45.0 §8 `timesheetEvidencePages`: one page per piece of evidence on the invoice's price work and
        // expense rows, after the invoice. If the pages cannot be added the invoice is still given without them.
        guard !made.evidence.isEmpty else { return made.url }
        let footer = [firebaseBackend.currentOrganization?.name ?? "Organisation", "Invoice", made.userName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let appended = await PayeClaimReportPDF.appendTimesheetEvidence(
            to: made.url,
            pages: made.evidence,
            footerText: footer,
            readFile: { path in try await firebaseBackend.payeClaimStoredFileData(path: path) }
        )
        return appended?.url ?? made.url
    }

    @MainActor
    private static func invoicePDF(
        period: InvoicePeriodOption,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        managerScheduleStore: ManagerScheduleStore,
        dayRateHistoryCollection: OperativeDayRateHistoryCollection,
        taxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile?
    ) -> (url: URL, evidence: [PayeClaimEvidencePage], userName: String)? {
        guard let currentUser = userStore.displayUser else { return nil }
        let bookings = bookingStore.bookings
        let managerBookings = managerScheduleStore.managerSiteBookings
        let operatives = operativeStore.allOperatives
        let projects = projectStore.projects
        let smallWorks = projectStore.smallWorks
        let organization = firebaseBackend.currentOrganization
        let policy = organization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = organization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let orgName = organization?.name ?? "Organization"
        let userName = currentUser.fullName.isEmpty ? currentUser.email : currentUser.fullName
        let history = dayRateHistoryCollection

        let (rows, evidence) = invoiceLineItems(
            for: period,
            currentUser: currentUser,
            policy: policy,
            scheduleOptions: scheduleOptions,
            organization: organization,
            bookings: bookings,
            managerBookings: managerBookings,
            operatives: operatives,
            projects: projects,
            smallWorks: smallWorks,
            history: history,
            relatedUsers: userStore.organizationUsers
        )
        let total = rows.reduce(0) { $0 + $1.amount }
        let notes = rateChangeNotes(
            for: period,
            currentUser: currentUser,
            operatives: operatives,
            dayRateHistoryCollection: history
        )
        guard let url = InvoicePDFBuilder.makePDF(
            context: InvoicePDFBuilder.Context(
                organizationName: orgName,
                userName: userName,
                vatNumber: taxIds.flatMap { $0.vatNumber.isEmpty ? nil : $0.vatNumber },
                utrNumber: taxIds.flatMap { $0.utrNumber.isEmpty ? nil : $0.utrNumber },
                generatedAt: Date(),
                periodTitle: period.title,
                periodDateRange: period.dateRangeText,
                lineItems: rows,
                totalAmount: total,
                rateChangeNotes: notes
            )
        ) else { return nil }
        return (url, evidence, userName)
    }

    private static func invoiceLineItems(
        for period: InvoicePeriodOption,
        currentUser: AppUser,
        policy: OrgPayrollTimePolicy,
        scheduleOptions: MyScheduleOptions,
        organization: Organization?,
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        operatives: [Operative],
        projects: [Project],
        smallWorks: [Project],
        history: OperativeDayRateHistoryCollection,
        relatedUsers: [AppUser] = []
    ) -> (rows: [InvoiceLineItem], evidence: [PayeClaimEvidencePage]) {
        let summary = TimesheetPayrollCollector.collect(
            for: currentUser,
            in: period.startDate...period.endDate,
            bookings: bookings,
            managerBookings: managerBookings,
            operatives: operatives,
            projects: projects,
            smallWorks: smallWorks,
            history: history,
            policy: policy,
            organization: organization,
            scheduleOptions: scheduleOptions,
            relatedUsers: relatedUsers
        )
        let draft = TimesheetDraftStore.load(
            userId: currentUser.id,
            weekStart: OrganizationRulebookContext.calendar.startOfDay(for: period.startDate)
        )
        // RULEBOOK 1.10.0 §8 `timesheetInvoiceRows` (`raw`, as web's owner invoice): the signed snapshot first, else
        // the live lines; PAYE and leave lines never go on an invoice.
        let rows = TimesheetInvoiceRows.rows(for: currentUser, summary: summary, draft: draft, period: period.startDate...period.endDate)
        let sorted = InvoiceLineItem.invoiceLines(rows).sorted {
            if $0.date == $1.date {
                return $0.projectName < $1.projectName
            }
            return $0.date < $1.date
        }
        // RULEBOOK 1.45.0 §8: the evidence pages of this invoice's price work and expense rows.
        let evidence = TimesheetInvoiceRows.evidencePages(
            for: currentUser, summary: summary, draft: draft, period: period.startDate...period.endDate
        )
        return (sorted, evidence)
    }

    private static func rateChangeNotes(
        for period: InvoicePeriodOption,
        currentUser: AppUser,
        operatives: [Operative],
        dayRateHistoryCollection: OperativeDayRateHistoryCollection
    ) -> [String] {
        let cal = OrganizationRulebookContext.calendar  // pay periods are organisation-zone days
        var notes: [String] = []

        let userHistory = (dayRateHistoryCollection.byUserId[currentUser.id] ?? [])
            .filter {
                let day = cal.startOfDay(for: $0.effectiveAt)
                return day >= period.startDate && day <= period.endDate
            }
            .sorted(by: { $0.effectiveAt < $1.effectiveAt })

        for entry in userHistory {
            notes.append(entry.dayRate.map { "Rate updated to \(formatCurrency($0)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted))." }
                ?? "Rate not set from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
        }

        let matchedOperatives = operatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == currentUser.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for operative in matchedOperatives {
            let entries = (dayRateHistoryCollection.byOperativeId[operative.id.uuidString] ?? [])
                .filter {
                    let day = cal.startOfDay(for: $0.effectiveAt)
                    return day >= period.startDate && day <= period.endDate
                }
                .sorted(by: { $0.effectiveAt < $1.effectiveAt })
            for entry in entries {
                notes.append(entry.dayRate.map { "Operative rate updated to \(formatCurrency($0)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted))." }
                ?? "Operative rate not set from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
            }
        }

        return Array(Set(notes)).sorted()
    }

    private static func formatCurrency(_ value: Double) -> String {
        OrgMoney.format(value)
    }
}

private struct GenerateInvoiceView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore

    let settings: OrganizationInvoicingSettings
    let lockedPeriod: InvoicePeriodOption?

    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    /// Pay-rate history read state: a failed read blocks sign-off, the agreed snapshot, invoices and exports.
    @State private var payInputsState: PayInputsLoadState = .loading
    /// Why pay cannot be worked out yet, else nil (`PayInputsLoad.blockMessage`).
    private var payInputsBlockMessage: String? {
        PayInputsLoad.blockMessage(state: payInputsState, organization: firebaseBackend.currentOrganization)
    }
    @State private var selectedPeriodId: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generatedPDFURL: URL?
    @State private var showInvoiceUTRWarning = false
    /// Off each time the screen opens (`SENSITIVE_EXPORT_OPTION_LABEL`).
    @State private var includeTaxIds = false
    @State private var invoiceTaxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile?
    @State private var showInvoiceSuccess = false

    private var periodOptions: [InvoicePeriodOption] {
        if let lockedPeriod {
            return [lockedPeriod]
        }
        if settings.paymentRunMode == .recurringTimeframe {
            guard let period = recurringInvoicePeriod() else { return [] }
            return [period]
        }
        let historical = historicalDateRangePeriods(limit: 18)
        if !historical.isEmpty { return historical }

        // Fallback keeps Generate Invoice usable even when historic periods are unavailable.
        let cal = OrganizationRulebookContext.calendar  // pay periods are organisation-zone days
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let monthLabel = monthStart.formatted(.dateTime.month(.abbreviated).year())
        guard let firstRange = settings.normalizedRanges.first,
              let fallback = makePeriodOption(for: firstRange, monthDate: monthStart, monthLabel: monthLabel) else {
            return []
        }
        return [fallback]
    }

    private var selectedPeriod: InvoicePeriodOption? {
        if let lockedPeriod {
            return lockedPeriod
        }
        if settings.paymentRunMode == .recurringTimeframe {
            return periodOptions.first
        }
        return periodOptions.first(where: { $0.id == selectedPeriodId }) ?? periodOptions.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard

                Text("Invoice Period")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)

                if let lockedPeriod {
                    lockedInvoicePeriodCard(lockedPeriod)
                } else {
                    invoicePeriodPickerCard
                }

                if let subject = userStore.displayUser {
                    InvoiceTaxIdsOption(subject: subject, isOn: $includeTaxIds)
                }
                Button {
                    beginInvoiceGeneration()
                } label: {
                    HStack {
                        Spacer()
                        if isGenerating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Generate Invoice")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
                .accessibilityIdentifier("invoicing.generateInvoice")
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(colors: [Color(red: 0.169, green: 0.816, blue: 0.478), Color(red: 0.102, green: 0.635, blue: 0.349)], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .green.opacity(0.25), radius: 12, y: 6)
                .disabled(isGenerating || selectedPeriod == nil)
                .opacity(selectedPeriod == nil ? 0.45 : 1)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Generate Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInvoiceUTRWarning) {
            InvoiceUTRBlankWarningSheet(
                onBack: { showInvoiceUTRWarning = false },
                onAccept: {
                    showInvoiceUTRWarning = false
                    Task { await runInvoiceGeneration() }
                }
            )
        }
        .sheet(isPresented: $showInvoiceSuccess) {
            if let generatedPDFURL {
                InvoiceGeneratedSuccessSheet(pdfURL: generatedPDFURL) {
                    showInvoiceSuccess = false
                    self.generatedPDFURL = nil
                }
            }
        }
        .task {
            await loadRateHistory()
            if selectedPeriodId.isEmpty {
                selectedPeriodId = periodOptions.first?.id ?? ""
            }
        }
    }

    init(settings: OrganizationInvoicingSettings, lockedPeriod: InvoicePeriodOption? = nil) {
        self.settings = settings
        self.lockedPeriod = lockedPeriod
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your payment runs")
                .font(.footnote.weight(.black))
                .foregroundStyle(Color(red: 0.169, green: 0.733, blue: 0.937))
                .textCase(.uppercase)
                .tracking(1.2)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            if settings.paymentRunMode == .dateRanges {
                ForEach(Array(settings.normalizedRanges.enumerated()), id: \.element.id) { index, range in
                    summaryRow(chip: "\(range.startDay) - \(range.endDay)", text: index == 0 ? "First payment run" : "Second payment run")
                    if let payout = payoutSummary(forRunIndex: index) {
                        summaryRow(chip: payout.chip, text: payout.text)
                    }
                }
            } else {
                summaryRow(chip: "\(settings.recurringRunStartDay.title.prefix(3)) - \(settings.recurringRunEndDay.title.prefix(3))", text: settings.recurringRunDisplaySummary)
                if let payout = payoutSummary(forRunIndex: 0) {
                    summaryRow(chip: payout.chip, text: payout.text)
                }
            }
        }
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.07), radius: 8, y: 2)
    }

    private func payoutSummary(forRunIndex index: Int) -> (chip: String, text: String)? {
        if settings.paymentDateMode == .specificDates {
            let dates = settings.normalizedPaymentDates
            guard index < dates.count else { return nil }
            return ("Day \(dates[index])", "Payout day")
        }
        return ("Every \(settings.recurringPaymentDay.title)", "Payout day")
    }

    @ViewBuilder
    private func summaryRow(chip: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(chip)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ProjectWorksRevampColors.blueTint)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 16) }
    }

    @ViewBuilder
    private var invoicePeriodPickerCard: some View {
        if settings.paymentRunMode == .dateRanges {
            Menu {
                ForEach(periodOptions) { option in
                    Button {
                        selectedPeriodId = option.id
                    } label: {
                        HStack {
                            Text(option.title)
                            if selectedPeriodId == option.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                        .accessibilityIdentifier("invoicing.row.\(option.id).checkmark")
                }
            } label: {
                HStack {
                    Text("Invoice Period")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(selectedPeriod?.title ?? "Select")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(ProjectWorksRevampColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
            }
            .accessibilityIdentifier("invoicing.checkmark")
            .buttonStyle(.plain)
            .onAppear {
                if selectedPeriodId.isEmpty {
                    selectedPeriodId = periodOptions.first?.id ?? ""
                }
            }
        } else if let period = selectedPeriod {
            HStack {
                Text("Invoice Period")
                    .font(.body)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(period.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text(period.dateRangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
        } else {
            Text("No recurring period available.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lockedInvoicePeriodCard(_ period: InvoicePeriodOption) -> some View {
        HStack {
            Text("Invoice Period")
                .font(.body)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(period.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(period.dateRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
    }

    /// A failed read is a failure (`PayInputsLoad`), never an empty history.
    private func loadRateHistory() async {
        let result = await PayInputsLoad.loadHistory(firebaseBackend)
        if let history = result.history { dayRateHistoryCollection = history }
        payInputsState = result.state
    }

    private func beginInvoiceGeneration() {
        guard let user = userStore.displayUser else { return }
        errorMessage = nil
        Task {
            invoiceTaxIds = await InvoicePDFGenerationSupport.taxIdsForExport(subject: user, requested: includeTaxIds, userStore: userStore)
            if InvoicePDFGenerationSupport.shouldWarnBlankUTR(requested: includeTaxIds, taxIds: invoiceTaxIds) {
                showInvoiceUTRWarning = true
            } else {
                await runInvoiceGeneration()
            }
        }
    }

    private func runInvoiceGeneration() async {
        guard !isGenerating else { return }
        guard let period = selectedPeriod else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        if payInputsState != .loaded {
            await loadRateHistory()
        }
        if let blocked = payInputsBlockMessage {
            errorMessage = blocked
            return
        }
        // RULEBOOK 1.43.0 §8 `timesheetSnapshotReady`: the invoice waits for the period's bookings.
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
            from: period.startDate, retryFailed: true
        )
        if let blocked = PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: PayInputsLoad.periodBookings(
                firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
                from: period.startDate
            )
        ) {
            errorMessage = blocked
            return
        }

        let pdfURL = await InvoicePDFGenerationSupport.generatePDF(
            period: period,
            settings: settings,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection,
            taxIds: invoiceTaxIds
        )

        if let pdfURL {
            generatedPDFURL = pdfURL
            showInvoiceSuccess = true
        } else {
            errorMessage = "Failed to generate the invoice PDF."
        }
    }

    private func generateInvoicePDF() async {
        await runInvoiceGeneration()
    }

    private func invoiceLineItems(for period: InvoicePeriodOption) -> [InvoiceLineItem] {
        guard let currentUser = userStore.displayUser else { return [] }
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let summary = TimesheetPayrollCollector.collect(
            for: currentUser,
            in: period.startDate...period.endDate,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            policy: policy,
            organization: firebaseBackend.currentOrganization,
            scheduleOptions: scheduleOptions,
            relatedUsers: userStore.organizationUsers
        )
        let draft = TimesheetDraftStore.load(
            userId: currentUser.id,
            weekStart: OrganizationRulebookContext.calendar.startOfDay(for: period.startDate)
        )
        // RULEBOOK 1.10.0 §8 `timesheetInvoiceRows` (`raw`, as web's owner invoice): the signed snapshot first, else
        // the live lines; PAYE and leave lines never go on an invoice.
        let rows = TimesheetInvoiceRows.rows(for: currentUser, summary: summary, draft: draft, period: period.startDate...period.endDate)
        return InvoiceLineItem.invoiceLines(rows).sorted {
            if $0.date == $1.date {
                return $0.projectName < $1.projectName
            }
            return $0.date < $1.date
        }
    }

    private func rateChangeNotes(for period: InvoicePeriodOption) -> [String] {
        guard let currentUser = userStore.displayUser else { return [] }
        let cal = OrganizationRulebookContext.calendar  // pay periods are organisation-zone days
        var notes: [String] = []

        let userHistory = (dayRateHistoryCollection.byUserId[currentUser.id] ?? [])
            .filter {
                let day = cal.startOfDay(for: $0.effectiveAt)
                return day >= period.startDate && day <= period.endDate
            }
            .sorted(by: { $0.effectiveAt < $1.effectiveAt })

        for entry in userHistory {
            notes.append(entry.dayRate.map { "Rate updated to \(formatCurrency($0)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted))." }
                ?? "Rate not set from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
        }

        let matchedOperatives = operativeStore.allOperatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == currentUser.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for operative in matchedOperatives {
            let entries = (dayRateHistoryCollection.byOperativeId[operative.id.uuidString] ?? [])
                .filter {
                    let day = cal.startOfDay(for: $0.effectiveAt)
                    return day >= period.startDate && day <= period.endDate
                }
                .sorted(by: { $0.effectiveAt < $1.effectiveAt })
            for entry in entries {
                notes.append(entry.dayRate.map { "Operative rate updated to \(formatCurrency($0)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted))." }
                ?? "Operative rate not set from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
            }
        }

        return Array(Set(notes)).sorted()
    }

    private func calendarDayStart(_ date: Date, in calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    private func projectLabel(for id: UUID) -> (jobNumber: String, siteName: String) {
        if let project = projectStore.projects.first(where: { $0.id == id }) {
            return (project.jobNumber, project.siteName)
        }
        if let project = projectStore.smallWorks.first(where: { $0.id == id }) {
            return (project.jobNumber, project.siteName)
        }
        return ("—", "Unknown Project")
    }

    private func historicalDateRangePeriods(limit: Int) -> [InvoicePeriodOption] {
        let cal = OrganizationRulebookContext.calendar  // pay periods are organisation-zone days
        let today = cal.startOfDay(for: Date())
        let monthStartToday = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        var periods: [InvoicePeriodOption] = []

        for monthOffset in 0..<max(3, limit) {
            guard let monthDate = cal.date(byAdding: .month, value: -monthOffset, to: monthStartToday) else { continue }
            let monthLabel = monthDate.formatted(.dateTime.month(.abbreviated).year())
            for range in settings.normalizedRanges {
                guard let option = makePeriodOption(for: range, monthDate: monthDate, monthLabel: monthLabel) else { continue }
                if option.endDate <= today {
                    periods.append(option)
                }
            }
            if periods.count >= limit { break }
        }

        return periods.sorted(by: { $0.endDate > $1.endDate })
    }

    private func makePeriodOption(for range: PaymentRunDateRange, monthDate: Date, monthLabel: String) -> InvoicePeriodOption? {
        let cal = OrganizationRulebookContext.calendar  // pay periods are organisation-zone days
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: monthDate)),
              let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count else {
            return nil
        }
        let startDay = min(max(range.startDay, 1), daysInMonth)
        guard let startDate = cal.date(byAdding: .day, value: startDay - 1, to: monthStart) else { return nil }

        let endDate: Date
        if range.startDay <= range.endDay {
            let clampedEnd = min(max(range.endDay, 1), daysInMonth)
            endDate = cal.date(byAdding: .day, value: clampedEnd - 1, to: monthStart) ?? startDate
        } else {
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
                  let daysInNextMonth = cal.range(of: .day, in: .month, for: nextMonth)?.count else {
                return nil
            }
            let clampedEnd = min(max(range.endDay, 1), daysInNextMonth)
            endDate = cal.date(byAdding: .day, value: clampedEnd - 1, to: nextMonth) ?? startDate
        }

        let title = "\(monthLabel): \(range.startDay)-\(range.endDay)"
        let rangeLabel = "\(startDate.formatted(date: .abbreviated, time: .omitted)) to \(endDate.formatted(date: .abbreviated, time: .omitted))"
        return InvoicePeriodOption(
            id: "\(range.id.uuidString)-\(Int(startDate.timeIntervalSince1970))",
            title: title,
            dateRangeText: rangeLabel,
            startDate: cal.startOfDay(for: startDate),
            endDate: cal.startOfDay(for: endDate)
        )
    }

    private func recurringInvoicePeriod() -> InvoicePeriodOption? {
        let period = TimesheetPayrollPolicy.timesheetWeekRange(for: settings)
        let label = "Previous recurring arrears period"
        return InvoicePeriodOption(
            id: "recurring-\(Int(period.start.timeIntervalSince1970))",
            title: label,
            dateRangeText: "\(period.start.formatted(date: .abbreviated, time: .omitted)) to \(period.end.formatted(date: .abbreviated, time: .omitted))",
            startDate: period.start,
            endDate: period.end
        )
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    private func formatMultiplier(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.001 {
            return "x\(Int(value.rounded()))"
        }
        return String(format: "x%.1f", value)
    }

    private func formatCurrency(_ value: Double) -> String {
        OrgMoney.format(value)
    }
}

private struct InvoicePeriodOption: Identifiable, Hashable {
    let id: String
    let title: String
    let dateRangeText: String
    let startDate: Date
    let endDate: Date
}

/// Approved annual leave on a timesheet (`timesheetLeaveLines`): no hours, no pay, no edit control,
/// never on an invoice. Shown to the person and to their line manager.
private struct TimesheetLeaveInfoRows: View {
    let lines: [CanonicalTimesheetLeaveLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.dayText(line.dayKey))
                            .font(.subheadline.weight(.bold))
                        Text(line.displayLabel)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.blue)
                    }
                    Spacer()
                    Text("No hours or pay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.06))
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("timesheets.leaveRows")
    }

    private static func dayText(_ dayKey: String) -> String {
        guard let date = OrganizationRulebookContext.date(fromDayKey: dayKey) else { return dayKey }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: OrganizationRulebookContext.timeZone))
    }
}

/// RULEBOOK 1.44.0 §8 (web `signedLabourSlice`): how a signed labour line reads — the pay basis stored on the line
/// (else the live line's, else day) and the rate that gives its signed amount: day rate = amount ÷ stored days;
/// hourly = amount ÷ stored hours (0 when none). A signed line is never re-priced at today's rate or paid day.
/// Display only. Known gap: a day line with no stored days uses 0, where web divides its hours by today's paid day.
enum TimesheetSignedLineRate {
    static func storedBasis(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        return raw == "hourly" ? "hourly" : "day"
    }

    static func rate(
        storedBasis: String?,
        liveBasis: PayrollRateBasis?,
        paidHours: Double,
        days: Double,
        amount: Double
    ) -> (basis: PayrollRateBasis, rate: Double) {
        let basis: PayrollRateBasis = storedBasis.map { $0 == "hourly" ? .hourly : .dayRate } ?? liveBasis ?? .dayRate
        switch basis {
        case .hourly:
            return (basis, paidHours > 0.0001 ? amount / paidHours : 0)
        case .dayRate:
            return (basis, days > 0.0001 ? amount / days : 0)
        }
    }
}

/// The rows one person's timesheet puts on an invoice, before `invoiceLines` and sorting. Shared by the
/// owner's "Generate invoice" and the signed-sheet export so both read the same sheet the same way:
/// a signed `weeklyReportOverride` wins when present (declined and zero lines left out); otherwise live
/// payroll lines with their `payrollLineReviews` applied, then price work and expenses at the decision in
/// effect (`timesheetEntryDecision`, already resolved by `parseTimesheetEntries` when the sheet is read)
/// through `timesheetEntryEffectiveAmount` (declined left out, revised amount used).
/// RULEBOOK 1.10.0 §8: the rows of a generated invoice are `timesheetInvoiceRows({ sheet, payrollLines, extrasMode })`
/// — the signed snapshot (`weeklyReportOverride`) first, else the live lines (`invoiceLines`), with reviews
/// (`payrollLineReview`) and entry decisions (`timesheetEntryDecision`) in `decided` mode. This only maps the
/// script's rows back onto the line items the PDF prints; nothing is decided here. PAYE price work and expenses follow
/// the function (kept today; owner decision pending).
private enum TimesheetInvoiceRows {
    enum ExtrasMode: String {
        /// The owner's invoice before review (web `TimesheetPeriodPage`).
        case raw
        /// An export, or after the line manager signed.
        case decided
    }

    /// `timesheetInvoiceRows({ sheet, payrollLines, extrasMode, timeZone, timesheetDays })`; nil when the script did
    /// not answer.
    private static func scriptRows(
        for user: AppUser,
        summary: TimesheetPayrollSummary,
        draft: TimesheetDraft,
        extrasMode: ExtrasMode,
        period: ClosedRange<Date>
    ) -> [[String: Any]]? {
        let sheet = FirebaseBackend.firestoreJSON(TimesheetDraftStore.asFirestoreMap(draft))
        let lines: [[String: Any]] = summary.lineItems.map(\.rulebookTotalsJSON)
        var input: [String: Any] = [
            "sheet": sheet, "payrollLines": lines, "extrasMode": extrasMode.rawValue,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        // RULEBOOK 1.45.0 §8: the loaded copy's stored-row fingerprints, handed over explicitly (`entryFingerprints`).
        let fingerprints = TimesheetDraftStore.entryFingerprints(draft)
        if !fingerprints.isEmpty { input["entryFingerprints"] = fingerprints }
        // RULEBOOK 1.11.0 / 1.22.0 §8: `timesheetDays` (`CanonicalBusinessEngine.timesheetDaysForPerson`) leaves out
        // labour, price work and expenses dated on a PAYE day, as web does (`timesheetDayKeysForPeriod`).
        if let days = TimesheetTotalsSource.timesheetDays(for: user, period: period) { input["timesheetDays"] = days }
        return CanonicalBusinessEngine.callJSON("timesheetInvoiceRows", arguments: [input]) as? [[String: Any]]
    }

    /// RULEBOOK 1.45.0 §8 `timesheetEvidencePages({ rows, entries, currency })`: one page per piece of evidence on the
    /// invoice's price work and expense rows (the same `timesheetInvoiceRows`, so a declined entry has none), the entries
    /// read with `parseTimesheetEntries` (the sheet owner's own claim files only). Empty when there is none.
    static func evidencePages(
        for user: AppUser,
        summary: TimesheetPayrollSummary,
        draft: TimesheetDraft,
        extrasMode: ExtrasMode = .raw,
        period: ClosedRange<Date>
    ) -> [PayeClaimEvidencePage] {
        let hasEvidence = draft.expenseEntries.contains { !$0.evidence.isEmpty }
            || draft.priceWorkEntries.contains { !$0.evidence.isEmpty }
        guard hasEvidence,
              let result = scriptRows(for: user, summary: summary, draft: draft, extrasMode: extrasMode, period: period) else { return [] }
        let rows: [[String: Any]] = result.compactMap { row in
            guard let kind = row["kind"] as? String, kind == "priceWork" || kind == "expense",
                  let id = row["id"] as? String else { return nil }
            var out: [String: Any] = ["kind": kind, "id": id, "amount": (row["amount"] as? NSNumber)?.doubleValue ?? 0]
            if let jobNumber = row["jobNumber"] as? String { out["jobNumber"] = jobNumber }
            return out
        }
        guard !rows.isEmpty else { return [] }
        var sheet = TimesheetDraftStore.asFirestoreMap(draft)
        sheet["userId"] = user.id
        guard let entries = CanonicalBusinessEngine.parseTimesheetEntries(
            sheetDocumentId: "",
            sheet: sheet,
            // The rulebook person-id set (`personIdSet`), as the sheet reader uses.
            ownerUserIds: Array(Set(RulebookRosterSnapshot.personIds(forUserId: user.id) + [user.id] + user.formerUserIds + user.sameEmailUserIds))
        ) else { return [] }
        return CanonicalBusinessEngine.timesheetEvidencePages(
            rows: rows,
            entries: entries.raw,
            currency: OrganizationRulebookContext.currencyCode
        )
    }

    static func rows(
        for user: AppUser,
        summary: TimesheetPayrollSummary,
        draft: TimesheetDraft,
        extrasMode: ExtrasMode = .raw,
        period: ClosedRange<Date>
    ) -> [InvoiceLineItem] {
        guard let result = scriptRows(for: user, summary: summary, draft: draft, extrasMode: extrasMode, period: period) else {
            // The script did not answer: nothing unchecked is invoiced.
            return []
        }
        func key(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let liveById = Dictionary(summary.lineItems.map { (key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let override = draft.weeklyReportOverride
        let overrideLines = Dictionary((override?.lines ?? []).map { (key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let overridePriceWork = Dictionary((override?.priceWork ?? []).map { (key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let overrideExpenses = Dictionary((override?.expenses ?? []).map { (key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        func entryKey(_ storedId: String?, _ id: UUID) -> String { key(storedId ?? WorkDocumentKeys.storedId(for: id)) }
        let priceWork = Dictionary(draft.priceWorkEntries.map { (entryKey($0.storedId, $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let expenses = Dictionary(draft.expenseEntries.map { (entryKey($0.storedId, $0.id), $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [InvoiceLineItem] = []
        for row in result {
            let id = row["id"] as? String ?? ""
            let amount = (row["amount"] as? NSNumber)?.doubleValue ?? 0
            let fromOverride = (row["source"] as? String) == "override"
            switch row["kind"] as? String {
            case "labour":
                // RULEBOOK 1.43.0 (review r318): a row the script took from the signed snapshot is shown as stored in it
                // (Export and the Exported tab's Download PDF), never re-read from the live line; the snapshot stores no
                // rate, so the rate label still comes from the live line when there is one.
                if fromOverride, let line = overrideLines[key(id)] {
                    let live = liveById[key(id)]
                    // RULEBOOK 1.44.0 §8: a signed line is never re-priced, and neither is how it reads: the basis stored
                    // on the signed line, and the rate that gives its signed amount (`TimesheetSignedLineRate`).
                    let signed = TimesheetSignedLineRate.rate(
                        storedBasis: line.payBasis,
                        liveBasis: live?.payrollBasis,
                        paidHours: line.paidHours,
                        days: line.days,
                        amount: amount
                    )
                    var item = InvoiceLineItem(
                        lineId: line.id, date: line.date, jobNumber: line.jobNumber, projectName: line.projectName,
                        details: line.details, paidHours: line.paidHours, payrollBasis: signed.basis,
                        dayRate: signed.basis == .dayRate ? signed.rate : 0,
                        hourlyRate: signed.basis == .hourly ? signed.rate : nil,
                        amount: amount,
                        isPayeDay: false, isOvertimeLine: line.isOvertime
                    )
                    item.isOverlapping = live?.isOverlapping ?? false
                    item.bookingId = line.bookingId ?? live?.bookingId
                    rows.append(item)
                } else if let live = liveById[key(id)] {
                    var item = InvoiceLineItem(
                        lineId: live.id, date: live.date, jobNumber: live.jobNumber, projectName: live.projectName,
                        details: live.details, paidHours: live.paidHours, payrollBasis: live.payrollBasis,
                        dayRate: live.dayRate, hourlyRate: live.hourlyRate, amount: amount,
                        isPayeDay: live.isPayeDay, isOvertimeLine: live.isOvertimeLine
                    )
                    item.isOverlapping = live.isOverlapping
                    item.bookingId = live.bookingId
                    rows.append(item)
                }
            case "priceWork":
                if fromOverride, let line = overridePriceWork[key(id)] {
                    rows.append(moneyRow(prefix: "pw", id: line.id, date: line.date, jobNumber: line.jobNumber, projectName: "Price work", details: line.title, amount: amount))
                } else if let entry = priceWork[key(id)] {
                    rows.append(moneyRow(prefix: "pw", id: entry.id.uuidString, date: entry.startDate, jobNumber: CanonicalBusinessEngine.priceWorkJobNumberText(entry.jobNumber), projectName: "Price work", details: entry.title, amount: amount))
                }
            case "expense":
                if fromOverride, let line = overrideExpenses[key(id)] {
                    rows.append(moneyRow(prefix: "exp", id: line.id, date: line.date, jobNumber: line.jobNumber.isEmpty ? "—" : line.jobNumber, projectName: "Expense", details: line.title, amount: amount))
                } else if let entry = expenses[key(id)] {
                    rows.append(moneyRow(prefix: "exp", id: entry.id.uuidString, date: entry.date, jobNumber: entry.jobNumber.isEmpty ? "—" : entry.jobNumber, projectName: "Expense", details: entry.title, amount: amount))
                }
            default:
                continue
            }
        }
        return rows
    }

    /// A price work or expense row (no hours). Not a PAYE day: `timesheetInvoiceRows` already decided it goes on.
    private static func moneyRow(prefix: String, id: String, date: Date, jobNumber: String, projectName: String, details: String, amount: Double) -> InvoiceLineItem {
        InvoiceLineItem(
            lineId: "\(prefix)-\(id)", date: date, jobNumber: jobNumber, projectName: projectName, details: details,
            paidHours: 0, payrollBasis: .dayRate, dayRate: 0, hourlyRate: nil, amount: amount,
            isPayeDay: false
        )
    }
}

private struct InvoiceLineItem {
    /// `invoiceLines`: the rows a generated invoice carries (never PAYE or leave lines), in input order.
    /// Empty when the script did not answer, so nothing unchecked is invoiced.
    static func invoiceLines(_ rows: [InvoiceLineItem]) -> [InvoiceLineItem] {
        guard let kept = CanonicalBusinessEngine.invoiceLineIndexes(
            rows.map { (isPayeDay: $0.isPayeDay, isLeave: false) }
        ) else { return [] }
        return kept.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    let lineId: String
    let date: Date
    let jobNumber: String
    let projectName: String
    let details: String
    let paidHours: Double
    let payrollBasis: PayrollRateBasis
    let dayRate: Double
    let hourlyRate: Double?
    let amount: Double
    let isPayeDay: Bool
    let isOvertimeLine: Bool
    /// `overlappingBookingIds`: shown amber with `OVERLAPPING_BOOKING_NOTE`; still paid.
    var isOverlapping: Bool = false
    var bookingId: String? = nil

    init(
        lineId: String,
        date: Date,
        jobNumber: String,
        projectName: String,
        details: String,
        paidHours: Double,
        payrollBasis: PayrollRateBasis,
        dayRate: Double,
        hourlyRate: Double?,
        amount: Double,
        isPayeDay: Bool = false,
        isOvertimeLine: Bool = false
    ) {
        self.lineId = lineId
        self.date = date
        self.jobNumber = jobNumber
        self.projectName = projectName
        self.details = details
        self.paidHours = paidHours
        self.payrollBasis = payrollBasis
        self.dayRate = dayRate
        self.hourlyRate = hourlyRate
        self.amount = amount
        self.isPayeDay = isPayeDay
        self.isOvertimeLine = isOvertimeLine
    }

    var payrollLine: TimesheetPayrollLineItem {
        TimesheetPayrollLineItem(
            id: lineId,
            date: date,
            jobNumber: jobNumber,
            projectName: projectName,
            details: details,
            paidHours: paidHours,
            payrollBasis: payrollBasis,
            dayRate: dayRate,
            hourlyRate: hourlyRate,
            amount: amount,
            isPayeDay: isPayeDay,
            isOvertimeLine: isOvertimeLine,
            bookingId: bookingId,
            isOverlapping: isOverlapping
        )
    }

    var resolvedPayrollRate: ResolvedPayrollRate {
        ResolvedPayrollRate(basis: payrollBasis, dayRate: dayRate, hourlyRate: hourlyRate)
    }

    var hasPayrollRate: Bool {
        resolvedPayrollRate.hasRate
    }

    var timesheetRateAnnotation: String {
        if isPayeDay { return "PAYE" }
        if let label = resolvedPayrollRate.displayRateLabel() { return label }
        return "rate not set"
    }

    var shouldHighlightRateInOrange: Bool {
        isPayeDay || !hasPayrollRate
    }

    init(payrollLine: TimesheetPayrollLineItem) {
        self.init(
            lineId: payrollLine.id,
            date: payrollLine.date,
            jobNumber: payrollLine.jobNumber,
            projectName: payrollLine.projectName,
            details: payrollLine.details,
            paidHours: payrollLine.paidHours,
            payrollBasis: payrollLine.payrollBasis,
            dayRate: payrollLine.dayRate,
            hourlyRate: payrollLine.hourlyRate,
            amount: payrollLine.amount,
            isPayeDay: payrollLine.isPayeDay,
            isOvertimeLine: payrollLine.isOvertimeLine
        )
        self.isOverlapping = payrollLine.isOverlapping
        self.bookingId = payrollLine.bookingId
    }
}

private struct TimesheetSignaturePad: View {
    @Binding var imageData: Data?
    @State private var canvas = PKCanvasView()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Signature")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    canvas.drawing = PKDrawing()
                    imageData = nil
                }
                .accessibilityIdentifier("timesheetSignaturePad.clear")
                .font(.system(size: 12, weight: .semibold))
            }
            TimesheetCanvasRepresentable(canvas: $canvas) { exportSignaturePNG() }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [5]))
                        .foregroundStyle(Color(.separator))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func exportSignaturePNG() {
        let bounds = canvas.drawing.bounds
        guard !bounds.isEmpty else {
            imageData = nil
            return
        }
        imageData = canvas.drawing.image(from: bounds, scale: UIScreen.main.scale).pngData()
    }
}

private struct TimesheetCanvasRepresentable: UIViewRepresentable {
    @Binding var canvas: PKCanvasView
    let onChange: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1), width: 3)
        canvas.delegate = context.coordinator
        canvas.backgroundColor = UIColor(red: 0.98, green: 0.985, blue: 0.992, alpha: 1)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange()
        }
    }
}

private struct InvoicingShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum InvoicePDFBuilder {
    struct Context {
        let organizationName: String
        let userName: String
        let vatNumber: String?
        let utrNumber: String?
        let generatedAt: Date
        let periodTitle: String
        let periodDateRange: String
        let lineItems: [InvoiceLineItem]
        let totalAmount: Double
        let rateChangeNotes: [String]
        /// "Invoice" or "Timesheet"
        var documentTitle: String = "Invoice"
        /// Optional override for the on-disk PDF filename.
        var preferredFileName: String? = nil
        var periodMetaLabel: String = "INVOICE PERIOD"
        var totalLabel: String = "Total invoice amount"
        var emptyStateMessage: String = "No work entries were found for this invoice period."
    }

    static func makePDF(context: Context) -> URL? {
        let defaultName = "\(context.documentTitle)-\(context.userName.replacingOccurrences(of: " ", with: "_"))-\(Int(Date().timeIntervalSince1970)).pdf"
        let fileName = sanitizeFileName(context.preferredFileName ?? defaultName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let margin: CGFloat = 28
        let contentWidth = pageRect.width - (margin * 2)
        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()
                var y: CGFloat = margin

                y = drawTitleBlock(context: context, at: CGPoint(x: margin, y: y), width: contentWidth)
                y += 14
                y = drawLineItems(context: context, pdf: pdf, startY: y, margin: margin, contentWidth: contentWidth, pageRect: pageRect)
                y += 12
                y = drawTotal(context: context, at: CGPoint(x: margin, y: y), width: contentWidth)

                if !context.rateChangeNotes.isEmpty {
                    y += 14
                    _ = drawRateNotes(context: context, pdf: pdf, startY: y, margin: margin, contentWidth: contentWidth, pageRect: pageRect)
                }
            }
            return url
        } catch {
            return nil
        }
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Timesheet.pdf" : cleaned
    }

    private static func drawTitleBlock(context: Context, at origin: CGPoint, width: CGFloat) -> CGFloat {
        let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
        let cyan = UIColor(red: 0.169, green: 0.733, blue: 0.937, alpha: 1)

        (context.documentTitle as NSString).draw(at: origin, withAttributes: [
            .font: UIFont.systemFont(ofSize: 31, weight: .bold),
            .foregroundColor: navy
        ])

        ("Project Planner" as NSString).draw(
            at: CGPoint(x: origin.x, y: origin.y + 36),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: cyan
            ]
        )

        let lineY = origin.y + 56
        UIBezierPath(rect: CGRect(x: origin.x, y: lineY, width: width, height: 1.6)).fill(with: .normal, alpha: 1)

        let metaTop = lineY + 12
        let colWidth = (width - 14) / 2
        let leftX = origin.x
        let rightX = origin.x + colWidth + 14

        func drawMeta(label: String, value: String, x: CGFloat, y: CGFloat) {
            (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: UIColor.gray
            ])
            (value as NSString).draw(
                in: CGRect(x: x, y: y + 12, width: colWidth, height: 30),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: navy
                ]
            )
        }

        drawMeta(label: "COMPANY", value: context.organizationName, x: leftX, y: metaTop)
        drawMeta(label: "NAME", value: context.userName, x: rightX, y: metaTop)
        drawMeta(label: "GENERATED", value: context.generatedAt.formatted(date: .abbreviated, time: .shortened), x: leftX, y: metaTop + 40)
        drawMeta(label: context.periodMetaLabel, value: context.periodDateRange, x: rightX, y: metaTop + 40)

        var nextRowY = metaTop + 80
        if let vat = context.vatNumber {
            drawMeta(label: "VAT NUMBER", value: vat, x: leftX, y: nextRowY)
        }
        if let utr = context.utrNumber {
            drawMeta(label: "UTR NUMBER", value: utr, x: rightX, y: nextRowY)
        }
        if context.vatNumber != nil || context.utrNumber != nil {
            nextRowY += 40
        }

        return nextRowY + 2
    }

    private static func drawLineItems(
        context: Context,
        pdf: UIGraphicsPDFRendererContext,
        startY: CGFloat,
        margin: CGFloat,
        contentWidth: CGFloat,
        pageRect: CGRect
    ) -> CGFloat {
        var y = startY
        let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
        let slate = UIColor(red: 0.36, green: 0.42, blue: 0.5, alpha: 1)

        let headerRect = CGRect(x: margin, y: y, width: contentWidth, height: 24)
        UIBezierPath(roundedRect: headerRect, cornerRadius: 0).fill(with: .normal, alpha: 1)
        navy.setFill()
        UIRectFill(headerRect)
        ("Date / Project" as NSString).draw(
            at: CGPoint(x: margin + 10, y: y + 7),
            withAttributes: [.font: UIFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: UIColor.white]
        )
        ("Details" as NSString).draw(
            at: CGPoint(x: margin + 156, y: y + 7),
            withAttributes: [.font: UIFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: UIColor.white]
        )
        ("Amount" as NSString).draw(
            at: CGPoint(x: margin + contentWidth - 54, y: y + 7),
            withAttributes: [.font: UIFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: UIColor.white]
        )
        y += 24

        if context.lineItems.isEmpty {
            (context.emptyStateMessage as NSString).draw(
                in: CGRect(x: margin, y: y, width: contentWidth, height: 30),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.darkGray
                ]
            )
            y += 24
            return y
        }

        for item in context.lineItems {
            if y > pageRect.height - 110 {
                pdf.beginPage()
                y = margin
            }
            UIColor(white: 0.93, alpha: 1).setFill()
            UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 0.8))

            let leftX = margin + 10
            let middleX = margin + 84
            let amountX = margin + contentWidth - 64

            (item.date.formatted(date: .abbreviated, time: .omitted) as NSString).draw(
                at: CGPoint(x: leftX, y: y + 8),
                withAttributes: [.font: UIFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: navy]
            )
            (item.jobNumber as NSString).draw(
                at: CGPoint(x: leftX, y: y + 22),
                withAttributes: [.font: UIFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: slate]
            )

            (item.projectName as NSString).draw(
                in: CGRect(x: middleX, y: y + 7, width: 190, height: 18),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: navy]
            )
            // RULEBOOK 1.43.0 §8: the clock part of the details (`timesheetLineClockText`), then the hours
            // (`payLineHoursText`: an overtime line with a break reads "6.5h × 2 − 0.5h break = 12.5h") — never both.
            let clockPart = TimesheetPayrollCollector.lineClockLabel(item.details) ?? ""
            let hoursPart = CanonicalBusinessEngine.payLineHoursText(details: item.details, paidHours: item.paidHours, isOvertimeLine: item.isOvertimeLine)
            let detail = [clockPart, hoursPart, item.timesheetRateAnnotation].filter { !$0.isEmpty }.joined(separator: " · ")
            (detail as NSString).draw(
                in: CGRect(x: middleX, y: y + 22, width: 190, height: 28),
                withAttributes: [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: slate]
            )

            (currency(item.amount) as NSString).draw(
                in: CGRect(x: amountX, y: y + 16, width: 56, height: 18),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11.5, weight: .bold), .foregroundColor: navy]
            )
            y += 50
        }
        return y
    }

    private static func drawTotal(context: Context, at origin: CGPoint, width: CGFloat) -> CGFloat {
        let boxRect = CGRect(x: origin.x, y: origin.y, width: width, height: 46)
        let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(red: 0.071, green: 0.149, blue: 0.243, alpha: 1).cgColor,
                UIColor(red: 0.039, green: 0.083, blue: 0.153, alpha: 1).cgColor
            ] as CFArray,
            locations: [0, 1]
        )
        if let ctx = UIGraphicsGetCurrentContext(), let grad {
            ctx.saveGState()
            let path = UIBezierPath(roundedRect: boxRect, cornerRadius: 12)
            path.addClip()
            ctx.drawLinearGradient(grad, start: CGPoint(x: boxRect.minX, y: boxRect.midY), end: CGPoint(x: boxRect.maxX, y: boxRect.midY), options: [])
            ctx.restoreGState()
        }
        (context.totalLabel as NSString).draw(
            at: CGPoint(x: boxRect.minX + 14, y: boxRect.minY + 16),
            withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor(red: 0.62, green: 0.72, blue: 0.82, alpha: 1)]
        )
        (currency(context.totalAmount) as NSString).draw(
            at: CGPoint(x: boxRect.maxX - 108, y: boxRect.minY + 11),
            withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.white]
        )
        return boxRect.maxY
    }

    private static func drawRateNotes(
        context: Context,
        pdf: UIGraphicsPDFRendererContext,
        startY: CGFloat,
        margin: CGFloat,
        contentWidth: CGFloat,
        pageRect: CGRect
    ) -> CGFloat {
        var y = startY
        ("Rate change notes" as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 20), withAttributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.black
        ])
        y += 20
        for note in context.rateChangeNotes {
            if y > pageRect.height - 70 {
                pdf.beginPage()
                y = margin
            }
            let line = "• \(note)"
            (line as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 30), withAttributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.darkGray
            ])
            y += 20
        }
        return y
    }

    private static func currency(_ value: Double) -> String {
        OrgMoney.format(value)
    }

    private static func hoursString(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}

private enum TimesheetExportHelper {
    /// RULEBOOK 1.43.0 (review r318): what the delivery of the stamped sheets did — the per-person PDFs that were built
    /// (and so sent), the people whose PDF could not be built (with the reason), backups skipped, and an email problem.
    struct Delivery {
        var sentCount = 0
        var notSent: [String] = []
        var backupSkipped: [String] = []
        var emailProblem: String?
    }

    struct PDFAttachment {
        let fileName: String
        let data: Data
    }

    /// Why a sheet's PDF could not be built (its text is shown, as web shows the error message).
    struct PDFBuildError: LocalizedError {
        let message: String
        /// True when `message` is a whole sentence for the person (shown as it is, not wrapped in "Couldn't build…").
        var isPlain: Bool = false
        var errorDescription: String? { message }
    }

    /// Review #231: the PDF was drawn but its file could not be read back.
    static let pdfReadBackFailedMessage = "Couldn't open the PDF file — try again."

    /// The message for a PDF that could not be built for `name`: a plain sentence as it is, else the reason in brackets.
    static func pdfFailureMessage(name: String, error: Error) -> String {
        if let build = error as? PDFBuildError, build.isPlain { return build.message }
        return "Couldn't build the PDF for \(name) (\(error.localizedDescription))."
    }

    /// One sheet's PDF from the copy that was saved (its stored snapshot) — the same builder for Export and for the
    /// Exported tab's Download. Throws with the reason when it could not be built.
    static func makeSheetPDF(
        operative: AppUser,
        week: WeekRange,
        draft: TimesheetDraft,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        dayRateHistory: OperativeDayRateHistoryCollection,
        payrollPolicy: OrgPayrollTimePolicy,
        organization: Organization?,
        organizationName: String,
        scheduleOptions: MyScheduleOptions = MyScheduleOptions(),
        organizationUsers: [AppUser] = [],
        taxIds: CanonicalBusinessEngine.CanonicalSensitiveProfile? = nil,
        rebuiltNote: String? = nil
    ) throws -> PDFAttachment {
        let userName = operative.fullName.isEmpty ? operative.email : operative.fullName
        let paymentRunStamp = paymentRunDateStamp(for: week)
        let periodRangeText = "\(paymentRunStamp.replacingOccurrences(of: " ", with: " – "))"
        let rows = buildLineItems(
            for: operative,
            week: week,
            draft: draft,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            dayRateHistory: dayRateHistory,
            payrollPolicy: payrollPolicy,
            organization: organization,
            scheduleOptions: scheduleOptions,
            relatedUsers: organizationUsers
        )
        let grandTotal = rows.reduce(0) { $0 + $1.amount }
        let fileName = timesheetPDFFileName(userName: userName, paymentRunStamp: paymentRunStamp)
        var notes = signatureNotes(for: draft)
        if let rebuiltNote { notes.insert(rebuiltNote, at: 0) }
        guard let pdfURL = InvoicePDFBuilder.makePDF(
            context: InvoicePDFBuilder.Context(
                organizationName: organizationName,
                userName: userName,
                vatNumber: taxIds.flatMap { $0.vatNumber.isEmpty ? nil : $0.vatNumber },
                utrNumber: taxIds.flatMap { $0.utrNumber.isEmpty ? nil : $0.utrNumber },
                generatedAt: Date(),
                periodTitle: "Signed timesheet",
                periodDateRange: periodRangeText,
                lineItems: rows,
                totalAmount: grandTotal,
                rateChangeNotes: notes,
                documentTitle: "Timesheet",
                preferredFileName: fileName,
                periodMetaLabel: "PAYMENT RUN",
                totalLabel: "Total timesheet amount",
                emptyStateMessage: "No work entries were found for this timesheet period."
            )
        ) else {
            throw PDFBuildError(message: "the PDF could not be drawn")
        }
        guard let data = try? Data(contentsOf: pdfURL) else {
            // Review #231: a file that cannot be read back gets a short plain message, never the raw system error.
            throw PDFBuildError(message: pdfReadBackFailedMessage, isPlain: true)
        }
        return PDFAttachment(fileName: fileName, data: data)
    }

    /// RULEBOOK 1.43.0 (review r318, web `runTimesheetExport` deliver): every STAMPED sheet gets its PDF (from the copy
    /// that was saved) and storage backup, each person on their own — one failure never skips the rest — then one email
    /// with every PDF that was built.
    static func deliver(
        stamped: [(operative: AppUser, draft: TimesheetDraft)],
        week: WeekRange,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        dayRateHistory: OperativeDayRateHistoryCollection,
        payrollPolicy: OrgPayrollTimePolicy,
        organization: Organization?,
        organizationName: String,
        scheduleOptions: MyScheduleOptions = MyScheduleOptions(),
        organizationUsers: [AppUser] = [],
        recipientEmail: String,
        recipientName: String,
        firebaseBackend: FirebaseBackend? = nil,
        taxIdsByUserId: [String: CanonicalBusinessEngine.CanonicalSensitiveProfile] = [:]
    ) async -> Delivery {
        var delivery = Delivery()
        var attachments: [PDFAttachment] = []
        var downloadLinks: [(fileName: String, url: String)] = []
        let paymentRunStamp = paymentRunDateStamp(for: week)

        for row in stamped {
            let userName = row.operative.fullName.isEmpty ? row.operative.email : row.operative.fullName
            let attachment: PDFAttachment
            do {
                attachment = try makeSheetPDF(
                operative: row.operative,
                week: week,
                draft: row.draft,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                operativeStore: operativeStore,
                projectStore: projectStore,
                dayRateHistory: dayRateHistory,
                payrollPolicy: payrollPolicy,
                organization: organization,
                organizationName: organizationName,
                scheduleOptions: scheduleOptions,
                organizationUsers: organizationUsers,
                taxIds: taxIdsByUserId[row.operative.id]
                )
            } catch {
                let reason = (error as? PDFBuildError).map(\.message) ?? error.localizedDescription
                delivery.notSent.append("\(userName) (\(reason))")
                continue
            }
            attachments.append(attachment)
            if let firebaseBackend, let orgId = organization?.firestoreDocumentId {
                do {
                    let url = try await firebaseBackend.uploadTimesheetExportPDF(
                        attachment.data,
                        fileName: attachment.fileName,
                        organizationId: orgId
                    )
                    downloadLinks.append((attachment.fileName, url))
                } catch {
                    delivery.backupSkipped.append(userName)
                }
            }
        }
        delivery.sentCount = attachments.count

        guard !recipientEmail.isEmpty else {
            delivery.emailProblem = "no email address on your account"
            return delivery
        }
        guard !attachments.isEmpty else { return delivery }

        let html = managerExportEmailHTML(
            recipientName: recipientName,
            weekTitle: week.title,
            paymentRunStamp: paymentRunStamp,
            organizationName: organizationName,
            attachmentNames: attachments.map(\.fileName),
            downloadLinks: downloadLinks,
            timesheetCount: attachments.count
        )
        let resend = ResendEmailService()
        let payload = attachments.map { (fileName: $0.fileName, data: $0.data) }
        let emailSubject = ExportTextEscaping.sanitizeEmailSubject(
            "Signed timesheets for filing — \(paymentRunStamp) — \(organizationName)"
        )
        let emailFromName = ExportTextEscaping.sanitizeFromDisplayName(organizationName)
        var sent = await resend.sendTimesheetExportEmail(
            to: recipientEmail,
            subject: emailSubject,
            htmlContent: html,
            pdfAttachments: payload,
            fromName: emailFromName
        )
        if !sent {
            sent = await resend.sendTimesheetExportEmail(
                to: recipientEmail,
                subject: emailSubject,
                htmlContent: html,
                pdfAttachments: payload,
                fromName: emailFromName
            )
        }
        if !sent { delivery.emailProblem = resend.errorMessage ?? "email delivery failed" }
        return delivery
    }
    static func paymentRunDateStamp(for week: WeekRange) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yy"
        return "\(formatter.string(from: week.start)) \(formatter.string(from: week.end))"
    }

    private static func timesheetPDFFileName(userName: String, paymentRunStamp: String) -> String {
        "\(userName) timesheet for payment run date \(paymentRunStamp).pdf"
    }

    private static func signatureNotes(for draft: TimesheetDraft) -> [String] {
        var notes: [String] = []
        if let name = draft.operativeSignedByName, let at = draft.operativeSignedAt {
            notes.append("Operative signed by \(name) on \(at.formatted(date: .abbreviated, time: .shortened)).")
        }
        if let name = draft.managerSignedByName, let at = draft.managerSignedAt {
            notes.append("Line manager counter-signed by \(name) on \(at.formatted(date: .abbreviated, time: .shortened)).")
        }
        return notes
    }

    private static func buildLineItems(
        for user: AppUser,
        week: WeekRange,
        draft: TimesheetDraft,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        dayRateHistory: OperativeDayRateHistoryCollection,
        payrollPolicy: OrgPayrollTimePolicy,
        organization: Organization?,
        scheduleOptions: MyScheduleOptions = MyScheduleOptions(),
        relatedUsers: [AppUser] = []
    ) -> [InvoiceLineItem] {
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            week: week,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistory,
            policy: payrollPolicy,
            organization: organization,
            scheduleOptions: scheduleOptions,
            relatedUsers: relatedUsers
        )
        // RULEBOOK 1.10.0 §8: an export reads decisions (`extrasMode` `decided`).
        let rows = TimesheetInvoiceRows.rows(for: user, summary: summary, draft: draft, extrasMode: .decided, period: week.start...week.end)
        return rows.sorted {
            if $0.date == $1.date {
                return $0.projectName < $1.projectName
            }
            return $0.date < $1.date
        }
    }

    private static func managerExportEmailHTML(
        recipientName: String,
        weekTitle: String,
        paymentRunStamp: String,
        organizationName: String,
        attachmentNames: [String],
        downloadLinks: [(fileName: String, url: String)] = [],
        timesheetCount: Int
    ) -> String {
        let safeRecipient = ExportTextEscaping.escapeHTML(recipientName)
        let safeWeekTitle = ExportTextEscaping.escapeHTML(weekTitle)
        let safeStamp = ExportTextEscaping.escapeHTML(paymentRunStamp)
        let safeOrganization = ExportTextEscaping.escapeHTML(organizationName)
        let list: String
        if downloadLinks.isEmpty {
            list = attachmentNames.map { "<li>\(ExportTextEscaping.escapeHTML($0))</li>" }.joined()
        } else {
            list = downloadLinks.map { link in
                let href = ExportTextEscaping.escapeHTMLAttributeURL(link.url)
                let name = ExportTextEscaping.escapeHTML(link.fileName)
                return "<li><a href=\"\(href)\">\(name)</a></li>"
            }.joined()
        }
        let attachNote = downloadLinks.isEmpty
            ? "\(timesheetCount) signed-off timesheet PDF\(timesheetCount == 1 ? "" : "s") for payment run <strong>\(safeStamp)</strong> (\(safeWeekTitle)) from <strong>\(safeOrganization)</strong> \(timesheetCount == 1 ? "is" : "are") attached for your records."
            : "\(timesheetCount) signed-off timesheet PDF\(timesheetCount == 1 ? "" : "s") for payment run <strong>\(safeStamp)</strong> (\(safeWeekTitle)) from <strong>\(safeOrganization)</strong> \(timesheetCount == 1 ? "is" : "are") attached, with backup download links below."
        return """
        <html><body style="font-family:Arial,sans-serif;max-width:720px;margin:0 auto;padding:20px;">
        <h2 style="color:#0D67ED;">Signed timesheets for filing</h2>
        <p>Hello \(safeRecipient),</p>
        <p>\(attachNote)</p>
        <p>Each file is named: <em>User Name timesheet for payment run date \(safeStamp)</em>.</p>
        <ul>\(list)</ul>
        <p style="color:#666;font-size:13px;">These timesheets were counter-signed and exported from Operative Timesheets → Signed off.</p>
        </body></html>
        """
    }
}

