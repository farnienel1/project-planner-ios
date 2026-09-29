import SwiftUI

struct LineManagersMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [AppUser]
    @Binding var selectedIds: Set<String>
    var allowNoLineManager: Bool = false
    @Binding var hasNoLineManager: Bool

    @State private var showingClearValidationAlert = false

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

    private var hasValidSelection: Bool {
        hasNoLineManager || !selectedIds.isEmpty
    }

    private var validationMessage: String {
        if allowNoLineManager {
            return "Either No line manager must be selected, or select a line manager/s from the list below."
        }
        return "Select a line manager/s from the list below."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("If and when more than one line manager is selected, then annual leave requests will be sent to both line managers. Only one is required to sign off the request and the other will receive a notification about its approval or denial.")
                        .font(.subheadline)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AnnualLeavePalette.leaveTint)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if allowNoLineManager {
                        Button {
                            hasNoLineManager = true
                            selectedIds.removeAll()
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No line manager")
                                        .font(.body.weight(.semibold))
                                    Text("For directors or senior staff who book their own annual leave without approval routing.")
                                        .font(.footnote)
                                        .foregroundStyle(AnnualLeavePalette.ink3)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: hasNoLineManager ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(hasNoLineManager ? AnnualLeavePalette.leave : AnnualLeavePalette.ink3)
                            }
                            .padding(14)
                            .background(AnnualLeavePalette.card)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AnnualLeavePalette.line, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Line managers")
                        .font(.headline)
                    if candidates.isEmpty {
                        Text("No line managers are available to assign.")
                            .font(.subheadline)
                            .foregroundStyle(AnnualLeavePalette.ink3)
                    }
                    ForEach(candidates, id: \.id) { candidate in
                        let selected = selectedIds.contains(candidate.id)
                        Button {
                            hasNoLineManager = false
                            if selected {
                                selectedIds.remove(candidate.id)
                            } else {
                                selectedIds.insert(candidate.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(initials(for: candidate))
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(AnnualLeavePalette.leave)
                                    .frame(width: 38, height: 38)
                                    .background(AnnualLeavePalette.leaveTint)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.fullName.isEmpty ? candidate.email : candidate.fullName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(AnnualLeavePalette.ink)
                                    if !candidate.fullName.isEmpty {
                                        Text(candidate.email)
                                            .font(.footnote)
                                            .foregroundStyle(AnnualLeavePalette.ink3)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected ? AnnualLeavePalette.leave : AnnualLeavePalette.ink3)
                            }
                            .padding(12)
                            .background(AnnualLeavePalette.card)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(selected ? AnnualLeavePalette.leave : AnnualLeavePalette.line, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button("Clear all") {
                        selectedIds.removeAll()
                        hasNoLineManager = false
                        DispatchQueue.main.async {
                            showingClearValidationAlert = true
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AnnualLeavePalette.red)
                }
                .padding(16)
            }
            .background(AnnualLeavePalette.soft.ignoresSafeArea())
            .navigationTitle("Line managers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if hasValidSelection {
                            dismiss()
                        } else {
                            showingClearValidationAlert = true
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .interactiveDismissDisabled(!hasValidSelection)
        }
        .alert("Line manager required", isPresented: $showingClearValidationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
    }

    private func initials(for user: AppUser) -> String {
        let source = user.fullName.isEmpty ? user.email : user.fullName
        let parts = source.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let text = String(letters).uppercased()
        return text.isEmpty ? "?" : text
    }
}
