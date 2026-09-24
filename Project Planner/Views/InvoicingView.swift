//
//  InvoicingView.swift
//  Project Planner
//

import SwiftUI
import UIKit
import PencilKit
import FirebaseFirestore
import PhotosUI

struct InvoicingView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    @State private var landingVersion = 0
    @State private var pendingReviewUserId: String?
    @State private var pendingReviewWeek: WeekRange?
    @State private var didConsumeDeepLink = false

    @Binding var initialReviewUserId: String?
    @Binding var initialReviewWeekStart: Date?

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
                VStack(alignment: .leading, spacing: 14) {
                    if showTimesheetsDisabledMessage && !canShowMyTimesheets && !canShowOperativeTimesheets {
                        timesheetsDisabledMessageCard
                    } else if !userStore.canAccessTimesheetsSurface() {
                        ContentUnavailableView(
                            "Timesheets unavailable",
                            systemImage: "lock.fill",
                            description: Text("No timesheet section is available for this account.")
                        )
                    } else {
                        paymentSummaryCard
                        if canShowOperativeTimesheets {
                            managerLandingCards
                        } else if canShowMyTimesheets {
                            operativeLandingCard
                        } else if showTimesheetsDisabledMessage {
                            timesheetsDisabledMessageCard
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Timesheets")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                captureTimesheetDeepLink()
                await syncLandingDraftsFromCloud()
            }
        }
    }

    init(
        initialReviewUserId: Binding<String?> = .constant(nil),
        initialReviewWeekStart: Binding<Date?> = .constant(nil)
    ) {
        _initialReviewUserId = initialReviewUserId
        _initialReviewWeekStart = initialReviewWeekStart
    }

    private var paymentSummaryCard: some View {
        let note = settings.normalizedUserNote
        return VStack(alignment: .leading, spacing: 10) {
            Text("CURRENT PAYMENT RUN")
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.85))

            if settings.paymentRunMode == .dateRanges, let first = settings.normalizedRanges.first {
                Text("Day \(first.startDay) - Day \(first.endDay)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text(settings.recurringRunDisplaySummary)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }

            if settings.paymentDateMode == .specificDates {
                Text("Paid on day \(settings.normalizedPaymentDates.map(String.init).joined(separator: " & "))")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.82))
            } else {
                Text("Paid every \(settings.recurringPaymentDay.title)")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.82))
            }

            if !note.isEmpty {
                Divider().overlay(Color.white.opacity(0.28))
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.184, green: 0.435, blue: 0.839), Color(red: 0.114, green: 0.306, blue: 0.847)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func timesheetEntryCard(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
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

    private var timesheetsDisabledMessageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Timesheets follow employment type")
                    .font(.headline)
            }
            Text("My Timesheets is for self-employed pay. PAYE accounts keep the current pay run until it is paid, then schedule hours no longer fill the next timesheet. Switch the person back to self-employed if they need timesheets again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var managerLandingCards: some View {
        let _ = landingVersion
        let reviewUsers = managerReviewUsersIncludingPending()
        let openWeek = pendingReviewWeek ?? WeekRange.current(settings: settings)
        let awaiting = landingAwaitingTimesheetCount(users: reviewUsers, preferredWeek: openWeek)
        let signed = reviewUsers.filter {
            let draft = TimesheetDraftStore.load(userId: $0.id, weekStart: openWeek.start)
            return TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: $0) && draft.exportedAt == nil
        }.count
        let exported = reviewUsers.filter { TimesheetDraftStore.load(userId: $0.id, weekStart: openWeek.start).exportedAt != nil }.count

        VStack(spacing: 12) {
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
                .buttonStyle(.plain)
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
                    badge: awaiting > 0 ? "\(awaiting) new" : nil
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                statMiniCard(value: "\(awaiting)", label: "Awaiting sign-off", color: .orange)
                statMiniCard(value: "\(signed)", label: "Signed off", color: .green)
                statMiniCard(value: "\(exported)", label: "Exported", color: .secondary)
            }
        }
    }

    @ViewBuilder
    private func managerTile(title: String, subtitle: String, symbol: String, badge: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 1)
    }

    @ViewBuilder
    private func statMiniCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var usersForManagerTimesheetScope: [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        if isAdminViewer {
            return userStore.organizationUsers.filter {
                $0.isActive &&
                ($0.permissions.operativeMode || $0.permissions.manager || $0.permissions.adminAccess || $0.role == .manager || $0.role == .admin)
            }
        }
        return userStore.organizationUsers.filter {
            $0.isActive && $0.isLineManager(currentUser.id)
        }
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

    private func landingAwaitingTimesheetCount(users: [AppUser], preferredWeek: WeekRange) -> Int {
        var seen = Set<String>()
        for user in users {
            var starts = Set(TimesheetDraftStore.discoverStoredWeekStarts(userId: user.id))
            starts.insert(preferredWeek.start)
            starts.insert(WeekRange.current(settings: settings).start)
            starts.insert(TimesheetPayrollPolicy.timesheetWeekRange(for: settings).start)
            for start in starts {
                let draft = TimesheetDraftStore.load(userId: user.id, weekStart: start)
                guard TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user) else { continue }
                let period = TimesheetPayrollPolicy.periodMatchingStoredStart(start, settings: settings)
                seen.insert("\(user.id)|\(Int(period.start.timeIntervalSince1970))")
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
                    _ = TimesheetDraftStore.ingestCloudRow(row, userId: userId)
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
        initialReviewUserId = nil
        initialReviewWeekStart = nil
        guard !rawId.isEmpty else { return }
        pendingReviewUserId = rawId
        if let weekStart {
            pendingReviewWeek = TimesheetPayrollPolicy.periodMatchingStoredStart(weekStart, settings: settings)
        }
    }
}

enum TimesheetApprovalPolicy {
    static func lineManagerUserIds(for user: AppUser) -> [String] {
        user.lineManagerUserIds
    }

    static func requiresLineManagerCounterSign(for user: AppUser) -> Bool {
        user.hasLineManager
    }

    static func isTimesheetFullyApproved(draft: TimesheetDraft, user: AppUser) -> Bool {
        guard draft.operativeSignedAt != nil else { return false }
        if requiresLineManagerCounterSign(for: user) {
            return draft.managerSignedAt != nil
        }
        return true
    }

    static func awaitingManagerSignOff(draft: TimesheetDraft, user: AppUser) -> Bool {
        requiresLineManagerCounterSign(for: user)
            && draft.operativeSignedAt != nil
            && draft.managerSignedAt == nil
    }

    static func applySelfApprovalIfNoLineManager(draft: inout TimesheetDraft, user: AppUser) {
        // No line manager: operative signature alone completes approval.
        guard !requiresLineManagerCounterSign(for: user) else { return }
        guard draft.operativeSignedAt != nil else { return }
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
        draft.operativeSignedAt != nil && isTimesheetFullyApproved(draft: draft, user: user)
    }
}

enum TimesheetDraftStore {
    private static let defaults = UserDefaults.standard

    static func load(userId: String, weekStart: Date) -> TimesheetDraft {
        guard let data = defaults.data(forKey: key(userId: userId, weekStart: weekStart)),
              let decoded = try? JSONDecoder().decode(TimesheetDraft.self, from: data) else {
            return TimesheetDraft()
        }
        return decoded
    }

    static func save(_ draft: TimesheetDraft, userId: String, weekStart: Date) {
        guard let encoded = try? JSONEncoder().encode(draft) else { return }
        defaults.set(encoded, forKey: key(userId: userId, weekStart: weekStart))
    }

    static func refreshFromCloud(
        userId: String,
        weekStart: Date,
        firebaseBackend: FirebaseBackend,
        organizationId: String
    ) async -> TimesheetDraft? {
        let raw: [String: Any]?
        do {
            raw = try await firebaseBackend.loadTimesheetState(
                organizationId: organizationId,
                userId: userId,
                weekStart: weekStart
            )
        } catch {
            return nil
        }
        guard let raw else { return nil }
        guard let decoded = fromFirestoreMap(raw) else { return nil }
        save(decoded, userId: userId, weekStart: weekStart)
        return decoded
    }

    static func saveToCloud(
        _ draft: TimesheetDraft,
        userId: String,
        weekStart: Date,
        firebaseBackend: FirebaseBackend,
        organizationId: String
    ) async {
        let payload = asFirestoreMap(draft)
        try? await firebaseBackend.saveTimesheetState(
            organizationId: organizationId,
            userId: userId,
            weekStart: weekStart,
            payload: payload
        )
    }

    private static func asFirestoreMap(_ draft: TimesheetDraft) -> [String: Any] {
        [
            "managerNote": draft.managerNote,
            "operativeSignedAt": draft.operativeSignedAt.map(Timestamp.init(date:)) as Any,
            "operativeSignedByName": draft.operativeSignedByName ?? "",
            "operativeSignatureImageBase64": draft.operativeSignatureImageBase64 ?? "",
            "managerSignedAt": draft.managerSignedAt.map(Timestamp.init(date:)) as Any,
            "managerSignedByName": draft.managerSignedByName ?? "",
            "managerSignedByUserId": draft.managerSignedByUserId ?? "",
            "managerSignatureImageBase64": draft.managerSignatureImageBase64 ?? "",
            "exportedAt": draft.exportedAt.map(Timestamp.init(date:)) as Any,
            "weeklyReportOverride": draft.weeklyReportOverride.map(weeklyReportOverrideMap) as Any,
            "expenseEntries": draft.expenseEntries.map { e in
                [
                    "id": e.id.uuidString,
                    "title": e.title,
                    "details": e.details,
                    "jobNumber": e.jobNumber,
                    "date": Timestamp(date: e.date),
                    "amount": e.amount,
                    "receiptName": e.receiptName ?? "",
                    "managerDecision": e.managerDecision.rawValue,
                    "managerRevisedAmount": e.managerRevisedAmount as Any
                ]
            },
            "priceWorkEntries": draft.priceWorkEntries.map { p in
                [
                    "id": p.id.uuidString,
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
            },
            "payrollLineReviews": draft.payrollLineReviews.mapValues { review in
                [
                    "decision": review.decision.rawValue,
                    "revisedAmount": review.revisedAmount as Any
                ]
            }
        ]
    }

    private static func fromFirestoreMap(_ map: [String: Any]) -> TimesheetDraft? {
        var output = TimesheetDraft()
        output.managerNote = map["managerNote"] as? String ?? ""
        output.operativeSignedAt = (map["operativeSignedAt"] as? Timestamp)?.dateValue()
        let operativeSignedBy = (map["operativeSignedByName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.operativeSignedByName = operativeSignedBy.isEmpty ? nil : operativeSignedBy
        let operativeSignature = (map["operativeSignatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.operativeSignatureImageBase64 = operativeSignature.isEmpty ? nil : operativeSignature
        output.managerSignedAt = (map["managerSignedAt"] as? Timestamp)?.dateValue()
        let signedBy = (map["managerSignedByName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignedByName = signedBy.isEmpty ? nil : signedBy
        let signedByUserId = (map["managerSignedByUserId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignedByUserId = signedByUserId.isEmpty ? nil : signedByUserId
        let managerSignature = (map["managerSignatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignatureImageBase64 = managerSignature.isEmpty ? nil : managerSignature
        output.exportedAt = (map["exportedAt"] as? Timestamp)?.dateValue()

        output.expenseEntries = ((map["expenseEntries"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let idRaw = row["id"] as? String,
                  let id = UUID(uuidString: idRaw),
                  let title = row["title"] as? String else { return nil }
            return TimesheetExpenseEntry(
                id: id,
                title: title,
                details: row["details"] as? String ?? "",
                jobNumber: row["jobNumber"] as? String ?? "",
                date: (row["date"] as? Timestamp)?.dateValue() ?? Date(),
                amount: row["amount"] as? Double ?? 0,
                receiptName: row["receiptName"] as? String,
                managerDecision: TimesheetManagerDecision(rawValue: row["managerDecision"] as? String ?? "") ?? .approved,
                managerRevisedAmount: row["managerRevisedAmount"] as? Double
            )
        }

        output.priceWorkEntries = ((map["priceWorkEntries"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let idRaw = row["id"] as? String,
                  let id = UUID(uuidString: idRaw),
                  let title = row["title"] as? String else { return nil }
            return TimesheetPriceWorkEntry(
                id: id,
                title: title,
                details: row["details"] as? String ?? "",
                jobNumber: row["jobNumber"] as? String ?? "",
                agreedManagerName: row["agreedManagerName"] as? String ?? "Manager",
                startDate: (row["startDate"] as? Timestamp)?.dateValue() ?? Date(),
                endDate: (row["endDate"] as? Timestamp)?.dateValue(),
                amount: row["amount"] as? Double ?? 0,
                managerDecision: TimesheetManagerDecision(rawValue: row["managerDecision"] as? String ?? "") ?? .approved,
                managerRevisedAmount: row["managerRevisedAmount"] as? Double
            )
        }

        if let reviewMap = map["payrollLineReviews"] as? [String: [String: Any]] {
            var reviews: [String: TimesheetPayrollLineReview] = [:]
            for (lineId, payload) in reviewMap {
                let decision = TimesheetManagerDecision(rawValue: payload["decision"] as? String ?? "") ?? .pending
                reviews[lineId] = TimesheetPayrollLineReview(
                    decision: decision,
                    revisedAmount: payload["revisedAmount"] as? Double
                )
            }
            output.payrollLineReviews = reviews
        }

        if let overrideMap = map["weeklyReportOverride"] as? [String: Any] {
            output.weeklyReportOverride = weeklyReportOverride(from: overrideMap)
        }

        return output
    }

    static func decodeFirestoreMap(_ map: [String: Any]) -> TimesheetDraft? {
        fromFirestoreMap(map)
    }

    private static func weeklyReportOverrideMap(_ override: TimesheetWeeklyReportOverride) -> [String: Any] {
        [
            "approvedAt": Timestamp(date: override.approvedAt),
            "approvedByUserId": override.approvedByUserId,
            "approvedByName": override.approvedByName,
            "selfSigned": override.selfSigned,
            "lines": override.lines.map { line in
                [
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
                ] as [String: Any]
            },
            "priceWork": override.priceWork.map(moneyLineMap),
            "expenses": override.expenses.map(moneyLineMap)
        ]
    }

    private static func moneyLineMap(_ line: TimesheetWeeklyReportMoneyLine) -> [String: Any] {
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
                bookingId: (bookingId?.isEmpty == false) ? bookingId : nil
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

    private static func key(userId: String, weekStart: Date) -> String {
        let stamp = Int(Calendar.current.startOfDay(for: weekStart).timeIntervalSince1970)
        return "timesheet-draft-\(userId)-\(stamp)"
    }

    /// Local cache keys — used so past pay runs appear before cloud sync finishes.
    static func discoverStoredWeekStarts(userId: String) -> [Date] {
        let prefix = "timesheet-draft-\(userId)-"
        let stamps = UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key -> Date? in
            guard key.hasPrefix(prefix) else { return nil }
            guard let stamp = Int(key.dropFirst(prefix.count)) else { return nil }
            return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(stamp)))
        }
        return stamps.sorted(by: >)
    }

    static func ingestCloudRow(_ row: [String: Any], userId: String) -> Date? {
        guard let weekStart = (row["weekStart"] as? Timestamp)?.dateValue() else { return nil }
        let storedStart = Calendar.current.startOfDay(for: weekStart)
        guard let draft = decodeFirestoreMap(row) else { return nil }
        save(draft, userId: userId, weekStart: storedStart)
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
        if let extraWeekStart {
            starts.insert(Calendar.current.startOfDay(for: extraWeekStart))
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
        guard user.hasLineManager else { return [] }
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
        var byStart: [Date: WeekRange] = [:]
        for weekStart in TimesheetDraftStore.discoverStoredWeekStarts(userId: userId) {
            let week = TimesheetPayrollPolicy.periodMatchingStoredStart(weekStart, settings: settings)
            guard week.start != current.start else { continue }
            byStart[week.start] = week
        }
        for week in TimesheetPayrollPolicy.previousPayPeriods(count: 120, settings: settings) {
            guard week.start != current.start else { continue }
            byStart[week.start] = week
        }
        let sorted = byStart.values.sorted(by: { $0.start > $1.start })
        if !sorted.isEmpty {
            pastWeeks = sorted
        }
    }

    private func loadPastWeeks() async {
        guard let userId = userStore.displayUser?.id else { return }

        await MainActor.run {
            refreshPastWeeksFromLocalCache(userId: userId)
            isLoadingPastWeeks = true
        }
        defer { Task { @MainActor in isLoadingPastWeeks = false } }

        let current = currentWeek
        var byStart: [Date: WeekRange] = [:]

        for weekStart in TimesheetDraftStore.discoverStoredWeekStarts(userId: userId) {
            let week = TimesheetPayrollPolicy.periodMatchingStoredStart(weekStart, settings: settings)
            guard week.start != current.start else { continue }
            byStart[week.start] = week
        }

        if let orgId = organizationId {
            if let rows = try? await firebaseBackend.listTimesheetStates(
                organizationId: orgId,
                userId: userId,
                limit: 200
            ) {
                for row in rows {
                    guard let weekStart = (row["weekStart"] as? Timestamp)?.dateValue() else { continue }
                    let storedStart = Calendar.current.startOfDay(for: weekStart)
                    let week = TimesheetPayrollPolicy.periodMatchingStoredStart(storedStart, settings: settings)
                    guard week.start != current.start else { continue }
                    guard let draft = TimesheetDraftStore.decodeFirestoreMap(row) else { continue }
                    // Always persist under the Firestore weekStart key — never remap to ISO Monday.
                    TimesheetDraftStore.save(draft, userId: userId, weekStart: storedStart)
                    byStart[week.start] = week
                }
            }

            for week in TimesheetPayrollPolicy.previousPayPeriods(count: 120, settings: settings) {
                guard week.start != current.start else { continue }
                byStart[week.start] = week
            }

            // Soft-refresh only the most recent periods from cloud (listing is local/policy; avoid 120 network hits).
            let recentToRefresh = byStart.values.sorted(by: { $0.start > $1.start }).prefix(24)
            for week in recentToRefresh {
                _ = await TimesheetDraftStore.refreshFromCloud(
                    userId: userId,
                    weekStart: week.start,
                    firebaseBackend: firebaseBackend,
                    organizationId: orgId
                )
            }
        }

        let sorted = byStart.values.sorted(by: { $0.start > $1.start })
        await MainActor.run { pastWeeks = sorted }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                hubCard(
                    title: "Current pay run period",
                    subtitle: currentWeek.title,
                    detail: "Review bookings, add extras, and sign your timesheet.",
                    symbol: "calendar",
                    tint: .blue
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

                if !pendingWeeks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pending timesheets")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                        ForEach(pendingWeeks, id: \.start) { week in
                            hubCard(
                                title: week.title,
                                subtitle: "Timesheet pending manager signature",
                                detail: "You signed — waiting for your line manager to counter-sign.",
                                symbol: "clock.fill",
                                tint: .orange
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
                    .padding(.vertical, 8)
                }

                if !pastWeeks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Past timesheets")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                        ForEach(pastWeeks, id: \.start) { week in
                            hubCard(
                                title: week.title,
                                subtitle: pastSubtitle(for: week),
                                detail: "View breakdown, signatures, and generate invoice again.",
                                symbol: "clock.arrow.circlepath",
                                tint: .secondary
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
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("My Timesheets")
        .navigationBarTitleDisplayMode(.inline)
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
        if draft.exportedAt != nil { return "Exported" }
        if TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) { return "Signed off" }
        if TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user) {
            return "Timesheet pending manager signature"
        }
        if draft.operativeSignedAt != nil { return "Partially signed" }
        return "Saved draft"
    }

    @ViewBuilder
    private func hubCard<Destination: View>(
        title: String,
        subtitle: String,
        detail: String,
        symbol: String,
        tint: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MyTimesheetView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService

    let settings: OrganizationInvoicingSettings

    @State private var week: WeekRange
    @State private var draft = TimesheetDraft()
    @State private var showAddExpense = false
    @State private var showAddPriceWork = false
    @State private var showPostSignExtraWarning = false
    @State private var pendingExtraMode: TimesheetExtraMode?
    @State private var showPriceWorkSheet = false
    @State private var showExpenseSheet = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    @State private var showInvoiceUTRWarning = false
    @State private var showInvoiceSuccess = false
    @State private var generatedInvoiceURL: URL?
    @State private var isGeneratingInvoice = false
    @State private var invoiceErrorMessage: String?

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

    private var hoursTotal: Double {
        invoiceRows.reduce(0) { $0 + $1.paidHours }
    }

    private var workAmount: Double {
        invoiceRows.reduce(0) { $0 + $1.amount }
    }

    private var grandTotal: Double {
        TimesheetDraftAdjustments.grandTotal(
            lines: invoiceRows.map(\.payrollLine),
            draft: draft,
            managerHasSigned: managerHasSigned
        )
    }

    private var managerHasSigned: Bool { draft.managerSignedAt != nil }

    private var effectiveWorkAmount: Double {
        TimesheetDraftAdjustments.payrollTotal(
            lines: invoiceRows.map(\.payrollLine),
            draft: draft,
            managerHasSigned: managerHasSigned
        )
    }

    private var effectiveExtrasTotal: Double {
        draft.effectiveAdditionalTotal(managerHasSigned: managerHasSigned)
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
            scheduleOptions: scheduleOptions
        )
        return summary.lineItems.map { InvoiceLineItem(payrollLine: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(week.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if managerHasSigned, TimesheetDraftAdjustments.managerAdjustmentCount(draft: draft) > 0 {
                    TimesheetManagerAdjustmentSummaryCard(
                        draft: draft,
                        managerName: draft.managerSignedByName ?? "Line manager"
                    )
                }

                sectionHeader("This period")

                VStack(alignment: .leading, spacing: 0) {
                    if invoiceRows.isEmpty {
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
                        let review = draft.payrollLineReviews[row.payrollLine.id]
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
                                Text(row.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .strikethrough(removed)
                                Text(timesheetHoursRateLine(for: row))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(row.shouldHighlightRateInOrange ? Color.orange : Color.primary)
                                    .strikethrough(removed)
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
                        .opacity(removed ? 0.55 : 1)
                        if index < invoiceRows.count - 1 { Divider().padding(.horizontal, 14) }
                    }
                    }
                    HStack {
                        Text("Hours subtotal")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "£%.2f", effectiveWorkAmount))
                            .font(.headline)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    if effectiveExtrasTotal > 0 || draft.additionalTotal > 0 {
                        HStack {
                            Text(managerHasSigned ? "Approved extras" : "Extras (price work & expenses)")
                                .font(.subheadline)
                            Spacer()
                            if managerHasSigned && effectiveExtrasTotal != draft.additionalTotal {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "£%.2f", draft.additionalTotal))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .strikethrough()
                                    Text(String(format: "£%.2f", effectiveExtrasTotal))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Text(String(format: "£%.2f", managerHasSigned ? effectiveExtrasTotal : draft.additionalTotal))
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
                        Text(String(format: "£%.2f", grandTotal))
                            .font(.title3.weight(.bold))
                        if managerHasSigned && grandTotal != (workAmount + draft.additionalTotal) {
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
                                    if managerHasSigned && item.managerDecision != .pending {
                                        Text(item.managerDecision.label)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(item.managerDecision.tint)
                                    }
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
                                    if managerHasSigned && item.managerDecision != .pending {
                                        Text(item.managerDecision.label)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(item.managerDecision.tint)
                                    }
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
                HStack(spacing: 10) {
                    Button {
                        beginAddingExtra(.priceWork)
                    } label: {
                        addonTile(title: "Price Work", subtitle: "Agreed extras", symbol: "bolt.fill", tint: Color(red: 0.329, green: 0.29, blue: 0.718))
                    }
                    .buttonStyle(.plain)
                    Button {
                        beginAddingExtra(.expense)
                    } label: {
                        addonTile(title: "Expenses", subtitle: "+ receipts", symbol: "sterlingsign.circle.fill", tint: Color(red: 0.706, green: 0.325, blue: 0.035))
                    }
                    .buttonStyle(.plain)
                }

                if let user = userStore.displayUser, user.hasLineManager {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Note to manager")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $draft.managerNote)
                            .frame(minHeight: 74)
                            .padding(8)
                            .background(ProjectWorksRevampColors.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: draft.managerNote) { _, _ in saveDraft() }
                    }
                    .padding(14)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(
                        (userStore.displayUser?.hasLineManager == true)
                        ? "If you don't agree with the hours shown, contact your line manager to amend your booking schedule before signing. Agreed changes appear on a new timesheet."
                        : "If you don't agree with the hours shown, amend your booking schedule before signing. Agreed changes appear on a new timesheet."
                    )
                        .font(.footnote)
                        .foregroundStyle(Color(red: 0.498, green: 0.113, blue: 0.113))
                }
                .padding(12)
                .background(Color(red: 0.992, green: 0.918, blue: 0.918))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if draft.operativeSignedAt == nil {
                    NavigationLink {
                        SignTimesheetView(
                            week: week,
                            hoursAmount: workAmount,
                            priceWorkAmount: draft.priceWorkEntries.reduce(0) { $0 + $1.amount },
                            expensesAmount: draft.expenseEntries.reduce(0) { $0 + $1.amount },
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
                    if currentUser.hasLineManager {
                        Text("To edit this timesheet, please go to the signed off timesheets page, export it and then edit within the exported timesheets tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Add expense") {
                        showAddExpense = true
                    }
                    .buttonStyle(.bordered)

                    if draft.operativeSignedAt == nil {
                        Button("Sign timesheet") {
                            draft.operativeSignedAt = Date()
                            saveDraft()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
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
        .onAppear { loadDraft() }
        .task { await loadDayRateHistory() }
        .confirmationDialog(
            "Re-sign required",
            isPresented: $showPostSignExtraWarning,
            titleVisibility: .visible
        ) {
            Button("Accept — add anyway") {
                TimesheetApprovalPolicy.clearSignatures(draft: &draft)
                saveDraft()
                openPendingExtraSheet()
            }
            Button("Decline", role: .cancel) {
                pendingExtraMode = nil
            }
        } message: {
            Text(postSignWarningMessage)
        }
        .sheet(isPresented: $showPriceWorkSheet) {
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .priceWork) { entry in
                    draft.priceWorkEntries.append(entry)
                    saveDraft()
                    showPriceWorkSheet = false
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
            }
        }
        .sheet(isPresented: $showExpenseSheet) {
            NavigationStack {
                TimesheetMoneyEntrySheet(mode: .expense) { entry in
                    draft.expenseEntries.append(entry)
                    saveDraft()
                    showExpenseSheet = false
                }
                .environmentObject(userStore)
                .environmentObject(projectStore)
            }
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
        if user.trimmedUTRNumber == nil {
            showInvoiceUTRWarning = true
        } else {
            Task { await runInvoiceGeneration() }
        }
    }

    private func runInvoiceGeneration() async {
        guard !isGeneratingInvoice else { return }
        await MainActor.run { isGeneratingInvoice = true; invoiceErrorMessage = nil }
        defer { Task { await MainActor.run { isGeneratingInvoice = false } } }

        if dayRateHistoryCollection.byUserId.isEmpty && dayRateHistoryCollection.byOperativeId.isEmpty {
            await loadDayRateHistory()
        }

        let pdfURL = InvoicePDFGenerationSupport.generatePDF(
            period: weekInvoicePeriod,
            settings: settings,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection
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

    private func beginAddingExtra(_ mode: TimesheetExtraMode) {
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
        .background(Color.white)
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
        .background(Color.white)
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

    private func markTimesheetSigned(signatureImageData: Data) {
        draft.operativeSignedAt = Date()
        draft.operativeSignedByName = userStore.displayUser?.fullName.isEmpty == false
            ? userStore.displayUser?.fullName
            : userStore.displayUser?.email
        draft.operativeSignatureImageBase64 = signatureImageData.base64EncodedString()
        if let current = userStore.displayUser {
            TimesheetApprovalPolicy.applySelfApprovalIfNoLineManager(draft: &draft, user: current)
        }
        saveDraft()
        guard let current = userStore.displayUser else { return }
        guard TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: current) else { return }
        let managerIds = TimesheetApprovalPolicy.lineManagerUserIds(for: current)
        Task {
            for managerId in managerIds {
                await notificationService.notifyTimesheetPendingManagerSignoff(
                    signedByUser: current,
                    lineManagerUserId: managerId,
                    weekStart: week.start
                )
            }
        }
    }

    private func saveDraft() {
        if let current = userStore.displayUser {
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
                viewer: current
            )
        }
        TimesheetDraftStore.save(draft, userId: currentUserId, weekStart: week.start)
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let snapshot = draft
        Task {
            await TimesheetDraftStore.saveToCloud(
                snapshot,
                userId: currentUserId,
                weekStart: week.start,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
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
        guard let remote = await TimesheetDraftStore.refreshFromCloud(
            userId: currentUserId,
            weekStart: week.start,
            firebaseBackend: firebaseBackend,
            organizationId: orgId
        ) else { return }
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

    private func loadDayRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let history = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
        await MainActor.run { dayRateHistoryCollection = history }
    }

    private func timesheetHoursRateLine(for row: InvoiceLineItem) -> String {
        let hours = formatTimesheetHours(row.paidHours)
        return "\(hours)h · \(row.timesheetRateAnnotation)"
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
    @State private var showInvoiceUTRWarning = false
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

                    if let run = selectedRun {
                        summaryCard(run)
                        signatureCard(run)
                        if run.isCompleted || (userStore.displayUser.map { TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: run.draft, user: $0) } ?? false),
                           let selectedPeriod,
                           let currentUser = userStore.displayUser {
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
        if user.trimmedUTRNumber == nil {
            showInvoiceUTRWarning = true
        } else {
            Task { await runPendingInvoiceGeneration() }
        }
    }

    private func runPendingInvoiceGeneration() async {
        guard let period = pendingInvoicePeriod else { return }
        guard !isGeneratingInvoice else { return }
        isGeneratingInvoice = true
        invoiceErrorMessage = nil
        defer { isGeneratingInvoice = false }

        let pdfURL = InvoicePDFGenerationSupport.generatePDF(
            period: period,
            settings: settings,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection
        )

        if let pdfURL {
            generatedInvoiceURL = pdfURL
            showInvoiceSuccess = true
        } else {
            invoiceErrorMessage = "Failed to generate the invoice PDF."
        }
    }

    private func loadDayRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let history = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
        await MainActor.run { dayRateHistoryCollection = history }
    }

    @ViewBuilder
    private func summaryCard(_ run: PreviousTimesheetRun) -> some View {
        let summary = bookingSummary(for: run.week)
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
            row("Hours", "\(formatHours(summary.hours))h")
            row("Overtime", "\(formatHours(summary.overtimeHours))h")
            row("Price work", String(format: "£%.2f", run.draft.priceWorkEntries.reduce(0) { $0 + $1.amount }))
            row("Expenses", String(format: "£%.2f", run.draft.expenseEntries.reduce(0) { $0 + $1.amount }))
            Divider()
            row("Summary total", String(format: "£%.2f", summary.baseAmount + summary.overtimeAmount + run.draft.priceWorkEntries.reduce(0) { $0 + $1.amount } + run.draft.expenseEntries.reduce(0) { $0 + $1.amount }))
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
                guard let weekStart = (row["weekStart"] as? Timestamp)?.dateValue() else { continue }
                let storedStart = Calendar.current.startOfDay(for: weekStart)
                let week = TimesheetPayrollPolicy.periodMatchingStoredStart(storedStart, settings: settings)
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
                TimesheetDraftStore.save(adjusted, userId: userId, weekStart: storedStart)
                output.append(
                    PreviousTimesheetRun(
                        id: "prev-\(Int(week.start.timeIntervalSince1970))",
                        week: week,
                        draft: adjusted
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
                            draft: merged
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

    private func bookingSummary(for week: WeekRange) -> (hours: Double, overtimeHours: Double, baseAmount: Double, overtimeAmount: Double) {
        guard let currentUser = userStore.displayUser else { return (0, 0, 0, 0) }
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
            scheduleOptions: scheduleOptions
        )
        return (summary.totalHours, summary.overtimeHours, summary.baseAmount, summary.overtimeAmount)
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

    var isCompleted: Bool {
        draft.operativeSignedAt != nil && draft.managerSignedAt != nil
    }
}

private struct OperativeTimesheetsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    let settings: OrganizationInvoicingSettings
    let week: WeekRange
    let initialReviewUserId: String?
    @State private var selectedTab: ManagerTimesheetListTab = .awaiting
    @State private var refreshVersion = 0
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    @State private var exportedHistory: [ExportedTimesheetHistoryRow] = []
    @State private var isLoadingExportedHistory = false
    @State private var awaitingRows: [ManagerTimesheetRow] = []
    @State private var autoOpenReview: TimesheetAutoOpenTarget?
    @State private var didAutoOpenReview = false

    private var isAdminViewer: Bool {
        guard let u = userStore.displayUser else { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.role == .admin
    }

    init(
        settings: OrganizationInvoicingSettings,
        week: WeekRange? = nil,
        initialReviewUserId: String? = nil
    ) {
        self.settings = settings
        self.week = week ?? TimesheetPayrollPolicy.payPeriodContaining(settings: settings)
        self.initialReviewUserId = initialReviewUserId
    }

    private var extraReviewUser: AppUser? {
        guard let id = initialReviewUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == id })
    }

    private var managerScopeUsers: [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        var users: [AppUser]
        if isAdminViewer {
            users = userStore.organizationUsers.filter { user in
                user.isActive
                && (user.permissions.operativeMode || user.permissions.manager || user.permissions.adminAccess || user.role == .manager || user.role == .admin)
            }
        } else {
            users = userStore.organizationUsers.filter { user in
                user.isActive && user.isLineManager(currentUser.id)
            }
        }
        if let extra = extraReviewUser, !users.contains(where: { $0.id == extra.id }) {
            users.append(extra)
        }
        return users.sorted(by: { $0.fullName < $1.fullName })
    }

    private var directReports: [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        var users: [AppUser]
        if isAdminViewer {
            users = userStore.organizationUsers
                .filter { user in
                    user.isActive
                    && TimesheetPayrollPolicy.shouldAppearInOperativeTimesheetRoster(user: user, week: week, settings: settings)
                    && (user.permissions.operativeMode || user.permissions.manager || user.permissions.adminAccess || user.role == .manager || user.role == .admin)
                }
        } else {
            users = userStore.organizationUsers
                .filter { user in
                    user.isActive
                    && TimesheetPayrollPolicy.shouldAppearInOperativeTimesheetRoster(user: user, week: week, settings: settings)
                    && user.isLineManager(currentUser.id)
                }
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
            switch selectedTab {
            case .awaiting:
                return TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user)
            case .signedOff:
                return TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) && draft.exportedAt == nil
            case .exported:
                return draft.exportedAt != nil
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Status", selection: $selectedTab) {
                    Text("Awaiting sign-off").tag(ManagerTimesheetListTab.awaiting)
                    Text("Signed off").tag(ManagerTimesheetListTab.signedOff)
                    Text("Exported").tag(ManagerTimesheetListTab.exported)
                }
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
                        } else {
                            ForEach(exportedHistory) { row in
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
                                        Circle()
                                            .fill(Color.blue.opacity(0.85))
                                            .frame(width: 38, height: 38)
                                            .overlay(
                                                Text(initials(for: row.user))
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(.white)
                                            )
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
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                if row.id != exportedHistory.last?.id {
                                    Divider().padding(.leading, 60)
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
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: 38, height: 38)
                                    .overlay(
                                        Text(initials(for: row.user))
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.user.fullName.isEmpty ? row.user.email : row.user.fullName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    let draft = TimesheetDraftStore.load(userId: row.user.id, weekStart: row.week.start)
                                    let summary = operativeSummary(for: row.user, draft: draft, week: row.week)
                                    Text("\(row.week.title) · Hrs \(formatHours(summary.hours)) · OT \(formatHours(summary.overtimeHours)) · PW \(String(format: "£%.2f", summary.priceWork)) · Exp \(String(format: "£%.2f", summary.expenses))")
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
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if row.id != awaitingRows.last?.id {
                            Divider().padding(.leading, 60)
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
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: 38, height: 38)
                                    .overlay(
                                        Text(initials(for: operative))
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(operative.fullName.isEmpty ? operative.email : operative.fullName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    let draft = TimesheetDraftStore.load(userId: operative.id, weekStart: week.start)
                                    let summary = operativeSummary(for: operative, draft: draft, week: week)
                                    Text("\(week.title) · Hrs \(formatHours(summary.hours)) · OT \(formatHours(summary.overtimeHours)) · PW \(String(format: "£%.2f", summary.priceWork)) · Exp \(String(format: "£%.2f", summary.expenses))")
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
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if operative.id != filteredReports.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                    }
                }
                .padding(8)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if selectedTab == .signedOff && !filteredReports.isEmpty {
                    Button {
                        Task { await exportSignedTimesheets() }
                    } label: {
                        Label(
                            isExporting ? "Sending timesheets…" : "Email and export \(filteredReports.count) timesheets",
                            systemImage: "envelope.fill"
                        )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(isAdminViewer ? "User Timesheets" : "Operative Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $autoOpenReview) { target in
            if let operative = userStore.organizationUsers.first(where: { $0.id == target.userId }) {
                let reviewWeek = TimesheetPayrollPolicy.periodMatchingStoredStart(target.weekStart, settings: settings)
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
    }

    @ViewBuilder
    private func statusPill(for draft: TimesheetDraft, user: AppUser) -> some View {
        if draft.exportedAt != nil {
            Label("Exported", systemImage: "tray.and.arrow.up.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        } else if TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) {
            Label("Signed off", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.14))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if draft.operativeSignedAt != nil {
            Label("Pending", systemImage: "clock.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.14))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else {
            Label("Not signed", systemImage: "circle")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
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
                    _ = TimesheetDraftStore.ingestCloudRow(row, userId: user.id)
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
            var starts = Set(TimesheetDraftStore.discoverStoredWeekStarts(userId: user.id))
            starts.insert(week.start)
            starts.insert(WeekRange.current(settings: settings).start)
            starts.insert(TimesheetPayrollPolicy.timesheetWeekRange(for: settings).start)
            for start in starts {
                let draft = TimesheetDraftStore.load(userId: user.id, weekStart: start)
                guard TimesheetApprovalPolicy.awaitingManagerSignOff(draft: draft, user: user) else { continue }
                let period = TimesheetPayrollPolicy.periodMatchingStoredStart(start, settings: settings)
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

    private func loadDayRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let history = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
        await MainActor.run { dayRateHistoryCollection = history }
    }

    private func exportSignedTimesheets() async {
        guard !isExporting else { return }
        isExporting = true
        exportMessage = nil
        defer { isExporting = false }

        guard let exporter = userStore.displayUser else {
            exportMessage = "Failed: no signed-in manager/admin to receive the export email."
            return
        }
        let recipientEmail = exporter.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipientEmail.isEmpty else {
            exportMessage = "Failed: your account has no email address for the timesheet export."
            return
        }

        let orgName = firebaseBackend.currentOrganization?.name ?? "Organization"
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let scheduleOptions = firebaseBackend.currentOrganization?.settings.myScheduleOptions ?? MyScheduleOptions()
        let targets = filteredReports
        let result = await TimesheetExportHelper.exportAndEmail(
            operatives: targets,
            week: week,
            draftForUser: { TimesheetDraftStore.load(userId: $0.id, weekStart: week.start) },
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            dayRateHistory: dayRateHistoryCollection,
            payrollPolicy: policy,
            organization: firebaseBackend.currentOrganization,
            organizationName: orgName,
            scheduleOptions: scheduleOptions,
            recipientEmail: recipientEmail,
            recipientName: exporter.fullName.isEmpty ? exporter.email : exporter.fullName,
            firebaseBackend: firebaseBackend
        )

        guard result.emailSent else {
            exportMessage = result.failed.isEmpty
                ? "Failed to send timesheet export email to \(recipientEmail)."
                : "Failed to send timesheet export email. \(result.failed.joined(separator: ", "))."
            return
        }

        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            exportMessage = "Emailed \(result.emailed) timesheet\(result.emailed == 1 ? "" : "s") to \(recipientEmail), but could not mark them exported (no organization)."
            return
        }

        for op in targets where result.emailedUserIds.contains(op.id) {
            var d = TimesheetDraftStore.load(userId: op.id, weekStart: week.start)
            d.exportedAt = Date()
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
                viewer: exporter
            )
            TimesheetDraftStore.save(d, userId: op.id, weekStart: week.start)
            let snapshot = d
            await TimesheetDraftStore.saveToCloud(
                snapshot,
                userId: op.id,
                weekStart: week.start,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
        }

        refreshVersion += 1
        rebuildAwaitingRows()
        await loadExportedHistory()
        selectedTab = .exported
        if result.failed.isEmpty {
            exportMessage = "Emailed \(result.emailed) timesheet PDF\(result.emailed == 1 ? "" : "s") to \(recipientEmail) for filing."
        } else {
            exportMessage = "Emailed \(result.emailed) to \(recipientEmail). Skipped: \(result.failed.joined(separator: ", "))."
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

        for user in users {
            var weekStarts = Set(TimesheetDraftStore.discoverStoredWeekStarts(userId: user.id))
            for period in TimesheetPayrollPolicy.previousPayPeriods(count: 260, settings: settings) {
                weekStarts.insert(period.start)
            }
            weekStarts.insert(week.start)

            if let orgId,
               let cloudRows = try? await firebaseBackend.listTimesheetStates(
                   organizationId: orgId,
                   userId: user.id,
                   limit: 400
               ) {
                for row in cloudRows {
                    guard let weekStart = (row["weekStart"] as? Timestamp)?.dateValue() else { continue }
                    let day = Calendar.current.startOfDay(for: weekStart)
                    weekStarts.insert(day)
                    if let decoded = TimesheetDraftStore.decodeFirestoreMap(row), decoded.exportedAt != nil {
                        TimesheetDraftStore.save(decoded, userId: user.id, weekStart: day)
                    }
                }
            }

            for start in weekStarts {
                let draft = TimesheetDraftStore.load(userId: user.id, weekStart: start)
                guard draft.exportedAt != nil else { continue }
                let period = TimesheetPayrollPolicy.periodMatchingStoredStart(start, settings: settings)
                let rowId = "\(user.id)|\(Int(period.start.timeIntervalSince1970))"
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

    private func usersForExportedHistory() -> [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        if isAdminViewer {
            return userStore.organizationUsers
                .filter { user in
                    user.isActive
                    && (user.permissions.operativeMode
                        || user.permissions.manager
                        || user.permissions.adminAccess
                        || user.role == .manager
                        || user.role == .admin)
                }
                .sorted(by: { $0.fullName < $1.fullName })
        }
        return userStore.organizationUsers
            .filter { user in
                user.isActive && user.isLineManager(currentUser.id)
            }
            .sorted(by: { $0.fullName < $1.fullName })
    }

    private func operativeSummary(for user: AppUser, draft: TimesheetDraft, week reviewWeek: WeekRange? = nil) -> (hours: Double, overtimeHours: Double, priceWork: Double, expenses: Double) {
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
            scheduleOptions: scheduleOptions
        )
        return (
            summary.totalHours,
            summary.overtimeHours,
            draft.priceWorkEntries.reduce(0) { $0 + $1.amount },
            draft.expenseEntries.reduce(0) { $0 + $1.amount }
        )
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
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    let operative: AppUser
    let settings: OrganizationInvoicingSettings
    let week: WeekRange
    @State private var draft = TimesheetDraft()
    @State private var showingManagerSignSheet = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    @State private var editingPayrollLineId: String?
    @State private var editingExpenseId: UUID?
    @State private var editingPriceWorkId: UUID?
    @State private var showExtrasReviewRequiredAlert = false

    private var canManagerReview: Bool {
        guard let viewer = userStore.displayUser else { return false }
        let isAdmin = viewer.isSuperAdmin || viewer.permissions.adminAccess || viewer.role == .admin
        let isLineManager = operative.isLineManager(viewer.id)
        guard isAdmin || isLineManager else { return false }
        if draft.exportedAt != nil {
            return TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative)
        }
        return operative.hasLineManager && draft.managerSignedAt == nil && draft.operativeSignedAt != nil
    }

    private var managerHasSigned: Bool { draft.managerSignedAt != nil }

    private var effectiveGrandTotal: Double {
        TimesheetDraftAdjustments.grandTotal(
            lines: payrollSummary.lineItems,
            draft: draft,
            managerHasSigned: managerHasSigned,
            applyLiveReview: canManagerReview
        )
    }

    var body: some View {
        reviewScrollContent
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Review Timesheet")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draft = TimesheetDraftStore.load(userId: operative.id, weekStart: week.start)
                Task { await refreshDraftFromCloud() }
            }
            .task { await loadDayRateHistory() }
            .alert("Review required", isPresented: $showExtrasReviewRequiredAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please approve, decline or edit each expense and price-work item using the buttons provided.")
            }
            .modifier(OperativeTimesheetReviewSheetsModifier(
                draft: $draft,
                operative: operative,
                week: week,
                payrollLines: payrollSummary.lineItems,
                policy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
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
            if payrollSummary.lineItems.isEmpty {
                Text("No bookings found for this period.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            rowLine(
                title: "Hours · \(hoursSummary.shifts) shifts (\(formatHours(hoursSummary.hours))h)",
                amount: normalHoursTotal
            )
            rowLine(title: "Overtime", amount: overtimeTotal)
            rowLine(
                title: "Price work · \(draft.priceWorkEntries.count)",
                amount: TimesheetDraftAdjustments.priceWorkTotal(
                    draft: draft,
                    managerHasSigned: managerHasSigned,
                    applyLiveReview: canManagerReview
                )
            )
            rowLine(
                title: "Expenses · \(draft.expenseEntries.count)",
                amount: TimesheetDraftAdjustments.expensesTotal(
                    draft: draft,
                    managerHasSigned: managerHasSigned,
                    applyLiveReview: canManagerReview
                )
            )
            Divider()
            rowLine(title: managerHasSigned ? "Approved total" : "Total", amount: effectiveGrandTotal)
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

    @ViewBuilder
    private var reviewExpensesCard: some View {
        if !draft.expenseEntries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(canManagerReview ? "Expenses — review required" : "Expenses")
                    .font(.headline)
                ForEach(Array(draft.expenseEntries.enumerated()), id: \.element.id) { index, entry in
                    managerExtraRow(
                        title: entry.title,
                        subtitle: "\(entry.date.formatted(date: .abbreviated, time: .omitted)) · \(entry.jobNumber)",
                        amount: entry.amount,
                        decision: entry.managerDecision,
                        revisedAmount: entry.managerRevisedAmount,
                        canReview: canManagerReview,
                        onApprove: { updateExpenseDecision(at: index, decision: .approved) },
                        onDecline: { updateExpenseDecision(at: index, decision: .declined) },
                        onEdit: { editingExpenseId = entry.id }
                    )
                    .id("\(entry.id)-\(entry.managerDecision.rawValue)-\(entry.managerRevisedAmount ?? -1)")
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
                        subtitle: "Agreed with: \(row.agreedManagerName) · \(row.startDate.formatted(date: .abbreviated, time: .omitted)) · \(row.jobNumber)",
                        amount: row.amount,
                        decision: row.managerDecision,
                        revisedAmount: row.managerRevisedAmount,
                        canReview: canManagerReview,
                        onApprove: { updatePriceWorkDecision(at: index, decision: .approved) },
                        onDecline: { updatePriceWorkDecision(at: index, decision: .declined) },
                        onEdit: { editingPriceWorkId = row.id }
                    )
                    .id("\(row.id)-\(row.managerDecision.rawValue)-\(row.managerRevisedAmount ?? -1)")
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
            if operative.hasLineManager {
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
        } else if operative.hasLineManager, draft.managerSignedAt == nil {
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
            .buttonStyle(.plain)
            .disabled(draft.operativeSignedAt == nil)
            .opacity(draft.operativeSignedAt == nil ? 0.5 : 1)
        }
    }

    private var normalHoursTotal: Double {
        TimesheetDraftAdjustments.payrollTotal(
            lines: payrollSummary.lineItems.filter { !$0.isOvertimeLine },
            draft: draft,
            managerHasSigned: managerHasSigned,
            applyLiveReview: canManagerReview
        )
    }

    private var overtimeTotal: Double {
        TimesheetDraftAdjustments.payrollTotal(
            lines: payrollSummary.lineItems.filter { $0.isOvertimeLine },
            draft: draft,
            managerHasSigned: managerHasSigned,
            applyLiveReview: canManagerReview
        )
    }

    private var needsExtrasReviewMessage: Bool {
        TimesheetDraftAdjustments.extrasPendingReview(in: draft)
            && (!draft.expenseEntries.isEmpty || !draft.priceWorkEntries.isEmpty)
    }

    private func handleSignOffTapped() {
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
        if let signedAt = draft.operativeSignedAt {
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
        let review = draft.payrollLineReviews[row.id]
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
        let effectiveAmount: Double = {
            guard canReview else { return amount }
            switch decision {
            case .declined: return 0
            case .edited: return revisedAmount ?? amount
            case .approved, .pending: return amount
            }
        }()
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
                        Text(String(format: "£%.2f", amount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .strikethrough(true, color: .secondary)
                        Text(String(format: "£%.2f", revised))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.blue)
                    } else if declined {
                        Text(String(format: "£%.2f", amount))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .strikethrough(true, color: .secondary)
                    } else {
                        Text(String(format: "£%.2f", effectiveAmount))
                            .font(.subheadline.weight(.bold))
                    }
                }
            } else {
                TimesheetAdjustedAmountText(
                    original: amount,
                    effective: decision == .edited ? (revisedAmount ?? amount) : (declined ? 0 : amount),
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
        if draft.operativeSignedAt != nil {
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
            Text(String(format: "£%.2f", amount))
                .fontWeight(.semibold)
        }
        .padding(.vertical, 2)
    }

    private func saveDraft() {
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
            viewer: userStore.displayUser
        )
        TimesheetDraftStore.save(draft, userId: operative.id, weekStart: week.start)
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let snapshot = draft
        Task {
            await TimesheetDraftStore.saveToCloud(
                snapshot,
                userId: operative.id,
                weekStart: week.start,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
        }
    }

    private func refreshDraftFromCloud() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        guard let remote = await TimesheetDraftStore.refreshFromCloud(
            userId: operative.id,
            weekStart: week.start,
            firebaseBackend: firebaseBackend,
            organizationId: orgId
        ) else { return }
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

    private func loadDayRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let history = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
        await MainActor.run { dayRateHistoryCollection = history }
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
            scheduleOptions: scheduleOptions
        )
    }

    private var hoursSummary: (hours: Double, shifts: Int, amount: Double, overtimeAmount: Double) {
        let summary = payrollSummary
        return (summary.totalHours, summary.shiftCount, summary.baseAmount, summary.overtimeAmount)
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

    private func applyPayrollReviewSave(lineId: String, row: TimesheetPayrollLineItem, revisedAmount: Double) {
        let prior = draft.payrollLineReviews[lineId]?.decision ?? .approved
        let unchanged = abs(revisedAmount - row.amount) < 0.01
        let decision: TimesheetManagerDecision
        if prior == .declined {
            decision = .approved
        } else if unchanged {
            decision = .approved
        } else {
            decision = .edited
        }
        draft.payrollLineReviews[lineId] = TimesheetPayrollLineReview(
            decision: decision,
            revisedAmount: unchanged ? nil : revisedAmount
        )
        editingPayrollLineId = nil
        onSaveDraft()
    }

    private func applyExtraReviewSave(
        expenseId: UUID?,
        priceWorkId: UUID?,
        revisedAmount: Double
    ) {
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
            let initialChoice = TimesheetPayrollLineBookingLookup.initialChoice(
                for: row,
                operativeBooking: operativeBooking,
                managerBooking: managerBooking,
                policy: policy
            )
            TimesheetPayrollLineEditHoursSheet(
                row: row,
                policy: policy,
                initialChoice: initialChoice,
                onSave: { value in
                    applyPayrollReviewSave(lineId: lineId, row: row, revisedAmount: value)
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
                draft.managerSignedAt = Date()
                draft.managerSignedByName = userStore.displayUser?.fullName.isEmpty == false
                    ? userStore.displayUser?.fullName
                    : userStore.displayUser?.email
                draft.managerSignedByUserId = userStore.displayUser?.id
                draft.managerSignatureImageBase64 = signatureImageData.base64EncodedString()
                onSaveDraft()
                let signer = draft.managerSignedByName ?? "Line manager"
                let signerId = userStore.displayUser?.id ?? ""
                let operativeName = operative.fullName.isEmpty ? operative.email : operative.fullName
                Task {
                    await notificationService.notifyTimesheetSignedByManager(
                        targetUserId: operative.id,
                        signedByName: signer,
                        weekStart: week.start
                    )
                    let peers = operative.lineManagerUserIds.filter { $0 != signerId }
                    if !peers.isEmpty {
                        await notificationService.notifyLineManagerPeerAction(
                            actorName: signer,
                            actionSummary: "\(operativeName)'s timesheet (\(week.title))",
                            peerManagerUserIds: peers,
                            excludingActorUserId: signerId,
                            actionVerb: "signed"
                        )
                    }
                }
                showingManagerSignSheet = false
            }
        }
        .presentationDetents([.large])
    }
}

private struct TimesheetMoneyEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    let mode: Mode
    let onSaveExpense: (TimesheetExpenseEntry) -> Void
    let onSavePriceWork: (TimesheetPriceWorkEntry) -> Void

    @State private var entryTitle = ""
    @State private var details = ""
    @State private var jobNumber = ""
    @State private var amountText = ""
    @State private var managerName = ""
    @State private var date = Date()
    @State private var endDate: Date?
    @State private var includeEndDate = false
    @State private var receiptItem: PhotosPickerItem?
    @State private var receiptName: String?

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: "£", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var managerSuggestions: [String] {
        let query = managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for user in userStore.organizationUsers where user.isActive {
            let isManager = user.permissions.manager || user.role == .manager || user.permissions.adminAccess || user.role == .admin || user.isSuperAdmin
            guard isManager else { continue }
            let haystack = "\(user.fullName) \(user.firstName) \(user.surname) \(user.email)"
            guard haystack.localizedCaseInsensitiveContains(query) else { continue }
            let name = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.caseInsensitiveCompare(query) != .orderedSame, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return Array(names.prefix(6))
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

    init(mode: Mode, onSave: @escaping (TimesheetExpenseEntry) -> Void) {
        self.mode = mode
        self.onSaveExpense = onSave
        self.onSavePriceWork = { _ in }
    }

    init(mode: Mode, onSave: @escaping (TimesheetPriceWorkEntry) -> Void) {
        self.mode = mode
        self.onSaveExpense = { _ in }
        self.onSavePriceWork = onSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                moneyCard {
                    labeledField(mode == .expense ? "Expense name" : "Price work name", text: $entryTitle)
                    Divider().overlay(ProjectWorksRevampColors.border)
                    labeledMultiline("Description", text: $details)
                    Divider().overlay(ProjectWorksRevampColors.border)
                    labeledField("Job number", text: $jobNumber)
                    suggestionRow(jobSuggestions) { jobNumber = $0 }
                    Divider().overlay(ProjectWorksRevampColors.border)
                    labeledField("Amount", text: $amountText, keyboard: .decimalPad)
                }

                moneyCard {
                    DatePicker(mode == .expense ? "Date" : "Start date", selection: $date, displayedComponents: .date)
                        .font(.system(size: 13, weight: .medium))
                    if mode == .priceWork {
                        Divider().overlay(ProjectWorksRevampColors.border)
                        Toggle("Add end date", isOn: $includeEndDate)
                            .font(.system(size: 13, weight: .medium))
                        if includeEndDate {
                            DatePicker("End date", selection: Binding(
                                get: { endDate ?? date },
                                set: { endDate = $0 }
                            ), displayedComponents: .date)
                            .font(.system(size: 13, weight: .medium))
                        }
                    }
                }

                if mode == .priceWork {
                    moneyCard {
                        labeledField("Manager who agreed this", text: $managerName)
                        suggestionRow(managerSuggestions) { managerName = $0 }
                    }
                }

                if mode == .expense {
                    moneyCard {
                        PhotosPicker(selection: $receiptItem, matching: .any(of: [.images, .not(.livePhotos)])) {
                            HStack {
                                Image(systemName: "paperclip")
                                    .foregroundStyle(ProjectWorksRevampColors.blue)
                                Text("Upload receipt")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                Spacer()
                                Text(receiptName ?? "Required")
                                    .font(.system(size: 12))
                                    .foregroundStyle(receiptName == nil ? ProjectWorksRevampColors.requiredPillFg : ProjectWorksRevampColors.blue)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle(mode == .expense ? "Add Expense" : "Add Price Work")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .expense ? "Add expense" : "Add price work") {
                    guard let amount, amount > 0 else { return }
                    if mode == .expense {
                        onSaveExpense(
                            .init(
                                id: UUID(),
                                title: entryTitle.isEmpty ? "Untitled expense" : entryTitle,
                                details: details,
                                jobNumber: jobNumber,
                                date: date,
                                amount: amount,
                                receiptName: receiptName
                            )
                        )
                    } else {
                        onSavePriceWork(
                            .init(
                                id: UUID(),
                                title: entryTitle.isEmpty ? "Untitled price work" : entryTitle,
                                details: details,
                                jobNumber: jobNumber,
                                agreedManagerName: managerName.isEmpty ? "Manager" : managerName,
                                startDate: date,
                                endDate: includeEndDate ? endDate : nil,
                                amount: amount
                            )
                        )
                    }
                    dismiss()
                }
                .disabled(amount == nil || (amount ?? 0) <= 0 || (mode == .expense && receiptName == nil))
            }
        }
        .onChange(of: receiptItem) { _, newItem in
            guard let newItem else { return }
            if let name = newItem.supportedContentTypes.first?.preferredFilenameExtension {
                receiptName = "receipt.\(name)"
            } else {
                receiptName = "receipt-uploaded"
            }
        }
    }

    private func moneyCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
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
                    stat("Hours", String(format: "£%.2f", hoursAmount))
                    stat("Price work", String(format: "£%.2f", priceWorkAmount))
                    stat("Expenses", String(format: "£%.2f", expensesAmount))
                    HStack {
                        Text("Timesheet total")
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(String(format: "£%.2f", total))
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
                        .foregroundStyle(Color(red: 0.498, green: 0.113, blue: 0.113))
                }
                .padding(12)
                .background(Color(red: 0.992, green: 0.918, blue: 0.918))
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
                .buttonStyle(.plain)
                .disabled(signatureImageData == nil)
                .opacity(signatureImageData == nil ? 0.5 : 1)
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
                .buttonStyle(.plain)
                .disabled(signatureImageData == nil)
                .opacity(signatureImageData == nil ? 0.5 : 1)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sign Off")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
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
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(24)
            .navigationTitle("Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
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
        dayRateHistoryCollection: OperativeDayRateHistoryCollection
    ) -> URL? {
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

        let rows = invoiceLineItems(
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
            history: history
        )
        let total = rows.reduce(0) { $0 + $1.amount }
        let notes = rateChangeNotes(
            for: period,
            currentUser: currentUser,
            operatives: operatives,
            dayRateHistoryCollection: history
        )
        return InvoicePDFBuilder.makePDF(
            context: InvoicePDFBuilder.Context(
                organizationName: orgName,
                userName: userName,
                vatNumber: currentUser.trimmedVATNumber,
                utrNumber: currentUser.trimmedUTRNumber,
                generatedAt: Date(),
                periodTitle: period.title,
                periodDateRange: period.dateRangeText,
                lineItems: rows,
                totalAmount: total,
                rateChangeNotes: notes
            )
        )
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
        history: OperativeDayRateHistoryCollection
    ) -> [InvoiceLineItem] {
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
            scheduleOptions: scheduleOptions
        )
        var rows = summary.lineItems.map { InvoiceLineItem(payrollLine: $0) }

        let draft = TimesheetDraftStore.load(
            userId: currentUser.id,
            weekStart: Calendar.current.startOfDay(for: period.startDate)
        )
        for entry in draft.priceWorkEntries {
            rows.append(
                InvoiceLineItem(
                    lineId: "pw-\(entry.id.uuidString)",
                    date: entry.startDate,
                    jobNumber: entry.jobNumber,
                    projectName: "Price work",
                    details: entry.title,
                    paidHours: 0,
                    payrollBasis: .dayRate,
                    dayRate: 0,
                    hourlyRate: nil,
                    amount: entry.amount,
                    isPayeDay: currentUser.employmentType(on: entry.startDate) == .paye
                )
            )
        }
        for entry in draft.expenseEntries {
            rows.append(
                InvoiceLineItem(
                    lineId: "exp-\(entry.id.uuidString)",
                    date: entry.date,
                    jobNumber: "—",
                    projectName: "Expense",
                    details: entry.title,
                    paidHours: 0,
                    payrollBasis: .dayRate,
                    dayRate: 0,
                    hourlyRate: nil,
                    amount: entry.amount,
                    isPayeDay: currentUser.employmentType(on: entry.date) == .paye
                )
            )
        }

        return rows.sorted {
            if $0.date == $1.date {
                return $0.projectName < $1.projectName
            }
            return $0.date < $1.date
        }
    }

    private static func rateChangeNotes(
        for period: InvoicePeriodOption,
        currentUser: AppUser,
        operatives: [Operative],
        dayRateHistoryCollection: OperativeDayRateHistoryCollection
    ) -> [String] {
        let cal = Calendar.current
        var notes: [String] = []

        let userHistory = (dayRateHistoryCollection.byUserId[currentUser.id] ?? [])
            .filter {
                let day = cal.startOfDay(for: $0.effectiveAt)
                return day >= period.startDate && day <= period.endDate
            }
            .sorted(by: { $0.effectiveAt < $1.effectiveAt })

        for entry in userHistory {
            notes.append("Rate updated to \(formatCurrency(entry.dayRate)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
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
                notes.append("Operative rate updated to \(formatCurrency(entry.dayRate)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
            }
        }

        return Array(Set(notes)).sorted()
    }

    private static func formatCurrency(_ value: Double) -> String {
        String(format: "£%.2f", value)
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
    @State private var selectedPeriodId: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generatedPDFURL: URL?
    @State private var showInvoiceUTRWarning = false
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
        let cal = Calendar.current
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
                .foregroundStyle(Color(red: 0.055, green: 0.122, blue: 0.2))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.929, green: 0.957, blue: 0.984))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(red: 0.863, green: 0.91, blue: 0.965), lineWidth: 1)
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

    private func loadRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        dayRateHistoryCollection = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
    }

    private func beginInvoiceGeneration() {
        guard let user = userStore.displayUser else { return }
        errorMessage = nil
        if user.trimmedUTRNumber == nil {
            showInvoiceUTRWarning = true
        } else {
            Task { await runInvoiceGeneration() }
        }
    }

    private func runInvoiceGeneration() async {
        guard !isGenerating else { return }
        guard let period = selectedPeriod else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        if dayRateHistoryCollection.byUserId.isEmpty && dayRateHistoryCollection.byOperativeId.isEmpty {
            await loadRateHistory()
        }

        let pdfURL = InvoicePDFGenerationSupport.generatePDF(
            period: period,
            settings: settings,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            managerScheduleStore: managerScheduleStore,
            dayRateHistoryCollection: dayRateHistoryCollection
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
            scheduleOptions: scheduleOptions
        )
        var rows = summary.lineItems.map { InvoiceLineItem(payrollLine: $0) }

        let draft = TimesheetDraftStore.load(
            userId: currentUser.id,
            weekStart: Calendar.current.startOfDay(for: period.startDate)
        )
        for entry in draft.priceWorkEntries {
            rows.append(
                InvoiceLineItem(
                    lineId: "pw-\(entry.id.uuidString)",
                    date: entry.startDate,
                    jobNumber: entry.jobNumber,
                    projectName: "Price work",
                    details: entry.title,
                    paidHours: 0,
                    payrollBasis: .dayRate,
                    dayRate: 0,
                    hourlyRate: nil,
                    amount: entry.amount,
                    isPayeDay: currentUser.employmentType(on: entry.startDate) == .paye
                )
            )
        }
        for entry in draft.expenseEntries {
            rows.append(
                InvoiceLineItem(
                    lineId: "exp-\(entry.id.uuidString)",
                    date: entry.date,
                    jobNumber: "—",
                    projectName: "Expense",
                    details: entry.title,
                    paidHours: 0,
                    payrollBasis: .dayRate,
                    dayRate: 0,
                    hourlyRate: nil,
                    amount: entry.amount,
                    isPayeDay: currentUser.employmentType(on: entry.date) == .paye
                )
            )
        }

        return rows.sorted {
            if $0.date == $1.date {
                return $0.projectName < $1.projectName
            }
            return $0.date < $1.date
        }
    }

    private func rateChangeNotes(for period: InvoicePeriodOption) -> [String] {
        guard let currentUser = userStore.displayUser else { return [] }
        let cal = Calendar.current
        var notes: [String] = []

        let userHistory = (dayRateHistoryCollection.byUserId[currentUser.id] ?? [])
            .filter {
                let day = cal.startOfDay(for: $0.effectiveAt)
                return day >= period.startDate && day <= period.endDate
            }
            .sorted(by: { $0.effectiveAt < $1.effectiveAt })

        for entry in userHistory {
            notes.append("Rate updated to \(formatCurrency(entry.dayRate)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
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
                notes.append("Operative rate updated to \(formatCurrency(entry.dayRate)) from \(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted)).")
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
        let cal = Calendar.current
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
        let cal = Calendar.current
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
        String(format: "£%.2f", value)
    }
}

private struct InvoicePeriodOption: Identifiable, Hashable {
    let id: String
    let title: String
    let dateRangeText: String
    let startDate: Date
    let endDate: Date
}

private struct InvoiceLineItem {
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
            isOvertimeLine: isOvertimeLine
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
            let detail = "\(item.details) · \(hoursString(item.paidHours))h · \(item.timesheetRateAnnotation)"
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
        String(format: "£%.2f", value)
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
    struct Result {
        let emailedUserIds: Set<String>
        let failed: [String]
        let emailSent: Bool
        var emailed: Int { emailedUserIds.count }
    }

    struct PDFAttachment {
        let fileName: String
        let data: Data
    }

    static func exportAndEmail(
        operatives: [AppUser],
        week: WeekRange,
        draftForUser: (AppUser) -> TimesheetDraft,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        dayRateHistory: OperativeDayRateHistoryCollection,
        payrollPolicy: OrgPayrollTimePolicy,
        organization: Organization?,
        organizationName: String,
        scheduleOptions: MyScheduleOptions = MyScheduleOptions(),
        recipientEmail: String,
        recipientName: String,
        firebaseBackend: FirebaseBackend? = nil
    ) async -> Result {
        var emailedUserIds = Set<String>()
        var failed: [String] = []
        var attachments: [PDFAttachment] = []
        let paymentRunStamp = paymentRunDateStamp(for: week)
        let periodRangeText = "\(paymentRunStamp.replacingOccurrences(of: " ", with: " – "))"

        for operative in operatives {
            let userName = operative.fullName.isEmpty ? operative.email : operative.fullName
            let draft = draftForUser(operative)
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
                scheduleOptions: scheduleOptions
            )
            let grandTotal = rows.reduce(0) { $0 + $1.amount }
            let fileName = timesheetPDFFileName(userName: userName, paymentRunStamp: paymentRunStamp)

            guard let pdfURL = InvoicePDFBuilder.makePDF(
                context: InvoicePDFBuilder.Context(
                    organizationName: organizationName,
                    userName: userName,
                    vatNumber: operative.trimmedVATNumber,
                    utrNumber: operative.trimmedUTRNumber,
                    generatedAt: Date(),
                    periodTitle: "Signed timesheet",
                    periodDateRange: periodRangeText,
                    lineItems: rows,
                    totalAmount: grandTotal,
                    rateChangeNotes: signatureNotes(for: draft),
                    documentTitle: "Timesheet",
                    preferredFileName: fileName,
                    periodMetaLabel: "PAYMENT RUN",
                    totalLabel: "Total timesheet amount",
                    emptyStateMessage: "No work entries were found for this timesheet period."
                )
            ), let pdfData = try? Data(contentsOf: pdfURL) else {
                failed.append(userName)
                continue
            }

            attachments.append(PDFAttachment(fileName: fileName, data: pdfData))
            emailedUserIds.insert(operative.id)
        }

        guard !attachments.isEmpty else {
            return Result(emailedUserIds: [], failed: failed.isEmpty ? ["No timesheet PDFs could be built"] : failed, emailSent: false)
        }

        var downloadLinks: [(fileName: String, url: String)] = []
        if let firebaseBackend, let orgId = organization?.firestoreDocumentId {
            for attachment in attachments {
                if let url = try? await firebaseBackend.uploadTimesheetExportPDF(
                    attachment.data,
                    fileName: attachment.fileName,
                    organizationId: orgId
                ) {
                    downloadLinks.append((attachment.fileName, url))
                }
            }
        }

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
        var sent = await resend.sendTimesheetExportEmail(
            to: recipientEmail,
            subject: "Signed timesheets for filing — \(paymentRunStamp) — \(organizationName)",
            htmlContent: html,
            pdfAttachments: payload,
            fromName: organizationName
        )
        if !sent {
            sent = await resend.sendTimesheetExportEmail(
                to: recipientEmail,
                subject: "Signed timesheets for filing — \(paymentRunStamp) — \(organizationName)",
                htmlContent: html,
                pdfAttachments: payload,
                fromName: organizationName
            )
        }

        if sent {
            return Result(emailedUserIds: emailedUserIds, failed: failed, emailSent: true)
        }
        return Result(
            emailedUserIds: [],
            failed: failed + ["Email delivery to \(recipientEmail) failed"],
            emailSent: false
        )
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
        scheduleOptions: MyScheduleOptions = MyScheduleOptions()
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
            scheduleOptions: scheduleOptions
        )
        var rows: [InvoiceLineItem] = []
        let managerHasSigned = draft.managerSignedAt != nil || TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user)
        if let override = draft.weeklyReportOverride {
            let liveById = Dictionary(summary.lineItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for line in override.lines where line.decision != .declined && line.amount > 0.0001 {
                if let live = liveById[line.id] {
                    rows.append(
                        InvoiceLineItem(
                            lineId: live.id,
                            date: live.date,
                            jobNumber: live.jobNumber,
                            projectName: live.projectName,
                            details: live.details,
                            paidHours: live.paidHours,
                            payrollBasis: live.payrollBasis,
                            dayRate: live.dayRate,
                            hourlyRate: live.hourlyRate,
                            amount: line.amount,
                            isPayeDay: live.isPayeDay,
                            isOvertimeLine: live.isOvertimeLine
                        )
                    )
                } else {
                    rows.append(
                        InvoiceLineItem(
                            lineId: line.id,
                            date: line.date,
                            jobNumber: line.jobNumber,
                            projectName: line.projectName,
                            details: line.details,
                            paidHours: line.paidHours,
                            payrollBasis: .dayRate,
                            dayRate: 0,
                            hourlyRate: nil,
                            amount: line.amount,
                            isPayeDay: user.employmentType(on: line.date) == .paye,
                            isOvertimeLine: line.isOvertime
                        )
                    )
                }
            }
            for line in override.priceWork where line.decision != .declined && line.amount > 0.0001 {
                rows.append(
                    InvoiceLineItem(
                        lineId: "pw-\(line.id)",
                        date: line.date,
                        jobNumber: line.jobNumber,
                        projectName: "Price work",
                        details: line.title,
                        paidHours: 0,
                        payrollBasis: .dayRate,
                        dayRate: 0,
                        hourlyRate: nil,
                        amount: line.amount,
                        isPayeDay: user.employmentType(on: line.date) == .paye
                    )
                )
            }
            for line in override.expenses where line.decision != .declined && line.amount > 0.0001 {
                rows.append(
                    InvoiceLineItem(
                        lineId: "exp-\(line.id)",
                        date: line.date,
                        jobNumber: line.jobNumber.isEmpty ? "—" : line.jobNumber,
                        projectName: "Expense",
                        details: line.title,
                        paidHours: 0,
                        payrollBasis: .dayRate,
                        dayRate: 0,
                        hourlyRate: nil,
                        amount: line.amount,
                        isPayeDay: user.employmentType(on: line.date) == .paye
                    )
                )
            }
        } else {
            for line in summary.lineItems {
                if TimesheetDraftAdjustments.isPayrollLineRemoved(
                    line: line,
                    draft: draft,
                    managerHasSigned: managerHasSigned,
                    applyLiveReview: true
                ) {
                    continue
                }
                let amount = TimesheetDraftAdjustments.effectivePayrollAmount(
                    line: line,
                    draft: draft,
                    managerHasSigned: managerHasSigned,
                    applyLiveReview: true
                )
                guard amount > 0.0001 else { continue }
                rows.append(
                    InvoiceLineItem(
                        lineId: line.id,
                        date: line.date,
                        jobNumber: line.jobNumber,
                        projectName: line.projectName,
                        details: line.details,
                        paidHours: line.paidHours,
                        payrollBasis: line.payrollBasis,
                        dayRate: line.dayRate,
                        hourlyRate: line.hourlyRate,
                        amount: amount,
                        isPayeDay: line.isPayeDay,
                        isOvertimeLine: line.isOvertimeLine
                    )
                )
            }
            for entry in draft.priceWorkEntries {
                let amount = TimesheetDraftAdjustments.effectivePriceWorkAmount(
                    entry,
                    managerHasSigned: managerHasSigned,
                    applyLiveReview: true
                )
                guard amount > 0.0001, entry.managerDecision != .declined else { continue }
                rows.append(
                    InvoiceLineItem(
                        lineId: "pw-\(entry.id.uuidString)",
                        date: entry.startDate,
                        jobNumber: entry.jobNumber,
                        projectName: "Price work",
                        details: entry.title,
                        paidHours: 0,
                        payrollBasis: .dayRate,
                        dayRate: 0,
                        hourlyRate: nil,
                        amount: amount,
                        isPayeDay: user.employmentType(on: entry.startDate) == .paye
                    )
                )
            }
            for entry in draft.expenseEntries {
                let amount = TimesheetDraftAdjustments.effectiveExpenseAmount(
                    entry,
                    managerHasSigned: managerHasSigned,
                    applyLiveReview: true
                )
                guard amount > 0.0001, entry.managerDecision != .declined else { continue }
                rows.append(
                    InvoiceLineItem(
                        lineId: "exp-\(entry.id.uuidString)",
                        date: entry.date,
                        jobNumber: entry.jobNumber.isEmpty ? "—" : entry.jobNumber,
                        projectName: "Expense",
                        details: entry.title,
                        paidHours: 0,
                        payrollBasis: .dayRate,
                        dayRate: 0,
                        hourlyRate: nil,
                        amount: amount,
                        isPayeDay: user.employmentType(on: entry.date) == .paye
                    )
                )
            }
        }

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
        let list: String
        if downloadLinks.isEmpty {
            list = attachmentNames.map { "<li>\($0)</li>" }.joined()
        } else {
            list = downloadLinks.map { "<li><a href=\"\($0.url)\">\($0.fileName)</a></li>" }.joined()
        }
        let attachNote = downloadLinks.isEmpty
            ? "\(timesheetCount) signed-off timesheet PDF\(timesheetCount == 1 ? "" : "s") for payment run <strong>\(paymentRunStamp)</strong> (\(weekTitle)) from <strong>\(organizationName)</strong> \(timesheetCount == 1 ? "is" : "are") attached for your records."
            : "\(timesheetCount) signed-off timesheet PDF\(timesheetCount == 1 ? "" : "s") for payment run <strong>\(paymentRunStamp)</strong> (\(weekTitle)) from <strong>\(organizationName)</strong> \(timesheetCount == 1 ? "is" : "are") attached, with backup download links below."
        return """
        <html><body style="font-family:Arial,sans-serif;max-width:720px;margin:0 auto;padding:20px;">
        <h2 style="color:#0D67ED;">Signed timesheets for filing</h2>
        <p>Hello \(recipientName),</p>
        <p>\(attachNote)</p>
        <p>Each file is named: <em>User Name timesheet for payment run date \(paymentRunStamp)</em>.</p>
        <ul>\(list)</ul>
        <p style="color:#666;font-size:13px;">These timesheets were counter-signed and exported from Operative Timesheets → Signed off.</p>
        </body></html>
        """
    }
}

