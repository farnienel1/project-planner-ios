import SwiftUI

/// Lists organisation qualification templates not yet on the profile.
/// Search, section chips, and multi-select use the same library browser as the organisation list.
struct AssignQualificationsPickerView: View {
    @Binding var selectedQualifications: Set<Qualification>
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddOrganisationType = false
    @State private var alreadyAssignedIds: Set<String> = []

    private var canCreateOrganisationTypes: Bool {
        userStore.canManageOrganisationQualifications()
    }

    private var pickerItems: [Qualification] {
        operativeStore.qualifications.filter { !alreadyAssignedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if operativeStore.qualifications.isEmpty {
                    Text(
                        canCreateOrganisationTypes
                            ? "No qualification templates yet. Tap Add to create one for the organisation."
                            : "No qualification templates yet. Ask someone who can manage qualifications to add them."
                    )
                    .foregroundStyle(.secondary)
                    .padding()
                } else if pickerItems.isEmpty {
                    Text("Every organisation qualification is already on this profile.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    QualificationLibraryBrowser(
                        items: pickerItems,
                        selectedIds: Set(selectedQualifications.map(\.id)),
                        onToggle: toggle,
                        hint: "Search or filter, tap + to choose a qualification, then Done. Set expiry dates and certificates on the cards after you return."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))   // matches the plain List inside the library browser
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: PPMetrics.contentCornerRadius,
                    topTrailingRadius: PPMetrics.contentCornerRadius,
                    style: .continuous
                )
            )
            .padding(.top, 8)
            .background(PPNavyBackdrop().ignoresSafeArea())
            .navigationTitle("Add qualifications")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(.white)
                        .accessibilityIdentifier("assignQualificationsPicker.done")
                }
                if canCreateOrganisationTypes {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add") {
                            showingAddOrganisationType = true
                        }
                        .fontWeight(.semibold)
                        .tint(.white)
                        .accessibilityIdentifier("assignQualificationsPicker.add")
                    }
                }
            }
            .sheet(isPresented: $showingAddOrganisationType) {
                NavigationStack {
                    AddQualificationView()
                        .environmentObject(operativeStore)
                }
            }
            .onAppear {
                if alreadyAssignedIds.isEmpty {
                    alreadyAssignedIds = Set(selectedQualifications.map(\.id))
                }
            }
        }
    }

    private func toggle(_ qualification: Qualification) {
        if selectedQualifications.contains(qualification) {
            selectedQualifications.remove(qualification)
        } else {
            selectedQualifications.insert(qualification)
        }
    }
}
