import SwiftUI

struct LineManagersMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [AppUser]
    @Binding var selectedIds: Set<String>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Clear all") {
                        selectedIds.removeAll()
                    }
                    .foregroundStyle(.red)
                }
                Section("Line managers") {
                    ForEach(candidates, id: \.id) { candidate in
                        Button {
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
