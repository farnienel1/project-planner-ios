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

    /// Shown while the person's own pay is not known yet (`UserStore.ownPayReady`): loading, or the read failed.
    @ViewBuilder
    private var ownPayWaitingCard: some View {
        if userStore.ownPayLoadFailed {
            ContentUnavailableView(
                "Pay details unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(PrivatePayOverlayReadiness.ownFailedMessage)
            )
        } else if userStore.isOffline {
            ContentUnavailableView(
                "Pay details unavailable",
                systemImage: "wifi.slash",
                description: Text(PrivatePayOverlayReadiness.ownOfflineMessage)
            )
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(PrivatePayOverlayReadiness.loadingMessage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .accessibilityIdentifier("timesheets.ownPayLoading")
        }
    }
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
                        if !userStore.ownPayReady && canShowOperativeTimesheets {
                            // A line manager whose own pay is still loading: their My Timesheets card is not decided yet.
                            ownPayWaitingCard
                        }
                        if !userStore.ownPayReady && !canShowOperativeTimesheets {
                            // RULEBOOK §8 (review of #240): whether this person has My Timesheets is decided from their
                            // own pay, which is not known yet — a loading state, never "Timesheets unavailable".
                            ownPayWaitingCard
                        } else if showTimesheetsDisabledMessage && !canShowMyTimesheets && !canShowOperativeTimesheets {
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
            // RULEBOOK 1.47.0 §8: the My Timesheets entry and the counts read each signed sheet's booking change.
            .attachesSignedTimesheetChanges()
            .onAppear {
                if let user = userStore.displayUser {
                    SignedTimesheetChangeContext.shared.ensureHubBookings(user: user, settings: settings)
                }
            }
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
        // RULEBOOK 1.47.0 §8: a yellow triangle when one of the person's signed sheets must be signed again.
        .overlay(alignment: .topTrailing) {
            if let message = ownSheetTriangleMessage {
                SignedTimesheetChangedTriangle(message: message)
                    .padding(8)
            }
        }
    }

    /// RULEBOOK 1.47.0 / 1.55.0 §8: the triangle's popup on the My Timesheets entry (signed sheet changed, or a revision
    /// due on an exported one), or nil when there is no triangle.
    private var ownSheetTriangleMessage: String? {
        let _ = landingVersion
        let _ = bookingStore.revision
        let _ = managerScheduleStore.revision
        guard let user = userStore.displayUser else { return nil }
        return SignedTimesheetChangeContext.shared.ownSheetTriangleMessage(user: user, settings: settings)
    }

    @ViewBuilder
    private var managerLandingCards: some View {
        let _ = landingVersion
        let reviewUsers = managerReviewUsersIncludingPending()
        let openWeek = pendingReviewWeek ?? WeekRange.current(settings: settings)
        let awaiting = landingAwaitingTimesheetCount(users: reviewUsers)
        let signed = reviewUsers.filter {
            let draft = TimesheetDraftStore.load(userId: $0.id, weekStart: openWeek.start)
            // RULEBOOK 1.47.0 §8: a sheet reopened by a booking change is not signed off (`timesheetListBucket` with it).
            return TimesheetApprovalPolicy.listBucket(draft: draft, user: $0, period: openWeek) == "signed"
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
                    // RULEBOOK 1.47.0 §8: the yellow triangle next to My Timesheets.
                    .overlay(alignment: .trailing) {
                        if let message = ownSheetTriangleMessage {
                            SignedTimesheetChangedTriangle(message: message)
                                .padding(.trailing, 30)
                        }
                    }
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

    static func awaitingManagerSignOff(draft: TimesheetDraft, user: AppUser, change: RulebookSignedTimesheetChange? = nil) -> Bool {
        TimesheetDraftStore.listBucket(for: draft, hasLineManager: requiresLineManagerCounterSign(for: user), change: change) == "awaiting"
    }

    /// RULEBOOK 1.47.0 §8: the sheet's list bucket with its booking change (`timesheetListBucket(fields, hasLineManager,
    /// change)`), the change read from `SignedTimesheetChangeContext` for the stored period.
    static func listBucket(draft: TimesheetDraft, user: AppUser, period: WeekRange) -> String? {
        let change = SignedTimesheetChangeContext.shared.change(draft: draft, user: user, period: period)
        return TimesheetDraftStore.listBucket(for: draft, hasLineManager: requiresLineManagerCounterSign(for: user), change: change)
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
            var period: WeekRange
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
                periodStart: period.start,
                period: period
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
            // RULEBOOK 1.47.0 §8: reopened + person → not awaiting; reopened + line manager → awaiting.
            let change = SignedTimesheetChangeContext.shared.change(draft: chosen, user: user, period: candidates[index].period)
            if awaitingManagerSignOff(draft: chosen, user: user, change: change) {
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
        // RULEBOOK 1.47.0 §8: the signed-bookings record goes with the signature.
        draft.operativeSignedBookings = nil
        draft.operativeSignedBookingsSignedAt = nil
        draft.operativeSignedBookingsAt = nil
        draft.operativeSignedBookingsAtPending = nil
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
        // `resolveTimesheetExportedAtMs` (inside `parseTimesheetStatusFields`) reads it beside `exportedAt`.
        put("invoiceGeneratedAt", draft.invoiceGeneratedAt)
        return row
    }

    static func statusFields(for draft: TimesheetDraft) -> CanonicalBusinessEngine.CanonicalTimesheetStatusFields? {
        parseTimesheetStatusFields(statusPayload(for: draft))
    }

    static func listBucket(for draft: TimesheetDraft, hasLineManager: Bool, change: RulebookSignedTimesheetChange? = nil) -> String? {
        guard let fields = statusFields(for: draft) else { return nil }
        return CanonicalBusinessEngine.timesheetListBucket(fields, hasLineManager: hasLineManager, change: change)
    }

    // MARK: RULEBOOK 1.55.0 §8 — timesheet revisions

    /// The version the draft was read from, as the script reads it (`timesheetVersionsForPeriod` of its document id and
    /// its stored sign-off fields) — the latest version of its pay run as this device holds it. A draft read before
    /// 1.55.0 (no `versionDocumentId`) is the original (`timesheetDocumentId`). [] when neither id is known.
    static func latestVersionChain(for draft: TimesheetDraft, userId: String, weekStart: Date) -> [TimesheetVersionInfo] {
        var documentId = draft.versionDocumentId ?? ""
        if documentId.isEmpty,
           let startKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(weekStart),
           let canonical = CanonicalBusinessEngine.timesheetDocumentId(userId: userId, startDayKey: startKey) {
            documentId = canonical
        }
        guard !documentId.isEmpty else { return [] }
        var data = statusPayload(for: draft)
        // The stored `exportedAt` as the rules test it decides "exported" (a copy read before 1.54.0 keeps its date).
        if draft.exportedAtStored == false { data.removeValue(forKey: "exportedAt") }
        if let snapshot = draft.weeklyReportOverride { data["weeklyReportOverride"] = ["approvedAt": snapshot.approvedAt.timeIntervalSince1970 * 1000] }
        return CanonicalBusinessEngine.timesheetVersionsForPeriod([(documentId, data)])?.first ?? []
    }

    /// RULEBOOK 1.55.0 §8 `timesheetRevisionDue({ chain, change })`: the draft is its pay run's latest version, exported,
    /// and `change` (`signedTimesheetBookingChanges` of it) reads `exported` and `changed`. `.notDue` otherwise.
    static func revisionDue(for draft: TimesheetDraft, userId: String, weekStart: Date, change: RulebookSignedTimesheetChange?) -> RulebookTimesheetRevisionDue {
        guard change?.exported == true, change?.changed == true else { return .notDue }
        let chain = latestVersionChain(for: draft, userId: userId, weekStart: weekStart)
        return CanonicalBusinessEngine.timesheetRevisionDue(chain: chain, change: change) ?? .notDue
    }

    /// "REV 1" for a revision, "" for the original (`timesheetRevisionLabel`).
    static func revisionLabel(for draft: TimesheetDraft) -> String {
        CanonicalBusinessEngine.timesheetRevisionLabel(draft.revision)
    }

    /// RULEBOOK 1.55.0 §8: the invoice number and revision note a document of this draft carries (`TimesheetRevisionCopy`).
    /// The invoice number comes from the ORIGINAL's stored id and stored `userId` (review of #344): the version's own
    /// id read back to its original.
    /// Review of #243 (L4): the original's id is never recomputed — a copy read without its document id gets no
    /// number (callers refresh from the cloud first, `ensureVersionRead`).
    static func revisionCopy(for draft: TimesheetDraft, subjectId _: String, weekStart _: Date, total: Double, currency: String) -> TimesheetRevisionCopy {
        let original = CanonicalBusinessEngine.parseTimesheetRevisionDocId(draft.versionDocumentId)?.baseDocumentId ?? ""
        return TimesheetRevisionCopy.make(
            originalDocumentId: original,
            storedUserId: draft.originalStoredUserId,
            revision: draft.revision,
            total: total,
            previousExportedTotal: draft.previousVersionExportedTotal,
            previousKnown: draft.previousVersionKnown == true,
            currency: currency
        )
    }

    /// Review of #243 (L4): a local copy read before 1.55.0 has no `versionDocumentId`, so its invoice number cannot be
    /// built without recomputing an id — read the sheet from the cloud first (which records the version it came from).
    /// The local copy is returned unchanged when the read fails.
    static func ensureVersionRead(
        _ draft: TimesheetDraft,
        userId: String,
        weekStart: Date,
        firebaseBackend: FirebaseBackend
    ) async -> TimesheetDraft {
        guard draft.versionDocumentId == nil,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return draft }
        return await refreshFromCloud(userId: userId, weekStart: weekStart, firebaseBackend: firebaseBackend, organizationId: orgId) ?? draft
    }

    /// RULEBOOK 1.55.0 §8: creates the next revision of the pay run whose latest version this device read
    /// (`firebaseBackend.createTimesheetRevision`), after `canCreateTimesheetRevision` allows it for this writer (the
    /// person when `writerIsSubject`, else a reviewer). The chain is read fresh first. Returns the new revision's id, or a
    /// message saying why nothing was created.
    static func createRevision(
        subject: AppUser,
        weekStart: Date,
        writer: AppUser,
        writerIsSubject: Bool,
        liveLines: [TimesheetPayrollLineItem],
        firebaseBackend: FirebaseBackend,
        organizationId: String
    ) async -> (documentId: String?, message: String?, revisionOpen: Bool) {
        let chain: [TimesheetVersionInfo]
        do {
            chain = try await firebaseBackend.loadTimesheetVersionChain(organizationId: organizationId, userId: subject.id, weekStart: weekStart)
        } catch {
            return (nil, "Couldn't create the revision: \(error.localizedDescription)", false)
        }
        // The `timesheetWriterIsReviewer` input; the subject's line managers are the rulebook's (`lineManagerIds`).
        let reviewerInput: [String: Any] = [
            "writerUserId": Auth.auth().currentUser?.uid ?? writer.id,
            "subjectUserId": subject.id,
            "writerIsAdmin": writer.isRosterAdmin,
            "writerFormerIds": writer.formerUserIds,
            "writerAliasIds": writer.sameEmailUserIds,
            "subjectLineManagerIds": RulebookRosterSnapshot.lineManagerIds(subject) ?? [],
            "roster": RulebookRosterSnapshot.roster,
        ]
        guard let check = CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: reviewerInput, chain: chain, writerIsSubject: writerIsSubject) else {
            return (nil, "Couldn't create the revision: the timesheet rules did not load. Try again.", false)
        }
        guard check.allowed, let latest = CanonicalBusinessEngine.timesheetLatestVersion(chain) else {
            // `revision-open`: a revision is already open (created elsewhere) — the screen opens it.
            return (nil, check.message.isEmpty ? CanonicalBusinessEngine.timesheetRevisionNotExportedMessage : check.message, check.reason == "revision-open")
        }
        do {
            let result = try await firebaseBackend.createTimesheetRevision(
                organizationId: organizationId,
                previousDocumentId: latest.documentId,
                writerIsSubject: writerIsSubject,
                liveLines: liveLines.map(\.rulebookTotalsJSON)
            )
            switch result.status {
            case "created": return (result.documentId, nil, false)
            case "exists": return (nil, CanonicalBusinessEngine.timesheetRevisionOpenMessage, true)
            default: return (nil, CanonicalBusinessEngine.timesheetRevisionNotExportedMessage, false)
            }
        } catch {
            return (nil, "Couldn't create the revision: \(error.localizedDescription)", false)
        }
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
        // Review of #243 (M-1): the fresh read is the latest version; save only when it is the version this draft was
        // read from, so the field diff below is against the draft's own version and nothing lands on a newer one.
        if let refusal = TimesheetVersionSaveGuard.refusal(
            draftVersionId: draft.versionDocumentId,
            serverVersionId: server?["__documentId"] as? String
        ) {
            return refusal
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
        /// RULEBOOK 1.55.0 §8: the person changed entries on a revision (refused, `TIMESHEET_REVISION_EXTRAS_MESSAGE`).
        var revisionEntriesRefused = false
        /// RULEBOOK 1.54.0 §8: why a change to the late extras was not saved (`timesheetOwnerCanAddLateExtras`).
        var lateExtrasRefusal: String?
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
            // RULEBOOK 1.55.0 §8 (review of #344): a revision carries the entries exactly as exported — the person never
            // changes price work, expenses or late extras on it (the rules refuse it); they go on the next timesheet.
            if (CanonicalBusinessEngine.parseTimesheetRevisionDocId(server?["__documentId"] as? String)?.revision ?? 0) > 0 {
                for key in ["expenseEntries", "priceWorkEntries", "lateExtras"] {
                    guard let value = fields[key] else { continue }
                    if !firestoreValuesEqual(value, server?[key]) { revisionEntriesRefused = true }
                    fields.removeValue(forKey: key)
                }
            }
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
            // RULEBOOK 1.54.0 §8: late extras (`lateExtras`) are written by the owner only once the line manager has
            // signed and until the stored `exportedAt` is set (`timesheetOwnerCanAddLateExtras`, read from the STORED
            // sheet — never this device's copy), and follow the ordinary entry rules by kind (`timesheetOwnerEntriesError`:
            // job number, evidence). The signed entries never change (above). No signature is ever cleared.
            let loadedLate = loadedCopy(userId: userId, weekStart: weekStart, organizationId: organizationId)
            let previousLate: [TimesheetLateExtra]? = loadedLate != nil ? loadedLate?.lateExtras : server.flatMap { decodeFirestoreMap($0) }?.lateExtras
            let baseLate: Any?
            if let loadedLate { baseLate = asFirestoreMap(loadedLate)["lateExtras"] } else { baseLate = server?["lateExtras"] }
            if let nextLate = fields["lateExtras"], !firestoreValuesEqual(nextLate, baseLate) {
                let latePermission = CanonicalBusinessEngine.timesheetOwnerCanAddLateExtras(
                    managerSignedAt: server.flatMap { statusFields(fromFirestore: $0)?.managerSignedAtMs }.map { Date(timeIntervalSince1970: $0 / 1000) },
                    approvedAt: firestoreDate(server?["approvedAt"]),
                    exportedAt: nil,
                    exportedAtStored: CanonicalBusinessEngine.timesheetExportedFieldSet(server?["exportedAt"]),
                    selfSigned: subject.map { !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0) } ?? false,
                    // RULEBOOK 1.55.0 §8: read from the stored version (a revision's entries are frozen for the person).
                    revision: CanonicalBusinessEngine.parseTimesheetRevisionDocId(server?["__documentId"] as? String)?.revision
                )
                if !latePermission.allowed {
                    fields.removeValue(forKey: "lateExtras")
                    lateExtrasRefusal = latePermission.message ?? CanonicalBusinessEngine.timesheetExportedExtrasMessage
                } else if let message = CanonicalBusinessEngine.timesheetOwnerEntriesError(
                    previous: TimesheetLateExtrasSupport.entriesByKind(previousLate),
                    next: TimesheetLateExtrasSupport.entriesByKind(draft.lateExtras),
                    organizationId: organizationId,
                    ownerUserIds: CanonicalBusinessEngine.timesheetEvidenceOwnerIds(
                        sheetDocumentId: "",
                        userId: userId,
                        extra: [writerId].filter { !$0.isEmpty }
                    )
                ) {
                    return message
                }
            } else {
                // Unchanged: never resent (a sheet whose late extras this device did not change keeps the stored list).
                fields.removeValue(forKey: "lateExtras")
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
            // RULEBOOK 1.47.0 §8: the signed-bookings record is the person's own; a reviewer never writes it.
            for key in signedBookingsKeys { changed.removeValue(forKey: key) }
            // RULEBOOK 1.54.0 §8 / §16: late extras are the person's own list; a reviewer never writes it.
            changed.removeValue(forKey: "lateExtras")
        } else if draft.operativeSignedBookingsAtPending == true,
                  changed["operativeSignedBookings"] != nil || changed["operativeSignedAt"] != nil {
            // RULEBOOK 1.47.0 §8: the record's server time, written once with the signature (never the device clock).
            changed["operativeSignedBookingsAt"] = FieldValue.serverTimestamp()
        }
        if reviewer {
            let storedIds = storedEntryIds(server)
            func entryId(_ id: UUID, _ stored: String?) -> String {
                stored ?? storedIds[id.uuidString.lowercased()] ?? WorkDocumentKeys.storedId(for: id)
            }
            // RULEBOOK 1.45.0 §8 (review #322): each entry's stored-row fingerprint, so the review stores it.
            func row(_ id: String, _ amount: Double, _ decision: TimesheetManagerDecision, _ revised: Double?, _ fingerprint: String?) -> [String: Any] {
                var out: [String: Any] = [
                    "id": id,
                    "amount": amount,
                    "managerDecision": decision.rawValue,
                    "managerRevisedAmount": revised.map { $0 as Any } ?? NSNull(),
                ]
                if let fingerprint, !fingerprint.isEmpty { out["reviewFingerprint"] = fingerprint }
                return out
            }
            let signedRows: [[String: Any]] = draft.expenseEntries.map {
                row(entryId($0.id, $0.storedId), $0.amount, $0.managerDecision, $0.managerRevisedAmount, $0.reviewFingerprint)
            } + draft.priceWorkEntries.map {
                row(entryId($0.id, $0.storedId), $0.amount, $0.managerDecision, $0.managerRevisedAmount, $0.reviewFingerprint)
            }
            // RULEBOOK 1.54.0 §8 (third and fourth reviews of #337): the late extras' decisions go in the SAME write as
            // the sheet (`lateExtra: true`, with the entry's fingerprint; never an ignored one), never after an export
            // (`exported`), and never under a signed entry's key (the writer reads the stored sheet's entries itself).
            let storedExported = CanonicalBusinessEngine.timesheetExportedFieldSet(server?["exportedAt"])
            if let reviewFields = CanonicalBusinessEngine.timesheetEntryReviewWriteFields(
                storedSheet: server,
                entryRows: signedRows + TimesheetLateExtrasSupport.reviewEntryRows(draft),
                reviewedByUserId: writerId,
                reviewedAtMs: Date().timeIntervalSince1970 * 1000,
                exported: storedExported,
                sheetDocId: server?["__documentId"] as? String
            ) {
                for (key, value) in reviewFields { changed[key] = value }
            }
            // RULEBOOK 1.54.0 (final check of #337): a stored `exportedAt` is never written back changed or removed.
            if storedExported { changed.removeValue(forKey: "exportedAt") }
            // RULEBOOK 1.54.0 §8 / §16 (third review of #337): an exported sheet with late extras is frozen — its review
            // map and snapshot are never changed (the security rules refuse those writes).
            if storedExported, let storedLate = server?["lateExtras"] as? [Any], !storedLate.isEmpty {
                for key in Array(changed.keys) where key == "weeklyReportOverride" || key == "extraEntryReviews" || key.hasPrefix("extraEntryReviews.") {
                    changed.removeValue(forKey: key)
                }
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
        // What this device wrote is now its loaded copy (the base of the next save). RULEBOOK 1.47.0 §8 (web third review
        // #325): the record's server time was written once with this save, so the flag is cleared — a later save never
        // re-stamps it.
        var written = draft
        if changed["operativeSignedBookingsAt"] != nil { written.operativeSignedBookingsAtPending = nil }
        rememberLoadedCopy(written, userId: userId, weekStart: weekStart, organizationId: organizationId)
        if changed["operativeSignedBookingsAt"] != nil {
            var local = load(userId: userId, weekStart: weekStart, organizationId: organizationId)
            if local.operativeSignedBookingsAtPending == true,
               local.operativeSignedBookingsSignedAt == draft.operativeSignedBookingsSignedAt {
                local.operativeSignedBookingsAtPending = nil
                save(local, userId: userId, weekStart: weekStart, organizationId: organizationId)
            }
        }
        if !reviewer && !frozenEntriesChanged && !revisionEntriesRefused {
            // RULEBOOK 1.45.0 §8 `timesheetEntryEvidenceToDelete`: removed files go only inside the §24 undo window.
            let evidenceAfter = draft.expenseEntries.flatMap(\.evidence) + draft.priceWorkEntries.flatMap(\.evidence)
            await firebaseBackend.discardRemovedTimesheetEvidence(before: evidenceBefore, after: evidenceAfter)
        }
        if frozenEntriesChanged {
            return "Price work and expenses can't be changed after your line manager has signed. Ask them to amend it."
        }
        if let lateExtrasRefusal { return lateExtrasRefusal }
        if revisionEntriesRefused { return CanonicalBusinessEngine.timesheetRevisionExtrasMessage }
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
        // RULEBOOK 1.54.0 (third review of #337): late extras under their own `late:` keys, never one map of both kinds.
        let late = TimesheetLateExtrasSupport.fingerprints(draft)
        guard !rows.isEmpty else { return late }
        return CanonicalBusinessEngine.timesheetEntryFingerprintMap(rows).merging(late) { first, _ in first }
    }

    static func asFirestoreMap(_ draft: TimesheetDraft) -> [String: Any] {
        var map = baseFirestoreMap(draft)
        // RULEBOOK 1.47.0 §8 (owner fields): what the person signed and the signature it belongs to. Written only when
        // the draft has them (a sheet signed before 1.47.0 keeps its stored shape), and cleared with the signature.
        // `operativeSignedBookingsAt` is server time: read back here; a fresh signature sends
        // `FieldValue.serverTimestamp()` once (`saveToCloud`).
        if let rows = draft.operativeSignedBookings {
            map["operativeSignedBookings"] = rows.map(\.storedMap)
        } else if draft.operativeSignedAt == nil {
            map["operativeSignedBookings"] = NSNull()
        }
        if let signedAt = draft.operativeSignedBookingsSignedAt {
            map["operativeSignedBookingsSignedAt"] = Timestamp(date: signedAt)
        } else if draft.operativeSignedAt == nil {
            map["operativeSignedBookingsSignedAt"] = NSNull()
        }
        if let writtenAt = draft.operativeSignedBookingsAt {
            map["operativeSignedBookingsAt"] = Timestamp(date: writtenAt)
        } else if draft.operativeSignedAt == nil {
            map["operativeSignedBookingsAt"] = NSNull()
        }
        // RULEBOOK 1.54.0 §8: late extras, written only when the draft has the list (a sheet without them keeps its
        // stored shape), each with its own fields and kind — never a decision.
        if let late = draft.lateExtras {
            map["lateExtras"] = late.map(TimesheetLateExtrasSupport.storedRow)
        }
        return map
    }

    /// RULEBOOK 1.47.0 §8: the three owner fields that record what the person signed (never written for someone else).
    static let signedBookingsKeys = ["operativeSignedBookings", "operativeSignedBookingsSignedAt", "operativeSignedBookingsAt"]

    private static func baseFirestoreMap(_ draft: TimesheetDraft) -> [String: Any] {
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
        output.invoiceGeneratedAt = firestoreDate(map["invoiceGeneratedAt"])
        output.approvedAt = firestoreDate(map["approvedAt"])
        // RULEBOOK 1.47.0 §8: the person's signed-bookings record (missing on sheets signed before 1.47.0).
        if let rows = map["operativeSignedBookings"] as? [Any] {
            output.operativeSignedBookings = rows.compactMap { TimesheetSignedBookingRow(stored: $0) }
        }
        output.operativeSignedBookingsSignedAt = firestoreDate(map["operativeSignedBookingsSignedAt"])
        output.operativeSignedBookingsAt = firestoreDate(map["operativeSignedBookingsAt"])
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

        // RULEBOOK 1.54.0 §8: late extras (added after the line manager signed) through `parseTimesheetLateExtras` —
        // the late decision from the review map, never an inline one. A sheet with a `lateExtras` array the script could
        // not read is not decoded at all (a save from a half-read sheet would drop them).
        if map["lateExtras"] is [Any] {
            guard let late = TimesheetLateExtrasSupport.read(
                sheetDocumentId: sheetDocumentId,
                sheet: map,
                ownerUserIds: RulebookRosterSnapshot.personIds(forUserId: subjectId)
            ) else { return nil }
            output.lateExtras = late
        }
        output.extraEntryReviewsJSON = TimesheetLateExtrasSupport.reviewsJSONText(fromStoredSheet: map)
        // RULEBOOK 1.54.0 (review of #337): the stored `exportedAt` as the security rules test it.
        output.exportedAtStored = CanonicalBusinessEngine.timesheetExportedFieldSet(map["exportedAt"])
        // RULEBOOK 1.55.0 §8: the version this copy was read from (its document id and REV number), and — on a
        // revision — the previous version's exported total the read attached (`timesheetExportedTotal`).
        if let readId = (map["__documentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !readId.isEmpty {
            output.versionDocumentId = readId
            output.revision = CanonicalBusinessEngine.parseTimesheetRevisionDocId(readId)?.revision ?? 0
        }
        output.previousVersionExportedTotal = (map["__previousExportedTotal"] as? NSNumber)?.doubleValue
        output.previousVersionKnown = map["__previousVersionKnown"] as? Bool
        output.originalStoredUserId = (map["__originalUserId"] as? String) ?? (output.revision == 0 ? map["userId"] as? String : nil)

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
        var row: [String: Any] = [
            "id": line.id,
            "title": line.title,
            "details": line.details,
            "jobNumber": line.jobNumber,
            "date": Timestamp(date: line.date),
            "amount": line.amount,
            "decision": line.decision.rawValue
        ]
        // RULEBOOK 1.54.0 §8 (web `weeklyReportOverrideToFirestore`): an approved late extra's row and its fingerprint,
        // only on such a row (every other row keeps its stored shape).
        if line.lateExtra == true { row["lateExtra"] = true }
        if let fingerprint = line.entryFingerprint, !fingerprint.isEmpty { row["entryFingerprint"] = fingerprint }
        return row
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
                    decision: TimesheetManagerDecision(rawValue: row["decision"] as? String ?? "") ?? .approved,
                    // RULEBOOK 1.54.0 §8: an approved late extra's row (and its fingerprint when approved).
                    lateExtra: (row["lateExtra"] as? Bool) == true ? true : nil,
                    entryFingerprint: (row["entryFingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
        var weeks: [WeekRange] = [currentWeek]
        weeks.append(contentsOf: TimesheetPayrollPolicy.previousPayPeriods(count: 24, settings: settings))
        let countersigned = TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user)
        return weeks.filter { week in
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
            // RULEBOOK 1.47.0 §8: a sheet reopened by a booking change is pending too (the person signs again), and
            // its bucket follows the change (`timesheetListBucket(fields, hasLineManager, change)`).
            let change = SignedTimesheetChangeContext.shared.change(draft: draft, user: user, period: week)
            if change?.waitingForPerson == true { return true }
            // RULEBOOK 1.55.0 §8: an exported sheet with a revision due is pending too (the person signs the update).
            if SignedTimesheetChangeContext.shared.revisionDue(draft: draft, user: user, period: week).due { return true }
            guard countersigned else { return false }
            return TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user, change: change)
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
                        family: .plan,
                        bookingsChanged: mustSignAgain(currentWeek) || revisionDue(for: currentWeek).due,
                        triangleMessage: revisionDue(for: currentWeek).message,
                        revisionLabel: revisionLabel(for: currentWeek)
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
                                let changed = mustSignAgain(week)
                                // RULEBOOK 1.55.0 §8: a revision due on an exported sheet.
                                let due = revisionDue(for: week)
                                hubCard(
                                    title: week.title,
                                    subtitle: due.due ? CanonicalBusinessEngine.timesheetRevisionDueStatus
                                        : changed ? CanonicalBusinessEngine.signedTimesheetChangedStatus : "Timesheet pending manager signature",
                                    detail: due.due ? (due.message ?? CanonicalBusinessEngine.timesheetRevisionDueMessage)
                                        : changed
                                        ? CanonicalBusinessEngine.signedTimesheetChangedMessage
                                        : "You signed — waiting for your line manager to counter-sign.",
                                    symbol: "clock.fill",
                                    tint: PPFamily.trade.bottom,
                                    family: .trade,
                                    bookingsChanged: changed || due.due,
                                    triangleMessage: due.due ? (due.message ?? CanonicalBusinessEngine.timesheetRevisionDueMessage) : nil,
                                    revisionLabel: revisionLabel(for: week)
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
                                    family: .system,
                                    bookingsChanged: mustSignAgain(week) || revisionDue(for: week).due,
                                    triangleMessage: revisionDue(for: week).message,
                                    revisionLabel: revisionLabel(for: week)
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
        .attachesSignedTimesheetChanges()
        .onAppear {
            if let userId = userStore.displayUser?.id {
                refreshPastWeeksFromLocalCache(userId: userId)
            }
            if let user = userStore.displayUser {
                SignedTimesheetChangeContext.shared.ensureHubBookings(user: user, settings: settings)
            }
        }
        .task(id: organizationId) {
            await loadPastWeeks()
        }
    }

    private func pastSubtitle(for week: WeekRange) -> String {
        guard let user = userStore.displayUser else { return "Previous period" }
        let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
        // RULEBOOK 1.55.0 §8: an exported sheet whose bookings changed since has an update to sign.
        if revisionDue(for: week).due { return CanonicalBusinessEngine.timesheetRevisionDueStatus }
        if TimesheetApprovalPolicy.isExported(draft) { return "Exported" }
        // RULEBOOK 1.47.0 §8: a reopened sheet is not signed off.
        if mustSignAgain(week) { return CanonicalBusinessEngine.signedTimesheetChangedStatus }
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
        bookingsChanged: Bool = false,
        triangleMessage: String? = nil,
        revisionLabel: String = "",
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
                    HStack(spacing: 6) {
                        Text(subtitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tint)
                        // RULEBOOK 1.55.0 §8: "REV 1" beside the status of a revision.
                        if !revisionLabel.isEmpty {
                            TimesheetRevisionBadge(label: revisionLabel)
                        }
                    }
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
        // RULEBOOK 1.47.0 §8: the yellow triangle on a sheet whose bookings changed since the person signed it.
        .overlay(alignment: .topTrailing) {
            if bookingsChanged {
                SignedTimesheetChangedTriangle(message: triangleMessage ?? CanonicalBusinessEngine.signedTimesheetChangedMessage)
                    .padding(6)
            }
        }
    }

    /// RULEBOOK 1.47.0 §8 `signedTimesheetBookingChanges` for the person's own sheet of `week` (nil when unsigned,
    /// exported-and-unchanged, or the pay run's bookings have not loaded).
    private func bookingChange(for week: WeekRange) -> RulebookSignedTimesheetChange? {
        let _ = bookingStore.revision
        let _ = managerScheduleStore.revision
        guard let user = userStore.displayUser else { return nil }
        let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
        return SignedTimesheetChangeContext.shared.change(draft: draft, user: user, period: week)
    }

    private func mustSignAgain(_ week: WeekRange) -> Bool {
        bookingChange(for: week)?.waitingForPerson == true
    }

    /// RULEBOOK 1.55.0 §8 `timesheetRevisionDue` for the person's own sheet of `week` (exported, bookings changed since).
    private func revisionDue(for week: WeekRange) -> RulebookTimesheetRevisionDue {
        let _ = bookingStore.revision
        let _ = managerScheduleStore.revision
        guard let user = userStore.displayUser else { return .notDue }
        let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
        return SignedTimesheetChangeContext.shared.revisionDue(draft: draft, user: user, period: week)
    }

    /// "REV 1" when the sheet stored for `week` is a revision (`timesheetRevisionLabel`), else "".
    private func revisionLabel(for week: WeekRange) -> String {
        guard let user = userStore.displayUser else { return "" }
        return TimesheetDraftStore.revisionLabel(for: TimesheetDraftStore.load(userId: user.id, weekStart: week.start))
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
    /// RULEBOOK 1.54.0 §8: a late extra (added after the line manager signed) being added, edited or deleted.
    @State private var showLateExtraConfirm = false
    @State private var pendingLateExtraMode: TimesheetExtraMode?
    @State private var showLatePriceWorkSheet = false
    @State private var showLateExpenseSheet = false
    @State private var editingLateExtra: TimesheetLateExtra?
    @State private var deletingLateExtraId: String?
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
            bookings: periodBookingsState,
            scope: .ownPay
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
    /// RULEBOOK 1.55.0 §8: "Review and sign again" is creating the revision.
    @State private var isCreatingRevision = false

    /// RULEBOOK 1.55.0 §8 `timesheetRevisionDue`: this exported sheet's bookings changed since — the person signs an
    /// update (a revision). Before export nothing changes from 1.47.0.
    private var revisionDue: RulebookTimesheetRevisionDue {
        guard TimesheetApprovalPolicy.isExported(draft) else { return .notDue }
        return TimesheetDraftStore.revisionDue(for: draft, userId: currentUserId, weekStart: week.start, change: bookingChange)
    }

    /// RULEBOOK 1.55.0 §8: the versions before the one shown, read only (`timesheetEarlierVersions`).
    private var earlierVersions: [TimesheetVersionInfo] {
        let chain = TimesheetVersionChainCache.chain(for: draft.versionDocumentId)
        guard chain.last?.documentId == draft.versionDocumentId else { return [] }
        return CanonicalBusinessEngine.timesheetEarlierVersions(chain)
    }

    /// RULEBOOK 1.55.0 §8: "Review and sign again" on an exported sheet whose revision is due — the person's own write
    /// creates `…_rev{N}` (`canCreateTimesheetRevision` with `writerIsSubject`), then the revision opens in the normal
    /// sign flow (it is unsigned, priced from the live bookings).
    private func createRevisionAndOpen() {
        guard !isCreatingRevision, let user = userStore.displayUser,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // The live lines decide which labour decisions the revision keeps: only once bookings and pay inputs loaded.
        if let blocked = payInputsBlockMessage {
            saveErrorMessage = blocked
            return
        }
        isCreatingRevision = true
        let lines = payrollLines
        Task {
            let result = await TimesheetDraftStore.createRevision(
                subject: user,
                weekStart: week.start,
                writer: user,
                writerIsSubject: true,
                liveLines: lines,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
            await MainActor.run {
                isCreatingRevision = false
                // An already-open revision is simply opened (no error).
                saveErrorMessage = result.revisionOpen ? nil : result.message
                if result.message != nil && !result.revisionOpen { Feedback.play(.actionRefused) }
            }
            // Created, or already open (review of #243 L1): show the open revision and listen to it.
            if result.documentId != nil || result.revisionOpen {
                await refreshDraftFromCloud()
                await MainActor.run { listenToServerTimesheet() }
            }
        }
    }

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

    /// RULEBOOK 1.55.0 §8: this sheet is a revision (REV N).
    private var isRevision: Bool { (draft.revision ?? 0) > 0 }

    /// RULEBOOK 1.22.0 §8 `CanonicalBusinessEngine.timesheetTotals`: this sheet's totals as the invoice will have them
    /// — review decisions apply once the line manager has signed (web `draftTimesheetTotals`).
    private var ownerTotals: RulebookTimesheetTotals? {
        // RULEBOOK 1.55.0 (review of #344): a revision is priced `decided` for everyone (its copied decisions stand).
        TimesheetTotalsSource.totals(lines: payrollLines, draft: draftForFigures, decided: managerHasSigned || isRevision, subject: userStore.displayUser, period: week.start...week.end)
    }

    /// The same sheet at the amounts the person entered (`timesheetTotals` in `raw` mode, no labour reviews), for the
    /// "before line manager adjustments" figures and the sign sheet.
    private var submittedTotals: RulebookTimesheetTotals? {
        var unreviewed = draftForFigures
        unreviewed.payrollLineReviews = [:]
        // RULEBOOK 1.55.0: a revision is signed at its decided figures (the copied decisions stand).
        if isRevision {
            return TimesheetTotalsSource.totals(lines: payrollLines, draft: draftForFigures, decided: true, subject: userStore.displayUser, period: week.start...week.end)
        }
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

    /// RULEBOOK 1.47.0 §8 `signedTimesheetBookingChanges`: whether this signed sheet's bookings changed since it was
    /// signed (only once the whole pay run's bookings have loaded — never from a partial load).
    private var bookingChange: RulebookSignedTimesheetChange? {
        guard let currentUser = userStore.displayUser, SignedTimesheetChanges.isSigned(draft) else { return nil }
        let inputs = SignedTimesheetChanges.Inputs(
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            organization: firebaseBackend.currentOrganization,
            users: userStore.organizationUsers,
            // The person's ids come from the operatives list too (web third review #325): wait for it.
            liveLoaded: periodBookingsState.loaded && operativesLoaded
        )
        return SignedTimesheetChanges.change(draft: draft, user: currentUser, period: week, inputs: inputs, lines: payrollLines)
    }

    /// The person must review and sign again (1.47.0 §8).
    private var mustSignAgain: Bool { bookingChange?.waitingForPerson == true }

    /// RULEBOOK 1.47.0 §8 (review of #234 item 5): a signed sheet's booking-change answer is ready — the whole pay run's
    /// bookings and the operatives list have loaded and the script answered. Until then nothing that a reopened sheet
    /// may not do (Generate Invoice) is offered: "not loaded" is not "unchanged".
    private var bookingCheckReady: Bool {
        guard SignedTimesheetChanges.isSigned(draft) else { return true }
        return periodBookingsState.loaded && operativesLoaded && bookingChange != nil
    }

    /// Review of #234 (B): the check cannot run right now — the bookings read failed (offline) or the operatives list
    /// stopped without finishing. The screen then says so with Retry instead of "Checking…".
    private var bookingCheckUnavailable: Bool {
        guard SignedTimesheetChanges.isSigned(draft), !bookingCheckReady else { return false }
        return SignedTimesheetCheckAvailability.unavailable(
            bookingsFailed: periodBookingsState.failed,
            operativesLoaded: operativesLoaded,
            operativesStalled: SignedTimesheetCheckAvailability.operativesStalled(
                operativeStore, organizationId: firebaseBackend.currentOrganization?.firestoreDocumentId
            )
        )
    }

    /// Retry: the pay run's bookings (a failed read is asked again), the operatives list when it stalled, and the pay
    /// inputs.
    private func retryBookingCheck() {
        ensurePeriodBookings()
        if SignedTimesheetCheckAvailability.operativesStalled(
            operativeStore, organizationId: firebaseBackend.currentOrganization?.firestoreDocumentId
        ) {
            operativeStore.loadData()
        }
        Task { await loadDayRateHistory() }
    }

    /// The operatives list of the open organisation has loaded (the person's booking ids depend on it).
    private var operativesLoaded: Bool {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return false }
        return operativeStore.finishedLoadOrganizationId == orgId && !operativeStore.isLoading
    }

    /// RULEBOOK 1.47.0 §8: a reopened sheet shows (and invoices) the live bookings' figures, never its stale signed
    /// snapshot (web `draftForFigures`). 1.54.0: late extras alone never discard the snapshot — its signed figures stand,
    /// with its late rows only while still approved (`TimesheetLateExtrasSupport.draftWithCurrentLateRows`).
    private var draftForFigures: TimesheetDraft {
        guard bookingChange?.reopened == true, bookingChange?.bookingsChanged != false, draft.weeklyReportOverride != nil else {
            return TimesheetLateExtrasSupport.draftWithCurrentLateRows(draft)
        }
        var live = draft
        live.weeklyReportOverride = nil
        return live
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
                HStack(spacing: 8) {
                    Text(week.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // RULEBOOK 1.55.0 §8: "REV 1" on a revision.
                    if !TimesheetDraftStore.revisionLabel(for: draft).isEmpty {
                        TimesheetRevisionBadge(label: TimesheetDraftStore.revisionLabel(for: draft))
                    }
                }

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

                if managerHasSigned, TimesheetDraftAdjustments.managerAdjustmentCount(draft: draft, lines: payrollLines) > 0 {
                    TimesheetManagerAdjustmentSummaryCard(
                        draft: draft,
                        lines: payrollLines,
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

                // RULEBOOK 1.54.0 §8: price work and expenses added after the line manager signed, each with where it
                // stands (`timesheetLateExtraLabel`); edited or deleted while `timesheetOwnerCanAddLateExtras` allows.
                if let late = draft.lateExtras, !late.isEmpty {
                    sectionCard(title: "Added after sign-off") {
                        ForEach(late) { item in
                            lateExtraOwnerRow(item)
                        }
                    }
                }

                sectionHeader("Add to this timesheet")
                // RULEBOOK 1.43.0 §8 `timesheetOwnerCanAddExtras`: nothing is added to the signed entries once the line
                // manager has signed (a self-signed sheet stays open; adding asks the person to sign again). 1.54.0: from
                // then until export the buttons add a late extra instead (`timesheetOwnerCanAddLateExtras`).
                let extras = extrasPermission
                let lateExtras = lateExtrasPermission
                if !extras.allowed && lateExtras.allowed {
                    Text(CanonicalBusinessEngine.timesheetLateExtraAddConfirmMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("timesheets.lateExtrasNote")
                } else if !extras.allowed, let message = lateExtras.message ?? extras.message {
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
                    .disabled(!extras.allowed && !lateExtras.allowed)
                    .opacity(extras.allowed || lateExtras.allowed ? 1 : 0.5)
                    Button {
                        beginAddingExtra(.expense)
                    } label: {
                        addonTile(title: "Expenses", subtitle: "+ receipts", symbol: "sterlingsign.circle.fill", tint: Color(red: 0.706, green: 0.325, blue: 0.035))
                    }
                    .accessibilityIdentifier("timesheets.expenses")
                    .buttonStyle(.plain)
                    .disabled(!extras.allowed && !lateExtras.allowed)
                    .opacity(extras.allowed || lateExtras.allowed ? 1 : 0.5)
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

                // RULEBOOK 1.47.0 §8: bookings changed since the person signed — they review the live bookings and sign
                // again (`SIGNED_TIMESHEET_CHANGED_MESSAGE`).
                if mustSignAgain {
                    SignedTimesheetChangedBanner(message: bookingChange?.message ?? CanonicalBusinessEngine.signedTimesheetChangedMessage)
                }
                // RULEBOOK 1.55.0 §8: exported and a booking changed since — the exported sheet stays as it was; the
                // person signs an update (a revision).
                if revisionDue.due {
                    SignedTimesheetChangedBanner(message: revisionDue.message ?? CanonicalBusinessEngine.timesheetRevisionDueMessage)
                    Button(action: createRevisionAndOpen) {
                        Label(
                            isCreatingRevision ? "Creating revision…" : CanonicalBusinessEngine.timesheetReviewAndSignRevisionLabel,
                            systemImage: "pencil.and.scribble"
                        )
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("timesheets.reviewAndSignRevision")
                    .buttonStyle(.plain)
                    .disabled(isCreatingRevision)
                    // RULEBOOK §2: signing is online only.
                    .onlineOnly(isOnline: smartCache.isOnline)
                }
                if !earlierVersions.isEmpty {
                    TimesheetEarlierVersionsList(versions: earlierVersions)
                        .padding(14)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if bookingCheckUnavailable {
                    // Review of #234 (B): a signed sheet whose bookings cannot be read says so, with Retry.
                    PayInputsFailureBanner(message: SignedTimesheetCheckAvailability.unavailableMessage) {
                        retryBookingCheck()
                    }
                } else if let blocked = payInputsBlockMessage,
                          draft.operativeSignedAt == nil || mustSignAgain || periodBookingsState.failed {
                    PayInputsFailureBanner(message: blocked) {
                        retryBookingCheck()
                    }
                }
                if (draft.operativeSignedAt == nil || mustSignAgain) && payInputsBlockMessage == nil {
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
                        Label(mustSignAgain ? "Review and sign again" : "Continue to sign", systemImage: "pencil.and.scribble")
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
                   // RULEBOOK 1.54.0: late extras alone never undo the counter-signature.
                   bookingChange?.reopened != true || bookingChange?.lateExtrasOnly == true,
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
                   TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: currentUser),
                   // RULEBOOK 1.47.0 §8: no invoice from a reopened sheet's stale snapshot.
                   CanonicalBusinessEngine.signedTimesheetActions(bookingChange).mayGenerateInvoice {
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
                    .disabled(isGeneratingInvoice || !bookingCheckReady)
                    .opacity(bookingCheckReady ? 1 : 0.5)

                    if !bookingCheckReady && !bookingCheckUnavailable {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(SignedTimesheetCheckAvailability.checkingMessage)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("timesheets.generateInvoice.checking")
                    }

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
        // RULEBOOK 1.54.0 §8: late extras — confirm, add, edit and delete (never a signature cleared).
        .confirmationDialog(
            "Added after sign-off",
            isPresented: $showLateExtraConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue") { openPendingLateExtraSheet() }
                .accessibilityIdentifier("timesheets.lateExtra.confirm")
            Button("Cancel", role: .cancel) { pendingLateExtraMode = nil }
        } message: {
            Text(CanonicalBusinessEngine.timesheetLateExtraAddConfirmMessage)
        }
        .sheet(isPresented: $showLatePriceWorkSheet) {
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .priceWork, editing: nil as TimesheetPriceWorkEntry?) { (entry: TimesheetPriceWorkEntry) async -> String? in
                    let late = TimesheetLateExtrasSupport.lateExtra(from: entry, id: UUID().uuidString)
                    return await applyLateExtraChange { $0.append(late) }
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
            }
        }
        .sheet(isPresented: $showLateExpenseSheet) {
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .expense, editing: nil as TimesheetExpenseEntry?) { (entry: TimesheetExpenseEntry) async -> String? in
                    let late = TimesheetLateExtrasSupport.lateExtra(from: entry, id: UUID().uuidString)
                    return await applyLateExtraChange { $0.append(late) }
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
            }
        }
        .sheet(item: $editingLateExtra) { editing in
            NavigationStack {
                if editing.isPriceWork {
                    TimesheetMoneyEntrySheet(mode: .priceWork, editing: TimesheetLateExtrasSupport.priceWorkEntry(editing)) { (entry: TimesheetPriceWorkEntry) async -> String? in
                        let late = TimesheetLateExtrasSupport.lateExtra(from: entry, id: editing.id)
                        return await applyLateExtraChange { list in
                            if let index = list.firstIndex(where: { $0.id == editing.id }) { list[index] = late }
                        }
                    }
                    .environmentObject(userStore)
                    .environmentObject(projectStore)
                    .environmentObject(firebaseBackend)
                } else {
                    TimesheetMoneyEntrySheet(mode: .expense, editing: TimesheetLateExtrasSupport.expenseEntry(editing)) { (entry: TimesheetExpenseEntry) async -> String? in
                        let late = TimesheetLateExtrasSupport.lateExtra(from: entry, id: editing.id)
                        return await applyLateExtraChange { list in
                            if let index = list.firstIndex(where: { $0.id == editing.id }) { list[index] = late }
                        }
                    }
                    .environmentObject(userStore)
                    .environmentObject(projectStore)
                    .environmentObject(firebaseBackend)
                }
            }
        }
        .confirmationDialog(
            CanonicalBusinessEngine.timesheetEntryDeleteLabel,
            isPresented: Binding(get: { deletingLateExtraId != nil }, set: { if !$0 { deletingLateExtraId = nil } }),
            titleVisibility: .visible
        ) {
            Button(CanonicalBusinessEngine.timesheetEntryDeleteLabel, role: .destructive) {
                guard let id = deletingLateExtraId else { return }
                deletingLateExtraId = nil
                Task {
                    if let message = await applyLateExtraChange({ $0.removeAll { $0.id == id } }) {
                        saveErrorMessage = message
                    }
                }
            }
            .accessibilityIdentifier("timesheets.lateExtra.deleteConfirm")
            Button("Cancel", role: .cancel) { deletingLateExtraId = nil }
        } message: {
            Text(CanonicalBusinessEngine.timesheetEntryDeleteConfirmMessage)
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
        // RULEBOOK 1.47.0 §8 `signedTimesheetActions(change).mayGenerateInvoice`: never invoice a reopened sheet, and
        // never before the check could run (review of #234 item 5).
        if !bookingCheckReady {
            await MainActor.run { invoiceErrorMessage = (bookingCheckUnavailable ? SignedTimesheetCheckAvailability.unavailableMessage : "Still checking the bookings on this timesheet. Try again in a moment.") }
            return
        }
        if !CanonicalBusinessEngine.signedTimesheetActions(bookingChange).mayGenerateInvoice {
            // RULEBOOK 1.54.0 §8: no invoice while late extras wait for the line manager (`timesheetChangesWithLateExtras`).
            let message = bookingChange?.lateExtrasOnly == true
                ? CanonicalBusinessEngine.timesheetLateExtraWaitingLabel
                : CanonicalBusinessEngine.signedTimesheetChangedMessage
            await MainActor.run { invoiceErrorMessage = message }
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
            selfSigned: selfSigned,
            revision: draft.revision
        )
    }

    /// RULEBOOK 1.54.0 §8 `timesheetOwnerCanAddLateExtras(sheet, { selfSigned })`: late extras only once the line manager
    /// has signed and until the stored `exportedAt` is set (`TIMESHEET_EXPORTED_EXTRAS_MESSAGE`).
    private var lateExtrasPermission: RulebookTimesheetExtrasPermission {
        let selfSigned = userStore.displayUser.map { !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: $0) } ?? false
        return CanonicalBusinessEngine.timesheetOwnerCanAddLateExtras(
            managerSignedAt: draft.managerSignedAt,
            approvedAt: draft.approvedAt,
            exportedAt: draft.exportedAt,
            exportedAtStored: draft.exportedAtStored,
            selfSigned: selfSigned,
            revision: draft.revision
        )
    }

    /// One late extra on the person's own sheet: what it is, its label (`timesheetLateExtraLabel`) and, while allowed,
    /// Edit / Delete. A late extra pays only once approved, so no amount is shown as paid until then.
    @ViewBuilder
    private func lateExtraOwnerRow(_ item: TimesheetLateExtra) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .fontWeight(.semibold)
                    .strikethrough(item.lateState == "declined")
                Text(item.isPriceWork ? "Price work · \(CanonicalBusinessEngine.priceWorkJobNumberText(item.jobNumber))" : "Expense · \(item.jobNumber.isEmpty ? "—" : item.jobNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let evidenceCount = CanonicalBusinessEngine.claimEvidenceCountText(item.evidence.count)
                if !evidenceCount.isEmpty {
                    Text(evidenceCount)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ClaimEvidenceLinks(evidence: item.evidence, legacyReceiptName: item.receiptName)
                if let label = CanonicalBusinessEngine.timesheetLateExtraLabel(state: item.lateState ?? "pending", reason: item.lateReason) {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(item.lateState == "approved" ? Color.green : PPColor.warningAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("timesheets.lateExtra.label")
                }
                if lateExtrasPermission.allowed {
                    HStack(spacing: 16) {
                        Button(CanonicalBusinessEngine.timesheetEntryEditLabel) { editingLateExtra = item }
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("timesheets.lateExtra.edit")
                        Button(CanonicalBusinessEngine.timesheetEntryDeleteLabel, role: .destructive) { deletingLateExtraId = item.id }
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("timesheets.lateExtra.delete")
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
            Spacer()
            Text(OrgMoney.format(item.amount))
                .fontWeight(.semibold)
                .foregroundStyle(item.lateState == "approved" ? Color.primary : Color.secondary)
        }
    }

    /// Opens the add sheet for a late extra once the person confirmed.
    private func openPendingLateExtraSheet() {
        switch pendingLateExtraMode {
        case .priceWork: showLatePriceWorkSheet = true
        case .expense: showLateExpenseSheet = true
        case .none: break
        }
        pendingLateExtraMode = nil
    }

    /// Adds, replaces or removes one late extra and saves (the signed entries are never touched).
    private func applyLateExtraChange(_ change: @escaping (inout [TimesheetLateExtra]) -> Void) async -> String? {
        guard lateExtrasPermission.allowed else { return lateExtrasPermission.message ?? CanonicalBusinessEngine.timesheetExportedExtrasMessage }
        // Merge with main (1.54): saved without a feedback sound, as on main (late extras are a sound follow-up).
        return await applyEntryChangeSaving(clearingSignatures: false) { sheet in
            var late = sheet.lateExtras ?? []
            change(&late)
            sheet.lateExtras = late
        }
    }

    private func beginAddingExtra(_ mode: TimesheetExtraMode) {
        // RULEBOOK 1.43.0: no add control and no signature cleared once the line manager has signed.
        let extras = extrasPermission
        guard extras.allowed else {
            // RULEBOOK 1.54.0 §8: after the line manager signed (until export) the person adds a late extra, after the
            // confirm (`TIMESHEET_LATE_EXTRA_ADD_CONFIRM_MESSAGE`). No signature is ever cleared.
            if lateExtrasPermission.allowed {
                pendingLateExtraMode = mode
                showLateExtraConfirm = true
                return
            }
            saveErrorMessage = lateExtrasPermission.message ?? extras.message
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
            || showLateExtraConfirm || showLatePriceWorkSheet || showLateExpenseSheet || editingLateExtra != nil
            || managerNoteFocused
    }

    private func listenToServerTimesheet() {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        firebaseBackend.listenTimesheetState(
            key: Self.liveTimesheetKey,
            organizationId: orgId,
            userId: currentUserId,
            weekStart: week.start,
            // RULEBOOK 1.55.0 §8: the version loaded (a revision once one exists), never also the frozen original.
            documentId: draft.versionDocumentId
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
            Feedback.play(.actionRefused)
            return
        }
        // RULEBOOK 1.47.0 §8: what the person signs is recorded only once every input has loaded (the roster and the
        // operatives list too).
        guard RulebookRosterSnapshot.hasLoaded, operativesLoaded else {
            saveErrorMessage = TimesheetDraftStore.rosterNotLoadedMessage
            Feedback.play(.actionRefused)
            return
        }
        let signedByName = userStore.displayUser?.fullName.isEmpty == false
            ? (userStore.displayUser?.fullName ?? "")
            : (userStore.displayUser?.email ?? "")
        // RULEBOOK 1.47.0 §8: a sheet reopened by a booking change rebuilds its snapshot from the live bookings when
        // this signature completes it (self-signed; with a line manager the counter-signature rebuilds it).
        let rebuild = CanonicalBusinessEngine.signedTimesheetActions(bookingChange).rebuildSnapshot
        let previous = draft
        guard TimesheetDraftStore.applySignOff(
            to: &draft,
            role: "operative",
            signedAt: Date(),
            signedByName: signedByName,
            signedByUserId: userStore.displayUser?.id,
            signatureImageBase64: signatureImageData.base64EncodedString()
        ) else {
            Feedback.play(.actionRefused)
            return
        }
        // RULEBOOK 1.47.0 §8 `signedTimesheetBookingRecord`: the bookings this signature covers, from the lines shown.
        guard SignedTimesheetChanges.stampSignedBookings(
            on: &draft,
            lines: payrollLines,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings
        ) else {
            draft = previous
            saveErrorMessage = TimesheetWeeklyReportOverrideBuilder.rulebookCheckFailedMessage
            Feedback.play(.actionRefused)
            return
        }
        if let current = userStore.displayUser {
            TimesheetApprovalPolicy.applySelfApprovalIfNoLineManager(draft: &draft, user: current)
        }
        let signSave = saveDraft(rebuildSnapshot: rebuild)
        playTimesheetFeedback(signSave, success: .timesheetSigned)
        guard let current = userStore.displayUser else { return }
        guard TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: current) else { return }
        // `timesheetSubmittedRecipients(subject, roster)`: active line managers, else the admins; never the owner.
        let weekStart = week.start
        let revision = draft.revision
        Task {
            await notificationService.notifyTimesheetSubmitted(
                signedByUser: current,
                weekStart: weekStart,
                revision: revision
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
            selfSigned: selfSigned,
            revision: draft.revision
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

    /// Feedback guide §4 for one owner save of this sheet: waits for the cloud save the action started (it does not
    /// change when or how it runs) and plays `success`, or `actionRefused` when it was refused. A save that never
    /// started because it was refused (`saveDraft` returned nil with an organisation open) plays the refusal.
    private func playTimesheetFeedback(_ save: Task<String?, Never>?, success: FeedbackEvent) {
        guard let save else {
            if firebaseBackend.currentOrganization?.firestoreDocumentId != nil {
                Feedback.play(.actionRefused)
            }
            return
        }
        Task {
            let message = await save.value
            Feedback.play(FeedbackDecision.event(refusal: message, success: success))
        }
    }

    /// Applies an entry change, saves the sheet and waits for the save. On a refusal the sheet goes back to how it was
    /// and the message is returned (the entry sheet then discards any file it just uploaded). Plays the feedback for
    /// the save (guide §4 `timesheetSaved`, or `actionRefused`).
    private func applyEntryChange(
        clearingSignatures: Bool = false,
        _ change: (inout TimesheetDraft) -> Void
    ) async -> String? {
        let message = await applyEntryChangeSaving(clearingSignatures: clearingSignatures, change)
        Feedback.play(FeedbackDecision.event(refusal: message, success: .timesheetSaved))
        return message
    }

    private func applyEntryChangeSaving(
        clearingSignatures: Bool,
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
    private func saveDraft(rebuildSnapshot: Bool = false) -> Task<String?, Never>? {
        // RULEBOOK 1.43.0 (review r318, 2nd round): nothing is saved while the period's sheet could not be read.
        guard !periodLoadFailed else {
            saveErrorMessage = TimesheetDraftStore.periodReadFailedMessage
            return nil
        }
        // A signature that completes the sheet never saves without its snapshot: while pay inputs (bookings, history or
        // the pay-profile overlays) are not ready, the save is refused rather than saved unfrozen.
        if let current = userStore.displayUser,
           let refusal = TimesheetWeeklyReportOverrideBuilder.saveRefusalWhilePayInputsBlocked(
               draft: draft,
               user: current,
               writerIsReviewer: TimesheetApprovalPolicy.writerIsReviewer(
                   writerId: current.id,
                   writer: current,
                   subjectUserId: current.id,
                   subject: current
               ),
               blockMessage: payInputsBlockMessage,
               rebuildSnapshot: rebuildSnapshot
           ) {
            saveErrorMessage = refusal
            return nil
        }
        // The agreed snapshot is never frozen from inputs that did not load (`PayInputsLoad`).
        if let current = userStore.displayUser, payInputsBlockMessage == nil || draft.weeklyReportOverride != nil {
            // The owner's own save: with a line manager it never builds the approved snapshot.
            // RULEBOOK 1.46.0: a snapshot the rulebook could not check is never saved (fail closed).
            let refusal = TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
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
                snapshotInputsReady: payInputsBlockMessage == nil,
                // RULEBOOK 1.47.0 §8 `signedTimesheetActions(change).rebuildSnapshot`: a reopened sheet's re-signature
                // builds the snapshot fresh from the live bookings.
                rebuildSnapshot: rebuildSnapshot && payInputsBlockMessage == nil
            )
            if let refusal {
                saveErrorMessage = refusal
                return nil
            }
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
            // RULEBOOK 1.47.0 §8: the record's server time went with this save; clear the flag on the draft as it is
            // now (same signature only), so a later save never re-stamps it.
            if message == nil, snapshot.operativeSignedBookingsAtPending == true,
               draft.operativeSignedBookingsAtPending == true,
               draft.operativeSignedBookingsSignedAt == snapshot.operativeSignedBookingsSignedAt {
                draft.operativeSignedBookingsAtPending = nil
            }
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
            // RULEBOOK 1.55.0 §8 ("lock all"): an exported version is never saved again.
            if updated.managerSignedAt != remote.managerSignedAt, !TimesheetApprovalPolicy.isExported(remote) {
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
        // RULEBOOK 1.61.0 §8: a day-rate overtime line reads in hours (`dayRateOvertimeCalcText`).
        if let text = row.dayRateOvertimeText { return text }
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
        PayInputsLoad.blockMessage(state: payInputsState, organization: firebaseBackend.currentOrganization, scope: .othersPay)
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
            // RULEBOOK 1.47.0 §8: the bucket follows the sheet's booking change.
            let bucket = TimesheetApprovalPolicy.listBucket(draft: draft, user: user, period: week)
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
                                    OperativeTimesheetReviewView(operative: live(row.user), settings: settings, week: row.week)
                                        .environmentObject(firebaseBackend)
                                        .environmentObject(userStore)
                                        .environmentObject(bookingStore)
                                        .environmentObject(operativeStore)
                                        .environmentObject(projectStore)
                                        .environmentObject(managerScheduleStore)
                                        .environmentObject(notificationService)
                                } label: {
                                    HStack(spacing: 12) {
                                        initialsAvatar(for: live(row.user))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(live(row.user).fullName.isEmpty ? live(row.user).email : live(row.user).fullName)
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
                                        statusPill(for: row.draft, user: live(row.user), period: row.week)
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
                                // RULEBOOK 1.55.0 §8: the pay run's earlier versions, read only, each with its PDF.
                                if !row.earlier.isEmpty {
                                    TimesheetEarlierVersionsList(versions: row.earlier) { version in
                                        downloadEarlierVersionPDF(version, of: row)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 8)
                                }
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
                            OperativeTimesheetReviewView(operative: live(row.user), settings: settings, week: row.week)
                                .environmentObject(firebaseBackend)
                                .environmentObject(userStore)
                                .environmentObject(bookingStore)
                                .environmentObject(operativeStore)
                                .environmentObject(projectStore)
                                .environmentObject(managerScheduleStore)
                                .environmentObject(notificationService)
                        } label: {
                            HStack(spacing: 12) {
                                initialsAvatar(for: live(row.user))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(live(row.user).fullName.isEmpty ? live(row.user).email : live(row.user).fullName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    let draft = TimesheetDraftStore.load(userId: live(row.user).id, weekStart: row.week.start)
                                    let summary = operativeSummary(for: live(row.user), draft: draft, week: row.week)
                                    Text(summary.map { "\(row.week.title) · Hrs \(formatHours($0.hours)) · OT \(formatHours($0.overtimeHours)) · PW \(OrgMoney.format($0.priceWork)) · Exp \(OrgMoney.format($0.expenses))" } ?? row.week.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if isAdminViewer {
                                        Text("Line manager: \(lineManagerName(for: live(row.user)))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                statusPill(
                                    for: TimesheetDraftStore.load(userId: live(row.user).id, weekStart: row.week.start),
                                    user: live(row.user),
                                    period: row.week
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
                                    user: operative,
                                    period: week
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
        // RULEBOOK 1.47.0 §8: rows, counts and Export read each sheet's booking change.
        .attachesSignedTimesheetChanges()
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
        // The rows keep each person: rebuilt when roster pay is laid over again (review of #240), never priced from a
        // copy kept from before the pay profiles arrived.
        .onChange(of: userStore.payOverlayVersion) { _, _ in rebuildAwaitingRows() }
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
        // RULEBOOK 1.47.0 §8: a sheet waiting for the person to sign the changed bookings again is not signed.
        // RULEBOOK §8: the viewer's own record with their pay profile laid over (PAYE days are not timesheet lines).
        let waitingForOwner = userStore.currentUserWithPay.flatMap {
            SignedTimesheetChangeContext.shared.change(draft: ownSheet, user: $0, period: week)
        }?.waitingForPerson == true
        ownSheetExportNotice = CanonicalBusinessEngine.timesheetExportOwnSheetNotice(
            ownSheetSigned: ownSheet.operativeSignedAt != nil && !waitingForOwner,
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

    /// The row's status with — RULEBOOK 1.55.0 §8 — "REV N" beside it on a revision (`timesheetRevisionLabel`).
    private func statusPill(for draft: TimesheetDraft, user: AppUser, period: WeekRange) -> some View {
        HStack(spacing: 4) {
            let label = TimesheetDraftStore.revisionLabel(for: draft)
            if !label.isEmpty { TimesheetRevisionBadge(label: label) }
            statusPillCore(for: draft, user: user, period: period)
        }
    }

    @ViewBuilder
    private func statusPillCore(for draft: TimesheetDraft, user: AppUser, period: WeekRange) -> some View {
        let bucket = TimesheetApprovalPolicy.listBucket(draft: draft, user: user, period: week)
        if TimesheetApprovalPolicy.isExported(draft),
           SignedTimesheetChangeContext.shared.revisionDue(draft: draft, user: user, period: period).due {
            // RULEBOOK 1.55.0 §8: exported, and a booking changed since — a revision is due.
            statusPillLabel(CanonicalBusinessEngine.timesheetRevisionDueStatus, symbol: "exclamationmark.triangle.fill", color: Color(.systemYellow))
        } else if TimesheetApprovalPolicy.isExported(draft) {
            statusPillLabel("Exported", symbol: "tray.and.arrow.up.fill", color: .secondary)
        } else if SignedTimesheetChangeContext.shared.change(draft: draft, user: user, period: week)?.waitingForPerson == true {
            // RULEBOOK 1.47.0 §8: back with the person to sign again.
            statusPillLabel(CanonicalBusinessEngine.signedTimesheetChangedStatus, symbol: "exclamationmark.triangle.fill", color: Color(.systemYellow))
        } else if bucket == "signed" || (bucket == nil && TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user)) {
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
        // The email function's `timesheet_export` sends only to the caller's own sign-in (ID token) email (web #334):
        // the signed-in Auth email, else the users-document copy.
        let recipientEmail = TimesheetExportRecipient.email(
            authEmail: Auth.auth().currentUser?.email,
            profileEmail: exporter.email
        )

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
            ),
            scope: .othersPay
        ) {
            exportMessage = blocked
            return
        }
        guard let exportOrgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            exportMessage = "Failed: no organisation."
            return
        }
        // RULEBOOK 1.47.0 §8 (review of #234 item 5): the booking-change check needs the whole pay run's bookings AND the
        // operatives list (the person's ids); until both have loaded nothing is exported (never fail open).
        func gateReady() -> Bool {
            PayInputsLoad.periodBookings(
                firebaseBackend: firebaseBackend, bookingStore: bookingStore, managerScheduleStore: managerScheduleStore,
                from: week.start
            ).loaded && operativeStore.finishedLoadOrganizationId == exportOrgId && !operativeStore.isLoading
        }
        func name(_ user: AppUser) -> String { user.fullName.isEmpty ? user.email : user.fullName }

        // Review r318 (web `runTimesheetExport`). 1. Prepare every sheet — fresh read, snapshot built (an empty frozen one
        // rebuilt) BEFORE `exportedAt` — checking the gate before each person. Nothing is written here, so a gate that
        // closes stops the export with nobody stamped. A sheet exported elsewhere, or not signed in its fresh copy, is left.
        var prepared: [(operative: AppUser, draft: TimesheetDraft)] = []
        var skippedElsewhere: [String] = []
        /// RULEBOOK 1.47.0 §8: sheets left out because their bookings changed since they were signed.
        var skippedChanged: [String] = []
        /// Review of #240: people whose pay details could not be loaded (their pay-profile read failed).
        var skippedPay: [String] = []
        /// RULEBOOK 1.54.0 §8: sheets left out because late extras wait for the line manager.
        var skippedLateExtras: [String] = []
        for target in targets {
            // RULEBOOK §8 (review of #240): the person as the roster holds them now, pay laid over.
            let op = live(target)
            guard gateReady() else {
                exportMessage = TimesheetDraftStore.exportStoppedMessage
                return
            }
            // The pay gate for this person, checked again for each one (review of #240): still loading stops the export;
            // their pay could not be loaded skips and names them.
            if let blocked = PrivatePayOverlayReadiness.blockMessage(scope: .forPerson(op)) {
                if blocked == PrivatePayOverlayReadiness.loadingMessage {
                    exportMessage = blocked
                    return
                }
                skippedPay.append(name(op))
                continue
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
            // RULEBOOK 1.47.0 §8 `signedTimesheetActions(change).mayExport`, re-checked on the fresh copy before
            // `exportedAt` is stamped: a reopened sheet is never exported on its stale snapshot.
            let change = SignedTimesheetChanges.change(
                draft: d,
                user: op,
                period: week,
                inputs: SignedTimesheetChanges.Inputs(
                    bookings: bookingStore.bookings,
                    managerBookings: managerScheduleStore.managerSiteBookings,
                    operatives: operativeStore.allOperatives,
                    projects: projectStore.projects,
                    smallWorks: projectStore.smallWorks,
                    organization: firebaseBackend.currentOrganization,
                    users: userStore.organizationUsers,
                    liveLoaded: gateReady()
                )
            )
            // No answer (the script did not run) is not a clean sheet: stop rather than export unchecked.
            guard let change else {
                exportMessage = TimesheetDraftStore.exportStoppedMessage
                return
            }
            if !CanonicalBusinessEngine.signedTimesheetActions(change).mayExport {
                // RULEBOOK 1.54.0 §8: a sheet held only by late extras is named with its own reason.
                if change.lateExtrasOnly {
                    skippedLateExtras.append(name(op))
                } else {
                    skippedChanged.append(name(op))
                }
                continue
            }
            // RULEBOOK 1.46.0: a snapshot the rulebook could not check is never exported (fail closed).
            if let refusal = TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
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
            ) {
                exportMessage = refusal
                return
            }
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
            // RULEBOOK 1.54.0 (third review of #337, web `stampTimesheetExport`): only the export fields — the signed
            // snapshot and `exportedAt` — in a transaction that re-reads the sheet and stamps nothing when it is already
            // exported or its late extras now wait for the line manager (a late extra added meanwhile is never overwritten).
            guard let exportedAt = row.draft.exportedAt,
                  let snapshot = TimesheetDraftStore.asFirestoreMap(row.draft)["weeklyReportOverride"] as? [String: Any] else { continue }
            let result: String
            do {
                result = try await firebaseBackend.stampTimesheetExport(
                    organizationId: exportOrgId,
                    userId: row.operative.id,
                    weekStart: week.start,
                    weeklyReportOverride: snapshot,
                    exportedAt: exportedAt,
                    // RULEBOOK 1.55.0 §8 (review of #243 M1): the version this snapshot was prepared from, only.
                    documentId: row.draft.versionDocumentId
                )
            } catch {
                stampError = "Couldn't export \(name(row.operative))'s timesheet: \(error.localizedDescription)"
                break
            }
            switch result {
            case "stamped":
                TimesheetDraftStore.save(row.draft, userId: row.operative.id, weekStart: week.start, weekEnd: week.end)
                TimesheetDraftStore.rememberLoadedCopy(row.draft, userId: row.operative.id, weekStart: week.start)
                stamped.append(row)
            case "late-extras-waiting":
                skippedLateExtras.append(name(row.operative))
            case "already-exported", "superseded":
                // RULEBOOK 1.55.0: `superseded` — a later revision exists; that one is exported on its own.
                skippedElsewhere.append(name(row.operative))
            default:
                continue
            }
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
        if !skippedChanged.isEmpty {
            let line = "\(skippedChanged.joined(separator: ", ")): \(CanonicalBusinessEngine.signedTimesheetExportSkippedMessage)"
            exportMessage = [exportMessage, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if !skippedLateExtras.isEmpty {
            let line = "\(skippedLateExtras.joined(separator: ", ")): \(CanonicalBusinessEngine.timesheetLateExtrasExportSkippedMessage)"
            exportMessage = [exportMessage, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if !skippedPay.isEmpty {
            let line = "\(skippedPay.joined(separator: ", ")): \(PrivatePayOverlayReadiness.exportSkippedMessage)"
            exportMessage = [exportMessage, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
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
            ),
            scope: .forPerson(live(row.user))
        ) {
            exportMessage = blocked
            return
        }
        var sheet = row.draft
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            let fresh = await TimesheetDraftStore.refreshFromCloudReporting(
                userId: live(row.user).id,
                weekStart: row.week.start,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
            // RULEBOOK 1.55.0 §8: only a fresh copy of the SAME version (an earlier version, or an open revision on
            // top, never replaces the version this row shows).
            if let draft = fresh.draft, draft.exportedAt != nil,
               row.draft.versionDocumentId == nil || draft.versionDocumentId == row.draft.versionDocumentId {
                sheet = draft
            }
        }
        let rebuilt = sheet.weeklyReportOverride == nil
        if rebuilt && !confirmedRebuild {
            rebuiltExportConfirmRow = row
            return
        }
        let taxIds = await InvoicePDFGenerationSupport.taxIdsForExport(
            subject: live(row.user),
            requested: includeTaxIdsInExport,
            userStore: userStore
        )
        let name = live(row.user).fullName.isEmpty ? live(row.user).email : live(row.user).fullName
        let attachment: TimesheetExportHelper.PDFAttachment
        do {
            attachment = try TimesheetExportHelper.makeSheetPDF(
            operative: live(row.user),
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

    /// RULEBOOK 1.55.0 §8: Download PDF of an earlier (frozen) version under an Exported row — built from that
    /// version's own stored copy (its snapshot), with its invoice number and REV label; never re-stamped.
    private func downloadEarlierVersionPDF(_ version: TimesheetVersionInfo, of row: ExportedTimesheetHistoryRow) {
        let chain = TimesheetVersionChainCache.chain(for: version.documentId)
        guard let decoded = TimesheetDraftStore.decodeFirestoreMap(FirebaseBackend.versionRow(version, chain: chain)) else {
            exportMessage = "Couldn't read this version of the timesheet."
            return
        }
        let earlierRow = ExportedTimesheetHistoryRow(id: "\(row.id)|\(version.documentId)", user: row.user, week: row.week, draft: decoded)
        Task { await downloadExportedPDF(earlierRow, confirmedRebuild: false) }
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
        /// RULEBOOK 1.55.0 §8: rows built from a pay run's version chain (one per pay run).
        var chainRows: [String: ExportedTimesheetHistoryRow] = [:]
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
                   limit: 400,
                   // RULEBOOK 1.55.0 §8: every version, grouped below into one row per pay run.
                   versions: .all
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
                // RULEBOOK 1.55.0 §8: an original and its revisions are one pay run — the row shows the latest EXPORTED
                // version, with the earlier versions under it (read only). Rows that are not timesheet versions stay.
                let chains = CanonicalBusinessEngine.timesheetVersionsForPeriod(cloudRows.compactMap { row in
                    (row["__documentId"] as? String).map { id in (documentId: id, data: row.filter { entry in !entry.key.hasPrefix("__") }) }
                }) ?? []
                var chained = Set<String>()
                for chain in chains {
                    for version in chain { chained.insert(version.documentId) }
                    TimesheetVersionChainCache.remember(chain)
                    guard let shownIndex = chain.lastIndex(where: { $0.exported }) else { continue }
                    let shown = chain[shownIndex]
                    let row = FirebaseBackend.versionRow(shown, chain: chain)
                    guard let weekStart = firestoreDate(row["weekStart"]),
                          let day = TimesheetDraftStore.organizationDay(weekStart),
                          let decoded = TimesheetDraftStore.decodeFirestoreMap(row) else { continue }
                    TimesheetDraftStore.rememberBounds(from: row, userId: user.id, weekStart: day)
                    weekStarts.insert(day)
                    let end = TimesheetDraftStore.storedPeriodEnd(userId: user.id, weekStart: day)
                    // The local copy of the pay run is its LATEST version: only saved when that is the one shown.
                    if shownIndex == chain.count - 1 {
                        TimesheetDraftStore.save(decoded, userId: user.id, weekStart: day, weekEnd: end)
                    }
                    let period = TimesheetPayrollPolicy.periodMatchingStoredStart(day, storedEnd: end, settings: settings)
                    let rowId = "\(user.id)|\(CanonicalBusinessEngine.dayKeyInOrganizationZone(period.start) ?? "")|\(CanonicalBusinessEngine.dayKeyInOrganizationZone(period.end) ?? "")"
                    chainRows[rowId] = ExportedTimesheetHistoryRow(
                        id: rowId,
                        user: user,
                        week: period,
                        draft: decoded,
                        earlier: CanonicalBusinessEngine.timesheetEarlierVersions(Array(chain[...shownIndex]))
                    )
                }
                for row in cloudRows where !chained.contains((row["__documentId"] as? String) ?? "") {
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
                // RULEBOOK 1.55.0 §8: a pay run read with its versions keeps that row (latest exported version).
                if chainRows[rowId] != nil { continue }
                byId[rowId] = ExportedTimesheetHistoryRow(
                    id: rowId,
                    user: user,
                    week: period,
                    draft: draft
                )
            }
        }

        for (rowId, row) in chainRows { byId[rowId] = row }
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
    /// RULEBOOK §8 (review of #240): a person kept on a row, as the roster holds them now (pay laid over).
    private func live(_ user: AppUser) -> AppUser { UserStore.livePerson(user, in: userStore.organizationUsers) }

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
    /// RULEBOOK 1.55.0 §8: the pay run's earlier versions (before the one this row shows), newest first, read only.
    var earlier: [TimesheetVersionInfo] = []
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
            return "Counter-signed and ready. Email and export sends timesheet PDFs to your email for filing. Once exported a timesheet never changes; a correction is made as a revision."
        case .exported:
            // RULEBOOK 1.55.0 §8: exported timesheets never change; corrections are revisions (REV 1, REV 2 …).
            return "Exported timesheets stay here for years and never change. A correction is made as a revision (REV 1, REV 2 …); earlier versions are listed under the latest."
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
    /// The person as passed in. Pricing and decisions use `operative`, the person as the roster holds them now.
    private let operativeSeed: AppUser
    let settings: OrganizationInvoicingSettings
    let week: WeekRange

    init(operative: AppUser, settings: OrganizationInvoicingSettings, week: WeekRange) {
        self.operativeSeed = operative
        self.settings = settings
        self.week = week
    }

    /// RULEBOOK §8 (review of #240): the reviewed person with their pay laid over now — looked up again by id, never the
    /// copy a list kept from before the roster's pay profiles arrived.
    private var operative: AppUser { UserStore.livePerson(operativeSeed, in: userStore.organizationUsers) }
    @State private var draft = TimesheetDraft()
    @State private var showingManagerSignSheet = false
    /// RULEBOOK 1.47.0 §8: the counter-signature of a reopened sheet rebuilds its snapshot on the save that follows.
    @State private var rebuildSnapshotOnSave = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    /// Pay-rate history read state: a failed read blocks sign-off, the agreed snapshot, invoices and exports.
    @State private var payInputsState: PayInputsLoadState = .loading
    /// Why pay cannot be worked out yet, else nil (`PayInputsLoad.blockMessage`).
    private var payInputsBlockMessage: String? {
        if periodLoadFailed { return TimesheetDraftStore.periodReadFailedMessage }
        if let blocked = PayInputsLoad.blockMessage(
            state: payInputsState,
            organization: firebaseBackend.currentOrganization,
            bookings: periodBookingsState,
            scope: .forPerson(operative)
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
    /// RULEBOOK 1.54.0 §8: the late extra whose amount the reviewer is editing (⚙).
    @State private var editingLateExtraId: String?
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
        // RULEBOOK 1.55.0 §8 / §16 ("lock all"): an exported timesheet never changes, admins included — a correction is
        // a revision (Create revision below).
        if TimesheetApprovalPolicy.isExported(draft) { return false }
        // RULEBOOK 1.47.0 §8: while the person must sign the changed bookings again nothing is reviewed or
        // counter-signed; once they have, the line manager reviews and counter-signs again.
        if bookingChange?.waitingForPerson == true { return false }
        // RULEBOOK 1.54.0 §8: late extras alone open only the late extras for review (below), never the signed lines.
        return TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: operative)
            && (TimesheetApprovalPolicy.recordedSignatureDate(draft.managerSignedAt) == nil
                || (bookingChange?.waitingForLineManager == true && bookingChange?.lateExtrasOnly != true))
            && TimesheetApprovalPolicy.operativeHasSigned(draft)
            && !TimesheetApprovalPolicy.isExported(draft)
    }

    /// RULEBOOK 1.47.0 §8 `signedTimesheetBookingChanges` for the subject's sheet (nil until the pay run's bookings
    /// have loaded).
    private var bookingChange: RulebookSignedTimesheetChange? {
        guard SignedTimesheetChanges.isSigned(draft) else { return nil }
        let inputs = SignedTimesheetChanges.Inputs(
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            organization: firebaseBackend.currentOrganization,
            users: userStore.organizationUsers,
            // The person's ids come from the operatives list too (web third review #325): wait for it.
            liveLoaded: periodBookingsState.loaded && operativesLoaded
        )
        return SignedTimesheetChanges.change(
            draft: draft, user: operative, period: week, inputs: inputs, lines: payrollSummary.lineItems
        )
    }

    /// The operatives list of the open organisation has loaded (the person's booking ids depend on it).
    private var operativesLoaded: Bool {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return false }
        return operativeStore.finishedLoadOrganizationId == orgId && !operativeStore.isLoading
    }

    /// RULEBOOK 1.47.0 §8 (review of #234 item 5): the booking-change answer is ready (the pay run's bookings and the
    /// operatives list loaded, the script answered). Until then nothing is counter-signed: "not loaded" is not "unchanged".
    private var bookingCheckReady: Bool {
        guard SignedTimesheetChanges.isSigned(draft) else { return true }
        return periodBookingsState.loaded && operativesLoaded && bookingChange != nil
    }

    /// Review of #234 (B): the check cannot run right now — the bookings read failed (offline) or the operatives list
    /// stopped without finishing. The screen then says so with Retry instead of "Checking…".
    private var bookingCheckUnavailable: Bool {
        guard SignedTimesheetChanges.isSigned(draft), !bookingCheckReady else { return false }
        return SignedTimesheetCheckAvailability.unavailable(
            bookingsFailed: periodBookingsState.failed,
            operativesLoaded: operativesLoaded,
            operativesStalled: SignedTimesheetCheckAvailability.operativesStalled(
                operativeStore, organizationId: firebaseBackend.currentOrganization?.firestoreDocumentId
            )
        )
    }

    /// Retry: the pay run's bookings (a failed read is asked again), the operatives list when it stalled, and the pay
    /// inputs.
    private func retryBookingCheck() {
        ensurePeriodBookings()
        if SignedTimesheetCheckAvailability.operativesStalled(
            operativeStore, organizationId: firebaseBackend.currentOrganization?.firestoreDocumentId
        ) {
            operativeStore.loadData()
        }
        Task { await loadDayRateHistory() }
    }

    /// RULEBOOK 1.47.0 §8: a reopened sheet's figures are the live bookings, never its stale snapshot. 1.54.0: late
    /// extras alone never discard the snapshot; its late rows count only while still approved.
    private var draftForFigures: TimesheetDraft {
        guard bookingChange?.reopened == true, bookingChange?.bookingsChanged != false, draft.weeklyReportOverride != nil else {
            return TimesheetLateExtrasSupport.draftWithCurrentLateRows(draft)
        }
        var live = draft
        live.weeklyReportOverride = nil
        return live
    }

    private var managerHasSigned: Bool {
        TimesheetApprovalPolicy.recordedSignatureDate(draft.managerSignedAt) != nil
    }

    /// RULEBOOK 1.22.0 §8 `CanonicalBusinessEngine.timesheetTotals`: decided once signed or while this viewer reviews
    /// it; a reviewer before signing sees their own labour reviews and entry decisions (web `draftTimesheetTotals`).
    private var reviewTotals: RulebookTimesheetTotals? {
        TimesheetTotalsSource.totals(
            lines: payrollSummary.lineItems,
            draft: draftForFigures,
            // RULEBOOK 1.55.0: a revision is priced `decided` for everyone.
            decided: managerHasSigned || canManagerReview || (draft.revision ?? 0) > 0,
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
            .sheet(isPresented: Binding(get: { editingLateExtraId != nil }, set: { if !$0 { editingLateExtraId = nil } })) {
                if let id = editingLateExtraId, let item = draft.lateExtras?.first(where: { $0.id == id }) {
                    TimesheetManagerAmountEditSheet(
                        title: item.isPriceWork ? "Edit price work" : "Edit expense",
                        subtitle: item.title,
                        originalAmount: item.managerRevisedAmount ?? item.amount,
                        onSave: { value in applyLateExtraAmount(id, entered: value) },
                        onDelete: nil
                    )
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
                onSaveDraft: { saveDraft() },
                onCounterSignSave: { saveDraft() },
                counterSignAllowed: counterSignAllowedNow
            ))
    }

    private var reviewScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                reviewHeaderCard
                reviewBreakdownCard
                reviewExpensesCard
                reviewPriceWorkCard
                reviewLateExtrasCard
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
            HStack(spacing: 8) {
                Text(week.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // RULEBOOK 1.55.0 §8: "REV 1" on a revision.
                if !TimesheetDraftStore.revisionLabel(for: draft).isEmpty {
                    TimesheetRevisionBadge(label: TimesheetDraftStore.revisionLabel(for: draft))
                }
            }
            statusLine
            if let saveErrorMessage {
                Label(saveErrorMessage, systemImage: "exclamationmark.icloud.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("operativeTimesheetReview.saveError")
            }
            if bookingCheckUnavailable {
                // Review of #234 (B): the bookings or the operatives list could not be read — say so, with Retry.
                PayInputsFailureBanner(message: SignedTimesheetCheckAvailability.unavailableMessage) {
                    retryBookingCheck()
                }
            } else if let blocked = payInputsBlockMessage {
                PayInputsFailureBanner(message: blocked) {
                    retryBookingCheck()
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
            // RULEBOOK 1.54.0 §8 `timesheetLateExtrasSummary(...).pending`: late extras still waiting (not in any figure).
            if let pending = lateExtrasSummary?.pending, pending > 0 {
                Text("\(pending) added after sign-off waiting for a decision (not in the total)")
                    .font(.caption)
                    .foregroundStyle(PPColor.warningAmber)
            }
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

    /// RULEBOOK 1.54.0 §8 `timesheetLateExtrasSummary` for this sheet (nil without late extras).
    private var lateExtrasSummary: RulebookLateExtrasSummary? {
        TimesheetLateExtrasSupport.summary(draft)
    }

    /// RULEBOOK 1.54.0 §8 `timesheetLateExtraReviewable(decision, { exported })` for one late extra, for this viewer:
    /// the line manager or an admin (never the person), after the line manager signed, never once exported, never an
    /// ignored one (its id is a signed entry's) and never while the person must sign changed bookings again.
    private func canReviewLateExtra(_ item: TimesheetLateExtra) -> Bool {
        guard viewerIsReviewer, managerHasSigned, bookingChange?.waitingForPerson != true else { return false }
        return CanonicalBusinessEngine.timesheetLateExtraReviewable(
            state: item.lateState ?? "pending",
            exported: TimesheetLateExtrasSupport.exportedStored(draft)
        )
    }

    @ViewBuilder
    private var reviewLateExtrasCard: some View {
        if let late = draft.lateExtras, !late.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Added after sign-off")
                    .font(.headline)
                if late.contains(where: canReviewLateExtra) {
                    Text(CanonicalBusinessEngine.timesheetLateExtrasReviewerMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(late) { item in
                    lateExtraReviewRow(item)
                    ClaimEvidenceLinks(evidence: item.evidence, legacyReceiptName: item.receiptName)
                }
            }
            .padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("operativeTimesheetReview.lateExtras")
        }
    }

    /// One late extra with ✓ ✕ ⚙ (nothing pre-selected while it is pending) or, when it cannot be reviewed, its label.
    @ViewBuilder
    private func lateExtraReviewRow(_ item: TimesheetLateExtra) -> some View {
        let reviewable = canReviewLateExtra(item)
        let subtitle = item.isPriceWork
            ? "Price work · Agreed with: \(item.agreedManagerName) · \(item.date.formatted(date: .abbreviated, time: .omitted)) · \(CanonicalBusinessEngine.priceWorkJobNumberText(item.jobNumber))"
            : "Expense · \(item.date.formatted(date: .abbreviated, time: .omitted)) · \(item.jobNumber.isEmpty ? "—" : item.jobNumber)"
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(item.managerDecision == .declined)
                Text(Self.extraSubtitle(subtitle, evidenceCount: item.evidence.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !reviewable, let label = CanonicalBusinessEngine.timesheetLateExtraLabel(state: item.lateState ?? "pending", reason: item.lateReason) {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PPColor.warningAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if reviewable {
                    HStack(spacing: 14) {
                        Button { updateLateExtraDecision(item.id, decision: .approved) } label: {
                            Image(systemName: item.managerDecision == .approved || item.managerDecision == .edited ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .accessibilityLabel("Approve")
                        .accessibilityIdentifier("operativeTimesheetReview.lateExtra.approve")
                        .foregroundStyle(Color.green)
                        Button { updateLateExtraDecision(item.id, decision: .declined) } label: {
                            Image(systemName: item.managerDecision == .declined ? "xmark.circle.fill" : "xmark.circle")
                        }
                        .accessibilityLabel("Decline")
                        .accessibilityIdentifier("operativeTimesheetReview.lateExtra.decline")
                        .foregroundStyle(Color.red)
                        Button { editingLateExtraId = item.id } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Edit amount")
                        .accessibilityIdentifier("operativeTimesheetReview.lateExtra.edit")
                        .foregroundStyle(Color.secondary)
                    }
                    .font(.title3)
                    .buttonStyle(.borderless)
                    .onlineOnly(isOnline: smartCache.isOnline)
                }
            }
            Spacer()
            let shown = item.managerDecision == .edited ? (item.managerRevisedAmount ?? item.amount) : item.amount
            Text(OrgMoney.format(shown))
                .fontWeight(.semibold)
                .strikethrough(item.managerDecision == .declined)
        }
    }

    /// The reviewer's ✓ / ✕ on one late extra; the save writes its review (`lateExtra: true`) with the snapshot.
    private func updateLateExtraDecision(_ id: String, decision: TimesheetManagerDecision, revisedAmount: Double? = nil) {
        guard var late = draft.lateExtras, let index = late.firstIndex(where: { $0.id == id }),
              canReviewLateExtra(late[index]) else { return }
        late[index].managerDecision = decision
        late[index].managerRevisedAmount = revisedAmount
        draft.lateExtras = late
        saveDraft()
    }

    /// ⚙: the reviewer's revised amount for one late extra (in pennies, `roundPennies`), as for a signed entry.
    private func applyLateExtraAmount(_ id: String, entered: Double) {
        guard let item = draft.lateExtras?.first(where: { $0.id == id }) else { return }
        let revised = CanonicalBusinessEngine.roundPennies(entered)
        if abs(revised - item.amount) < 0.01 {
            updateLateExtraDecision(id, decision: .approved)
        } else {
            updateLateExtraDecision(id, decision: .edited, revisedAmount: revised)
        }
        editingLateExtraId = nil
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

    /// RULEBOOK 1.55.0 §8: the versions before the one shown, read only (`timesheetEarlierVersions`).
    private var earlierVersions: [TimesheetVersionInfo] {
        let chain = TimesheetVersionChainCache.chain(for: draft.versionDocumentId)
        guard chain.last?.documentId == draft.versionDocumentId else { return [] }
        return CanonicalBusinessEngine.timesheetEarlierVersions(chain)
    }

    /// RULEBOOK 1.55.0 §8 `timesheetRevisionDue` of the subject's exported sheet (bookings changed since export).
    private var revisionDue: RulebookTimesheetRevisionDue {
        guard TimesheetApprovalPolicy.isExported(draft) else { return .notDue }
        return TimesheetDraftStore.revisionDue(for: draft, userId: operative.id, weekStart: week.start, change: bookingChange)
    }

    /// RULEBOOK 1.55.0 §8 `canCreateTimesheetRevision`: this viewer (an admin or the person's line manager,
    /// `timesheetWriterIsReviewer`) may create the next revision of this exported latest version ("Create revision").
    private var reviewerMayCreateRevision: Bool {
        guard viewerIsReviewer, TimesheetApprovalPolicy.isExported(draft), let viewer = userStore.displayUser else { return false }
        let chain = TimesheetDraftStore.latestVersionChain(for: draft, userId: operative.id, weekStart: week.start)
        let reviewerInput: [String: Any] = [
            "writerUserId": viewer.id,
            "subjectUserId": operative.id,
            "writerIsAdmin": viewer.isRosterAdmin,
            "writerFormerIds": viewer.formerUserIds,
            "writerAliasIds": viewer.sameEmailUserIds,
            "subjectLineManagerIds": RulebookRosterSnapshot.lineManagerIds(operative) ?? [],
            "roster": RulebookRosterSnapshot.roster,
        ]
        return CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: reviewerInput, chain: chain, writerIsSubject: false)?.allowed == true
    }

    @State private var isCreatingRevision = false

    /// RULEBOOK 1.55.0 §8: a reviewer's "Create revision" — creates `…_rev{N}`, tells the person
    /// (`timesheet_revision_to_sign`), then shows the new (open) revision.
    private func createRevisionForPerson() {
        guard !isCreatingRevision, let viewer = userStore.displayUser,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // The live lines decide which labour decisions the revision keeps: only once bookings and pay inputs loaded.
        if let blocked = payInputsBlockMessage {
            saveErrorMessage = blocked
            return
        }
        isCreatingRevision = true
        let subject = operative
        let lines = payrollSummary.lineItems
        Task {
            let result = await TimesheetDraftStore.createRevision(
                subject: subject,
                weekStart: week.start,
                writer: viewer,
                writerIsSubject: false,
                liveLines: lines,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
            if let created = result.documentId {
                await notificationService.notifyTimesheetRevisionToSign(subject: subject, revisionDocumentId: created, weekStart: week.start)
            }
            // Created, or already open (review of #243 L1): show the open revision and listen to it.
            if result.documentId != nil || result.revisionOpen {
                await refreshDraftFromCloud()
                await MainActor.run { listenToServerTimesheet() }
            }
            await MainActor.run {
                isCreatingRevision = false
                // An already-open revision is simply opened (no error).
                saveErrorMessage = result.revisionOpen ? nil : result.message
            }
        }
    }

    @ViewBuilder
    private var reviewSignOffSection: some View {
        // RULEBOOK 1.47.0 §8: the reviewer's note — back with the person, counter-sign again, or (exported) a warning.
        // RULEBOOK 1.55.0 §8: on an exported sheet whose bookings changed, the revision note instead.
        if revisionDue.due {
            SignedTimesheetChangedBanner(message: revisionDue.reviewerMessage ?? CanonicalBusinessEngine.timesheetRevisionDueReviewerMessage)
        } else if let note = bookingChange?.reviewerMessage {
            SignedTimesheetChangedBanner(message: note)
        }
        if reviewerMayCreateRevision {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: createRevisionForPerson) {
                    Label(isCreatingRevision ? "Creating revision…" : CanonicalBusinessEngine.timesheetCreateRevisionLabel, systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("operativeTimesheetReview.createRevision")
                .buttonStyle(.plain)
                .disabled(isCreatingRevision)
                .onlineOnly(isOnline: smartCache.isOnline)
                Text(CanonicalBusinessEngine.timesheetCreateRevisionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if !earlierVersions.isEmpty {
            TimesheetEarlierVersionsList(versions: earlierVersions)
        }
        if bookingChange?.lateExtrasOnly == true {
            // RULEBOOK 1.54.0 §8: only late extras wait — each ✓ / ✕ saves with the snapshot; no counter-signature.
            EmptyView()
        } else if bookingChange?.waitingForLineManager == true, viewerIsReviewer {
            if needsExtrasReviewMessage {
                Text("Approve, decline or edit every expense and price-work line before signing off.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(action: handleSignOffTapped) {
                Label("Counter-sign again", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityIdentifier("operativeTimesheetReview.counterSignAgain")
            .buttonStyle(.plain)
            .disabled(!bookingCheckReady || !CanonicalBusinessEngine.signedTimesheetActions(bookingChange).lineManagerMayCounterSign)
            .onlineOnly(isOnline: smartCache.isOnline)
        } else if bookingChange?.reopened == true {
            EmptyView()
        } else if TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Signed off", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color.green)
                    .background(Color.green.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // RULEBOOK 1.55.0 §8: once exported a timesheet never changes; a correction is a revision.
                Text(TimesheetApprovalPolicy.isExported(draft)
                     ? "Exported timesheets never change. A correction is made as a revision (REV 1, REV 2 …), signed again by the person and you."
                     : "Signed off. Once exported it never changes; a later correction is made as a revision.")
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
            .disabled(!TimesheetApprovalPolicy.operativeHasSigned(draft) || !bookingCheckReady)
            .opacity(TimesheetApprovalPolicy.operativeHasSigned(draft) && bookingCheckReady ? 1 : 0.5)
            // RULEBOOK §2: timesheet signing is online only.
            .onlineOnly(isOnline: smartCache.isOnline)
            if TimesheetApprovalPolicy.operativeHasSigned(draft), !bookingCheckReady, !bookingCheckUnavailable {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(SignedTimesheetCheckAvailability.checkingMessage)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("operativeTimesheetReview.checkingBookings")
            }
        }
    }

    private var needsExtrasReviewMessage: Bool {
        TimesheetDraftAdjustments.extrasPendingReview(in: draft)
            && (!draft.expenseEntries.isEmpty || !draft.priceWorkEntries.isEmpty || !(draft.lateExtras ?? []).isEmpty)
    }

    /// RULEBOOK 1.47.0 §8 (review of #234 item 5): the counter-signature waits for the booking-change check and follows
    /// `signedTimesheetActions(change).lineManagerMayCounterSign`; the reason is shown when it may not.
    private func counterSignAllowedNow() -> Bool {
        guard bookingCheckReady else {
            saveErrorMessage = (bookingCheckUnavailable ? SignedTimesheetCheckAvailability.unavailableMessage : "Still checking the bookings on this timesheet. Try again in a moment.")
            return false
        }
        guard CanonicalBusinessEngine.signedTimesheetActions(bookingChange).lineManagerMayCounterSign else {
            saveErrorMessage = bookingChange?.reviewerMessage
            return false
        }
        return true
    }

    private func handleSignOffTapped() {
        // RULEBOOK 1.30.2: nobody counter-signs their own sheet (`timesheetWriterIsReviewer`).
        guard viewerIsReviewer else { return }
        // RULEBOOK 1.47.0 §8 `signedTimesheetActions`: no counter-signature while the person must sign again; a
        // counter-signature of a reopened sheet rebuilds the snapshot from the live bookings.
        ensurePeriodBookings()
        guard counterSignAllowedNow() else { return }
        let actions = CanonicalBusinessEngine.signedTimesheetActions(bookingChange)
        rebuildSnapshotOnSave = actions.rebuildSnapshot
        // RULEBOOK 1.43.0 §8 (review r318): tapping re-checks the period's bookings (reloads them when no server answer
        // covers the period), so a stuck "Loading bookings…" recovers.
        ensurePeriodBookings()
        // Nothing is counter-signed (and frozen) until pay can be worked out from loaded inputs.
        if let blocked = payInputsBlockMessage {
            saveErrorMessage = blocked
            return
        }
        if TimesheetDraftAdjustments.extrasPendingReview(in: draft)
            && (!draft.expenseEntries.isEmpty || !draft.priceWorkEntries.isEmpty || !(draft.lateExtras ?? []).isEmpty) {
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

    /// Returns the cloud save's task (started here, as before) so the counter-signature can play its feedback once the
    /// save has answered (guide §4). Nil when nothing was sent.
    @discardableResult
    private func saveDraft() -> Task<String?, Never>? {
        // RULEBOOK 1.43.0 (review r318, 2nd round): nothing is saved while the period's sheet could not be read.
        guard !periodLoadFailed else {
            saveErrorMessage = TimesheetDraftStore.periodReadFailedMessage
            return nil
        }
        // A counter-signature never saves without its snapshot (review of #240): while pay inputs (bookings, history or
        // the roster's pay-profile overlay) are not ready, the save is refused rather than saved unfrozen.
        if let refusal = TimesheetWeeklyReportOverrideBuilder.saveRefusalWhilePayInputsBlocked(
            draft: draft,
            user: operative,
            writerIsReviewer: userStore.displayUser.map {
                TimesheetApprovalPolicy.writerIsReviewer(
                    writerId: $0.id,
                    writer: $0,
                    subjectUserId: operative.id,
                    subject: operative
                )
            },
            blockMessage: payInputsBlockMessage,
            rebuildSnapshot: rebuildSnapshotOnSave
        ) {
            saveErrorMessage = refusal
            return nil
        }
        // The agreed snapshot is never frozen from inputs that did not load (`PayInputsLoad`).
        if payInputsBlockMessage == nil || draft.weeklyReportOverride != nil {
        // RULEBOOK 1.46.0: a snapshot the rulebook could not check is never saved (fail closed).
        let refusal = TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
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
            snapshotInputsReady: payInputsBlockMessage == nil,
            // RULEBOOK 1.47.0 §8 `rebuildSnapshot`: only on the save after a counter-signature of a reopened sheet.
            rebuildSnapshot: rebuildSnapshotOnSave && payInputsBlockMessage == nil
        )
        if let refusal {
            saveErrorMessage = refusal
            return nil
        }
        }
        rebuildSnapshotOnSave = false
        TimesheetDraftStore.save(draft, userId: operative.id, weekStart: week.start, weekEnd: week.end)
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return nil }
        let snapshot = draft
        let writer = userStore.displayUser
        let subject = operative
        return Task {
            // Owner-or-reviewer partial write, plus changed `extraEntryReviews` (`timesheetEntryReviewWriteFields`).
            let message = await TimesheetDraftStore.saveToCloud(
                snapshot,
                userId: subject.id,
                weekStart: week.start,
                weekEnd: week.end,
                firebaseBackend: firebaseBackend,
                organizationId: orgId,
                writer: writer,
                subject: subject
            )
            saveErrorMessage = message
            return message
        }
    }

    private static let liveTimesheetKey = "timesheet.review"

    private var isEditingReview: Bool {
        showingManagerSignSheet || editingPayrollLineId != nil || editingExpenseId != nil || editingPriceWorkId != nil
            || editingLateExtraId != nil
    }

    private func listenToServerTimesheet() {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        firebaseBackend.listenTimesheetState(
            key: Self.liveTimesheetKey,
            organizationId: orgId,
            userId: operative.id,
            weekStart: week.start,
            // RULEBOOK 1.55.0 §8: the version loaded (a revision once one exists), never also the frozen original.
            documentId: draft.versionDocumentId
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
    /// The same save as `onSaveDraft`, returning its task so the counter-signature plays its feedback once the save
    /// has answered (feedback guide §4 `timesheetSigned`).
    let onCounterSignSave: () -> Task<String?, Never>?
    /// RULEBOOK 1.47.0 §8: whether the counter-signature may be saved now (the review screen's check; it shows why not).
    let counterSignAllowed: () -> Bool

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
    /// Returns a refusal message when nothing was saved, else nil.
    private func applyPayrollReviewSave(lineId: String, edit: TimesheetPayrollLineBookingLookup.Edit) -> String? {
        guard edit.error == nil, edit.amounts != nil else { return edit.error ?? CanonicalBusinessEngine.payrollLineEditTimesMessage }
        // Review of #233: a line's current review the rulebook could not check refuses the edit (fail closed).
        guard let reviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: lineId, draft: draft) else {
            return TimesheetWeeklyReportOverrideBuilder.rulebookCheckFailedMessage
        }
        draft.payrollLineReviews = reviews
        editingPayrollLineId = nil
        onSaveDraft()
        return nil
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
                // RULEBOOK 1.47.0 §8 (review of #234 item 5): re-checked when the signature is saved — never counter-sign
                // before the booking-change check could run, nor a sheet waiting for the person.
                guard counterSignAllowed() else {
                    showingManagerSignSheet = false
                    Feedback.play(.actionRefused)
                    return
                }
                guard TimesheetDraftStore.applySignOff(
                    to: &draft,
                    role: "manager",
                    signedAt: Date(),
                    signedByName: signedByName,
                    signedByUserId: userStore.displayUser?.id,
                    signatureImageBase64: signatureImageData.base64EncodedString()
                ) else {
                    Feedback.play(.actionRefused)
                    return
                }
                let counterSignSave = onCounterSignSave()
                let signer = draft.managerSignedByName ?? "Line manager"
                let operativeName = operative.fullName.isEmpty ? operative.email : operative.fullName
                let revision = draft.revision
                Task {
                    await notificationService.notifyTimesheetSignedByManager(
                        targetUserId: operative.id,
                        signedByName: signer,
                        weekStart: week.start,
                        revision: revision
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
                // Feedback guide §4: once the counter-signature's save has answered (it is not delayed by this).
                if let counterSignSave {
                    Task {
                        let message = await counterSignSave.value
                        Feedback.play(FeedbackDecision.event(refusal: message, success: .timesheetSigned))
                    }
                } else {
                    Feedback.play(.actionRefused)
                }
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
        // Review of #243 (L4): the invoice number needs the version the sheet was read from.
        if let user = userStore.displayUser {
            let local = TimesheetDraftStore.load(userId: user.id, weekStart: period.startDate)
            _ = await TimesheetDraftStore.ensureVersionRead(local, userId: user.id, weekStart: period.startDate, firebaseBackend: firebaseBackend)
        }
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
        // RULEBOOK 1.53.0: the total in pennies (`roundPennies`).
        let total = CanonicalBusinessEngine.roundPennies(rows.reduce(0) { $0 + $1.amount })
        let notes = rateChangeNotes(
            for: period,
            currentUser: currentUser,
            operatives: operatives,
            dayRateHistoryCollection: history
        )
        // RULEBOOK 1.55.0 §8: the invoice number and, on a revision, the difference from the previous version.
        let copy = TimesheetDraftStore.revisionCopy(
            for: TimesheetDraftStore.load(userId: currentUser.id, weekStart: period.startDate),
            subjectId: currentUser.id,
            weekStart: period.startDate,
            total: total,
            currency: OrganizationRulebookContext.currencyCode
        )
        var context = InvoicePDFBuilder.Context(
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
        context.invoiceNumber = copy.invoiceNumber
        context.revisionNote = copy.note
        guard let url = InvoicePDFBuilder.makePDF(context: context) else { return nil }
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
        // RULEBOOK 1.10.0 §8 `timesheetInvoiceRows`: the signed snapshot first, else the live lines; PAYE and leave
        // lines never go on an invoice. 1.53.0 (B12): `decided` once the line manager has signed (their review
        // decisions apply), `raw` before (the owner's draft at the amounts entered).
        // RULEBOOK 1.55.0: a revision's invoice is `decided` (its copied decisions stand).
        let extrasMode: TimesheetInvoiceRows.ExtrasMode = draft.managerSignedAt != nil || (draft.revision ?? 0) > 0 ? .decided : .raw
        let rows = TimesheetInvoiceRows.rows(
            for: currentUser, summary: summary, draft: draft, extrasMode: extrasMode, period: period.startDate...period.endDate
        )
        let sorted = InvoiceLineItem.invoiceLines(rows).sorted {
            if $0.date == $1.date {
                return $0.projectName < $1.projectName
            }
            return $0.date < $1.date
        }
        // RULEBOOK 1.45.0 §8: the evidence pages of this invoice's price work and expense rows.
        let evidence = TimesheetInvoiceRows.evidencePages(
            for: currentUser, summary: summary, draft: draft, extrasMode: extrasMode, period: period.startDate...period.endDate
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
enum TimesheetInvoiceRows {
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
        // RULEBOOK 1.54.0 §8: approved late extras are invoice rows (`timesheetInvoiceRows` reads them from the sheet).
        let sheet = TimesheetLateExtrasSupport.rulebookSheet(draft)
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
        // RULEBOOK 1.54.0 §8: an approved late extra's row (`timesheetInvoiceRows` adds only approved ones).
        let late = Dictionary((draft.lateExtras ?? []).map { (key($0.id), $0) }, uniquingKeysWith: { first, _ in first })

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
                    // RULEBOOK 1.61.0 §8: a signed overtime line reads in hours from its stored hours, days and amount
                    // when its multiplier is known (stored, or in its stored multiplied text) — never re-priced and
                    // never a guessed ×1. Its divisor is its own paid day (paid hours ÷ days); the day rate is the one
                    // that gave the signed amount (amount ÷ days ÷ multiplier, unrounded).
                    let storedMultiplier = line.otMultiplier ?? CanonicalBusinessEngine.parseMultipliedHoursText(line.details)?.multiplier
                    if line.isOvertime, let multiplier = storedMultiplier, multiplier > 0, line.days > 0.0001, line.paidHours > 0 {
                        item.otMultiplier = multiplier
                        item.dayRateDivisor = line.paidHours / line.days
                        item.baseDayRate = amount / line.days / multiplier
                    }
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
                } else if let entry = late[key(id)], entry.isPriceWork {
                    rows.append(moneyRow(prefix: "pw", id: entry.id, date: entry.date, jobNumber: CanonicalBusinessEngine.priceWorkJobNumberText(entry.jobNumber), projectName: "Price work", details: entry.title, amount: amount))
                }
            case "expense":
                if fromOverride, let line = overrideExpenses[key(id)] {
                    rows.append(moneyRow(prefix: "exp", id: line.id, date: line.date, jobNumber: line.jobNumber.isEmpty ? "—" : line.jobNumber, projectName: "Expense", details: line.title, amount: amount))
                } else if let entry = expenses[key(id)] {
                    rows.append(moneyRow(prefix: "exp", id: entry.id.uuidString, date: entry.date, jobNumber: entry.jobNumber.isEmpty ? "—" : entry.jobNumber, projectName: "Expense", details: entry.title, amount: amount))
                } else if let entry = late[key(id)], !entry.isPriceWork {
                    rows.append(moneyRow(prefix: "exp", id: entry.id, date: entry.date, jobNumber: entry.jobNumber.isEmpty ? "—" : entry.jobNumber, projectName: "Expense", details: entry.title, amount: amount))
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

struct InvoiceLineItem {
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
    /// RULEBOOK 1.61.0 §8 (display only): an overtime line's multiplier, the person's own day rate (never multiplied)
    /// and the line's day-rate divisor, so a day-rate overtime line reads in hours (`dayRateOvertimeText`). Nil when
    /// unknown (the older "hours · rate" text stays).
    var otMultiplier: Double? = nil
    var baseDayRate: Double? = nil
    var dayRateDivisor: Double? = nil

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

    /// RULEBOOK 1.61.0 §8 `dayRateOvertimeCalcText`: the whole hours-and-rate text of a day-rate overtime line, e.g.
    /// "6h × 1.5 = 9h · 9h × £26.47/h (rounded) = £238.24 (£225.00/day ÷ 8.5h)". Nil for every other line (standard,
    /// hourly, PAYE) or when the multiplier, day rate or divisor is unknown.
    var dayRateOvertimeText: String? {
        guard isOvertimeLine, !isPayeDay, payrollBasis == .dayRate,
              let multiplier = otMultiplier, multiplier > 0,
              let dayRate = baseDayRate, dayRate > 0,
              let divisor = dayRateDivisor, divisor >= 1 else { return nil }
        // The clock hours and any unpaid break come from the line's multiplied text when it has one (1.20.3);
        // otherwise the line's hours are its clock hours at the multiplier.
        let parsed = CanonicalBusinessEngine.parseMultipliedHoursText(details)
        guard let calc = CanonicalBusinessEngine.dayRateOvertimeCalc(
            clockHours: parsed?.clockHours ?? paidHours,
            multiplier: multiplier,
            breakHours: parsed?.breakHours ?? 0,
            dayRate: dayRate,
            dayRateHours: divisor,
            pay: amount
        ) else { return nil }
        // Owner 17 Nov: the amount is priced first and the text only shows it. The text is used only when it shows this
        // line's own figures — its hours sum the line's paid hours at the multiplier, its £ the line's amount in pennies;
        // otherwise the older wording stays and the amount is unchanged.
        guard abs(calc.paidHours - paidHours * multiplier) <= 0.005,
              calc.pay == CanonicalBusinessEngine.roundPennies(amount) else { return nil }
        return calc.text
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
        // RULEBOOK 1.61.0: the live overtime line's multiplier and divisor; its `dayRate` is the multiplied rate.
        if payrollLine.isOvertimeLine, let multiplier = payrollLine.otMultiplier, multiplier > 0 {
            self.otMultiplier = multiplier
            // The person's own day rate when the collector gave it, so the hourly rate shown is exactly day rate ÷
            // divisor in pennies (`dayRateHourlyEquivalent`); the multiplied rate ÷ N need not give it back exactly.
            self.baseDayRate = payrollLine.otBaseDayRate ?? payrollLine.dayRate / multiplier
            self.dayRateDivisor = payrollLine.standardDayHours
        }
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
        /// RULEBOOK 1.55.0 §8: "TS-20261101-6A9632" (+ "-REV1" on a revision; `timesheetInvoiceNumberForRevision`).
        var invoiceNumber: String = ""
        /// RULEBOOK 1.55.0 §8: "REV 1 · +£44.12 from the previous version" (`TimesheetRevisionCopy.note`), or "".
        var revisionNote: String = ""
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
        // RULEBOOK 1.55.0 §8: the invoice number on every invoice and timesheet, and on a revision what changed.
        if !context.invoiceNumber.isEmpty || !context.revisionNote.isEmpty {
            if !context.invoiceNumber.isEmpty {
                drawMeta(label: "INVOICE NO.", value: context.invoiceNumber, x: leftX, y: nextRowY)
            }
            if !context.revisionNote.isEmpty {
                drawMeta(label: "REVISION", value: context.revisionNote, x: rightX, y: nextRowY)
            }
            nextRowY += 40
        }
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
            // RULEBOOK 1.61.0 §8: a day-rate overtime line reads in hours (`dayRateOvertimeCalcText`).
            let hoursSum = item.dayRateOvertimeText
            let ratePart = hoursSum.map { [$0] } ?? [hoursPart, item.timesheetRateAnnotation]
            let detail = ([clockPart] + ratePart).filter { !$0.isEmpty }.joined(separator: " · ")
            // The hours sum is longer: up to three lines, so it is never cut off.
            let detailHeight: CGFloat = hoursSum == nil ? 28 : 40
            (detail as NSString).draw(
                in: CGRect(x: middleX, y: y + 22, width: 190, height: detailHeight),
                withAttributes: [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: slate]
            )

            (currency(item.amount) as NSString).draw(
                in: CGRect(x: amountX, y: y + 16, width: 56, height: 18),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11.5, weight: .bold), .foregroundColor: navy]
            )
            y += hoursSum == nil ? 50 : 62
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
        // RULEBOOK 1.53.0: the total in pennies (`roundPennies`).
        let grandTotal = CanonicalBusinessEngine.roundPennies(rows.reduce(0) { $0 + $1.amount })
        let fileName = timesheetPDFFileName(userName: userName, paymentRunStamp: paymentRunStamp)
        var notes = signatureNotes(for: draft)
        if let rebuiltNote { notes.insert(rebuiltNote, at: 0) }
        // RULEBOOK 1.55.0 §8: the invoice number ("-REV1" on a revision) and the difference from the previous version.
        let copy = TimesheetDraftStore.revisionCopy(
            for: draft,
            subjectId: operative.id,
            weekStart: week.start,
            total: grandTotal,
            currency: OrganizationRulebookContext.currencyCode
        )
        var context = InvoicePDFBuilder.Context(
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
        context.invoiceNumber = copy.invoiceNumber
        context.revisionNote = copy.note
        guard let pdfURL = InvoicePDFBuilder.makePDF(context: context) else {
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

        // The authenticated `sendEmail` function, template `timesheet_export` (web docs/EMAIL_FUNCTION.md): it renders
        // `managerExportEmailHTML` itself and sends only to an active member of the organisation (the exporter).
        guard let orgId = organization?.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines),
              !orgId.isEmpty else {
            delivery.emailProblem = "no organisation is open"
            return delivery
        }
        let files = attachments.map { (fileName: $0.fileName, data: $0.data) }
        // Over the function's 10 MB / 80-file limit: send the backup links only, when every file has one.
        let fits = AppEmailPayload.attachmentsFit(files)
        if !fits && downloadLinks.count < attachments.count {
            delivery.emailProblem = "the timesheet PDFs are larger than the 10 MB email limit; download them from the backup links instead"
            return delivery
        }
        let data = AppEmailPayload.timesheetExportData(
            weekTitle: week.title,
            paymentRunStamp: paymentRunStamp,
            timesheetCount: attachments.count,
            downloadLinks: downloadLinks
        )
        // One id for this export, reused on the retry, so a send that went but timed out is never emailed twice.
        let requestId = UUID().uuidString
        var lastError: Error?
        for _ in 0..<2 {
            do {
                _ = try await AppEmailClient.send(
                    template: .timesheetExport,
                    organizationId: orgId,
                    to: [recipientEmail],
                    data: data,
                    attachments: fits ? files : [],
                    requestId: requestId
                )
                lastError = nil
                break
            } catch MaterialRequestEmailError.refused(let status, let reason) where status >= 400 && status < 500 {
                // A refusal (bad data, not allowed, too large) will not change on a retry.
                lastError = MaterialRequestEmailError.refused(status: status, reason: reason)
                break
            } catch {
                lastError = error
            }
        }
        if let lastError { delivery.emailProblem = AppEmailClient.message(for: lastError) }
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

}

