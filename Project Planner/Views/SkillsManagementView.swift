import SwiftUI

struct SkillsManagementView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var newSkill = ""
    @State private var showingAddSkill = false
    
    var body: some View {
        NavigationView {
            VStack {
                if operativeStore.skills.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Skills Added Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Add skills that your operatives can have. These will appear as options when creating or editing operatives.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("Add Your First Skill") {
                            showingAddSkill = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(operativeStore.skills.sorted(), id: \.self) { skill in
                            HStack {
                                Image(systemName: "wrench.fill")
                                    .foregroundColor(.blue)
                                Text(skill)
                                    .font(.body)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: deleteSkill)
                    }
                    .listStyle(PlainListStyle())
                }
                
                Spacer()
            }
            .navigationTitle("Skills Management")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.blue)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add Skill") {
                        showingAddSkill = true
                    }
                }
            }
            .sheet(isPresented: $showingAddSkill) {
                AddSkillView()
                    .environmentObject(operativeStore)
            }
        }
    }
    
    private func deleteSkill(at offsets: IndexSet) {
        let skillsArray = operativeStore.skills.sorted()
        for index in offsets {
            let skillToDelete = skillsArray[index]
            Task {
                await operativeStore.removeSkill(skillToDelete)
            }
        }
    }
}

struct AddSkillView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var skillName = ""
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Add New Skill")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Enter the name of the skill you want to add for your operatives.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Skill Name")
                        .font(.headline)
                    
                    TextField("e.g., Plumbing, Electrical, Carpentry", text: $skillName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                Button("Create New Skill") {
                    addSkill()
                }
                .buttonStyle(.borderedProminent)
                .disabled(skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func addSkill() {
        let trimmedSkill = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedSkill.isEmpty else {
            errorMessage = "Skill name cannot be empty"
            return
        }
        
        guard !operativeStore.skills.contains(trimmedSkill) else {
            errorMessage = "This skill already exists"
            return
        }
        
        Task {
            await operativeStore.addSkill(trimmedSkill)
            await MainActor.run {
                dismiss()
            }
        }
    }
}

#Preview {
    SkillsManagementView()
        .environmentObject(OperativeStore())
}











