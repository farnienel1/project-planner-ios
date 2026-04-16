import SwiftUI
import Combine

struct OrganisationSetupFlow: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    
    @State private var currentStep = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var policyAccepted = false
    @State private var showingPrivacyPolicy = true
    
    // Manager form fields
    @State private var managerFirstName = ""
    @State private var managerLastName = ""
    @State private var managerEmail = ""
    @State private var managerMobileNumber = ""
    @State private var managerDepartment = ""
    @State private var managerNotes = ""
    
    // Client form fields
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var clientPhone = ""
    @State private var clientAddress = ""
    
    // Operative form fields
    @State private var operativeFirstName = ""
    @State private var operativeSurname = ""
    @State private var operativeEmail = ""
    @State private var operativePhone = ""
    @State private var operativeDayRate = ""
    
    // Project form fields
    @State private var projectJobNumber = ""
    @State private var projectSiteName = ""
    @State private var projectAddressLine1 = ""
    @State private var projectAddressLine2 = ""
    @State private var projectTownCity = ""
    @State private var projectPostcode = ""
    @State private var projectStartDate = Date()
    @State private var projectEndDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var projectWorksType = "Small Works"
    @State private var projectDescription = ""
    
    private let steps = [
        "Welcome",
        "Create Manager",
        "Create Client", 
        "Create Operative",
        "Create Project",
        "Privacy Policy",
        "Complete"
    ]
    
    var body: some View {
        NavigationView {
            VStack {
                // Progress indicator
                HStack {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle()
                            .fill(index <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 12, height: 12)
                        
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(index < currentStep ? Color.blue : Color.gray.opacity(0.3))
                                .frame(height: 2)
                        }
                    }
                }
                .padding()
                
                Text("Step \(currentStep + 1) of \(steps.count): \(steps[currentStep])")
                    .font(.headline)
                    .padding(.bottom)
                
                TabView(selection: $currentStep) {
                    // Step 1: Welcome
                    welcomeStep
                        .tag(0)
                    
                    // Step 2: Create Manager
                    managerStep
                        .tag(1)
                    
                    // Step 3: Create Client
                    clientStep
                        .tag(2)
                    
                    // Step 4: Create Operative
                    operativeStep
                        .tag(3)
                    
                    // Step 5: Create Project
                    projectStep
                        .tag(4)
                    
                    // Step 6: Privacy Policy
                    privacyPolicyStep
                        .tag(5)
                    
                    // Step 7: Complete
                    completeStep
                        .tag(6)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                
                // Navigation buttons
                HStack {
                    if currentStep > 0 {
                        Button("Previous") {
                            withAnimation {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Spacer()
                    
                    if currentStep < steps.count - 2 {
                        // Show "Next" for all steps except the last two (privacy policy and complete)
                        if currentStep == 4 {
                            // Show "Next" on project step to go to privacy policy
                            Button("Next") {
                                withAnimation {
                                    currentStep += 1
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isCurrentStepValid)
                        } else if currentStep == 5 {
                            // Show "I Accept" on privacy policy step
                            Button("I Accept") {
                                policyAccepted = true
                                createInitialData()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!policyAccepted || isLoading)
                        } else {
                            // Show "Next" for other steps
                            Button("Next") {
                                withAnimation {
                                    currentStep += 1
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isCurrentStepValid)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Organisation Setup")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
        }
    }
    
    // MARK: - Step Views
    
    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            Text("Welcome to Project Planner!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text("Let's set up your organisation with some initial data to get you started.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundColor(.blue)
                    Text("Create your first manager")
                }
                
                HStack {
                    Image(systemName: "person.2.fill")
                        .foregroundColor(.green)
                    Text("Add your first client")
                }
                
                HStack {
                    Image(systemName: "wrench.fill")
                        .foregroundColor(.orange)
                    Text("Set up your first operative")
                }
                
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.purple)
                    Text("Create your first project")
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
    
    private var managerStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Create Your First Manager")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Managers oversee projects and coordinate with teams.")
                    .foregroundColor(.secondary)
                
                VStack(spacing: 15) {
                    TextField("First Name *", text: $managerFirstName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Last Name *", text: $managerLastName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Email *", text: $managerEmail)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    
                    TextField("Mobile Number *", text: $managerMobileNumber)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.phonePad)
                    
                    TextField("Department (Optional)", text: $managerDepartment)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Notes (Optional)", text: $managerNotes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }
                .padding(.horizontal)
            }
            .padding()
        }
    }
    
    private var clientStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Add Your First Client")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Clients are the companies or individuals you work for.")
                    .foregroundColor(.secondary)
                
                VStack(spacing: 15) {
                    TextField("Company/Client Name *", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Email (Optional)", text: $clientEmail)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    
                    TextField("Phone (Optional)", text: $clientPhone)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.phonePad)
                    
                    TextField("Address (Optional)", text: $clientAddress)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
            }
            .padding()
        }
    }
    
    private var operativeStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Set Up Your First Operative")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Operatives are the workers who will be assigned to projects.")
                    .foregroundColor(.secondary)
                
                VStack(spacing: 15) {
                    TextField("First Name *", text: $operativeFirstName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Surname *", text: $operativeSurname)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Email *", text: $operativeEmail)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    
                    TextField("Phone *", text: $operativePhone)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.phonePad)
                    
                    HStack {
                        Text("Skills (Setup Later)")
                            .foregroundColor(.black)
                            .font(.body)
                            .fontWeight(.bold)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    
                    TextField("Day Rate (Optional)", text: $operativeDayRate)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
                .padding(.horizontal)
            }
            .padding()
        }
    }
    
    private var projectStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Create Your First Project")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Projects are the main work items you'll be managing.")
                    .foregroundColor(.secondary)
                
                VStack(spacing: 15) {
                    TextField("Job Number *", text: $projectJobNumber)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Site Name *", text: $projectSiteName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Address Line 1 *", text: $projectAddressLine1)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Address Line 2 (Optional)", text: $projectAddressLine2)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Town/City *", text: $projectTownCity)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Postcode *", text: $projectPostcode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                    
                    DatePicker("Start Date", selection: $projectStartDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    
                    DatePicker("End Date", selection: $projectEndDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    
                    HStack {
                        Text("Job Type (Setup Later)")
                            .foregroundColor(.black)
                            .font(.body)
                            .fontWeight(.bold)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    
                    TextField("Description (Optional)", text: $projectDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                    }
                    .padding(.horizontal)
            }
            .padding()
        }
    }
    
    private var privacyPolicyStep: some View {
        PrivacyPolicyView(isAcceptanceRequired: $showingPrivacyPolicy) {
            policyAccepted = true
            showingPrivacyPolicy = false
        }
        .onAppear {
            showingPrivacyPolicy = true
        }
    }
    
    private var completeStep: some View {
        VStack(spacing: 30) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
                .scaleEffect(1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: UUID())
            
            Text("Welcome to Project Planner!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.blue)
            
            Text("Your organisation is now ready to use Project Planner. You can start creating more managers, clients, operatives, and projects as needed.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            Button("Get Started") {
                firebaseBackend.completeSetupFlow()
            }
            .buttonStyle(.borderedProminent)
            .font(.headline)
        }
        .padding()
        .onAppear {
            // Trigger animation when the view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Animation is handled by the scaleEffect modifier
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var isFormValid: Bool {
        !managerFirstName.isEmpty &&
        !managerLastName.isEmpty &&
        !managerEmail.isEmpty &&
        !managerMobileNumber.isEmpty &&
        !clientName.isEmpty &&
        !operativeFirstName.isEmpty &&
        !operativeSurname.isEmpty &&
        !operativeEmail.isEmpty &&
        !operativePhone.isEmpty &&
        !projectJobNumber.isEmpty &&
        !projectSiteName.isEmpty &&
        !projectAddressLine1.isEmpty &&
        !projectTownCity.isEmpty &&
        !projectPostcode.isEmpty
    }
    
    private var isCurrentStepValid: Bool {
        switch currentStep {
        case 0: // Welcome step - always valid
            return true
        case 1: // Manager step - only mandatory fields (excluding Department and Notes which are optional)
            return !managerFirstName.isEmpty &&
                   !managerLastName.isEmpty &&
                   !managerEmail.isEmpty &&
                   !managerMobileNumber.isEmpty
        case 2: // Client step - only mandatory fields (excluding Email, Phone, Address which are optional)
            return !clientName.isEmpty
        case 3: // Operative step - only mandatory fields (excluding Day Rate which is optional)
            return !operativeFirstName.isEmpty &&
                   !operativeSurname.isEmpty &&
                   !operativeEmail.isEmpty &&
                   !operativePhone.isEmpty
        case 4: // Project step - only mandatory fields (excluding Description which is optional)
            return !projectJobNumber.isEmpty &&
                   !projectSiteName.isEmpty &&
                   !projectAddressLine1.isEmpty &&
                   !projectTownCity.isEmpty &&
                   !projectPostcode.isEmpty
        case 5: // Privacy Policy step - must accept
            return policyAccepted
        case 6: // Complete step
            return true
        default:
            return false
        }
    }
    
    // MARK: - Methods
    
    private func createInitialData() {
        isLoading = true
        errorMessage = nil
        
        Task {
            // Create manager
            let manager = Manager(
                firstName: managerFirstName,
                lastName: managerLastName,
                email: managerEmail,
                mobileNumber: managerMobileNumber.isEmpty ? "" : managerMobileNumber,
                department: managerDepartment.isEmpty ? nil : managerDepartment,
                isActive: true,
                notes: managerNotes.isEmpty ? nil : managerNotes
            )
            await operativeStore.addManager(manager)
            
            // Create client
            let client = Client(
                name: clientName,
                email: clientEmail,
                phone: clientPhone.isEmpty ? nil : clientPhone,
                address: clientAddress.isEmpty ? nil : clientAddress
            )
            await projectStore.addClient(client)
            
            // Create operative
            let operative = Operative(
                name: "\(operativeFirstName) \(operativeSurname)",
                email: operativeEmail,
                phone: operativePhone,
                startDate: Date(),
                skills: [], // Start with empty skills set
                hourlyRate: operativeDayRate.isEmpty ? nil : Double(operativeDayRate)
            )
            await operativeStore.addOperative(operative)
            
            // Create project
            let project = Project(
                jobNumber: projectJobNumber,
                siteName: projectSiteName,
                addressLine1: projectAddressLine1,
                addressLine2: projectAddressLine2.isEmpty ? nil : projectAddressLine2,
                townCity: projectTownCity,
                postcode: projectPostcode,
                client: client,
                startDate: projectStartDate,
                endDate: projectEndDate,
                jobType: .catA, // Default to catA since we just created the project
                manager: .na, // Default to N/A since we just created the manager
                isLive: true,
                description: projectDescription.isEmpty ? nil : projectDescription
            )
            
            do {
                try await projectStore.addProject(project)
                
                // Mark policy as accepted for the current user
                if let currentUser = userStore.currentUser {
                    var updatedUser = currentUser
                    updatedUser.policyAccepted = true
                    updatedUser.policyAcceptedAt = Date()
                    do {
                        try await firebaseBackend.saveUser(updatedUser)
                        await userStore.loadCurrentUser() // Reload to get updated user
                    } catch {
                        print("🔥🔥🔥 DEBUG: Failed to save policy acceptance: \(error)")
                    }
                }
                
                await MainActor.run {
                    isLoading = false
                    withAnimation {
                        currentStep = 6 // Move to complete step
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Failed to save project: \(error.localizedDescription). Please try again."
                }
            }
        }
    }
}

#Preview {
    OrganisationSetupFlow()
        .environmentObject(FirebaseBackend())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
}
