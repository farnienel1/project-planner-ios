//
//  WorkingAuthView.swift
//  Project Planner
//
//  Created by Farnie Nel on 29/09/2025.
//

import SwiftUI

struct WorkingAuthView: View {
    @State private var isAuthenticated = false
    @State private var currentUser: String?
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 30) {
            if isAuthenticated {
                // Main app content - simplified version
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("Successfully Signed In!")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("User: \(currentUser ?? "Unknown")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 16) {
                        Text("Welcome to Project Planner")
                            .font(.headline)
                        
                        Text("Your projects and tasks will appear here")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    
                    Button("Sign Out") {
                        isAuthenticated = false
                        currentUser = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding()
            } else {
                // Login screen
                VStack(spacing: 30) {
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
                    }
                    
                    // Login form
                    VStack(spacing: 20) {
                        TextField("Email", text: .constant("farnie@raccordmep.co.uk"))
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(true)
                        
                        SecureField("Password", text: .constant("RaccordPlanner"))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(true)
                        
                        Button {
                            signInDemo()
                        } label: {
                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                    Text("Signing In...")
                                }
                            } else {
                                Text("Sign In to Demo")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isLoading)
                        
                        Text("Demo Account Ready")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    Text("One-time purchase: £4.99")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }
    
    private func signInDemo() {
        isLoading = true
        
        // Simulate authentication
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isLoading = false
            self.currentUser = "farnie@raccordmep.co.uk"
            self.isAuthenticated = true
        }
    }
}

#Preview {
    WorkingAuthView()
}
