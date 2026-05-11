import SwiftUI
import PhotosUI
import MessageUI
import FirebaseAuth

struct OrganizationSetupView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var organizationName = ""
    @State private var hasOfficeAddress = true
    @State private var officeAddressLine1 = ""
    @State private var officeCity = ""
    @State private var officePostcode = ""
    @State private var countryCode = "GB"
    @State private var adminEmail = ""
    @State private var adminFirstName = ""
    @State private var adminSurname = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var selectedLogo: PhotosPickerItem?
    @State private var logoImage: UIImage?
    @State private var currentStep = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingOnboarding = false
    @State private var verificationCode = ""
    @State private var isEmailVerified = false
    @State private var showingEmailVerification = false
    @StateObject private var emailService = EmailVerificationService()
    
    private let steps = [
        "Organisation Details",
        "Office Location",
        "Admin Account",
        "Email Verification",
        "Upload Logo",
        "Complete Setup"
    ]
    
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress indicator
                VStack(spacing: 16) {
                    HStack {
                        ForEach(0..<steps.count, id: \.self) { index in
                            Circle()
                                .fill(index <= currentStep ? Color.theme.primary : Color.gray.opacity(0.3))
                                .frame(width: 12, height: 12)
                            
                            if index < steps.count - 1 {
                                Rectangle()
                                    .fill(index < currentStep ? Color.theme.primary : Color.gray.opacity(0.3))
                                    .frame(height: 2)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    Text(steps[currentStep])
                        .font(.headline)
                        .foregroundStyle(Color.theme.primary)
                }
                .padding(.vertical, 20)
                
                Divider()
                
                // Content
                ScrollView {
                    VStack(spacing: 24) {
                        switch currentStep {
                        case 0:
                            organizationDetailsStep
                        case 1:
                            officeLocationStep
                        case 2:
                            adminAccountStep
                        case 3:
                            emailVerificationStep
                        case 4:
                            logoUploadStep
                        case 5:
                            completeSetupStep
                        default:
                            EmptyView()
                        }
                    }
                    .padding()
                }
                
                Spacer()
                
                // Navigation buttons
                HStack(spacing: 16) {
                    if currentStep > 0 {
                        Button("Back") {
                            withAnimation {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    
                    Spacer()
                    
                    Button(currentStep == steps.count - 1 ? "Complete Setup" : "Next") {
                        if currentStep == steps.count - 1 {
                            completeSetup()
                        } else {
                            withAnimation {
                                currentStep += 1
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canProceed)
                }
                .padding()
            }
            .navigationTitle("Setup Organisation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: selectedLogo) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    logoImage = image
                }
            }
        }
            // TODO: Fix OnboardingTutorialView compilation errors
            // .sheet(isPresented: $showingOnboarding) {
            //     OnboardingTutorialView()
            //         .environmentObject(authManager)
            //         .environmentObject(AppState())
            // }
            .sheet(isPresented: $emailService.isShowingMailView) {
                MailComposeView(
                    toRecipients: [adminEmail],
                    subject: "Verify Your Project Planner Account",
                    messageBody: createVerificationEmailBody()
                )
            }
    }
    
    // MARK: - Step Views
    
    private var organizationDetailsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let's set up your organisation")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Enter your organisation details to get started")
                .foregroundStyle(.secondary)
            
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Organisation Name")
                        .font(.headline)
                    TextField("Enter organisation name", text: $organizationName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
        }
    }

    private var officeLocationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set your office map location")
                .font(.title2)
                .fontWeight(.bold)

            Text("Admins and super admins will open the map centered on this location.")
                .foregroundStyle(.secondary)

            Toggle("My organisation has an office address", isOn: $hasOfficeAddress)

            VStack(alignment: .leading, spacing: 8) {
                Text("Country")
                    .font(.headline)
                Picker("Country", selection: $countryCode) {
                    ForEach(CountryCapitalDirectory.supported, id: \.code) { country in
                        Text(country.name).tag(country.code)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }

            if hasOfficeAddress {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Office Address Line 1")
                        .font(.headline)
                    TextField("Enter office address", text: $officeAddressLine1)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("City / Town")
                        .font(.headline)
                    TextField("Enter city or town", text: $officeCity)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Postcode (optional)")
                        .font(.headline)
                    TextField("Enter postcode", text: $officePostcode)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            } else {
                Text("No office address set: map defaults to \(CountryCapitalDirectory.fallbackDescription(for: countryCode)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var adminAccountStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Create Admin Account")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Set up your admin account to manage the organisation")
                    .foregroundStyle(.secondary)
                
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("First Name")
                            .font(.headline)
                        TextField("Enter first name", text: $adminFirstName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.words)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Surname")
                            .font(.headline)
                        TextField("Enter surname", text: $adminSurname)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.words)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Admin Email")
                            .font(.headline)
                        TextField("Enter admin email", text: $adminEmail)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: adminEmail) { _, newValue in
                                // Auto-send verification email when email changes
                                if isValidEmail(newValue) && !newValue.isEmpty {
                                    // Reset verification state
                                    isEmailVerified = false
                                    verificationCode = ""
                                    // Send new verification email
                                    emailService.sendVerificationEmail(to: newValue, forceResend: true)
                                }
                            }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.headline)
                        CustomSecureField(title: "Enter password", text: $password)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirm Password")
                            .font(.headline)
                        CustomSecureField(title: "Confirm password", text: $confirmPassword)
                    }
                }
                
                // Password Requirements
                VStack(alignment: .leading, spacing: 12) {
                    Text("Password Requirements:")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: password.count >= 8 ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(password.count >= 8 ? .green : .gray)
                            Text("At least 8 characters")
                                .font(.caption)
                        }
                        
                        HStack {
                            Image(systemName: password.contains(where: { $0.isUppercase }) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(password.contains(where: { $0.isUppercase }) ? .green : .gray)
                            Text("One uppercase letter")
                                .font(.caption)
                        }
                        
                        HStack {
                            Image(systemName: password.contains(where: { $0.isLowercase }) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(password.contains(where: { $0.isLowercase }) ? .green : .gray)
                            Text("One lowercase letter")
                                .font(.caption)
                        }
                        
                        HStack {
                            Image(systemName: password.contains(where: { $0.isNumber }) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(password.contains(where: { $0.isNumber }) ? .green : .gray)
                            Text("One number")
                                .font(.caption)
                        }
                        
                        HStack {
                            Image(systemName: password == confirmPassword && !password.isEmpty ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(password == confirmPassword && !password.isEmpty ? .green : .gray)
                            Text("Passwords match")
                                .font(.caption)
                        }
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                )
                
            }
            .padding()
        }
    }
    
    private var emailVerificationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Verify Your Email")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("You will receive an email to verify your account at \(adminEmail). Please check your inbox and enter the verification code below.")
                .foregroundStyle(.secondary)
            
            // Spam folder note
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Check your spam/junk folder for verification emails")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
            
            VStack(spacing: 16) {
                if !isEmailVerified {
                    VStack(spacing: 12) {
                        Image(systemName: "envelope")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        
                        Text("Verification Email Sent")
                            .font(.headline)
                        
                        Text("Check your email and enter the verification code below.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.1))
                    )
                    
                    // Verification Code Input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Verification Code")
                            .font(.headline)
                        TextField("Enter 6-digit code", text: $verificationCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.1))
                    )
                    
                    Button("Verify Code") {
                        verifyEmailCode()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(verificationCode.count != 6)
                    
                    Button("Resend Verification Email") {
                        sendVerificationEmail()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
                    
                    // Email status feedback
                    if emailService.isEmailSent {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Email sent successfully!")
                                .foregroundColor(.green)
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    if let errorMessage = emailService.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .foregroundColor(.red)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        
                        Text("Email Verified!")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        Text("Your email has been successfully verified. You can now continue with the setup.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green.opacity(0.1))
                    )
                }
            }
        }
        .padding()
        .onAppear {
            if verificationCode.isEmpty {
                sendVerificationEmail()
            }
        }
    }
    
    private var logoUploadStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload Organisation Logo")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Add a logo that will appear on your home screen")
                .foregroundStyle(.secondary)
            
            VStack(spacing: 20) {
                // Logo preview
                VStack(spacing: 12) {
                    if let logoImage = logoImage {
                        Image(uiImage: logoImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.theme.primary, lineWidth: 2)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 120, height: 120)
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                    Text("No Logo")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            )
                    }
                }
                
                PhotosPicker(selection: $selectedLogo, matching: .images) {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text(logoImage == nil ? "Select Logo" : "Change Logo")
                    }
                    .foregroundStyle(Color.theme.primary)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.theme.primary, lineWidth: 1)
                    )
                }
                
                if logoImage != nil {
                    Button("Remove Logo") {
                        logoImage = nil
                        selectedLogo = nil
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }
    
    private var completeSetupStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to Complete Setup")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Review your organisation details before completing setup")
                .foregroundStyle(.secondary)
            
            VStack(spacing: 16) {
                // Organisation details summary
                VStack(alignment: .leading, spacing: 12) {
                    Text("Organisation Details")
                        .font(.headline)
                    
                    HStack {
                        Text("Name:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(organizationName)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Admin Name:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(adminFirstName) \(adminSurname)")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Admin Email:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(adminEmail)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Logo:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(logoImage != nil ? "Uploaded" : "Not provided")
                            .fontWeight(.medium)
                            .foregroundStyle(logoImage != nil ? .green : .orange)
                    }

                    HStack(alignment: .top) {
                        Text("Map default:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(setupLocationSummary)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                )
                
                Text("After setup, you'll be guided through creating your first client, manager, operative, and project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var setupLocationSummary: String {
        if hasOfficeAddress {
            return "\(officeAddressLine1), \(officeCity)\(officePostcode.isEmpty ? "" : ", \(officePostcode)")"
        }
        return CountryCapitalDirectory.fallbackDescription(for: countryCode)
    }
    
    // MARK: - Computed Properties
    
    private var canProceed: Bool {
        switch currentStep {
        case 0:
            return !organizationName.isEmpty
        case 1:
            if hasOfficeAddress {
                return !officeAddressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !officeCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !countryCode.isEmpty
            }
            return !countryCode.isEmpty
        case 2:
            return !adminFirstName.isEmpty &&
                   !adminSurname.isEmpty &&
                   !adminEmail.isEmpty && 
                   isValidEmail(adminEmail) &&
                   isValidPassword(password) && 
                   password == confirmPassword
        case 3:
            return isEmailVerified
        case 4:
            return true // Logo is optional
        case 5:
            return true
        default:
            return false
        }
    }
    
    private func isValidPassword(_ password: String) -> Bool {
        return password.count >= 8 &&
               password.contains(where: { $0.isUppercase }) &&
               password.contains(where: { $0.isLowercase }) &&
               password.contains(where: { $0.isNumber })
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    private func sendVerificationEmail() {
        emailService.sendVerificationEmail(to: adminEmail, forceResend: true)
    }
    
    private func createVerificationEmailBody() -> String {
        return """
        <html>
        <body>
        <h2>Welcome to Project Planner!</h2>
        <p>Thank you for creating your organisation account. To complete your registration, please click the verification link below:</p>
        
        <div style="text-align: center; margin: 30px 0;">
            <a href="https://projectplanner.us/verify?code=\(verificationCode)&email=\(adminEmail)" 
               style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold;">
                Verify Account
            </a>
        </div>
        
        <p>If the button doesn't work, copy and paste this link into your browser:</p>
        <p style="word-break: break-all; color: #666;">
            https://projectplanner.us/verify?code=\(verificationCode)&email=\(adminEmail)
        </p>
        
        <p>This verification link will expire in 24 hours.</p>
        
        <hr>
        <p style="color: #666; font-size: 12px;">
            If you didn't create this account, please ignore this email.<br>
            This email was sent by Project Planner - Your Project Management Solution
        </p>
        </body>
        </html>
        """
    }
    
    // MARK: - Actions
    
    private func verifyEmailCode() {
        print("🔐 Verifying code: \(verificationCode) for email: \(adminEmail)")
        
        // Validate code format first
        guard verificationCode.count == 6 && verificationCode.allSatisfy({ $0.isNumber }) else {
            errorMessage = "Please enter a valid 6-digit verification code"
            print("❌ Invalid code format: \(verificationCode)")
            return
        }
        
        // Verify code with the verification manager
        let result = emailService.verifyCode(verificationCode, for: adminEmail)
        
        print("🔐 Verification result: \(result)")
        
        if result.isSuccess {
            isEmailVerified = true
            errorMessage = nil
            print("✅ Email verification successful!")
        } else {
            errorMessage = result.message
            print("❌ Email verification failed: \(result.message)")
        }
    }
    
    private func completeSetup() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // Create Firebase user account
                let authResult = try await Auth.auth().createUser(withEmail: adminEmail, password: password)
                let userId = authResult.user.uid
                
                // Create organization
                let organizationId = UUID().uuidString
                try await firebaseBackend.createOrganization(
                    id: organizationId,
                    name: organizationName,
                    adminUserId: userId,
                    officeAddressLine1: hasOfficeAddress ? officeAddressLine1.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    officeCity: hasOfficeAddress ? officeCity.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    officePostcode: hasOfficeAddress ? officePostcode.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    countryCode: countryCode
                )
                
                // Create admin user document
                let adminUser = AppUser(
                    id: userId,
                    email: adminEmail,
                    organizationId: organizationId,
                    role: .admin,
                    createdAt: Date(),
                    firstName: adminFirstName,
                    surname: adminSurname,
                    isActive: true,
                    passwordSet: true
                )
                
                // Save admin user to Firebase
                try await firebaseBackend.saveUser(adminUser)
                
                // Save logo image to organization if provided
                if let logoImage = logoImage,
                   let logoData = logoImage.jpegData(compressionQuality: 0.8) {
                    // TODO: Save logo data to organization in Firebase
                    print("🔥 Logo data ready for saving: \(logoData.count) bytes")
                }
                
                await MainActor.run {
                    isLoading = false
                    dismiss()
                    showingOnboarding = true
                }
                
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Failed to create organization: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func extractFirstName(from email: String) -> String {
        let components = email.components(separatedBy: "@")
        let namePart = components.first ?? ""
        let nameComponents = namePart.components(separatedBy: ".")
        return nameComponents.first?.capitalized ?? "Admin"
    }
    
    private func extractSurname(from email: String) -> String {
        let components = email.components(separatedBy: "@")
        let namePart = components.first ?? ""
        let nameComponents = namePart.components(separatedBy: ".")
        if nameComponents.count > 1 {
            return nameComponents[1].capitalized
        }
        return "User"
    }
}

struct MailComposeView: UIViewControllerRepresentable {
    let toRecipients: [String]
    let subject: String
    let messageBody: String
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = context.coordinator
        mailComposer.setToRecipients(toRecipients)
        mailComposer.setSubject(subject)
        mailComposer.setMessageBody(messageBody, isHTML: true)
        return mailComposer
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
        }
    }
}

#Preview {
    OrganizationSetupView()
        .environmentObject(SimpleAuthManager())
}
