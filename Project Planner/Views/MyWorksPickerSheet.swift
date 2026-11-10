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

    /// The rows shown: `worksInTab(jobs, tab, now, timeZone)` for the chip (All keeps every job, in order), then the
    /// search text on job number, site name, address and client.
    @MainActor static func shownJobs(
        _ jobs: [Project],
        chip: ProjectStatus?,
        search: String,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [Project] {
        let tab = WorksListStatusCounts.tab(for: chip)
        let inTab = tab == "all" ? jobs : CanonicalBusinessEngine.worksInTab(jobs, tab: tab, now: now, timeZone: timeZone)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return inTab }
        return inTab.filter { job in
            job.jobNumber.lowercased().contains(q)
                || job.siteName.lowercased().contains(q)
                || job.siteAddress.lowercased().contains(q)
                || job.client.name.lowercased().contains(q)
        }
    }
}

struct MyWorksPickerSheet: View {
    let kind: JobKind
    /// `myWorksPickerRows` for the viewer.
    let rows: [(job: Project, picked: Bool)]
    let accent: Color
    let onSave: ([String]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []
    @State private var search = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var started = false
    /// The status filter; All by default. Changing it never changes `ids`.
    @State private var chip: ProjectStatus?

    private var noun: String { kind == .smallWorks ? "small works" : "projects" }

    private var pickedKeys: Set<String> { Set(ids.map { $0.lowercased() }) }

    private var shownJobs: [Project] {
        MyWorksPickerFilter.shownJobs(rows.map(\.job), chip: chip, search: search)
    }

    /// `worksTabCounts` over every job the picker lists (not narrowed by the search).
    private var counts: WorksListStatusCounts { WorksListStatusCounts.from(rows.map(\.job)) }

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
        NavigationStack {
            List {
                Section {
                    Text("Tick the \(noun) you want on your list. Your list is the same on the web and on iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    filterChips
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    if shownJobs.isEmpty {
                        Text("No \(noun) found.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(shownJobs) { job in
                            let on = pickedKeys.contains(job.documentId.lowercased())
                            Button {
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
                        .disabled(saving)
                        .accessibilityIdentifier("myWorksPicker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("myWorksPicker.save")
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                ids = rows.filter(\.picked).map { $0.job.documentId }
            }
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let chosen = ids
        Task {
            do {
                try await onSave(chosen)
                saving = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription.isEmpty ? "Could not save your list." : error.localizedDescription
                saving = false
            }
        }
    }
}
