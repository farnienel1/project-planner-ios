import SwiftUI

struct JobTypesManagementView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddJobType = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                jobTypesNavyHeader

                VStack(spacing: 0) {
                    if projectStore.jobTypes.isEmpty {
                        VStack(spacing: 16) {
                            PPIconTile(symbol: "folder.fill", family: .people, size: PPMetrics.quickActionIcon, lifted: true)

                            Text("No Job Types Added Yet")
                                .font(.system(.title2, design: .rounded))
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)

                            Text("Add job types that you can assign to your projects. These will appear as options when creating or editing projects.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Text("Recommended: Create job types like 'CAT A', 'CAT B', 'Small Works', 'Maintenance', or any custom types you use.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button("Add Your First Job Type") {
                                showingAddJobType = true
                            }
                            .accessibilityIdentifier("jobTypesManagement.addYourFirstJobType")
                            .ppProminentCapsule()
                            .padding(.top, 4)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        .padding(.top, 20)

                        Spacer(minLength: 0)
                    } else {
                        PPGroupLabel(text: "Job types")
                        List {
                            ForEach(projectStore.jobTypes.sorted(), id: \.self) { jobType in
                                HStack(spacing: 13) {
                                    PPIconTile(symbol: "folder.fill", family: .people, size: PPMetrics.menuIcon)
                                    Text(jobType)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .listRowBackground(PPColor.card)
                            }
                            .onDelete(perform: deleteJobType)
                        }
                        .listStyle(PlainListStyle())
                        .scrollContentBackground(.hidden)
                        .background(PPColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        .padding(.bottom, 16)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .ppContentSheet()
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Job Types Management")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                    .accessibilityIdentifier("jobTypesManagement.close")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add Job Type") {
                        showingAddJobType = true
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("jobTypesManagement.addJobType")
                }
            }
            .sheet(isPresented: $showingAddJobType) {
                AddJobTypeView()
                    .environmentObject(projectStore)
            }
        }
    }

    /// Home-style navy header with the number of job types already loaded.
    private var jobTypesNavyHeader: some View {
        let count = projectStore.jobTypes.count
        return VStack(alignment: .leading, spacing: 8) {
            PPOverviewTitle(
                eyebrow: "Your job types",
                count: "\(count)",
                countLabel: count == 1 ? "job type" : "job types"
            )
            Text("Options shown when you create or edit a project.")
                .font(.footnote)
                .foregroundStyle(PPColor.onNavySecondary)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
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
                        .accessibilityIdentifier("addJobType.eGRenovationNewBuildRepair")
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
                .accessibilityIdentifier("addJobType.createNewJobType")
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
                        .accessibilityIdentifier("addJobType.done")
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

