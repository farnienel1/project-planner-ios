//
//  PayeClaimsViews.swift
//  Project Planner
//
//  RULEBOOK 1.30.0 §26: Timesheets → Overtime, Expenses & Price Work → Price work / Expenses — the same screens and flow
//  as web `components/overtime/PayeClaimsScreen.tsx`: Current PAYE payrun / Past PAYE payruns / Custom date range plus
//  Add (the person only), the list with its total, Add Price Work / Add Expense (Cancel at the top, the add button at the
//  bottom), the item detail, Generate price work report / Generate expenses report (green once one item is in the range,
//  `payeClaimReportReady`; a summary page and one page per piece of evidence, shared with the share sheet; a frozen copy
//  in `payeClaimReports`). Users' view is read-only apart from the 1.32.0 review; a self-employed person's items are
//  their timesheet entries (`timesheetClaimRows`). Every rule, figure, permission and write shape comes from `CanonicalBusinessEngine`
//  (`Rulebook+PayeClaims.swift`); these views only pass inputs and show results. Online only.
//  RULEBOOK 1.32.0 §26: items and reviews load under every id of the person (`overtimePersonIds`); in Users' view a
//  reviewer (`canReviewPayeClaims`) ticks or crosses each item and presses one Approve (`payeClaimReviewWrites` →
//  `payeClaimReviews`, "Approved X of Y"); each item shows its state (`payeClaimReviewState`) and "Not theirs — left
//  out." for an item on none of their ids (`payeClaimReviewOutcomeLabel`), as web `PayeClaimsScreen.tsx`.
//  RULEBOOK 1.33.0 §26: a line manager can always review (no "Needs an admin"): items and reviews also load through
//  `personUserId`, and a review of an item under another of the person's ids carries it (`payeClaimReviewWrites`).
//

import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers
import FirebaseStorage

// MARK: - People inputs (no rule)

@MainActor
enum PayeClaimPeople {
    /// A roster row as `priceWorkApproverCandidates` reads it: the line-manager row plus the organisation the users
    /// document STORES (`AppUser.storedOrganizationId`, web `homeOrganizationId`) — never `organizationId`, which the
    /// roster readers fill with the open organisation when the document has none. The rules' `homeOrgIs` reads the
    /// stored field, so a person whose document names no organisation (or another one) is never offered.
    static func approverRow(_ user: AppUser) -> [String: Any] {
        var row = LineManagerRulebook.row(user)
        row["organizationId"] = user.storedOrganizationId ?? ""
        return row
    }

    static func approverRoster(_ users: [AppUser]) -> [[String: Any]] {
        users.map { approverRow($0) }
    }

    /// `canViewPayeClaims(viewer, subject, roster)` for the signed-in (display) user.
    static func canView(subject: AppUser?, userStore: UserStore) -> Bool {
        guard let viewer = userStore.displayUser, let subject else { return false }
        return CanonicalBusinessEngine.canViewPayeClaims(
            viewer: RulebookPeople.person(viewer),
            subject: RulebookPeople.person(subject),
            roster: RulebookPeople.roster(userStore.organizationUsers)
        )
    }

    static func subject(_ subjectId: String, userStore: UserStore) -> AppUser? {
        userStore.organizationUsers.first { $0.id == subjectId }
            ?? (userStore.displayUser?.id == subjectId ? userStore.displayUser : nil)
    }

    /// 1.33.0 `reportGeneratedText`: "6 Nov 2026, 14:05 by Sam Smith" in the organisation zone; "saving…" until the
    /// saved time is back.
    static func generatedText(_ report: PayeClaimReportRecord, users: [AppUser]) -> String {
        guard report.generatedAtMs != nil else { return "saving…" }
        return CanonicalBusinessEngine.reportGeneratedText(
            generatedAtMs: report.generatedAtMs,
            generatedBy: report.generatedBy,
            userId: report.userId,
            userName: report.userName,
            generatedByName: OvertimeScreenSupport.generatorName(report.generatedBy, users: users),
            now: nil
        ).generated
    }
}

// MARK: - Section: the three ranges plus Add

/// Price work / Expenses for one person: Current PAYE payrun / Past PAYE payruns / Custom date range, plus Add.
struct PayeClaimsSectionView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let kind: PayeClaimKind
    let subjectId: String
    let scope: OvertimeScope

    var body: some View {
        let subject = PayeClaimPeople.subject(subjectId, userStore: userStore)
        let today = OvertimeScreenSupport.todayKey()
        let org = OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization)
        let current = CanonicalBusinessEngine.payePayrunPeriod(org, dayKey: today)
        let past = CanonicalBusinessEngine.payePastPayruns(org, todayKey: today)
        let selfEmployed = !(subject?.isPayeEmployment ?? true)
        OvertimeScreenScaffold(title: kind.sectionTitle) {
            if let subject, PayeClaimPeople.canView(subject: subject, userStore: userStore) {
                if selfEmployed {
                    Text("\(OvertimeScreenSupport.name(subject)) is self-employed: these are the entries on their timesheets, read-only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(current.map { CanonicalBusinessEngine.payePayrunLabel($0) }
                    ?? CanonicalBusinessEngine.overtimeText("PAYE_PAYDAY_NOT_SET_MESSAGE", fallback: "Ask an admin to set the PAYE payday"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let current {
                    NavigationLink {
                        PayeClaimsRangeView(kind: kind, subjectId: subjectId, scope: scope, range: OvertimeDayRange(start: current.start, end: current.end))
                    } label: {
                        OvertimeTile(title: "Current PAYE payrun")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("payeClaims.\(kind.rawValue).range.current")
                } else {
                    OvertimeTile(title: "Current PAYE payrun", disabled: true)
                }
                NavigationLink {
                    PayeClaimsPastPayrunsView(kind: kind, subjectId: subjectId, scope: scope)
                } label: {
                    OvertimeTile(title: "Past PAYE payruns", disabled: current == nil && past.isEmpty)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("payeClaims.\(kind.rawValue).range.past")
                NavigationLink {
                    PayeClaimsCustomRangeView(kind: kind, subjectId: subjectId, scope: scope)
                } label: {
                    OvertimeTile(title: "Custom date range")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("payeClaims.\(kind.rawValue).range.custom")
                if scope == .mine && !selfEmployed {
                    if let current {
                        NavigationLink {
                            PayeClaimsRangeView(
                                kind: kind,
                                subjectId: subjectId,
                                scope: scope,
                                range: OvertimeDayRange(start: current.start, end: current.end),
                                openAdd: true
                            )
                        } label: {
                            OvertimeTile(title: kind.addLabel, subtitle: "Online only")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("payeClaims.\(kind.rawValue).add")
                    } else {
                        OvertimeTile(title: kind.addLabel, subtitle: "Online only", disabled: true)
                        Text("Open Custom date range to add \(kind == .priceWork ? "price work" : "an expense") until the PAYE payday is set.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(userStore.organizationUsers.isEmpty
                    ? "Loading…"
                    : "You cannot see this person's \(kind.sectionTitle.lowercased()).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Past PAYE payruns (`payePastPayruns`) and the saved reports of this kind (`payeClaimReportsOfKind`, read on open).
struct PayeClaimsPastPayrunsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let kind: PayeClaimKind
    let subjectId: String
    let scope: OvertimeScope

    @State private var reports: [PayeClaimReportRecord] = []
    @State private var notice: String?
    @State private var shareURL: URL?
    @State private var busyReportId: String?

    var body: some View {
        let today = OvertimeScreenSupport.todayKey()
        let org = OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization)
        let past = CanonicalBusinessEngine.payePastPayruns(org, todayKey: today)
        let current = CanonicalBusinessEngine.payePayrunPeriod(org, dayKey: today)
        let subject = PayeClaimPeople.subject(subjectId, userStore: userStore)
        OvertimeScreenScaffold(title: "Past PAYE payruns") {
            if past.isEmpty {
                Text(current != nil
                    ? "No past PAYE payruns yet."
                    : CanonicalBusinessEngine.overtimeText("PAYE_PAYDAY_NOT_SET_MESSAGE", fallback: "Ask an admin to set the PAYE payday"))
                    .foregroundStyle(.secondary)
            }
            ForEach(past) { run in
                NavigationLink {
                    PayeClaimsRangeView(kind: kind, subjectId: subjectId, scope: scope, range: OvertimeDayRange(start: run.start, end: run.end))
                } label: {
                    OvertimeTile(
                        title: OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: run.start, end: run.end)),
                        subtitle: "Paid \(CanonicalBusinessEngine.formatPayePayrunDay(run.payDate))"
                    )
                }
                .buttonStyle(.plain)
            }
            let rows = CanonicalBusinessEngine.payeClaimReportsOfKind(reports, kind: kind)
            if !rows.isEmpty, subject?.isPayeEmployment ?? false {
                Text("SAVED REPORTS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                ForEach(rows) { report in
                    Button {
                        Task { await share(report) }
                    } label: {
                        OvertimeTile(
                            title: "\(OvertimeScreenSupport.rangeTitle(OvertimeDayRange(start: report.rangeStart, end: report.rangeEnd))) · \(OrgMoney.format(report.totals.amount, currencyCode: report.currency))",
                            subtitle: busyReportId == report.id
                                ? "Making PDF…"
                                : "\(report.totals.itemCount) item(s) · made \(PayeClaimPeople.generatedText(report, users: userStore.organizationUsers)) · Share PDF"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busyReportId != nil)
                }
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            do {
                reports = try await firebaseBackend.loadPayeClaimReports(userId: subjectId)
            } catch {
                notice = "Saved reports could not be loaded."
            }
        }
        .sheet(item: Binding(get: { shareURL.map(OvertimeShareItem.init) }, set: { shareURL = $0?.url })) { item in
            HSDocumentActivityView(activityItems: [item.url])
        }
    }

    private func share(_ report: PayeClaimReportRecord) async {
        busyReportId = report.id
        defer { busyReportId = nil }
        let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
        let backend = firebaseBackend
        let made = await PayeClaimReportPDF.makeFile(
            report: report,
            logo: logo,
            generatedByName: OvertimeScreenSupport.generatorName(report.generatedBy, users: userStore.organizationUsers)
        ) { path in
            try await backend.payeClaimStoredFileData(path: path)
        }
        shareURL = made.url
        notice = PayeClaimReportPDF.notice(made)
    }
}

/// Custom date range (`payeCustomRange`).
struct PayeClaimsCustomRangeView: View {
    let kind: PayeClaimKind
    let subjectId: String
    let scope: OvertimeScope
    @State private var start = Date()
    @State private var end = Date()
    @State private var picked: OvertimeDayRange?

    var body: some View {
        OvertimeScreenScaffold(title: "Custom date range") {
            DatePicker("Start", selection: $start, displayedComponents: .date)
                .environment(\.timeZone, OrganizationRulebookContext.timeZone)
            DatePicker("End", selection: $end, displayedComponents: .date)
                .environment(\.timeZone, OrganizationRulebookContext.timeZone)
            Button {
                if let range = CanonicalBusinessEngine.payeCustomRange(
                    start: OrganizationRulebookContext.dayKey(start),
                    end: OrganizationRulebookContext.dayKey(end)
                ) {
                    picked = OvertimeDayRange(start: range.start, end: range.end)
                }
            } label: {
                Text("View \(kind.sectionTitle)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("payeClaims.custom.view")
        }
        .navigationDestination(item: $picked) { range in
            PayeClaimsRangeView(kind: kind, subjectId: subjectId, scope: scope, range: range)
        }
    }
}

// MARK: - The list for a range

struct PayeClaimsRangeView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let kind: PayeClaimKind
    let subjectId: String
    let scope: OvertimeScope
    let range: OvertimeDayRange
    var openAdd: Bool = false

    @State private var items: [PayeClaimItem] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var timesheetRows: [TimesheetClaimRow]?
    @State private var adding = false
    @State private var didOpenAdd = false
    @State private var open: PayeClaimItem?
    @State private var busy = false
    @State private var notice: String?
    @State private var shareURL: URL?
    @State private var listener = OvertimeListeners()
    @State private var reviews: [PayeClaimReviewRecord] = []
    /// RULEBOOK 1.32.0 §26: the reviewer's ✓ / ✕ per item id (`approved` | `rejected`), not saved until Approve.
    @State private var decisions: [String: String] = [:]
    @State private var listenedIds: [String] = []

    private var subject: AppUser? { PayeClaimPeople.subject(subjectId, userStore: userStore) }
    private var selfEmployed: Bool { !(subject?.isPayeEmployment ?? true) }
    private var writable: Bool {
        guard scope == .mine, let uid = firebaseBackend.payeClaimsUid else { return false }
        return CanonicalBusinessEngine.canWritePayeClaim(viewerId: uid, itemUserId: subjectId)
    }

    /// RULEBOOK 1.32.0 (`overtimePersonIds`): every id this person's items may be filed under, users id first. Web's
    /// claims screen passes no operatives rows (claims are written under the Auth uid), so neither does iOS.
    private var personIds: [String] {
        guard let subject else { return [subjectId] }
        let ids = CanonicalBusinessEngine.overtimePersonIds(
            person: RulebookPeople.person(subject),
            roster: RulebookPeople.roster(userStore.organizationUsers),
            operatives: []
        )
        return ids.isEmpty ? [subjectId] : ids
    }

    /// RULEBOOK 1.32.0 §26 `canReviewPayeClaims`: Users' view only, the person's active line managers and admins.
    private var reviewer: Bool {
        guard scope != .mine, let viewer = userStore.displayUser, let subject else { return false }
        return CanonicalBusinessEngine.canReviewPayeClaims(
            viewer: RulebookPeople.person(viewer),
            subject: RulebookPeople.person(subject),
            roster: RulebookPeople.roster(userStore.organizationUsers)
        )
    }

    var body: some View {
        let title = "\(kind.sectionTitle) · \(OvertimeScreenSupport.rangeTitle(range))"
        OvertimeScreenScaffold(title: title) {
            if !PayeClaimPeople.canView(subject: subject, userStore: userStore) {
                Text("You cannot see this person's \(kind.sectionTitle.lowercased()).").foregroundStyle(.secondary)
            } else if selfEmployed {
                timesheetList
            } else {
                claimList
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            listener.stop()
            listenedIds = []
        }
        .onChange(of: personIds) { _, ids in
            // Only while listening (not for a self-employed person's timesheet rows, not after the screen closed).
            if !listenedIds.isEmpty && ids != listenedIds { listen(ids) }
        }
        .sheet(isPresented: $adding) {
            if let subject {
                AddPayeClaimSheet(kind: kind, subject: subject, range: range)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
            }
        }
        .sheet(item: $open) { item in
            PayeClaimDetailSheet(item: item, canRemove: writable)
                .environmentObject(firebaseBackend)
        }
        .sheet(item: Binding(get: { shareURL.map(OvertimeShareItem.init) }, set: { shareURL = $0?.url })) { item in
            HSDocumentActivityView(activityItems: [item.url])
        }
    }

    @ViewBuilder private var claimList: some View {
        let inRange = CanonicalBusinessEngine.payeClaimsInRange(items, start: range.start, end: range.end)
        let ready = CanonicalBusinessEngine.payeClaimReportReady(itemCount: inRange.count)
        let currency = OrganizationRulebookContext.currencyCode
        let canReview = reviewer
        let preview = reviewPlan(inRange)
        if let loadError {
            Text(loadError).foregroundStyle(.secondary)
        } else if !loaded {
            Text("Loading…").foregroundStyle(.secondary)
        } else if inRange.isEmpty {
            Text(kind.emptyMessage).foregroundStyle(.secondary)
        }
        ForEach(inRange) { item in
            let row = CanonicalBusinessEngine.payeClaimListRow(item, currency: currency)
            let state = CanonicalBusinessEngine.payeClaimReviewState(item, reviews: reviews)
            let decision = decisions[item.id]
            let outcomeLabel = decision == nil ? nil : CanonicalBusinessEngine.payeClaimReviewOutcomeLabel(preview?.outcomes[item.id])
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    open = item
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row?.title ?? item.title).font(.body.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(row?.figure ?? "").font(.body.weight(.semibold))
                        }
                        Text((row?.subtitle ?? "") + (item.evidence.isEmpty ? "" : " · \(item.evidence.count) evidence"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                // RULEBOOK 1.32.0 §26: the item's review state (`payeClaimReviewState`), the unsaved ✓ / ✕, and
                // 1.33.0 "Not theirs — left out." for an item on none of the person's ids (`payeClaimReviewOutcomeLabel`).
                HStack(spacing: 8) {
                    if let state {
                        Text(state.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(reviewStateColor(state.state).opacity(0.15), in: Capsule())
                            .foregroundStyle(reviewStateColor(state.state))
                    }
                    if let decision {
                        Text("\(decision == "approved" ? "Ticked" : "Crossed") (not saved)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let outcomeLabel {
                        Text(outcomeLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    if canReview {
                        Button {
                            decisions[item.id] = "rejected"
                        } label: {
                            Image(systemName: "xmark").foregroundStyle(PPColor.danger)
                        }
                        .accessibilityLabel("Reject this item")
                        .disabled(busy)
                        Button {
                            decisions[item.id] = "approved"
                        } label: {
                            Image(systemName: "checkmark").foregroundStyle(Color.green)
                        }
                        .accessibilityLabel("Approve this item")
                        .disabled(busy)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        }
        if !inRange.isEmpty {
            Text("Total \(OrgMoney.format(CanonicalBusinessEngine.payeClaimsTotal(amounts: inRange.map(\.amount))))")
                .font(.subheadline.weight(.semibold))
        }
        if scope != .mine {
            Text("\(OvertimeScreenSupport.name(subject)) adds these themselves.\(canReview ? " Tick or cross each item, then Approve." : "")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if canReview && !inRange.isEmpty {
            let writes = preview?.writes ?? []
            Button {
                Task { await approve(writes: writes, message: preview?.message ?? "") }
            } label: {
                Text(CanonicalBusinessEngine.overtimeText("OVERTIME_APPROVE_LABEL", fallback: "Approve"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(writes.isEmpty ? Color.gray.opacity(0.4) : Color.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(busy || writes.isEmpty)
            .accessibilityIdentifier("payeClaims.list.approve")
        }
        if writable {
            Button {
                adding = true
            } label: {
                Text(kind.addLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(PPColor.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityIdentifier("payeClaims.list.add")
        }
        if scope == .mine {
            Button {
                Task { await generate(inRange) }
            } label: {
                Text(busy ? "Making report…" : kind.generateReportLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ready ? Color.green : Color.gray.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(!ready || busy)
            .accessibilityIdentifier("payeClaims.list.generate")
        }
        if let notice {
            Text(notice).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var timesheetList: some View {
        if let loadError {
            Text(loadError).foregroundStyle(.secondary)
        } else if let rows = timesheetRows {
            if rows.isEmpty {
                Text(kind.emptyMessage).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title).font(.body.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(OrgMoney.format(row.amount)).font(.body.weight(.semibold))
                    }
                    Text(timesheetSubtitle(row)).font(.footnote).foregroundStyle(.secondary)
                    if !row.details.isEmpty {
                        Text(row.details).font(.footnote)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
            }
            if !rows.isEmpty {
                Text("Total \(OrgMoney.format(CanonicalBusinessEngine.payeClaimsTotal(amounts: rows.map(\.amount)))) · read-only, from their timesheets")
                    .font(.subheadline.weight(.semibold))
            }
        } else {
            Text("Loading…").foregroundStyle(.secondary)
        }
    }

    private func timesheetSubtitle(_ row: TimesheetClaimRow) -> String {
        let dates = row.startDate == row.endDate
            ? CanonicalBusinessEngine.formatPayePayrunDay(row.startDate)
            : "\(CanonicalBusinessEngine.formatPayePayrunDay(row.startDate)) – \(CanonicalBusinessEngine.formatPayePayrunDay(row.endDate))"
        // RULEBOOK 1.30.1: price work shows its job number, or "—" for an entry stored before (`priceWorkJobNumberText`).
        let job = kind == .priceWork ? CanonicalBusinessEngine.priceWorkJobNumberText(row.jobNumber) : row.jobNumber
        return [dates, job, row.approvedByName.isEmpty ? "" : "Agreed by \(row.approvedByName)", "Timesheet: \(row.managerDecision)"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func start() {
        if openAdd && !didOpenAdd && writable {
            didOpenAdd = true
            adding = true
        }
        if selfEmployed {
            Task {
                do {
                    let sheets = try await firebaseBackend.loadTimesheetClaimSheets(userId: subjectId)
                    timesheetRows = CanonicalBusinessEngine.timesheetClaimRows(sheets: sheets, kind: kind, start: range.start, end: range.end)
                } catch {
                    loadError = "Their timesheets could not be read."
                }
            }
            return
        }
        listen(personIds)
    }

    /// RULEBOOK 1.32.0 §26: the items and their reviews under every id of the person (`overtimePersonIds`), listened to
    /// again when the ids change (the roster loading after the screen opened), as web keys its listeners on the ids.
    private func listen(_ ids: [String]) {
        listener.stop()
        listenedIds = ids
        let registrations = firebaseBackend.listenPersonPayeClaims(
            userIds: ids,
            kind: kind,
            onChange: { rows in
                items = rows
                loaded = true
            },
            onError: { error in
                loadError = error.localizedDescription
            }
        )
        guard !registrations.isEmpty else {
            loadError = "No organisation is open."
            return
        }
        registrations.forEach { listener.add($0) }
        let reviewRegistrations = firebaseBackend.listenPayeClaimReviews(userIds: ids, onChange: { rows in
            reviews = rows
        })
        reviewRegistrations.forEach { listener.add($0) }
    }

    /// `payeClaimReviewWrites` for the current ✓ / ✕ (the preview Approve saves), or nil outside a reviewer's view.
    private func reviewPlan(_ inRange: [PayeClaimItem]) -> PayeClaimReviewPlan? {
        guard reviewer, let viewer = userStore.displayUser else { return nil }
        return CanonicalBusinessEngine.payeClaimReviewWrites(
            items: inRange,
            decisions: decisions,
            reviews: reviews,
            subjectUserId: subjectId,
            personIds: personIds,
            // The security rules require `reviewedBy` to be the signed-in Auth uid.
            reviewerId: firebaseBackend.payeClaimsUid ?? viewer.id
        )
    }

    /// RULEBOOK 1.32.0 §26 Approve: every review write in one batch, then the rulebook's "Approved X of Y" message.
    private func approve(writes: [PayeClaimReviewWrite], message: String) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await firebaseBackend.savePayeClaimReviews(writes)
            decisions = [:]
            notice = message
        } catch {
            notice = error.localizedDescription.isEmpty ? "The review could not be saved." : error.localizedDescription
        }
    }

    private func reviewStateColor(_ state: String) -> Color {
        switch state {
        case "approved": return .green
        case "rejected": return PPColor.danger
        default: return .orange
        }
    }

    private func generate(_ inRange: [PayeClaimItem]) async {
        guard let subject else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let report = try await firebaseBackend.savePayeClaimReport(
                kind: kind,
                person: subject,
                companyName: firebaseBackend.currentOrganization?.name ?? "",
                rangeStart: range.start,
                rangeEnd: range.end,
                items: inRange
            )
            let logo = await OvertimeReportPDF.loadLogo(firebaseBackend.currentOrganization?.companyLogoURL)
            let backend = firebaseBackend
            let made = await PayeClaimReportPDF.makeFile(
            report: report,
            logo: logo,
            generatedByName: OvertimeScreenSupport.generatorName(report.generatedBy, users: userStore.organizationUsers)
        ) { path in
                try await backend.payeClaimStoredFileData(path: path)
            }
            shareURL = made.url
            notice = PayeClaimReportPDF.notice(made)
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: - Item detail

struct PayeClaimDetailSheet: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    let item: PayeClaimItem
    let canRemove: Bool

    @State private var error: String?
    @State private var removing = false
    @State private var viewing: IdentifiableURL?

    var body: some View {
        let row = CanonicalBusinessEngine.payeClaimListRow(item, currency: OrganizationRulebookContext.currencyCode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row?.title ?? item.title).font(.title3.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(row?.figure ?? "").font(.title3.weight(.semibold))
                    }
                    Text(row?.subtitle ?? "").font(.footnote).foregroundStyle(.secondary)
                    if !item.details.isEmpty {
                        Text(item.details).font(.body)
                    }
                    Text("EVIDENCE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    if item.evidence.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(item.evidence) { entry in
                        Button {
                            Task { await openEvidence(entry) }
                        } label: {
                            Text(entry.name + (entry.kind == "personalSiteAudit" ? " (personal site audit copy)" : ""))
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if canRemove {
                        Button(role: .destructive) {
                            Task { await remove() }
                        } label: {
                            Text(removing ? "Removing…" : "Remove")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .disabled(removing)
                        .padding(.top, 12)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle(item.kind == PayeClaimKind.priceWork.rawValue ? "Price work" : "Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $viewing) { target in
                InAppRemoteDocumentViewer(remoteURL: target.url, title: "Evidence", noun: "evidence")
            }
        }
    }

    private func openEvidence(_ entry: PayeClaimEvidence) async {
        do {
            let url = try await Storage.storage().reference(withPath: entry.path).downloadURL()
            viewing = IdentifiableURL(url)
        } catch {
            self.error = "\(entry.name) could not be opened."
        }
    }

    private func remove() async {
        removing = true
        defer { removing = false }
        do {
            try await firebaseBackend.removePayeClaim(item)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add Price Work / Add Expense

/// A piece of evidence picked but not uploaded yet (uploaded on Add, into the person's claim folder).
struct PendingPayeClaimEvidence: Identifiable {
    enum Source {
        /// A JPEG photo or a PDF, ready to upload.
        case file(data: Data, contentType: String, kind: String)
        /// A personal site audit: a frozen PDF copy is built and uploaded on Add.
        case audit(PersonalSiteAudit)
    }

    let id = UUID()
    let label: String
    let source: Source
}

/// Add Price Work / Add Expense: Cancel at the top, the add button at the bottom (web `AddClaimSheet`). Laid out as
/// labelled cards (PayeClaimFormComponents.swift); each rulebook validation message is shown on the card it is about
/// (`PayeClaimFormSection`). What is validated, saved and when Add is enabled are unchanged.
struct AddPayeClaimSheet: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    let kind: PayeClaimKind
    let subject: AppUser
    let range: OvertimeDayRange

    @State private var title = ""
    @State private var details = ""
    @State private var jobNumber = ""
    @State private var from = Date()
    @State private var to = Date()
    @State private var approver = ""
    @State private var amount = ""
    @State private var evidence: [PendingPayeClaimEvidence] = []
    @State private var error: String?
    /// A photo or file that could not be added (shown on the Evidence card).
    @State private var evidenceError: String?
    @State private var saving: String?
    @State private var pickingPhoto: UIImagePickerController.SourceType?
    @State private var pickingFile = false
    @State private var pickingAudit = false
    @State private var didSetDates = false

    private var priceWork: Bool { kind == .priceWork }
    private var person: [String: Any] { PayeClaimPeople.approverRow(subject) }
    private var roster: [[String: Any]] { PayeClaimPeople.approverRoster(userStore.organizationUsers) }
    private var organizationId: String { firebaseBackend.payeClaimsOrganizationId ?? "" }
    private var fromKey: String { OrganizationRulebookContext.dayKey(from) }
    private var toKey: String { OrganizationRulebookContext.dayKey(to) }

    private var approvers: [PriceWorkApproverCandidate] {
        CanonicalBusinessEngine.priceWorkApproverCandidates(person: person, roster: roster, organizationId: organizationId)
    }

    /// The rulebook's shape check before upload (paths are checked again on save), as web does.
    private var draftError: String? {
        if priceWork {
            let draft: [String: Any] = [
                "title": title, "details": details, "jobNumber": jobNumber, "startDate": fromKey, "endDate": toKey,
                "approvedByUserId": approver, "amount": amount,
            ]
            return CanonicalBusinessEngine.priceWorkValidationError(draft: draft, person: person, roster: roster, organizationId: organizationId)
        }
        let placeholders: [[String: Any]] = evidence.map { _ in ["path": "", "name": "", "kind": "file"] }
        let draft: [String: Any] = [
            "title": title, "details": details, "jobNumber": jobNumber, "date": fromKey, "amount": amount, "evidence": placeholders,
        ]
        return CanonicalBusinessEngine.expenseValidationError(draft: draft, organizationId: nil, userId: nil)
    }

    var body: some View {
        let currentError = draftError
        // The rulebook's message once the person has started (as before), shown next to the card it is about.
        let shownError = (title.isEmpty && amount.isEmpty) ? nil : currentError
        let errorSection = shownError.map { PayeClaimFormSection.section(for: $0) }
        let canAdd = currentError == nil && saving == nil
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailsCard(message: errorSection == .details ? shownError : nil)
                    datesCard(message: errorSection == .dates ? shownError : nil)
                    if priceWork {
                        approverCard(message: errorSection == .approver ? shownError : nil)
                    }
                    amountCard(message: errorSection == .amount ? shownError : nil)
                    evidenceCard(message: evidenceError ?? (errorSection == .evidence ? shownError : nil))
                    if let general = error ?? (errorSection == .other ? shownError : nil) {
                        PayeClaimFieldMessage(text: general)
                            .padding(.horizontal, 4)
                            .accessibilityIdentifier("payeClaims.add.error")
                    }
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PPColor.page.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                PPBottomActionBar(
                    title: saving ?? kind.addLabel,
                    isEnabled: canAdd,
                    isBusy: saving != nil,
                    accessibilityIdentifier: "payeClaims.add.submit",
                    action: { Task { await submit() } }
                )
            }
            .navigationTitle(kind.addLabel)
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(PPOnNavyPillButtonStyle())
                        .disabled(saving != nil)
                        .opacity(saving != nil ? 0.5 : 1)
                        .accessibilityIdentifier("payeClaims.add.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // The same Add as the bottom button, enabled exactly when it is.
                    Button("Add") { Task { await submit() } }
                        .buttonStyle(PPOnNavyPillButtonStyle())
                        .disabled(!canAdd)
                        .opacity(canAdd ? 1 : 0.5)
                        .accessibilityIdentifier("payeClaims.add.submitTop")
                }
            }
            .onAppear(perform: setInitialDates)
            .sheet(item: Binding(
                get: { pickingPhoto.map(PayeClaimPickerSource.init) },
                set: { pickingPhoto = $0?.sourceType }
            )) { source in
                PayeClaimImagePicker(sourceType: source.sourceType) { image in
                    addPhoto(image)
                }
            }
            .sheet(isPresented: $pickingFile) {
                PayeClaimDocumentPicker { url in
                    addFile(url)
                }
            }
            .sheet(isPresented: $pickingAudit) {
                PersonalSiteAuditPickerSheet { audit in
                    evidence.append(PendingPayeClaimEvidence(
                        label: CanonicalBusinessEngine.personalSiteAuditTitle(audit),
                        source: .audit(audit)
                    ))
                    evidenceError = nil
                }
                .environmentObject(firebaseBackend)
            }
        }
        .interactiveDismissDisabled(saving != nil)
    }

    // MARK: Cards

    private func detailsCard(message: String?) -> some View {
        PayeClaimFormCard(title: "Details", symbol: "text.alignleft", family: .plan, message: message, identifier: "payeClaims.add.details") {
            PayeClaimLabeledField(priceWork ? "Price work name" : "Expense name") {
                TextField("Name", text: $title)
                    .accessibilityIdentifier("payeClaims.add.title")
            }
            PayeClaimLabeledField("Description") {
                TextField("Optional", text: $details, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("payeClaims.add.description")
            }
            // RULEBOOK 1.30.1: price work needs a job number (`priceWorkJobNumberError` inside the validator).
            PayeClaimLabeledField(priceWork ? "Job number (required)" : "Job number") {
                TextField(priceWork ? "Required" : "Optional", text: $jobNumber)
                    .accessibilityIdentifier("payeClaims.add.jobNumber")
                    .onChange(of: jobNumber) { _, value in
                        let max = CanonicalBusinessEngine.priceWorkJobNumberMax
                        if value.count > max { jobNumber = String(value.prefix(max)) }
                    }
            }
        }
    }

    private func datesCard(message: String?) -> some View {
        PayeClaimFormCard(title: priceWork ? "Dates" : "Date", symbol: "calendar", family: .plan, message: message, identifier: "payeClaims.add.dates") {
            PayeClaimLabeledField(priceWork ? "From" : "Date") {
                DatePicker(priceWork ? "From" : "Date", selection: $from, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                    .onChange(of: from) { _, value in
                        if to < value { to = value }
                    }
                    .accessibilityIdentifier("payeClaims.add.from")
            }
            if priceWork {
                PayeClaimLabeledField("To") {
                    DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                        .accessibilityIdentifier("payeClaims.add.to")
                }
            }
        }
    }

    private func approverCard(message: String?) -> some View {
        PayeClaimFormCard(
            title: "Approved by",
            symbol: "person.crop.circle.badge.checkmark",
            family: .people,
            note: CanonicalBusinessEngine.payeClaimText("PAYE_CLAIM_APPROVER_NOT_NOTIFIED_NOTE", fallback: "They are not notified; the report names them."),
            message: message,
            identifier: "payeClaims.add.approvedBy"
        ) {
            PayeClaimLabeledField("Approved by (required)") {
                Picker("Approved by (required)", selection: $approver) {
                    Text("Choose an admin or manager").tag("")
                    ForEach(approvers) { row in
                        Text("\(row.name) (\(row.level == "admin" ? "Admin" : "Manager"))").tag(row.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(PPColor.brand)
                .accessibilityIdentifier("payeClaims.add.approver")
            }
        }
    }

    private func amountCard(message: String?) -> some View {
        PayeClaimFormCard(title: "Amount", symbol: "banknote", family: .sites, message: message, identifier: "payeClaims.add.amountCard") {
            PayeClaimLabeledField("Amount (\(OrganizationRulebookContext.currencyCode))") {
                HStack(spacing: 6) {
                    Text(OrgMoney.symbol())
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityIdentifier("payeClaims.add.amount")
                }
            }
        }
    }

    private func evidenceCard(message: String?) -> some View {
        let canPickMore = evidence.count < CanonicalBusinessEngine.payeClaimEvidenceMax
        let well = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return PayeClaimFormCard(
            title: priceWork ? "Evidence (optional)" : "Evidence (at least one)",
            symbol: "paperclip",
            family: .trade,
            message: message,
            identifier: "payeClaims.add.evidence"
        ) {
            if !evidence.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(evidence.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().padding(.leading, 58)
                        }
                        PayeClaimAttachedEvidenceRow(entry: entry) {
                            evidence.removeAll { $0.id == entry.id }
                        }
                    }
                }
                .background(PPColor.well, in: well)
            }
            if canPickMore {
                VStack(spacing: 0) {
                    PayeClaimEvidenceSourceButton(title: "File (PDF or image)", symbol: "doc", family: .plan, identifier: "payeClaims.add.evidence.file") {
                        pickingFile = true
                    }
                    PPRowDivider()
                    PayeClaimEvidenceSourceButton(
                        title: "Take photo",
                        symbol: "camera",
                        family: .sites,
                        isEnabled: UIImagePickerController.isSourceTypeAvailable(.camera),
                        identifier: "payeClaims.add.evidence.camera"
                    ) {
                        pickingPhoto = .camera
                    }
                    PPRowDivider()
                    PayeClaimEvidenceSourceButton(title: "Photo library", symbol: "photo.on.rectangle", family: .people, identifier: "payeClaims.add.evidence.library") {
                        pickingPhoto = .photoLibrary
                    }
                    PPRowDivider()
                    PayeClaimEvidenceSourceButton(title: "Personal site audit", symbol: "checklist", family: .trade, identifier: "payeClaims.add.evidence.audit") {
                        pickingAudit = true
                    }
                }
                .background(PPColor.well, in: well)
                .clipShape(well)
            } else {
                Text(CanonicalBusinessEngine.payeClaimText("PAYE_CLAIM_EVIDENCE_LIMIT_MESSAGE", fallback: "Up to 20 pieces of evidence."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setInitialDates() {
        guard !didSetDates else { return }
        didSetDates = true
        let today = OvertimeScreenSupport.todayKey()
        let day = today >= range.start && today <= range.end ? today : range.start
        if let date = OrganizationRulebookContext.date(fromDayKey: day) {
            from = date
            to = date
        }
    }

    /// Every photo becomes a JPEG (`jpegDataFittingUploadLimit`) so the report can draw it full size.
    private func addPhoto(_ image: UIImage) {
        do {
            let data = try StorageUploadPolicy.jpegDataFittingUploadLimit(
                image,
                maxBytes: StorageUploadPolicy.standardMaxBytes,
                initialQuality: 0.85,
                encodeFailedMessage: "This photo could not be read.",
                oversizedMessage: "This photo is too large to upload."
            )
            evidence.append(PendingPayeClaimEvidence(
                label: "Photo \(evidence.count + 1)",
                source: .file(data: data, contentType: "image/jpeg", kind: "photo")
            ))
            error = nil
            evidenceError = nil
        } catch {
            evidenceError = error.localizedDescription
        }
    }

    /// A PDF is kept as a PDF; an image becomes a JPEG; anything else (SVG included) is refused.
    private func addFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            evidenceError = "This file could not be read."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            guard data.count <= StorageUploadPolicy.standardMaxBytes else {
                evidenceError = "This file is larger than 10 MB."
                return
            }
            evidence.append(PendingPayeClaimEvidence(
                label: url.lastPathComponent,
                source: .file(data: data, contentType: "application/pdf", kind: "file")
            ))
            error = nil
            evidenceError = nil
        } else if type?.conforms(to: .image) == true, type?.conforms(to: .svg) != true, let image = UIImage(data: data) {
            addPhoto(image)
        } else {
            evidenceError = "Evidence must be a photo or a PDF."
        }
    }

    private func submit() async {
        guard draftError == nil, saving == nil else { return }
        error = nil
        // Frozen audit copies are built (and size-checked) before anything is uploaded, so a copy over the claim
        // folder's 10 MB limit is refused with a clear message and nothing is left behind.
        var auditCopies: [UUID: Data] = [:]
        for entry in evidence {
            guard case .audit(let audit) = entry.source else { continue }
            saving = "Making the personal site audit copy"
            let backend = firebaseBackend
            guard let pdf = await PersonalSiteAuditPDF.makeData(audit: audit, readFile: { path in
                try await backend.payeClaimStoredFileData(path: path)
            }) else {
                saving = nil
                error = "The personal site audit copy could not be made."
                return
            }
            if let refusal = PersonalSiteAuditPDF.attachRefusal(byteCount: pdf.count) {
                saving = nil
                error = refusal
                return
            }
            auditCopies[entry.id] = pdf
        }
        var uploaded: [PayeClaimEvidence] = []
        do {
            for (index, entry) in evidence.enumerated() {
                saving = "Uploading evidence \(index + 1) of \(evidence.count)"
                switch entry.source {
                case .file(let data, let contentType, let kind):
                    uploaded.append(try await firebaseBackend.uploadPayeClaimEvidence(
                        data: data,
                        name: entry.label,
                        contentType: contentType,
                        kind: kind
                    ))
                case .audit(let audit):
                    guard let pdf = auditCopies[entry.id] else {
                        throw PayeClaimRefused(message: "The personal site audit copy could not be made.")
                    }
                    uploaded.append(try await firebaseBackend.attachPersonalSiteAuditCopy(audit, pdfData: pdf))
                }
            }
            saving = "Adding…"
            let evidenceJSON = uploaded.map(\.json)
            if priceWork {
                let draft: [String: Any] = [
                    "title": title, "details": details, "jobNumber": jobNumber, "startDate": fromKey, "endDate": toKey,
                    "approvedByUserId": approver, "amount": amount, "evidence": evidenceJSON,
                ]
                _ = try await firebaseBackend.addPriceWork(draft: draft, person: person, roster: roster)
            } else {
                let draft: [String: Any] = [
                    "title": title, "details": details, "jobNumber": jobNumber, "date": fromKey,
                    "amount": amount, "evidence": evidenceJSON,
                ]
                _ = try await firebaseBackend.addExpense(draft: draft)
            }
            saving = nil
            dismiss()
        } catch {
            // 1.30.0: a refused or failed add leaves no copy behind where line managers and admins could read it.
            await firebaseBackend.discardPayeClaimEvidence(uploaded)
            saving = nil
            self.error = error.localizedDescription
        }
    }
}

/// The person's own personal site audits (owner only), to attach a frozen copy.
struct PersonalSiteAuditPickerSheet: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    let onPick: (PersonalSiteAudit) -> Void

    @State private var audits: [PersonalSiteAudit]?
    @State private var listener = OvertimeListeners()

    var body: some View {
        NavigationStack {
            List {
                if audits == nil {
                    Text("Loading…").foregroundStyle(.secondary)
                } else if audits?.isEmpty == true {
                    Text("You have no personal site audits. Create one in Site audits → Personal.").foregroundStyle(.secondary)
                }
                ForEach(audits ?? []) { audit in
                    Button(CanonicalBusinessEngine.personalSiteAuditTitle(audit)) {
                        onPick(audit)
                        dismiss()
                    }
                }
                Section {
                    Text("A frozen copy (PDF) is attached; your line managers and admins see the copy, never your list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Choose a personal site audit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            listener.stop()
            if let registration = firebaseBackend.listenPersonalSiteAudits(
                onChange: { audits = $0 },
                onError: { _ in audits = [] }
            ) {
                listener.add(registration)
            } else {
                audits = []
            }
        }
        .onDisappear { listener.stop() }
    }
}

// MARK: - Pickers

struct PayeClaimPickerSource: Identifiable {
    let sourceType: UIImagePickerController.SourceType
    var id: Int { sourceType.rawValue }
}

/// Camera or photo library.
struct PayeClaimImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: PayeClaimImagePicker
        init(_ parent: PayeClaimImagePicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }
    }
}

/// A PDF or image from Files.
struct PayeClaimDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .jpeg, .png, .heic, .image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - PDFs

/// Draws text, images and appended PDF pages on A4 pages (the personal site audit copy). No rule here. The claim
/// report itself is drawn by `PayeClaimReportPDF` (PayeClaimReportPDF.swift).
@MainActor
final class PayeClaimPDFWriter {
    static let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    let context: UIGraphicsPDFRendererContext
    let margin: CGFloat = 48
    var y: CGFloat = 48

    init(context: UIGraphicsPDFRendererContext) {
        self.context = context
        context.beginPage()
        y = margin
    }

    private var width: CGFloat { Self.page.width - margin * 2 }

    func newPage() {
        context.beginPage(withBounds: Self.page, pageInfo: [:])
        y = margin
    }

    func text(_ value: String, size: CGFloat = 10.5, bold: Bool = false, color: UIColor = .black, gap: CGFloat = 0) {
        guard !value.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]
        let height = ceil((value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        ).height)
        if y + height > Self.page.height - margin { newPage() }
        (value as NSString).draw(
            with: CGRect(x: margin, y: y, width: width, height: height),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        y += height + 5 + gap
    }

    /// An image scaled to fit the space left on the page (a new page when little is left).
    func image(_ image: UIImage) {
        var room = Self.page.height - margin - y
        if room < 200 {
            newPage()
            room = Self.page.height - margin - y
        }
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(width / image.size.width, room / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: margin, y: y, width: size.width, height: size.height))
        y += size.height + 12
    }

    /// Appends every page of a PDF. False when the data is not a readable PDF.
    func appendPDF(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { return false }
        for index in 1...document.numberOfPages {
            guard let pdfPage = document.page(at: index) else { continue }
            Self.draw(pdfPage, in: context)
        }
        y = Self.page.height
        return true
    }

    /// One page of another PDF on a new page of its own size (also used by `PayeClaimReportCanvas`).
    static func draw(_ pdfPage: CGPDFPage, in context: UIGraphicsPDFRendererContext) {
        let box = pdfPage.getBoxRect(.mediaBox)
        context.beginPage(withBounds: CGRect(origin: .zero, size: box.size), pageInfo: [:])
        let cg = context.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: box.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -box.origin.x, y: -box.origin.y)
        cg.drawPDFPage(pdfPage)
        cg.restoreGState()
    }
}

/// The frozen PDF copy of a personal site audit (`personalSiteAuditPdfRows`), also its Share PDF. Photos are drawn
/// downscaled (longest side `maxPhotoPixels`, JPEG `photoQuality`) so the copy fits the claim folder's 10 MB Storage
/// limit; a copy still over `StorageUploadPolicy.standardMaxBytes` is never uploaded (`attachRefusal`).
@MainActor
enum PersonalSiteAuditPDF {
    static let maxPhotoPixels: CGFloat = 1600
    static let photoQuality: CGFloat = 0.7
    static let tooLargeMessage = "This audit is too large to attach — remove some photos or attach it as separate photos."

    /// Nil when a frozen copy of `byteCount` bytes may be uploaded to the claim folder, else the message to show.
    static func attachRefusal(byteCount: Int) -> String? {
        byteCount > StorageUploadPolicy.standardMaxBytes ? tooLargeMessage : nil
    }

    /// `image` with its longest side at most `maxPixels` (never enlarged), re-encoded as JPEG at `quality`, and the
    /// image to draw, backed by that JPEG so the PDF embeds the compressed bytes. Nil when it cannot be encoded.
    static func downscaledPhoto(_ image: UIImage, maxPixels: CGFloat = maxPhotoPixels, quality: CGFloat = photoQuality) -> (jpeg: Data, image: UIImage)? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let factor = min(1, maxPixels / max(pixelWidth, pixelHeight))
        let target = CGSize(width: max(1, (pixelWidth * factor).rounded()), height: max(1, (pixelHeight * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = redrawn.jpegData(compressionQuality: quality) else { return nil }
        if let provider = CGDataProvider(data: jpeg as CFData),
           let cgImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return (jpeg, UIImage(cgImage: cgImage))
        }
        return UIImage(data: jpeg).map { (jpeg, $0) }
    }

    static func makeData(audit: PersonalSiteAudit, readFile: (String) async throws -> Data) async -> Data? {
        guard let rows = CanonicalBusinessEngine.personalSiteAuditPdfRows(audit) else { return nil }
        var photos: [String: UIImage] = [:]
        var unreadable = Set<String>()
        for item in rows.items where !item.imagePath.isEmpty && photos[item.imagePath] == nil {
            do {
                let data = try await readFile(item.imagePath)
                if let image = UIImage(data: data), let small = downscaledPhoto(image) {
                    photos[item.imagePath] = small.image
                } else {
                    unreadable.insert(item.imagePath)
                }
            } catch {
                unreadable.insert(item.imagePath)
            }
        }
        let unreadableNote = CanonicalBusinessEngine.payeClaimText(
            "PAYE_CLAIM_EVIDENCE_UNREADABLE_NOTE", fallback: "This file could not be read when the report was made. Open it in the app."
        )
        let renderer = UIGraphicsPDFRenderer(bounds: PayeClaimPDFWriter.page)
        return renderer.pdfData { context in
            let writer = PayeClaimPDFWriter(context: context)
            writer.text(rows.title, size: 18, bold: true, gap: 6)
            for line in rows.lines { writer.text(line, size: 11) }
            for item in rows.items {
                writer.y += 10
                writer.text(item.heading, size: 12, bold: true)
                for line in item.lines { writer.text(line, size: 10, color: .darkGray) }
                guard !item.imagePath.isEmpty else { continue }
                if let image = photos[item.imagePath] {
                    writer.image(image)
                } else if unreadable.contains(item.imagePath) {
                    writer.text(unreadableNote, size: 9, color: UIColor(red: 0.6, green: 0.3, blue: 0, alpha: 1))
                }
            }
        }
    }
}
