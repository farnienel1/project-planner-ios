//
//  ProjectActiveOperativesView.swift
//  Project Planner
//
//  Everyone booked onto a project or small works site — operatives, staff, subcontractors.
//

import SwiftUI

private enum ProjectBookedPersonKind: String {
    case operative
    case staff
    case subcontractor
}

private struct ProjectBookedPersonSummary: Identifiable {
    let id: String
    let kind: ProjectBookedPersonKind
    let displayName: String
    let subtitle: String
    let initials: String
    let bookingCount: Int
    let totalHours: Double
    let firstDate: Date
    let lastDate: Date
    let operativeId: UUID?
    let staffUserId: String?
    let subcontractorId: UUID?
}

struct ProjectActiveOperativesView: View {
    let project: Project
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    private var payrollPolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var summaries: [ProjectBookedPersonSummary] {
        var rows: [ProjectBookedPersonSummary] = []
        rows.append(contentsOf: operativeSummaries)
        rows.append(contentsOf: staffSummaries)
        rows.append(contentsOf: subcontractorSummaries)
        return rows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var operativeSummaries: [ProjectBookedPersonSummary] {
        let projectBookings = bookingStore.bookings.filter {
            $0.projectId == project.id && $0.status != .cancelled
        }
        let grouped = Dictionary(grouping: projectBookings, by: \.operativeId)
        return grouped.compactMap { operativeId, bookings -> ProjectBookedPersonSummary? in
            guard let operative = operativeStore.allOperatives.first(where: { $0.id == operativeId }) else { return nil }
            let sorted = bookings.sorted { $0.date < $1.date }
            let hours = bookings.reduce(0.0) { $0 + $1.paidBookedHours(policy: payrollPolicy) }
            return ProjectBookedPersonSummary(
                id: "op-\(operativeId.uuidString)",
                kind: .operative,
                displayName: operative.name,
                subtitle: "Operative",
                initials: PlannerUIInitials.from(operative.name),
                bookingCount: bookings.count,
                totalHours: hours,
                firstDate: sorted.first?.date ?? Date(),
                lastDate: sorted.last?.date ?? Date(),
                operativeId: operativeId,
                staffUserId: nil,
                subcontractorId: nil
            )
        }
    }

    private var staffSummaries: [ProjectBookedPersonSummary] {
        let projectBookings = managerScheduleStore.managerSiteBookings.filter { booking in
            booking.locationId == project.id &&
            (booking.locationType == .project || booking.locationType == .smallWork)
        }
        let grouped = Dictionary(grouping: projectBookings, by: \.userId)
        return grouped.compactMap { userId, bookings -> ProjectBookedPersonSummary? in
            let user = userStore.organizationUsers.first(where: { $0.id == userId })
            let name = user?.fullName.isEmpty == false ? (user?.fullName ?? userId) : (user?.email ?? "Staff member")
            let sorted = bookings.sorted { $0.date < $1.date }
            let hours = bookings.reduce(0.0) { $0 + $1.paidBookedHours(policy: payrollPolicy) }
            return ProjectBookedPersonSummary(
                id: "staff-\(userId)",
                kind: .staff,
                displayName: name,
                subtitle: user?.permissions.manager == true ? "Manager / staff" : "Staff",
                initials: PlannerUIInitials.from(name),
                bookingCount: bookings.count,
                totalHours: hours,
                firstDate: sorted.first?.date ?? Date(),
                lastDate: sorted.last?.date ?? Date(),
                operativeId: nil,
                staffUserId: userId,
                subcontractorId: nil
            )
        }
    }

    private var subcontractorSummaries: [ProjectBookedPersonSummary] {
        let projectBookings = subcontractorStore.bookings.filter { booking in
            booking.projectId == project.id &&
            (booking.status == .confirmed || booking.status == .tentative)
        }
        let grouped = Dictionary(grouping: projectBookings, by: \.subcontractorId)
        return grouped.compactMap { subcontractorId, bookings -> ProjectBookedPersonSummary? in
            guard let sub = subcontractorStore.subcontractors.first(where: { $0.id == subcontractorId }) else { return nil }
            let sorted = bookings.sorted { $0.date < $1.date }
            let hours = bookings.reduce(0.0) { $0 + $1.payrollMirrorBooking().paidBookedHours(policy: payrollPolicy) }
            return ProjectBookedPersonSummary(
                id: "sub-\(subcontractorId.uuidString)",
                kind: .subcontractor,
                displayName: sub.name,
                subtitle: sub.subcontractorType.isEmpty ? "Subcontractor" : sub.subcontractorType,
                initials: PlannerUIInitials.from(sub.name),
                bookingCount: bookings.count,
                totalHours: hours,
                firstDate: sorted.first?.date ?? Date(),
                lastDate: sorted.last?.date ?? Date(),
                operativeId: nil,
                staffUserId: nil,
                subcontractorId: subcontractorId
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerCard

                if summaries.isEmpty {
                    ContentUnavailableView(
                        "No booking history",
                        systemImage: "person.3",
                        description: Text("Operatives, staff and subcontractors booked onto \(project.siteName) will appear here.")
                    )
                    .padding(.top, 24)
                } else {
                    ForEach(summaries) { summary in
                        NavigationLink {
                            ProjectBookedPersonHistoryView(
                                project: project,
                                summary: summary,
                                payrollPolicy: payrollPolicy
                            )
                            .environmentObject(bookingStore)
                            .environmentObject(managerScheduleStore)
                            .environmentObject(subcontractorStore)
                        } label: {
                            bookedPersonRow(summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Active users")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            managerScheduleStore.loadData()
            Task { await subcontractorStore.loadData() }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.jobNumber)
                .font(.caption.weight(.bold))
                .foregroundStyle(ProjectWorksRevampColors.blue)
            Text(project.siteName)
                .font(.headline)
            Text("\(summaries.count) person\(summaries.count == 1 ? "" : "s") booked on this job")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bookedPersonRow(_ summary: ProjectBookedPersonSummary) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(rowTint(for: summary.kind).opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(summary.initials)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(rowTint(for: summary.kind))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(summary.bookingCount) day\(summary.bookingCount == 1 ? "" : "s") · \(formatHours(summary.totalHours))h")
                    .font(.caption2)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text("\(summary.firstDate.formatted(date: .abbreviated, time: .omitted)) – \(summary.lastDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rowTint(for kind: ProjectBookedPersonKind) -> Color {
        switch kind {
        case .operative: return ProjectWorksRevampColors.blue
        case .staff: return .purple
        case .subcontractor: return .orange
        }
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}

private struct ProjectBookedPersonHistoryView: View {
    let project: Project
    let summary: ProjectBookedPersonSummary
    let payrollPolicy: OrgPayrollTimePolicy

    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore

    private struct DayRow: Identifiable {
        let id: String
        let date: Date
        let scheduleLabel: String
        let hours: Double
    }

    private var dayRows: [DayRow] {
        switch summary.kind {
        case .operative:
            guard let operativeId = summary.operativeId else { return [] }
            return bookingStore.bookings
                .filter { $0.projectId == project.id && $0.operativeId == operativeId && $0.status != .cancelled }
                .sorted { $0.date > $1.date }
                .map {
                    DayRow(
                        id: $0.id.uuidString,
                        date: $0.date,
                        scheduleLabel: $0.scheduleLabel(policy: payrollPolicy),
                        hours: $0.paidBookedHours(policy: payrollPolicy)
                    )
                }
        case .staff:
            guard let userId = summary.staffUserId else { return [] }
            return managerScheduleStore.managerSiteBookings
                .filter {
                    $0.userId == userId &&
                    $0.locationId == project.id &&
                    ($0.locationType == .project || $0.locationType == .smallWork)
                }
                .sorted { $0.date > $1.date }
                .map {
                    DayRow(
                        id: $0.id.uuidString,
                        date: $0.date,
                        scheduleLabel: $0.scheduleLabel(policy: payrollPolicy),
                        hours: $0.paidBookedHours(policy: payrollPolicy)
                    )
                }
        case .subcontractor:
            guard let subcontractorId = summary.subcontractorId else { return [] }
            return subcontractorStore.bookings
                .filter {
                    $0.projectId == project.id &&
                    $0.subcontractorId == subcontractorId &&
                    ($0.status == .confirmed || $0.status == .tentative)
                }
                .sorted { $0.date > $1.date }
                .map {
                    let mirror = $0.payrollMirrorBooking()
                    return DayRow(
                        id: $0.id.uuidString,
                        date: $0.date,
                        scheduleLabel: mirror.scheduleLabel(policy: payrollPolicy),
                        hours: mirror.paidBookedHours(policy: payrollPolicy)
                    )
                }
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total hours")
                    Spacer()
                    Text("\(formatHours(dayRows.reduce(0) { $0 + $1.hours }))h")
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Days booked")
                    Spacer()
                    Text("\(dayRows.count)")
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Job")
                    Spacer()
                    Text("\(project.jobNumber) · \(project.siteName)")
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Day by day") {
                if dayRows.isEmpty {
                    Text("No bookings recorded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dayRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.date.formatted(date: .complete, time: .omitted))
                                .font(.subheadline.weight(.semibold))
                            Text(row.scheduleLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(formatHours(row.hours))h")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(summary.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
