import SwiftUI

/// Lists organisation qualification templates not yet on the profile; tap + to assign, then **Done**.
/// Creating a new organisation type is only offered when the acting user can manage organisation qualifications.
struct AssignQualificationsPickerView: View {
    @Binding var selectedQualifications: Set<Qualification>
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddOrganisationType = false

    private var canCreateOrganisationTypes: Bool {
        userStore.canManageOrganisationQualifications()
    }

    private var available: [Qualification] {
        operativeStore.qualifications
            .filter { !selectedQualifications.contains($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if operativeStore.qualifications.isEmpty {
                    Section {
                        Text(
                            canCreateOrganisationTypes
                                ? "No qualification templates yet. Tap Add to create one for the organisation."
                                : "No qualification templates yet. Ask someone who can manage qualifications to add them."
                        )
                        .foregroundStyle(.secondary)
                    }
                } else if available.isEmpty {
                    Section {
                        Text("Every organisation qualification is already on this profile.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("Tap + to add a qualification. Set expiry dates and certificates when you return.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(available) { qualification in
                        Button {
                            selectedQualifications.insert(qualification)
                        } label: {
                            HStack {
                                Text(qualification.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add qualifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if canCreateOrganisationTypes {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add") {
                            showingAddOrganisationType = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddOrganisationType) {
                NavigationStack {
                    AddQualificationView()
                        .environmentObject(operativeStore)
                }
            }
        }
    }
}
