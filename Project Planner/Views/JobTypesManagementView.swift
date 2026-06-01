import SwiftUI

struct JobTypesManagementView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddJobType = false
    
    var body: some View {
        NavigationView {
            VStack {
                if projectStore.jobTypes.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Job Types Added Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Add job types that you can assign to your projects. These will appear as options when creating or editing projects.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Text("Recommended: Create job types like 'CAT A', 'CAT B', 'Small Works', 'Maintenance', or any custom types you use.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.top, 4)
                        
                        Button("Add Your First Job Type") {
                            showingAddJobType = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(projectStore.jobTypes.sorted(), id: \.self) { jobType in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.purple)
                                Text(jobType)
                                    .font(.body)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: deleteJobType)
                    }
                    .listStyle(PlainListStyle())
                }
                
                Spacer()
            }
            .navigationTitle("Job Types Management")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.blue)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add Job Type") {
                        showingAddJobType = true
                    }
                }
            }
            .sheet(isPresented: $showingAddJobType) {
                AddJobTypeView()
                    .environmentObject(projectStore)
            }
        }
    }
    
    private func deleteJobType(at offsets: IndexSet) {
        let jobTypesArray = projectStore.jobTypes.sorted()
        for index in offsets {
            let jobTypeToDelete = jobTypesArray[index]
            projectStore.removeJobType(jobTypeToDelete)
        }
    }
}

struct AddJobTypeView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var jobTypeName = ""
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Add New Job Type")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Enter the name of the job type you want to add for your projects.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job Type Name")
                        .font(.headline)
                    
                    TextField("e.g., Renovation, New Build, Repair", text: $jobTypeName)
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
                
                Button("Create New Job Type") {
                    addJobType()
                }
                .buttonStyle(.borderedProminent)
                .disabled(jobTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    
    private func addJobType() {
        let trimmedJobType = jobTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedJobType.isEmpty else {
            errorMessage = "Job type name cannot be empty"
            return
        }
        
        guard !projectStore.jobTypes.contains(trimmedJobType) else {
            errorMessage = "This job type already exists"
            return
        }
        
        projectStore.addJobType(trimmedJobType)
        dismiss()
    }
}

#Preview {
    JobTypesManagementView()
        .environmentObject(ProjectStore())
}

