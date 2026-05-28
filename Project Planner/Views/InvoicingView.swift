//
//  InvoicingView.swift
//  Project Planner
//

import SwiftUI
import UIKit
import FirebaseFirestore
import PhotosUI
import PencilKit

struct InvoicingView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var notificationService: NotificationService
    @State private var landingVersion = 0
    @State private var deepLinkTargetUser: AppUser?
    @State private var deepLinkWeek: WeekRange?
    @State private var showDeepLinkReview = false

    let initialReviewUserId: String?
    let initialReviewWeekStart: Date?

    private var settings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    private var canShowMyTimesheets: Bool { userStore.canAccessMyTimesheets() }
    private var canShowOperativeTimesheets: Bool { userStore.canAccessOperativeTimesheets() }
    private var isAdminViewer: Bool {
        guard let u = userStore.displayUser else { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.role == .admin
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !userStore.canAccessTimesheetsSurface() {
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
                            previousTimesheetsCard
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
            .navigationTitle("Timesheets")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await syncLandingDraftsFromCloud()
                await handleInitialTimesheetDeepLinkIfNeeded()
            }
            .navigationDestination(isPresented: $showDeepLinkReview) {
                if let deepLinkTargetUser, let deepLinkWeek {
                    OperativeTimesheetReviewView(
                        operative: deepLinkTargetUser,
                        settings: settings,
                        week: deepLinkWeek
                    )
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(notificationService)
                }
            }
        }
    }

    init(initialReviewUserId: String? = nil, initialReviewWeekStart: Date? = nil) {
        self.initialReviewUserId = initialReviewUserId
        self.initialReviewWeekStart = initialReviewWeekStart
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

    @ViewBuilder
    private var operativeLandingCard: some View {
        NavigationLink {
            MyTimesheetView(settings: settings)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(notificationService)
        } label: {
            timesheetEntryCard(
                title: "My Timesheet",
                detail: "Auto-built from your bookings. Review, add extras and sign.",
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
        let directReports = usersForManagerReview
        let awaiting = directReports.filter { TimesheetDraftStore.load(userId: $0.id, weekStart: WeekRange.current().start).operativeSignedAt != nil && TimesheetDraftStore.load(userId: $0.id, weekStart: WeekRange.current().start).managerSignedAt == nil }.count
        let signed = directReports.filter { TimesheetDraftStore.load(userId: $0.id, weekStart: WeekRange.current().start).managerSignedAt != nil && TimesheetDraftStore.load(userId: $0.id, weekStart: WeekRange.current().start).exportedAt == nil }.count
        let exported = directReports.filter { TimesheetDraftStore.load(userId: $0.id, weekStart: WeekRange.current().start).exportedAt != nil }.count

        VStack(spacing: 12) {
            if canShowMyTimesheets {
                NavigationLink {
                    MyTimesheetView(settings: settings)
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
                OperativeTimesheetsView(settings: settings)
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

    private var usersForManagerReview: [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        if isAdminViewer {
            return userStore.organizationUsers.filter {
                $0.isActive &&
                $0.employmentType(on: Date()) == .selfEmployed &&
                ($0.permissions.operativeMode || $0.permissions.manager || $0.permissions.adminAccess || $0.role == .manager || $0.role == .admin)
            }
        }
        return userStore.organizationUsers.filter {
            $0.isActive &&
            $0.employmentType(on: Date()) == .selfEmployed &&
            ($0.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == currentUser.id
        }
    }

    private func syncLandingDraftsFromCloud() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let weekStart = WeekRange.current().start
        let ids = Set(usersForManagerReview.map(\.id) + (userStore.displayUser.map { [$0.id] } ?? []))
        for userId in ids {
            _ = await TimesheetDraftStore.refreshFromCloud(
                userId: userId,
                weekStart: weekStart,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
        }
        await MainActor.run { landingVersion += 1 }
    }

    private func handleInitialTimesheetDeepLinkIfNeeded() async {
        guard let targetUserId = initialReviewUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetUserId.isEmpty else { return }
        guard let target = userStore.organizationUsers.first(where: { $0.id == targetUserId }) else { return }
        let week = WeekRange.from(start: initialReviewWeekStart ?? Date())
        await MainActor.run {
            deepLinkTargetUser = target
            deepLinkWeek = week
            showDeepLinkReview = true
        }
    }
}

private struct TimesheetExpenseEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var details: String
    var jobNumber: String
    var date: Date
    var amount: Double
    var receiptName: String?
}

private struct TimesheetPriceWorkEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var details: String
    var jobNumber: String
    var agreedManagerName: String
    var startDate: Date
    var endDate: Date?
    var amount: Double
}

private struct TimesheetDraft: Codable {
    var expenseEntries: [TimesheetExpenseEntry] = []
    var priceWorkEntries: [TimesheetPriceWorkEntry] = []
    var managerNote: String = ""
    var operativeSignedAt: Date?
    var operativeSignedByName: String?
    var operativeSignatureImageBase64: String?
    var managerSignedAt: Date?
    var managerSignedByName: String?
    var managerSignatureImageBase64: String?
    var exportedAt: Date?

    var additionalTotal: Double {
        expenseEntries.reduce(0) { $0 + $1.amount } + priceWorkEntries.reduce(0) { $0 + $1.amount }
    }
}

private enum TimesheetDraftStore {
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
            "managerSignatureImageBase64": draft.managerSignatureImageBase64 ?? "",
            "exportedAt": draft.exportedAt.map(Timestamp.init(date:)) as Any,
            "expenseEntries": draft.expenseEntries.map { e in
                [
                    "id": e.id.uuidString,
                    "title": e.title,
                    "details": e.details,
                    "jobNumber": e.jobNumber,
                    "date": Timestamp(date: e.date),
                    "amount": e.amount,
                    "receiptName": e.receiptName ?? ""
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
                    "amount": p.amount
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
        let operativeSig = (map["operativeSignatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.operativeSignatureImageBase64 = operativeSig.isEmpty ? nil : operativeSig
        output.managerSignedAt = (map["managerSignedAt"] as? Timestamp)?.dateValue()
        let signedBy = (map["managerSignedByName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignedByName = signedBy.isEmpty ? nil : signedBy
        let managerSig = (map["managerSignatureImageBase64"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output.managerSignatureImageBase64 = managerSig.isEmpty ? nil : managerSig
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
                receiptName: row["receiptName"] as? String
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
                amount: row["amount"] as? Double ?? 0
            )
        }
        return output
    }

    static func decodeFirestoreMap(_ map: [String: Any]) -> TimesheetDraft? {
        fromFirestoreMap(map)
    }

    private static func key(userId: String, weekStart: Date) -> String {
        let stamp = Int(Calendar.current.startOfDay(for: weekStart).timeIntervalSince1970)
        return "timesheet-draft-\(userId)-\(stamp)"
    }
}

private struct WeekRange {
    let start: Date
    let end: Date
    let title: String

    static func current() -> WeekRange {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = today.startOfISOWeek ?? today
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
        let title = "\(start.formatted(date: .abbreviated, time: .omitted)) - \(end.formatted(date: .abbreviated, time: .omitted))"
        return WeekRange(start: start, end: end, title: title)
    }

    static func from(start: Date) -> WeekRange {
        let cal = Calendar.current
        let normalized = cal.startOfDay(for: start)
        let weekStart = normalized.startOfISOWeek ?? normalized
        let end = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let title = "\(weekStart.formatted(date: .abbreviated, time: .omitted)) - \(end.formatted(date: .abbreviated, time: .omitted))"
        return WeekRange(start: weekStart, end: end, title: title)
    }

    func offset(byWeeks weeks: Int) -> WeekRange {
        let cal = Calendar.current
        let shifted = cal.date(byAdding: .day, value: 7 * weeks, to: start) ?? start
        return .from(start: shifted)
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

    @State private var week = WeekRange.current()
    @State private var draft = TimesheetDraft()
    @State private var showAddExpense = false
    @State private var showAddPriceWork = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty

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
        workAmount + draft.additionalTotal
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
        let currentUser = userStore.displayUser
        guard let currentUser else { return [] }
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let standardDayHours = max(policy.standardPaidHours, 0.01)
        let cal = Calendar.current

        let matchedOperatives = operativeStore.allOperatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == currentUser.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let operativeIds = Set(matchedOperatives.map(\.id))
        var rows: [InvoiceLineItem] = []

        for booking in bookingStore.bookings where booking.status != .cancelled {
            guard operativeIds.contains(booking.operativeId) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= week.start && day <= week.end else { continue }
            let paid = booking.paidBookedHours(policy: policy)
            let rate = dayRateForBookingDay(
                user: currentUser,
                matchedOperative: matchedOperatives.first(where: { $0.id == booking.operativeId }),
                day: day
            )
            let amount = rate * (paid / standardDayHours)
            rows.append(
                InvoiceLineItem(
                    date: day,
                    jobNumber: projectLabel(for: booking.projectId).jobNumber,
                    projectName: projectLabel(for: booking.projectId).siteName,
                    details: booking.scheduleLabel(policy: policy),
                    paidHours: paid,
                    dayRate: rate,
                    amount: amount
                )
            )
        }

        for booking in managerScheduleStore.managerSiteBookings {
            guard booking.userId == currentUser.id else { continue }
            guard booking.locationType == .project || booking.locationType == .smallWork else { continue }
            guard let locationId = booking.locationId else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= week.start && day <= week.end else { continue }
            let paid = booking.paidBookedHours(policy: policy)
            let rate = dayRateForUserDay(user: currentUser, day: day)
            let amount = rate * (paid / standardDayHours)
            rows.append(
                InvoiceLineItem(
                    date: day,
                    jobNumber: projectLabel(for: locationId).jobNumber,
                    projectName: projectLabel(for: locationId).siteName,
                    details: booking.scheduleLabel(policy: policy),
                    paidHours: paid,
                    dayRate: rate,
                    amount: amount
                )
            )
        }

        return rows.sorted(by: { $0.date < $1.date })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("This period")

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(invoiceRows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.subheadline.weight(.bold))
                                Text("\(row.jobNumber) \(row.projectName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(row.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "£%.2f", row.amount))
                                .font(.subheadline.weight(.bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < invoiceRows.count - 1 { Divider().padding(.horizontal, 14) }
                    }
                    HStack {
                        Text("Hours subtotal")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "£%.2f", workAmount))
                            .font(.headline)
                    }
                    .padding(14)
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                paymentSummary(settings: settings)

                if !draft.priceWorkEntries.isEmpty {
                    sectionCard(title: "Price Work") {
                        ForEach(draft.priceWorkEntries) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .fontWeight(.semibold)
                                    Text(item.details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "£%.2f", item.amount))
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }

                if !draft.expenseEntries.isEmpty {
                    sectionCard(title: "Expenses") {
                        ForEach(draft.expenseEntries) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .fontWeight(.semibold)
                                    Text(item.details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "£%.2f", item.amount))
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }

                sectionHeader("Add to this timesheet")
                HStack(spacing: 10) {
                    NavigationLink {
                        TimesheetMoneyEntrySheet(mode: .priceWork) { entry in
                            draft.priceWorkEntries.append(entry)
                            saveDraft()
                        }
                    } label: {
                        addonTile(title: "Price Work", subtitle: "Agreed extras", symbol: "bolt.fill", tint: Color(red: 0.329, green: 0.29, blue: 0.718))
                    }
                    NavigationLink {
                        TimesheetMoneyEntrySheet(mode: .expense) { entry in
                            draft.expenseEntries.append(entry)
                            saveDraft()
                        }
                    } label: {
                        addonTile(title: "Expenses", subtitle: "+ receipts", symbol: "sterlingsign.circle.fill", tint: Color(red: 0.706, green: 0.325, blue: 0.035))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Note to manager")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $draft.managerNote)
                        .frame(minHeight: 74)
                        .padding(8)
                        .background(Color(red: 0.969, green: 0.976, blue: 0.988))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("If you don't agree with the hours shown, contact your line manager to amend your booking schedule before signing. Agreed changes appear on a new timesheet.")
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
                            onApprove: { signatureBase64 in
                                markTimesheetSigned(signatureBase64: signatureBase64)
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
                    TimesheetSignedSummaryCard(
                        title: "Operative signature",
                        signatureBase64: draft.operativeSignatureImageBase64,
                        signedByName: draft.operativeSignedByName,
                        signedAt: draft.operativeSignedAt,
                        pendingText: "Not signed yet."
                    )
                }
                
                if draft.managerSignedAt != nil {
                    TimesheetSignedSummaryCard(
                        title: "Manager sign-off",
                        signatureBase64: draft.managerSignatureImageBase64,
                        signedByName: draft.managerSignedByName,
                        signedAt: draft.managerSignedAt,
                        pendingText: "Manager has not signed off."
                    )
                }

                if draft.operativeSignedAt != nil && draft.managerSignedAt != nil {
                    NavigationLink {
                        GenerateInvoiceView(settings: settings, lockedPeriod: weekInvoicePeriod)
                            .environmentObject(firebaseBackend)
                            .environmentObject(userStore)
                            .environmentObject(bookingStore)
                            .environmentObject(operativeStore)
                            .environmentObject(projectStore)
                            .environmentObject(managerScheduleStore)
                    } label: {
                        Text("Generate Invoice")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                            .padding(.vertical, 14)
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Invoice generation unlocks after operative and manager signatures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
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
        .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
        .navigationTitle("My Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDraft() }
        .task { await loadDayRateHistory() }
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
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func sectionHeader(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(1.0)
    }

    @ViewBuilder
    private func paymentSummary(settings: OrganizationInvoicingSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment Runs and Payouts")
                .font(.headline)
            if settings.paymentRunMode == .dateRanges {
                ForEach(settings.normalizedRanges, id: \.id) { range in
                    Text("• Run: \(range.startDay) - \(range.endDay)")
                        .font(.subheadline)
                }
            } else {
                Text("• \(settings.recurringRunDisplaySummary)")
                    .font(.subheadline)
            }
            if settings.paymentDateMode == .specificDates {
                ForEach(settings.normalizedPaymentDates, id: \.self) { day in
                    Text("• Payout day \(day)")
                        .font(.subheadline)
                }
            } else {
                Text("• Payout every \(settings.recurringPaymentDay.title)")
                    .font(.subheadline)
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

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadDraft() {
        draft = TimesheetDraftStore.load(userId: currentUserId, weekStart: week.start)
        Task { await refreshDraftFromCloud() }
    }

    private func markTimesheetSigned(signatureBase64: String) {
        draft.operativeSignedAt = Date()
        draft.operativeSignedByName = userStore.displayUser?.fullName.isEmpty == false
            ? userStore.displayUser?.fullName
            : userStore.displayUser?.email
        draft.operativeSignatureImageBase64 = signatureBase64
        saveDraft()
        guard let current = userStore.displayUser else { return }
        guard let managerId = current.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !managerId.isEmpty else { return }
        Task {
            await notificationService.notifyTimesheetPendingManagerSignoff(
                signedByUser: current,
                lineManagerUserId: managerId,
                weekStart: week.start
            )
        }
    }

    private func saveDraft() {
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
            draft = remote
        }
    }

    private func loadDayRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let history = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
        await MainActor.run { dayRateHistoryCollection = history }
    }

    private func dayRateForUserDay(user: AppUser, day: Date) -> Double {
        guard user.employmentType(on: day) == .selfEmployed else { return 0 }
        let dayStart = Calendar.current.startOfDay(for: day)
        let history = (dayRateHistoryCollection.byUserId[user.id] ?? []).sorted(by: { $0.effectiveAt < $1.effectiveAt })
        let fromHistory = history.last(where: { Calendar.current.startOfDay(for: $0.effectiveAt) <= dayStart })?.dayRate
        return fromHistory ?? user.dayRate ?? 0
    }

    private func dayRateForBookingDay(user: AppUser, matchedOperative: Operative?, day: Date) -> Double {
        guard user.employmentType(on: day) == .selfEmployed else { return 0 }
        let dayStart = Calendar.current.startOfDay(for: day)
        if let matchedOperative {
            let merged = dayRateHistoryCollection
                .mergedEntries(userId: user.id, operativeId: matchedOperative.id)
                .sorted(by: { $0.effectiveAt < $1.effectiveAt })
            let fromHistory = merged.last(where: { Calendar.current.startOfDay(for: $0.effectiveAt) <= dayStart })?.dayRate
            return fromHistory ?? matchedOperative.dayRate ?? user.dayRate ?? 0
        }
        return dayRateForUserDay(user: user, day: day)
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
                        if run.isCompleted, let selectedPeriod {
                            NavigationLink {
                                GenerateInvoiceView(settings: settings, lockedPeriod: selectedPeriod)
                                    .environmentObject(firebaseBackend)
                                    .environmentObject(userStore)
                                    .environmentObject(bookingStore)
                                    .environmentObject(operativeStore)
                                    .environmentObject(projectStore)
                                    .environmentObject(managerScheduleStore)
                            } label: {
                                Text("Generate Invoice")
                                    .frame(maxWidth: .infinity)
                                    .fontWeight(.semibold)
                                    .padding(.vertical, 14)
                                    .background(Color.green)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
        .navigationTitle("Previous Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRuns() }
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
            TimesheetSignedSummaryCard(
                title: "Operative",
                signatureBase64: run.draft.operativeSignatureImageBase64,
                signedByName: run.draft.operativeSignedByName,
                signedAt: run.draft.operativeSignedAt,
                pendingText: "Operative has not signed."
            )
            TimesheetSignedSummaryCard(
                title: "Manager",
                signatureBase64: run.draft.managerSignatureImageBase64,
                signedByName: run.draft.managerSignedByName,
                signedAt: run.draft.managerSignedAt,
                pendingText: "Manager has not signed off."
            )
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
            limit: 80
        ) {
            for row in rows {
                guard let weekStart = (row["weekStart"] as? Timestamp)?.dateValue() else { continue }
                let week = WeekRange.from(start: weekStart)
                guard let draft = TimesheetDraftStore.decodeFirestoreMap(row) else { continue }
                let hasAnyContent = !draft.expenseEntries.isEmpty
                    || !draft.priceWorkEntries.isEmpty
                    || draft.operativeSignedAt != nil
                    || draft.managerSignedAt != nil
                    || !draft.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard hasAnyContent else { continue }
                TimesheetDraftStore.save(draft, userId: userId, weekStart: week.start)
                output.append(
                    PreviousTimesheetRun(
                        id: "prev-\(Int(week.start.timeIntervalSince1970))",
                        week: week,
                        draft: draft
                    )
                )
            }
        }
        if output.isEmpty {
            let current = WeekRange.current()
            for offset in 1...16 {
                let week = current.offset(byWeeks: -offset)
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
        let cal = Calendar.current
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let standardDayHours = max(policy.standardPaidHours, 0.01)
        let userOperatives = operativeStore.allOperatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == currentUser.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let ids = Set(userOperatives.map(\.id))
        let dayRate = userOperatives.first?.dayRate ?? currentUser.dayRate ?? 0
        var hours = 0.0
        var otHours = 0.0
        var base = 0.0
        var otAmount = 0.0
        for booking in bookingStore.bookings where booking.status != .cancelled {
            guard ids.contains(booking.operativeId) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= week.start && day <= week.end else { continue }
            let paid = booking.paidBookedHours(policy: policy)
            let ot = max(0, booking.overtimeHoursBeyondPaidStandard(policy: policy))
            let normal = max(0, paid - ot)
            hours += paid
            otHours += ot
            base += dayRate * (normal / standardDayHours)
            if ot > 0 {
                otAmount += dayRate * ((ot / standardDayHours) * booking.effectiveWeekdayOtMultiplier(policy: policy))
            }
        }
        return (hours, otHours, base, otAmount)
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
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
    @EnvironmentObject var notificationService: NotificationService
    let settings: OrganizationInvoicingSettings
    let week: WeekRange
    @State private var selectedTab: ManagerTimesheetListTab = .awaiting
    @State private var refreshVersion = 0

    private var isAdminViewer: Bool {
        guard let u = userStore.displayUser else { return false }
        return u.isSuperAdmin || u.permissions.adminAccess || u.role == .admin
    }

    init(settings: OrganizationInvoicingSettings, week: WeekRange = .current()) {
        self.settings = settings
        self.week = week
    }

    private var directReports: [AppUser] {
        guard let currentUser = userStore.displayUser else { return [] }
        if isAdminViewer {
            return userStore.organizationUsers
                .filter { user in
                    user.isActive
                    && user.employmentType(on: Date()) == .selfEmployed
                    && (user.permissions.operativeMode || user.permissions.manager || user.permissions.adminAccess || user.role == .manager || user.role == .admin)
                }
                .sorted(by: { $0.fullName < $1.fullName })
        }
        return userStore.organizationUsers
            .filter { user in
                user.isActive
                && user.employmentType(on: Date()) == .selfEmployed
                && (user.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == currentUser.id
            }
            .sorted(by: { $0.fullName < $1.fullName })
    }

    private var filteredReports: [AppUser] {
        let _ = refreshVersion
        return directReports.filter { user in
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: week.start)
            switch selectedTab {
            case .awaiting:
                return draft.operativeSignedAt != nil && draft.managerSignedAt == nil
            case .signedOff:
                return draft.managerSignedAt != nil && draft.exportedAt == nil
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

                VStack(spacing: 0) {
                    ForEach(filteredReports, id: \.id) { operative in
                        NavigationLink {
                            OperativeTimesheetReviewView(operative: operative, settings: settings, week: week)
                                .environmentObject(firebaseBackend)
                                .environmentObject(userStore)
                                .environmentObject(bookingStore)
                                .environmentObject(operativeStore)
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
                                    let summary = operativeSummary(for: operative, draft: draft)
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
                                statusPill(for: TimesheetDraftStore.load(userId: operative.id, weekStart: week.start))
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
                .padding(8)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if selectedTab == .signedOff && !filteredReports.isEmpty {
                    Button {
                        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
                        for op in filteredReports {
                            var d = TimesheetDraftStore.load(userId: op.id, weekStart: week.start)
                            d.exportedAt = Date()
                            TimesheetDraftStore.save(d, userId: op.id, weekStart: week.start)
                            if let orgId {
                                let snapshot = d
                                Task {
                                    await TimesheetDraftStore.saveToCloud(
                                        snapshot,
                                        userId: op.id,
                                        weekStart: week.start,
                                        firebaseBackend: firebaseBackend,
                                        organizationId: orgId
                                    )
                                }
                            }
                        }
                        refreshVersion += 1
                    } label: {
                        Label("Export & email \(filteredReports.count) timesheets", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
        .navigationTitle(isAdminViewer ? "User Timesheets" : "Operative Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshFromCloud()
        }
    }

    @ViewBuilder
    private func statusPill(for draft: TimesheetDraft) -> some View {
        if draft.exportedAt != nil {
            Text("Exported")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        } else if draft.managerSignedAt != nil {
            Text("Signed off")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.14))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if draft.operativeSignedAt != nil {
            Text("Signed")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.14))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else {
            Text("Pending")
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
        for user in directReports {
            _ = await TimesheetDraftStore.refreshFromCloud(
                userId: user.id,
                weekStart: week.start,
                firebaseBackend: firebaseBackend,
                organizationId: orgId
            )
        }
        await MainActor.run { refreshVersion += 1 }
    }

    private func operativeSummary(for user: AppUser, draft: TimesheetDraft) -> (hours: Double, overtimeHours: Double, priceWork: Double, expenses: Double) {
        let cal = Calendar.current
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let operativeIds = Set(
            operativeStore.allOperatives
                .filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .map(\.id)
        )
        var totalHours = 0.0
        var otHours = 0.0
        for booking in bookingStore.bookings where booking.status != .cancelled {
            guard operativeIds.contains(booking.operativeId) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= week.start && day <= week.end else { continue }
            totalHours += booking.paidBookedHours(policy: policy)
            otHours += max(0, booking.overtimeHoursBeyondPaidStandard(policy: policy))
        }
        return (
            totalHours,
            otHours,
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

private enum ManagerTimesheetListTab {
    case awaiting
    case signedOff
    case exported

    var helpText: String {
        switch self {
        case .awaiting:
            return "Signed by operative, waiting for your sign-off."
        case .signedOff:
            return "Ready to export and email."
        case .exported:
            return "Already exported records."
        }
    }
}

private struct OperativeTimesheetReviewView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    let operative: AppUser
    let settings: OrganizationInvoicingSettings
    let week: WeekRange
    @State private var draft = TimesheetDraft()
    @State private var managerSignatureImageData: Data?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Breakdown")
                        .font(.headline)
                    rowLine(title: "Hours · \(hoursSummary.shifts) shifts (\(formatHours(hoursSummary.hours))h)", amount: hoursSummary.amount)
                    rowLine(title: "Overtime", amount: hoursSummary.overtimeAmount)
                    rowLine(title: "Price work · \(draft.priceWorkEntries.count)", amount: draft.priceWorkEntries.reduce(0) { $0 + $1.amount })
                    rowLine(title: "Expenses · \(draft.expenseEntries.count)", amount: draft.expenseEntries.reduce(0) { $0 + $1.amount })
                    Divider()
                    rowLine(
                        title: "Total",
                        amount: hoursSummary.amount + hoursSummary.overtimeAmount + draft.priceWorkEntries.reduce(0) { $0 + $1.amount } + draft.expenseEntries.reduce(0) { $0 + $1.amount }
                    )
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

                if !draft.priceWorkEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Price work — needs your nod")
                            .font(.headline)
                        ForEach(draft.priceWorkEntries) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.subheadline.weight(.semibold))
                                Text("Agreed with: \(row.agreedManagerName) · \(row.startDate.formatted(date: .abbreviated, time: .omitted)) · \(row.jobNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(14)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Signatures")
                        .font(.headline)
                    TimesheetSignedSummaryCard(
                        title: "Operative",
                        signatureBase64: draft.operativeSignatureImageBase64,
                        signedByName: draft.operativeSignedByName,
                        signedAt: draft.operativeSignedAt,
                        pendingText: "Operative has not signed this week yet."
                    )
                    if draft.managerSignedAt == nil {
                        TimesheetSignaturePad(imageData: $managerSignatureImageData, title: "Manager signature")
                    } else {
                        TimesheetSignedSummaryCard(
                            title: "Manager",
                            signatureBase64: draft.managerSignatureImageBase64,
                            signedByName: draft.managerSignedByName,
                            signedAt: draft.managerSignedAt,
                            pendingText: "Manager has not signed off."
                        )
                    }
                }
                .padding(14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if draft.managerSignedAt == nil {
                    Button {
                        guard let managerSignatureImageData else { return }
                        draft.managerSignedAt = Date()
                        draft.managerSignedByName = userStore.displayUser?.fullName.isEmpty == false
                            ? userStore.displayUser?.fullName
                            : userStore.displayUser?.email
                        draft.managerSignatureImageBase64 = managerSignatureImageData.base64EncodedString()
                        saveDraft()
                        let signer = draft.managerSignedByName ?? "Line manager"
                        Task {
                            await notificationService.notifyTimesheetSignedByManager(
                                targetUserId: operative.id,
                                signedByName: signer,
                                weekStart: week.start
                            )
                        }
                    } label: {
                        Label("Sign off & finalise", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.operativeSignedAt == nil || managerSignatureImageData == nil)
                    .opacity((draft.operativeSignedAt == nil || managerSignatureImageData == nil) ? 0.5 : 1)
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
        .navigationTitle("Review Timesheet")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = TimesheetDraftStore.load(userId: operative.id, weekStart: week.start)
            managerSignatureImageData = draft.managerSignatureImageBase64.flatMap { Data(base64Encoded: $0) }
            Task { await refreshDraftFromCloud() }
        }
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
        await MainActor.run {
            draft = remote
            managerSignatureImageData = remote.managerSignatureImageBase64.flatMap { Data(base64Encoded: $0) }
        }
    }

    private var hoursSummary: (hours: Double, shifts: Int, amount: Double, overtimeAmount: Double) {
        let cal = Calendar.current
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let standardDayHours = max(policy.standardPaidHours, 0.01)
        let operativeIds = Set(
            operativeStore.allOperatives
                .filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == operative.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .map(\.id)
        )

        var totalHours = 0.0
        var shifts = 0
        var baseAmount = 0.0
        var overtimeAmount = 0.0
        let dayRate = operativeStore.allOperatives.first {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == operative.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }?.dayRate ?? operative.dayRate ?? 0

        for booking in bookingStore.bookings where booking.status != .cancelled {
            guard operativeIds.contains(booking.operativeId) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= week.start && day <= week.end else { continue }
            shifts += 1
            let paid = booking.paidBookedHours(policy: policy)
            let ot = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normal = max(0, paid - ot)
            totalHours += paid
            baseAmount += dayRate * (normal / standardDayHours)
            if ot > 0 {
                let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
                overtimeAmount += dayRate * ((ot / standardDayHours) * otMultiplier)
            }
        }

        return (totalHours, shifts, baseAmount, overtimeAmount)
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}

private struct TimesheetMoneyEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            Form {
                TextField(mode == .expense ? "Expense name" : "Price work name", text: $entryTitle)
                TextField("Description", text: $details, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                TextField("Job number", text: $jobNumber)
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                DatePicker(mode == .expense ? "Date" : "Start date", selection: $date, displayedComponents: .date)
                if mode == .expense {
                    PhotosPicker(selection: $receiptItem, matching: .any(of: [.images, .not(.livePhotos)])) {
                        HStack {
                            Label("Upload receipt", systemImage: "paperclip")
                            Spacer()
                            Text(receiptName ?? "Required")
                                .foregroundStyle(receiptName == nil ? Color.secondary : Color.blue)
                        }
                    }
                }
                if mode == .priceWork {
                    TextField("Manager who agreed this", text: $managerName)
                    Toggle("Add end date", isOn: $includeEndDate)
                    if includeEndDate {
                        DatePicker("End date", selection: Binding(
                            get: { endDate ?? date },
                            set: { endDate = $0 }
                        ), displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(mode == .expense ? "Add Expense" : "Add Price Work")
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
    let onApprove: (String) -> Void
    @State private var signatureImageData: Data?

    var total: Double { hoursAmount + priceWorkAmount + expensesAmount }

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
                    TimesheetSignaturePad(imageData: $signatureImageData, title: "Operative signature")
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
                    onApprove(signatureImageData.base64EncodedString())
                    dismiss()
                } label: {
                    Label("Approve timesheet & send to manager", systemImage: "checkmark")
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
        .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
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

private struct TimesheetSignedSummaryCard: View {
    let title: String
    let signatureBase64: String?
    let signedByName: String?
    let signedAt: Date?
    let pendingText: String
    
    private var displaySignerName: String {
        let value = signedByName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Signed" : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let signedAt {
                if let signatureData = signatureBase64.flatMap({ Data(base64Encoded: $0) }),
                   let signatureImage = UIImage(data: signatureData) {
                    Image(uiImage: signatureImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 100, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.98, green: 0.985, blue: 0.992))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .frame(height: 82)
                        .overlay(
                            Text(displaySignerName)
                                .font(.system(size: 24, weight: .regular, design: .serif))
                                .italic()
                                .foregroundStyle(.primary.opacity(0.8))
                        )
                }
                Text("\(displaySignerName) · \(signedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Text(pendingText)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TimesheetSignaturePad: View {
    @Binding var imageData: Data?
    let title: String
    @State private var canvas = PKCanvasView()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
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
                .frame(height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [5]))
                        .foregroundStyle(Color(red: 0.8, green: 0.84, blue: 0.88))
                )
        }
        .padding(12)
        .background(.white)
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
    @State private var showShareSheet = false

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
                    Task { await generateInvoicePDF() }
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
        .background(Color(red: 0.933, green: 0.945, blue: 0.961).ignoresSafeArea())
        .navigationTitle("Generate Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let generatedPDFURL {
                InvoicingShareSheet(items: [generatedPDFURL])
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
                }
            } else {
                summaryRow(chip: "\(settings.recurringRunStartDay.title.prefix(3)) - \(settings.recurringRunEndDay.title.prefix(3))", text: settings.recurringRunDisplaySummary)
            }

            Text("Payment Day / Dates")
                .font(.footnote.weight(.black))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1.2)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .overlay(alignment: .top) { Divider().padding(.horizontal, 16) }

            if settings.paymentDateMode == .specificDates {
                ForEach(Array(settings.normalizedPaymentDates.enumerated()), id: \.offset) { index, day in
                    summaryRow(chip: "Day \(day)", text: index == 0 ? "Run 1 payout" : "Run 2 payout")
                }
            } else {
                summaryRow(chip: "Every \(settings.recurringPaymentDay.title)", text: "Recurring payout day")
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.07), radius: 8, y: 2)
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
                .background(Color.white)
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
            .background(Color.white)
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
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
    }

    private func loadRateHistory() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        dayRateHistoryCollection = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
    }

    private func generateInvoicePDF() async {
        guard !isGenerating else { return }
        guard let period = selectedPeriod else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        let rows = invoiceLineItems(for: period)
        let total = rows.reduce(0) { $0 + $1.amount }
        let currentUser = userStore.displayUser
        let userName = currentUser?.fullName.isEmpty == false
            ? (currentUser?.fullName ?? currentUser?.email ?? "Unknown user")
            : (currentUser?.email ?? "Unknown user")
        let rateChangeNotes = rateChangeNotes(for: period)

        guard let pdfURL = InvoicePDFBuilder.makePDF(
            context: InvoicePDFBuilder.Context(
                organizationName: firebaseBackend.currentOrganization?.name ?? "Organization",
                userName: userName,
                generatedAt: Date(),
                periodTitle: period.title,
                periodDateRange: period.dateRangeText,
                lineItems: rows,
                totalAmount: total,
                rateChangeNotes: rateChangeNotes
            )
        ) else {
            errorMessage = "Failed to generate the invoice PDF."
            return
        }

        generatedPDFURL = pdfURL
        showShareSheet = true
    }

    private func invoiceLineItems(for period: InvoicePeriodOption) -> [InvoiceLineItem] {
        guard let currentUser = userStore.displayUser else { return [] }
        let cal = Calendar.current
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let standardDayHours = max(policy.standardPaidHours, 0.01)

        let userOperatives = operativeStore.allOperatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == currentUser.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let userOperativeIds = Set(userOperatives.map(\.id))

        var rows: [InvoiceLineItem] = []

        let operativeBookings = bookingStore.bookings.filter { booking in
            guard booking.status != .cancelled else { return false }
            guard userOperativeIds.contains(booking.operativeId) else { return false }
            let day = cal.startOfDay(for: booking.date)
            return day >= period.startDate && day <= period.endDate
        }

        for booking in operativeBookings {
            guard let operative = userOperatives.first(where: { $0.id == booking.operativeId }) else { continue }
            let rate = dayRateForOperativeBooking(user: currentUser, operative: operative, on: booking.date)
            let paidHours = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normalHours = max(0, paidHours - otHours)
            let normalDays = normalHours / standardDayHours
            let otDays = max(0, otHours) / standardDayHours
            let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
            let normalAmount = (rate ?? 0) * normalDays

            rows.append(
                InvoiceLineItem(
                    date: cal.startOfDay(for: booking.date),
                    jobNumber: projectLabel(for: booking.projectId).jobNumber,
                    projectName: projectLabel(for: booking.projectId).siteName,
                    details: booking.scheduleLabel(policy: policy),
                    paidHours: normalHours,
                    dayRate: rate ?? 0,
                    amount: normalAmount
                )
            )

            if otHours > 0.05 {
                let otAmount = (rate ?? 0) * (otDays * otMultiplier)
                let otExtra = (rate ?? 0) * (otDays * max(0, otMultiplier - 1))
                rows.append(
                    InvoiceLineItem(
                        date: cal.startOfDay(for: booking.date),
                        jobNumber: projectLabel(for: booking.projectId).jobNumber,
                        projectName: "\(projectLabel(for: booking.projectId).siteName) (Overtime)",
                        details: "OT \(formatHours(otHours))h × \(formatMultiplier(otMultiplier)) · extra \(formatCurrency(otExtra))",
                        paidHours: otHours,
                        dayRate: (rate ?? 0) * otMultiplier,
                        amount: otAmount
                    )
                )
            }
        }

        let managerBookings = managerScheduleStore.managerSiteBookings.filter { booking in
            guard booking.userId == currentUser.id else { return false }
            guard booking.locationType == .project || booking.locationType == .smallWork else { return false }
            guard let _ = booking.locationId else { return false }
            let day = cal.startOfDay(for: booking.date)
            return day >= period.startDate && day <= period.endDate
        }

        for booking in managerBookings {
            guard let locationId = booking.locationId else { continue }
            let rate = dayRateForUserOnDay(userId: currentUser.id, fallback: currentUser.dayRate, date: booking.date)
            let paidHours = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normalHours = max(0, paidHours - otHours)
            let normalDays = normalHours / standardDayHours
            let otDays = max(0, otHours) / standardDayHours
            let otMultiplier = policy.weekdayOutsideStandardMultiplier
            let normalAmount = (rate ?? 0) * normalDays

            rows.append(
                InvoiceLineItem(
                    date: cal.startOfDay(for: booking.date),
                    jobNumber: projectLabel(for: locationId).jobNumber,
                    projectName: projectLabel(for: locationId).siteName,
                    details: booking.scheduleLabel(policy: policy),
                    paidHours: normalHours,
                    dayRate: rate ?? 0,
                    amount: normalAmount
                )
            )

            if otHours > 0.05 {
                let otAmount = (rate ?? 0) * (otDays * otMultiplier)
                let otExtra = (rate ?? 0) * (otDays * max(0, otMultiplier - 1))
                rows.append(
                    InvoiceLineItem(
                        date: cal.startOfDay(for: booking.date),
                        jobNumber: projectLabel(for: locationId).jobNumber,
                        projectName: "\(projectLabel(for: locationId).siteName) (Overtime)",
                        details: "OT \(formatHours(otHours))h × \(formatMultiplier(otMultiplier)) · extra \(formatCurrency(otExtra))",
                        paidHours: otHours,
                        dayRate: (rate ?? 0) * otMultiplier,
                        amount: otAmount
                    )
                )
            }
        }

        return rows.sorted {
            if $0.date == $1.date {
                return $0.jobNumber < $1.jobNumber
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

    private func dayRateForUserOnDay(userId: String, fallback: Double?, date: Date) -> Double? {
        let day = calendarDayStart(date)
        let history = (dayRateHistoryCollection.byUserId[userId] ?? []).sorted(by: { $0.effectiveAt < $1.effectiveAt })
        let rateFromHistory = history.last(where: { calendarDayStart($0.effectiveAt) <= day })?.dayRate
        return rateFromHistory ?? fallback
    }

    private func dayRateForOperativeBooking(user: AppUser, operative: Operative, on date: Date) -> Double? {
        let day = calendarDayStart(date)
        let merged = dayRateHistoryCollection
            .mergedEntries(userId: user.id, operativeId: operative.id)
            .sorted(by: { $0.effectiveAt < $1.effectiveAt })
        let rateFromHistory = merged.last(where: { calendarDayStart($0.effectiveAt) <= day })?.dayRate
        let fallback = operative.dayRate ?? user.dayRate
        return rateFromHistory ?? fallback ?? user.dayRate ?? operative.dayRate
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
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startOfCurrentWeek = today.startOfISOWeek else { return nil }

        let startOffset = settings.recurringRunStartDay.isoWeekOffset
        let endOffset = settings.recurringRunEndDay.isoWeekOffset

        guard let baseWeekStart = cal.date(byAdding: .day, value: -7, to: startOfCurrentWeek),
              var startDate = cal.date(byAdding: .day, value: startOffset, to: baseWeekStart),
              var endDate = cal.date(byAdding: .day, value: endOffset, to: baseWeekStart) else {
            return nil
        }
        if endOffset < startOffset {
            endDate = cal.date(byAdding: .day, value: 7, to: endDate) ?? endDate
        }
        while endDate >= today {
            startDate = cal.date(byAdding: .day, value: -7, to: startDate) ?? startDate
            endDate = cal.date(byAdding: .day, value: -7, to: endDate) ?? endDate
        }

        let label = "Previous recurring arrears period"
        return InvoicePeriodOption(
            id: "recurring-\(Int(startDate.timeIntervalSince1970))",
            title: label,
            dateRangeText: "\(startDate.formatted(date: .abbreviated, time: .omitted)) to \(endDate.formatted(date: .abbreviated, time: .omitted))",
            startDate: cal.startOfDay(for: startDate),
            endDate: cal.startOfDay(for: endDate)
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
    let date: Date
    let jobNumber: String
    let projectName: String
    let details: String
    let paidHours: Double
    let dayRate: Double
    let amount: Double
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
        let generatedAt: Date
        let periodTitle: String
        let periodDateRange: String
        let lineItems: [InvoiceLineItem]
        let totalAmount: Double
        let rateChangeNotes: [String]
    }

    static func makePDF(context: Context) -> URL? {
        let fileName = "Invoice-\(context.userName.replacingOccurrences(of: " ", with: "_"))-\(Int(Date().timeIntervalSince1970)).pdf"
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

    private static func drawTitleBlock(context: Context, at origin: CGPoint, width: CGFloat) -> CGFloat {
        let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
        let cyan = UIColor(red: 0.169, green: 0.733, blue: 0.937, alpha: 1)

        ("Invoice" as NSString).draw(at: origin, withAttributes: [
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
        drawMeta(label: "INVOICE PERIOD", value: context.periodDateRange, x: rightX, y: metaTop + 40)

        return metaTop + 82
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
            ("No work entries were found for this invoice period." as NSString).draw(
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
            let detail = "\(item.details) · \(hoursString(item.paidHours))h · \(currency(item.dayRate))/day"
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
        ("Total invoice amount" as NSString).draw(
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

private extension RecurringPaymentDay {
    var isoWeekOffset: Int {
        switch self {
        case .monday: return 0
        case .tuesday: return 1
        case .wednesday: return 2
        case .thursday: return 3
        case .friday: return 4
        case .saturday: return 5
        case .sunday: return 6
        }
    }
}

private extension Date {
    var startOfISOWeek: Date? {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return cal.date(from: components).map { Calendar.current.startOfDay(for: $0) }
    }
}

