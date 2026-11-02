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
            $0.projectId == project.id && $0.occupiesDay
        }
        // One row per person (`resolveBookingPerson`): a re-added person's bookings under an old and a new id share a row,
        // and a booking with no catalogue row is still listed.
        let people = LabourBookingPeople(operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
        let grouped = Dictionary(grouping: projectBookings) { booking -> UUID in
            let person = people.person(for: booking.operativeId)
            return person.operative?.id ?? person.user.map { Booking.internalOperativeId(for: $0.id) } ?? booking.operativeId
        }
        return grouped.compactMap { operativeId, bookings -> ProjectBookedPersonSummary? in
            let name = rosterNameForLabourBooking(
                operativeId: operativeId,
                operatives: operativeStore.allOperatives,
                users: userStore.organizationUsers
            )
            let sorted = bookings.sorted { $0.date < $1.date }
            let hours = bookings.reduce(0.0) { $0 + $1.paidBookedHours(policy: payrollPolicy) }
            return ProjectBookedPersonSummary(
                id: "op-\(operativeId.uuidString)",
                kind: .operative,
                displayName: name,
                subtitle: "Operative",
                initials: PlannerUIInitials.from(name),
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
            // Still on the job (`isOpenBookingStatus`), as web's active users list: a completed
            // subcontractor booking is not open.
            booking.status.isOpen
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
            VStack(spacing: 0) {
                headerCard

                VStack(spacing: 12) {
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
                            .accessibilityIdentifier("projectActiveOperatives.row.\(summary.id)")
                            .buttonStyle(PPPressableButtonStyle())
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Active users")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .onAppear {
            managerScheduleStore.loadData()
            Task { await subcontractorStore.loadData() }
        }
    }

    /// Navy header: job number, site name and the existing "previously booked" line.
    private var headerCard: some View {
        let count = summaries.count
        return VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                eyebrow: project.jobNumber,
                title: project.siteName,
                subtitle: "\(count) user\(count == 1 ? "" : "s") previously booked on this job"
            )
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func bookedPersonRow(_ summary: ProjectBookedPersonSummary) -> some View {
        HStack(spacing: 13) {
            Text(summary.initials)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(rowFamily(for: summary.kind).gradient, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(summary.bookingCount) day\(summary.bookingCount == 1 ? "" : "s") · \(formatHours(summary.totalHours))h")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(summary.firstDate.formatted(date: .abbreviated, time: .omitted)) – \(summary.lastDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
    }

    /// Icon colour family per person kind (operative blue, staff indigo, subcontractor amber).
    private func rowFamily(for kind: ProjectBookedPersonKind) -> PPFamily {
        switch kind {
        case .operative: return .plan
        case .staff: return .people
        case .subcontractor: return .trade
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
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore

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
            let personIds = labourBookingIds(sameAs: operativeId, operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
            return bookingStore.bookings
                .filter { $0.projectId == project.id && personIds.contains($0.operativeId) && $0.occupiesDay }
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
                    $0.status.isOpen
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
                        .monospacedDigit()
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
            .listRowBackground(PPColor.card)

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
                                .foregroundStyle(PPColor.brand)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listRowBackground(PPColor.card)
        }
        .scrollContentBackground(.hidden)
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle(summary.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
    }

    private func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
