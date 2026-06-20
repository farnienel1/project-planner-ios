//
//  SelectOperativesView.swift
//  Project Planner
//

import SwiftUI

struct SelectOperativesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    @Binding var selectedOperatives: Set<UUID>
    let people: [ScheduleBookablePerson]
    let selectedDates: Set<Date>
    let bulkChoice: OperativeDayBookingChoice
    let projectId: UUID
    let excludingBookingIds: Set<UUID>
    @Binding var acknowledgedConflictIds: Set<String>
    @Binding var struckConflictIds: Set<String>
    @Binding var expandedPersonIds: Set<UUID>

    @State private var searchText = ""
    @State private var selectedFilter: AvailabilityFilter = .all
    @State private var tradeFilterPreset: String? = nil

    enum AvailabilityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case available = "Available"
        case onThisJob = "On this job"
        case annualLeave = "Annual Leave"

        var id: String { rawValue }
    }

    private var policy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var canSave: Bool {
        guard !selectedDates.isEmpty else { return false }
        return ScheduleBookingConflictEngine.allActionableRowsResolved(
            people: people,
            selectedOperativeIds: selectedOperatives,
            selectedDates: selectedDates,
            choice: bulkChoice,
            projectId: projectId,
            projectStore: projectStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            policy: policy,
            excludingBookingIds: excludingBookingIds,
            manuallyExcludedDaysByOperative: manuallyExcludedDaysByOperative,
            acknowledgedRowIds: acknowledgedConflictIds,
            struckRowIds: struckConflictIds
        )
    }

    private var manuallyExcludedDaysByOperative: [UUID: Set<Date>] {
        var map: [UUID: Set<Date>] = [:]
        for person in people where selectedOperatives.contains(person.operativeId) {
            let rows = ScheduleBookingConflictEngine.buildConflictRows(
                person: person,
                selectedDates: selectedDates,
                choice: bulkChoice,
                projectId: projectId,
                projectStore: projectStore,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                policy: policy,
                excludingBookingIds: excludingBookingIds
            )
            let approved = Set(rows.filter { $0.kind == .approvedAnnualLeave }.map { Calendar.current.startOfDay(for: $0.date) })
            map[person.operativeId] = approved
        }
        return map
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !people.isEmpty {
                    OperativeSearchBar(text: $searchText)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(AvailabilityFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    Picker("Trade", selection: $tradeFilterPreset) {
                        Text("All trades").tag(Optional<String>.none)
                        ForEach(StaffTradeType.pickerCases) { trade in
                            Text(trade.rawValue).tag(Optional(trade.rawValue))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if operativeStore.isLoading {
                    ProgressView("Loading people…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredPeople.isEmpty {
                    emptyState
                } else {
                    List(filteredPeople) { person in
                        SchedulePersonSelectionRow(
                            person: person,
                            isSelected: selectedOperatives.contains(person.operativeId),
                            summary: personSummary(person),
                            isExpanded: expandedPersonIds.contains(person.operativeId),
                            onToggleSelect: { toggleSelection(person) },
                            onToggleExpand: { toggleExpand(person.operativeId) },
                            onAcknowledge: { rowId in
                                acknowledgedConflictIds.insert(rowId)
                                struckConflictIds.remove(rowId)
                            },
                            onStrike: { rowId in
                                struckConflictIds.insert(rowId)
                                acknowledgedConflictIds.remove(rowId)
                            },
                            acknowledgedIds: acknowledgedConflictIds,
                            struckIds: struckConflictIds
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Select people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(Color.theme.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(canSave ? Color.theme.primary : Color.secondary)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No matching people")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Try a different filter or add staff in Manage Users.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func personSummary(_ person: ScheduleBookablePerson) -> SchedulePersonConflictSummary? {
        ScheduleBookingConflictEngine.summarizePerson(
            person: person,
            selectedDates: selectedDates,
            isSelected: selectedOperatives.contains(person.operativeId),
            choice: bulkChoice,
            projectId: projectId,
            projectStore: projectStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            policy: policy,
            excludingBookingIds: excludingBookingIds,
            manuallyExcludedDays: manuallyExcludedDaysByOperative[person.operativeId] ?? [],
            acknowledgedRowIds: acknowledgedConflictIds,
            struckRowIds: struckConflictIds
        )
    }

    private func toggleSelection(_ person: ScheduleBookablePerson) {
        if selectedOperatives.contains(person.operativeId) {
            selectedOperatives.remove(person.operativeId)
            expandedPersonIds.remove(person.operativeId)
        } else {
            selectedOperatives.insert(person.operativeId)
            if let summary = personSummary(person), summary.triangle != .none {
                expandedPersonIds.insert(person.operativeId)
            }
        }
    }

    private func toggleExpand(_ operativeId: UUID) {
        if expandedPersonIds.contains(operativeId) {
            expandedPersonIds.remove(operativeId)
        } else {
            expandedPersonIds.insert(operativeId)
        }
    }

    private var filteredPeople: [ScheduleBookablePerson] {
        let filteredBySegment = people.filter { person in
            let summary = personSummary(person)
            switch selectedFilter {
            case .all:
                return true
            case .available:
                if selectedOperatives.contains(person.operativeId) { return true }
                return summary?.effectiveSelectedDates.isEmpty != false && summary?.rows.isEmpty != false
            case .onThisJob:
                return person.hasPastBookingOnProject
            case .annualLeave:
                return summary?.rows.contains(where: { $0.kind == .approvedAnnualLeave || $0.kind == .pendingAnnualLeave }) == true
            }
        }

        let tradeFiltered: [ScheduleBookablePerson]
        if let fp = tradeFilterPreset?.trimmingCharacters(in: .whitespacesAndNewlines), !fp.isEmpty {
            tradeFiltered = filteredBySegment.filter { $0.tradeLabel == fp || $0.tradeLabel.contains(fp) }
        } else {
            tradeFiltered = filteredBySegment
        }

        if searchText.isEmpty { return tradeFiltered }
        return tradeFiltered.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.email.localizedCaseInsensitiveContains(searchText) ||
            $0.roleLabel.localizedCaseInsensitiveContains(searchText) ||
            $0.tradeLabel.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Row

private struct SchedulePersonSelectionRow: View {
    let person: ScheduleBookablePerson
    let isSelected: Bool
    let summary: SchedulePersonConflictSummary?
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let onAcknowledge: (String) -> Void
    let onStrike: (String) -> Void
    let acknowledgedIds: Set<String>
    let struckIds: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onToggleSelect) {
                    ZStack {
                        Circle()
                            .stroke(isSelected ? Color.theme.primary : Color.gray.opacity(0.3), lineWidth: 2)
                            .frame(width: 24, height: 24)
                        if isSelected {
                            Circle()
                                .fill(Color.theme.primary)
                                .frame(width: 16, height: 16)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(person.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(person.roleLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                        if let summary, summary.triangle != .none {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(summary.triangle == .red ? .red : .orange)
                        }
                    }
                    Text(person.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if person.tradeLabel != "—" {
                        Text(person.tradeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isSelected, let summary, !summary.droppedApprovedLeaveDates.isEmpty {
                        Text("Dropped from booking: \(summary.droppedApprovedLeaveDates.map { $0.formatted(date: .abbreviated, time: .omitted) }.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if let summary, !summary.rows.isEmpty {
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded, let summary {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.rows) { row in
                        ScheduleConflictRowView(
                            row: row,
                            isAcknowledged: acknowledgedIds.contains(row.id),
                            isStruck: struckIds.contains(row.id),
                            onAcknowledge: { onAcknowledge(row.id) },
                            onStrike: { onStrike(row.id) }
                        )
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
    }
}

struct OperativeSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by name, email, or trade", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
