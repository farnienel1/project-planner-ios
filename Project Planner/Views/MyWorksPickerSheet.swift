//
//  MyWorksPickerSheet.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §21: the ⚙ of "My Projects" / "My Small works" — every job of the list the person sees, ticked when
//  it is on their list (web `components/projects/MyWorksPicker.tsx`). The rows and the list after a tick are the
//  rulebook's (`myWorksPickerRows`, `myWorksPicksAfterToggle`); Save writes `organizations/{orgId}/worksListPicks/{uid}`.
//  Owner request 10 Nov: an All / Active / Upcoming / Completed filter narrows the rows while ticking — the job's tab is
//  the rulebook's (`worksInTab`, counts `worksTabCounts`, §21) in the organisation zone; ticks are kept across filters
//  and Save writes the whole list, whatever is shown.
//

import SwiftUI

/// The ⚙ picker's status filter (owner request 10 Nov). Which tab a job is under is §21 (`worksInTab` /
/// `worksTabCounts`, an inactive job under Completed); only the search text match is local.
enum MyWorksPickerFilter {
    /// All, Active, Upcoming, Completed — the chips in order (nil is All, the default).
    static let chips: [ProjectStatus?] = [nil, .active, .upcoming, .completed]

    static func title(_ chip: ProjectStatus?) -> String {
        switch chip {
        case nil: return "All"
        case .active: return "Active"
        case .upcoming: return "Upcoming"
        case .completed, .inactive: return "Completed"
        }
    }

    static func count(_ chip: ProjectStatus?, in counts: WorksListStatusCounts) -> Int {
        switch chip {
        case nil: return counts.all
        case .active: return counts.active
        case .upcoming: return counts.upcoming
        case .completed, .inactive: return counts.completed
        }
    }

    /// The ids (lower case) of the jobs under each status tab — `worksInTab(jobs, tab, now, timeZone)` — asked once when
    /// the picker opens (1.33.1: never per render; the rows are a snapshot while the sheet is open).
    @MainActor static func tabMembership(
        _ jobs: [Project],
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for tab in ["active", "upcoming", "completed"] {
            let inTab = CanonicalBusinessEngine.worksInTab(jobs, tab: tab, now: now, timeZone: timeZone)
            out[tab] = Set(inTab.map { $0.documentId.lowercased() })
        }
        return out
    }

    /// The rows shown for a chip from `tabMembership` (All keeps every job, in order), then the search text on job
    /// number, site name, address and client. Pure Swift filtering of the rulebook's answer.
    static func shownJobs(_ jobs: [Project], chip: ProjectStatus?, search: String, membership: [String: Set<String>]) -> [Project] {
        let tab = WorksListStatusCounts.tab(for: chip)
        let inTab = tab == "all" ? jobs : jobs.filter { membership[tab]?.contains($0.documentId.lowercased()) == true }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return inTab }
        return inTab.filter { job in
            job.jobNumber.lowercased().contains(q)
                || job.siteName.lowercased().contains(q)
                || job.siteAddress.lowercased().contains(q)
                || job.client.name.lowercased().contains(q)
        }
    }

    /// The rows shown: `worksInTab(jobs, tab, now, timeZone)` for the chip (All keeps every job, in order), then the
    /// search text on job number, site name, address and client.
    @MainActor static func shownJobs(
        _ jobs: [Project],
        chip: ProjectStatus?,
        search: String,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [Project] {
        shownJobs(jobs, chip: chip, search: search, membership: tabMembership(jobs, now: now, timeZone: timeZone))
    }
}

struct MyWorksPickerSheet: View {
    let kind: JobKind
    /// `myWorksPickerRows` for the viewer, taken once when the ⚙ was opened (1.33.1: a snapshot, so a listener
    /// update while the sheet is open never recomputes the rows). #210 review fix 2: the list screen takes them once
    /// more when the server's first answer arrives after the ⚙ opened; the person's ticks are then replayed on it.
    let rows: [MyWorksPickerRow]
    /// `myWorksIds`: the whole stored list for this kind, ids of deleted or hidden jobs included (§21: they stay
    /// stored; guardrail 3). The ticks start from this, never from the visible ticked rows, so Save keeps them.
    let storedIds: [String]
    let accent: Color
    /// #210 review fix 2: false until the picks are known (server answer or cached copy) or the wait is over
    /// (`MyWorksPicksModel.pickerReady`). Save waits for it; Cancel never does.
    var ready: Bool = true
    /// Ready only because the wait for the server is over: the ticks start from the pre-fill.
    var startsFromPrefill: Bool = false
    /// Hands the list to Firestore (`MyWorksPicksModel.save`). Returns at once: Firestore applies it on this phone and
    /// the server's answer is awaited in the background. Throws only when nothing could be written.
    let onSave: @MainActor ([String]) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var started = false
    /// The status filter; All by default. Changing it never changes `ids`.
    @State private var chip: ProjectStatus?
    /// `worksTabCounts` and `worksInTab` for the rows, asked once on open (never per render).
    @State private var counts = WorksListStatusCounts(all: 0, active: 0, upcoming: 0, completed: 0)
    @State private var membership: [String: Set<String>] = [:]
    /// The person's own ticks, in order, so they can be replayed on the server's list (`MyWorksPickerGate.ids`).
    @State private var toggles: [(jobId: String, picked: Bool)] = []

    static let loadingMessage = "Loading your list…"
    static let prefillMessage = "Couldn't reach the server. Your list starts from the jobs you manage; saving replaces a list saved on another device."

    /// 1.33.1 (owner report: Cancel did nothing while the save spun): Cancel always closes the sheet. Save never waits for
    /// the server, so there is no saving state to lock it; a write already handed to Firestore carries on.
    static let cancelAlwaysEnabled = true

    private var noun: String { kind == .smallWorks ? "small works" : "projects" }

    private var jobs: [Project] { rows.map(\.job) }

    private var filterChips: some View {
        let tabCounts = counts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MyWorksPickerFilter.chips, id: \.self) { option in
                    WorksRevampFilterChip(
                        title: "\(MyWorksPickerFilter.title(option)) · \(MyWorksPickerFilter.count(option, in: tabCounts))",
                        isSelected: chip == option,
                        selectedForeground: .primary,
                        selectedFill: accent,
                        titleFont: .subheadline.weight(.semibold),
                        horizontalPadding: 14,
                        verticalPadding: 7,
                        accessibilityIdentifier: "myWorksPicker.filter.\(WorksListStatusCounts.tab(for: option))",
                        action: { chip = option }
                    )
                    .accessibilityAddTraits(chip == option ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    var body: some View {
        let shown = MyWorksPickerFilter.shownJobs(jobs, chip: chip, search: search, membership: membership)
        let pickedKeys = Set(ids.map { $0.lowercased() })
        return NavigationStack {
            List {
                Section {
                    Text("Tick the \(noun) you want on your list. Your list is the same on the web and on iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !ready {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(Self.loadingMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("myWorksPicker.loading")
                    } else if startsFromPrefill {
                        Text(Self.prefillMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("myWorksPicker.prefillNote")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    filterChips
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    if shown.isEmpty {
                        Text("No \(noun) found.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(shown) { job in
                            let on = pickedKeys.contains(job.documentId.lowercased())
                            Button {
                                toggles.append((jobId: job.documentId, picked: !on))
                                ids = CanonicalBusinessEngine.myWorksPicksAfterToggle(ids, jobId: job.documentId, picked: !on)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(on ? accent : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(job.siteName.isEmpty ? job.jobNumber : job.siteName)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(job.jobNumber)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("myWorksPicker.row.\(job.documentId)")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(noun)…")
            .navigationTitle(CanonicalBusinessEngine.myWorksTabLabel(kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(!Self.cancelAlwaysEnabled)
                        .accessibilityIdentifier("myWorksPicker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!ready)
                        .accessibilityIdentifier("myWorksPicker.save")
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                ids = MyWorksPickerGate.ids(base: storedIds, toggles: [])
                counts = WorksListStatusCounts.from(jobs)
                membership = MyWorksPickerFilter.tabMembership(jobs)
            }
            .onChange(of: storedIds) { _, newStoredIds in
                // The server's first answer arrived after the ⚙ opened: start from the whole list the server holds
                // (hidden and deleted jobs' ids included), then the person's own ticks on top, so Save never writes
                // the pre-fill over a list saved elsewhere and never drops ids it does not show.
                guard started else { return }
                ids = MyWorksPickerGate.ids(base: newStoredIds, toggles: toggles)
            }
            .onChange(of: rows) { _, newRows in
                guard started else { return }
                let newJobs = newRows.map(\.job)
                counts = WorksListStatusCounts.from(newJobs)
                membership = MyWorksPickerFilter.tabMembership(newJobs)
            }
        }
    }

    private func save() {
        guard ready else { return }
        errorMessage = nil
        do {
            try onSave(ids)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription.isEmpty ? MyWorksPicksModel.saveFailedMessage : error.localizedDescription
        }
    }
}
