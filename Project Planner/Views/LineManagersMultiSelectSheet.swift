import SwiftUI

struct LineManagersMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [AppUser]
    @Binding var selectedIds: Set<String>
    var allowNoLineManager: Bool = false
    @Binding var hasNoLineManager: Bool

    init(
        candidates: [AppUser],
        selectedIds: Binding<Set<String>>,
        allowNoLineManager: Bool = false,
        hasNoLineManager: Binding<Bool> = .constant(false)
    ) {
        self.candidates = candidates
        self._selectedIds = selectedIds
        self.allowNoLineManager = allowNoLineManager
        self._hasNoLineManager = hasNoLineManager
    }

    var body: some View {
        NavigationStack {
            List {
                if allowNoLineManager {
                    Section {
                        Button {
                            hasNoLineManager = true
                            selectedIds.removeAll()
                            dismiss()
                        } label: {
                            HStack {
                                Text("No line manager")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if hasNoLineManager {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    } footer: {
                        Text("For directors or senior staff who book their own annual leave without approval routing.")
                    }
                }
                Section {
                    Button("Clear all") {
                        selectedIds.removeAll()
                        hasNoLineManager = false
                    }
                    .foregroundStyle(.red)
                }
                Section("Line managers") {
                    ForEach(candidates, id: \.id) { candidate in
                        Button {
                            hasNoLineManager = false
                            if selectedIds.contains(candidate.id) {
                                selectedIds.remove(candidate.id)
                            } else {
                                selectedIds.insert(candidate.id)
                            }
                        } label: {
                            HStack {
                                Text(candidate.fullName.isEmpty ? candidate.email : candidate.fullName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedIds.contains(candidate.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Line managers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
