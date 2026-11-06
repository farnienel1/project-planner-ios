//
//  MyWorksPickerSheet.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §21: the ⚙ of "My Projects" / "My Small works" — every job of the list the person sees, ticked when
//  it is on their list (web `components/projects/MyWorksPicker.tsx`). The rows and the list after a tick are the
//  rulebook's (`myWorksPickerRows`, `myWorksPicksAfterToggle`); Save writes `organizations/{orgId}/worksListPicks/{uid}`.
//

import SwiftUI

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

    private var noun: String { kind == .smallWorks ? "small works" : "projects" }

    private var pickedKeys: Set<String> { Set(ids.map { $0.lowercased() }) }

    private var shownJobs: [Project] {
        let jobs = rows.map(\.job)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return jobs }
        return jobs.filter { job in
            job.jobNumber.lowercased().contains(q)
                || job.siteName.lowercased().contains(q)
                || job.siteAddress.lowercased().contains(q)
                || job.client.name.lowercased().contains(q)
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
