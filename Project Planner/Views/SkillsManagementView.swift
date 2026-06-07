import SwiftUI

struct SkillsManagementView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddSkill = false
    @State private var skillToEdit: OrganizationSkill?
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
                                        Button {
                                            skillToEdit = skill
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
                                                Image(systemName: "chevron.right")
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
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
                    SkillFormView(mode: .add)
                        .environmentObject(operativeStore)
                }
            }
            .sheet(item: $skillToEdit) { skill in
                NavigationStack {
                    SkillFormView(mode: .edit(skill))
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

struct SkillFormView: View {
    enum Mode {
        case add
        case edit(OrganizationSkill)
    }

    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var skillName = ""
    @State private var tradeText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var editingSkill: OrganizationSkill? {
        if case .edit(let skill) = mode { return skill }
        return nil
    }

    private var existingTrades: [String] {
        operativeStore.organizationSkills.map(\.trade)
    }

    private var navigationTitle: String {
        editingSkill == nil ? "New skill" : "Edit skill"
    }

    private var headline: String {
        editingSkill == nil ? "Add New Skill" : "Edit Skill"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(headline)
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Enter the trade this skill belongs to, then the skill name. Skills can be assigned to any staff member regardless of their trade.")
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
                    SkillTradeSearchField(
                        trade: $tradeText,
                        existingTrades: existingTrades,
                        title: "Trade"
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
                    saveSkill()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving ||
                    skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    tradeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .padding()
            }
            .padding(.vertical)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear {
            if let skill = editingSkill {
                skillName = skill.name
                tradeText = skill.trade
            }
        }
    }

    private func saveSkill() {
        let trimmedSkill = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrade = tradeText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSkill.isEmpty else {
            errorMessage = "Skill name cannot be empty"
            return
        }

        guard !trimmedTrade.isEmpty else {
            errorMessage = "Trade name cannot be empty"
            return
        }

        let excludeId = editingSkill?.id
        let (nk, tk) = OrganizationSkill.normalizedPair(name: trimmedSkill, trade: trimmedTrade)
        if operativeStore.organizationSkills.contains(where: {
            if let excludeId, $0.id == excludeId { return false }
            let p = OrganizationSkill.normalizedPair(name: $0.name, trade: $0.trade)
            return p.0 == nk && p.1 == tk
        }) {
            errorMessage = "This skill already exists for that trade."
            return
        }

        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            if let skill = editingSkill {
                let ok = await operativeStore.updateOrganizationSkill(
                    id: skill.id,
                    name: trimmedSkill,
                    trade: trimmedTrade
                )
                isSaving = false
                if ok {
                    dismiss()
                } else {
                    errorMessage = "Could not save this skill. Check for duplicates."
                }
            } else {
                await operativeStore.addOrganizationSkill(name: trimmedSkill, trade: trimmedTrade)
                isSaving = false
                dismiss()
            }
        }
    }
}

#Preview {
    SkillsManagementView()
        .environmentObject(OperativeStore())
}
