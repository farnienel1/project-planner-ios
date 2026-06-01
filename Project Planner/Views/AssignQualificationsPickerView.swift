import SwiftUI

/// Lists organisation qualification templates not yet on the profile; tap a row to add it (one-by-one or multiple), then **Done** to return.
struct AssignQualificationsPickerView: View {
    @Binding var selectedQualifications: Set<Qualification>
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingOrganisationManagement = false

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
                        Text("No qualification templates yet. Use Organisation list to create some.")
                            .foregroundStyle(.secondary)
                    }
                } else if available.isEmpty {
                    Section {
                        Text("Every organisation qualification is already on this profile.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("Tap a qualification to add it. Set expiry dates and certificates when you return.")
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Organisation list") {
                        showingOrganisationManagement = true
                    }
                }
            }
            .sheet(isPresented: $showingOrganisationManagement) {
                QualificationsManagementView()
                    .environmentObject(operativeStore)
            }
        }
    }
}
