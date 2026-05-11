import SwiftUI

struct SkillsManagementView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddSkill = false
    @State private var tradeFilter: String? = nil

    /// When set, each skill row is tappable to add that skill’s id to the set (operative profile editor).
    var assignmentSkillIds: Binding<Set<String>>?

    init(assignmentSkillIds: Binding<Set<String>>? = nil) {
        self.assignmentSkillIds = assignmentSkillIds
    }

    private var isAssignmentMode: Bool {
        assignmentSkillIds != nil
    }

    private var tradeNames: [String] {
        let trades = Set(operativeStore.organizationSkills.map(\.trade))
        return trades.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filteredSkills: [OrganizationSkill] {
        let base: [OrganizationSkill]
        if let tradeFilter {
            base = operativeStore.organizationSkills.filter { $0.trade == tradeFilter }
        } else {
            base = operativeStore.organizationSkills
        }
        return base.sorted {
            if $0.trade.localizedCaseInsensitiveCompare($1.trade) != .orderedSame {
                return $0.trade.localizedCaseInsensitiveCompare($1.trade) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var groupedFiltered: [(trade: String, skills: [OrganizationSkill])] {
        let grouped = Dictionary(grouping: filteredSkills, by: { $0.trade })
        return grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { key in
            (trade: key, skills: (grouped[key] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isAssignmentMode {
                    Text("Tap a skill to add it to this profile. Tap the back button when finished.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }

                if operativeStore.organizationSkills.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)

                        Text("No Skills Added Yet")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Add skills by trade so you can assign them to staff.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        if !isAssignmentMode {
                            Button("Add Your First Skill") {
                                showingAddSkill = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                } else {
                    List {
                        if tradeNames.count > 1 {
                            Section {
                                Picker("Filter by trade", selection: Binding(
                                    get: { tradeFilter ?? "All trades" },
                                    set: { newValue in
                                        tradeFilter = (newValue == "All trades") ? nil : newValue
                                    }
                                )) {
                                    Text("All trades").tag("All trades")
                                    ForEach(tradeNames, id: \.self) { t in
                                        Text(t).tag(t)
                                    }
                                }
                            }
                        }

                        ForEach(groupedFiltered, id: \.trade) { group in
                            Section(group.trade) {
                                ForEach(group.skills) { skill in
                                    if let binding = assignmentSkillIds {
                                        let already = binding.wrappedValue.contains(skill.id)
                                        Button {
                                            binding.wrappedValue.insert(skill.id)
                                        } label: {
                                            HStack(alignment: .top, spacing: 10) {
                                                Image(systemName: "wrench.fill")
                                                    .foregroundColor(.blue)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(skill.name)
                                                        .font(.body)
                                                        .foregroundStyle(.primary)
                                                    Text(skill.trade)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                                Spacer()
                                                Image(systemName: already ? "checkmark.circle.fill" : "plus.circle.fill")
                                                    .foregroundStyle(already ? Color.green : Color.blue)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: "wrench.fill")
                                                .foregroundColor(.blue)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(skill.name)
                                                    .font(.body)
                                                Text(skill.trade)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteSkills(in: group.skills, at: offsets)
                                }
                                .deleteDisabled(isAssignmentMode)
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                Spacer()
            }
            .navigationTitle(isAssignmentMode ? "Add skills" : "Skills Management")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: isAssignmentMode ? "chevron.backward" : "xmark")
                            .foregroundColor(.blue)
                    }
                }

                if !isAssignmentMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Add Skill") {
                            showingAddSkill = true
                        }
                    }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Add new…") {
                            showingAddSkill = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddSkill) {
                NavigationStack {
                    AddSkillView()
                        .environmentObject(operativeStore)
                }
            }
        }
    }

    private func deleteSkills(in skills: [OrganizationSkill], at offsets: IndexSet) {
        for index in offsets {
            let skill = skills[index]
            Task {
                await operativeStore.removeOrganizationSkill(id: skill.id)
            }
        }
    }
}

struct AddSkillView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var skillName = ""
    @State private var tradePresetRaw = StaffTradeType.electrician.rawValue
    @State private var tradeCustomText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var resolvedTradeLabel: String {
        StaffTradeType.displayLabel(presetRaw: tradePresetRaw, custom: tradeCustomText)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Add New Skill")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Choose the trade this skill belongs to, then enter the skill name. The same skill can exist under different trades.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skill name")
                        .font(.headline)

                    TextField("e.g. Containment installation", text: $skillName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    StaffTradeTypeFormSection(
                        presetRaw: $tradePresetRaw,
                        customText: $tradeCustomText,
                        title: "Trade",
                        footnote: "Used to group and filter skills."
                    )
                }
                .padding(.horizontal)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                Button(isSaving ? "Saving…" : "Save") {
                    addSkill()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving ||
                    skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !StaffTradeType.isComplete(presetRaw: tradePresetRaw, custom: tradeCustomText)
                )
                .padding()
            }
            .padding(.vertical)
        }
        .navigationTitle("New skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func addSkill() {
        let trimmedSkill = skillName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSkill.isEmpty else {
            errorMessage = "Skill name cannot be empty"
            return
        }

        guard StaffTradeType.isComplete(presetRaw: tradePresetRaw, custom: tradeCustomText) else {
            errorMessage = "Please complete the trade selection."
            return
        }

        let trade = resolvedTradeLabel
        let (nk, tk) = OrganizationSkill.normalizedPair(name: trimmedSkill, trade: trade)
        if operativeStore.organizationSkills.contains(where: {
            let p = OrganizationSkill.normalizedPair(name: $0.name, trade: $0.trade)
            return p.0 == nk && p.1 == tk
        }) {
            errorMessage = "This skill already exists for that trade."
            return
        }

        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            await operativeStore.addOrganizationSkill(name: trimmedSkill, trade: trade)
            isSaving = false
            dismiss()
        }
    }
}

#Preview {
    SkillsManagementView()
        .environmentObject(OperativeStore())
}
