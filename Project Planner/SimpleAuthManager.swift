import Foundation
import Combine

// MARK: - Notification Names Extension

extension Notification.Name {
    static let userDidSignIn = Notification.Name("userDidSignIn")
    static let userDidSignOut = Notification.Name("userDidSignOut")
    static let organizationDidLoad = Notification.Name("organizationDidLoad")
    static let syncOfflineChanges = Notification.Name("syncOfflineChanges")
}

class SimpleAuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    init() {
        print("🔐 SimpleAuthManager initialized")
        print("🔐 SimpleAuthManager: isAuthenticated = \(isAuthenticated)")
        // Check if user was previously logged in
        if UserDefaults.standard.bool(forKey: "isLoggedIn") {
            isAuthenticated = true
            currentUser = UserDefaults.standard.string(forKey: "currentUser") ?? "Raccord MEP"
            print("🔐 Found existing login: \(currentUser)")
        } else {
            print("🔐 No existing login found")
        }
        print("🔐 SimpleAuthManager: Final isAuthenticated = \(isAuthenticated)")
    }
    
    func signIn(email: String, password: String) {
        print("🔐 SimpleAuthManager: Attempting sign in with: \(email)")
        isLoading = true
        errorMessage = nil
        
        // Simple validation
        if email.isEmpty || password.isEmpty {
            print("🔐 SimpleAuthManager: Empty email or password")
            errorMessage = "Please enter both email and password"
            isLoading = false
            return
        }
        
        print("🔐 SimpleAuthManager: Starting 1 second delay...")
        
        // Simulate network delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("🔐 SimpleAuthManager: Delay completed, checking email...")
            // For now, accept any email/password combination
            if email.contains("@") {
                print("🔐 SimpleAuthManager: Email valid, signing in...")
                self.isAuthenticated = true
                self.currentUser = email
                self.isLoading = false
                
                // Save login state
                UserDefaults.standard.set(true, forKey: "isLoggedIn")
                UserDefaults.standard.set(email, forKey: "currentUser")
                
                print("✅ SimpleAuthManager: Sign in successful: \(email)")
                print("✅ SimpleAuthManager: isAuthenticated = \(self.isAuthenticated)")
            } else {
                print("🔐 SimpleAuthManager: Invalid email format")
                self.errorMessage = "Please enter a valid email address"
                self.isLoading = false
            }
        }
    }
    
    func signOut() {
        print("🔐 Signing out")
        isAuthenticated = false
        currentUser = ""
        
        // Clear saved login state
        UserDefaults.standard.set(false, forKey: "isLoggedIn")
        UserDefaults.standard.removeObject(forKey: "currentUser")
        
        print("✅ Sign out successful")
    }
}
