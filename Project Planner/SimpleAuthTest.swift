//
//  SimpleAuthTest.swift
//  Project Planner
//
//  Created by Farnie Nel on 29/09/2025.
//

import SwiftUI

struct SimpleAuthTest: View {
    @State private var isAuthenticated = false
    @State private var currentUser: String?
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 30) {
            if isAuthenticated {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("Successfully Authenticated!")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("User: \(currentUser ?? "Unknown")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("Sign Out") {
                        signOut()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("Authentication Test")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Button("Sign In to Demo") {
                        signInDemo()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isLoading)
                    
                    if isLoading {
                        ProgressView("Signing in...")
                            .padding()
                    }
                }
            }
        }
        .padding()
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
    
    private func signOut() {
        currentUser = nil
        isAuthenticated = false
    }
}

#Preview {
    SimpleAuthTest()
}
