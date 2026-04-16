//
//  TestAuthView.swift
//  Project Planner
//
//  Created by Farnie Nel on 29/09/2025.
//

import SwiftUI

struct TestAuthView: View {
    // @EnvironmentObject var authManager: SimpleAuthManager  // Commented out - not used
    @State private var debugInfo = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Authentication Debug")
                .font(.title)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Current Status:")
                Text("• isAuthenticated: N/A (authManager commented out)")
                Text("• currentUser: N/A (authManager commented out)")
                Text("• isLoading: N/A (authManager commented out)")
                Text("• errorMessage: N/A (authManager commented out)")
                Text("• organization: N/A (authManager commented out)")
            }
            .font(.caption)
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            Button("Test Demo Sign In") {
                debugInfo = "Test view - authManager commented out"
                // authManager.signIn(email: "farnie@raccordmep.co.uk", password: "RaccordPlanner")
            }
            .buttonStyle(PrimaryButtonStyle())
            
            Button("Sign Out") {
                debugInfo = "Test view - authManager commented out"
                // authManager.signOut()
            }
            .buttonStyle(SecondaryButtonStyle())
            
            if !debugInfo.isEmpty {
                Text(debugInfo)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding()
            }
            
            Spacer()
        }
        .padding()
    }
}

#Preview {
    TestAuthView()
        .environmentObject(SimpleAuthManager())
}
