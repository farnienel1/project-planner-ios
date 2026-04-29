import SwiftUI

struct SimpleLoginView: View {
    @StateObject private var authManager = SimpleAuthManager()
    @State private var email = "farnie@raccordmep.co.uk"
    @State private var password = "Raccord50!"
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "building.2.crop.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.theme.primary)
                    
                    Text("Project Planner")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.theme.primary)
                    
                    Text("Manage your projects and team efficiently")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Login Form
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign In")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                        
                        Text("Enter your credentials to continue")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 16) {
                        TextField("Email", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                        
                        CustomSecureField(title: "Password", text: $password)
                    }
                    
                    if let errorMessage = authManager.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    
                    Button("Sign In") {
                        print("🔐 SimpleLoginView: Sign In button tapped")
                        print("🔐 SimpleLoginView: Email: \(email), Password: \(password)")
                        authManager.signIn(email: email, password: password)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(authManager.isLoading || email.isEmpty || password.isEmpty)
                    
                    if authManager.isLoading {
                        ProgressView("Signing in...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Footer
                VStack(spacing: 16) {
                    Text("£4.99 one-time purchase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
        }
        .environmentObject(authManager)
    }
}

#Preview {
    SimpleLoginView()
}
