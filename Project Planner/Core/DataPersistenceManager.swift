//
//  DataPersistenceManager.swift
//  Project Planner
//
//  Created by Assistant on 29/10/2025.
//

import Foundation
import FirebaseAuth

/// Centralized data persistence manager with retry logic and verification
@MainActor
class DataPersistenceManager {
    static let shared = DataPersistenceManager()
    
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 1.0
    
    private init() {}
    
    /// Saves data with retry logic and verification
    func saveWithRetry<T>(
        operation: @escaping () async throws -> T,
        description: String,
        onSuccess: ((T) -> Void)? = nil,
        onFailure: ((Error) -> Void)? = nil
    ) async -> Result<T, Error> {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                print("🔥🔥🔥 DEBUG: [Persistence] Attempting \(description) (attempt \(attempt)/\(maxRetries))")
                let result = try await operation()
                print("🔥🔥🔥 DEBUG: [Persistence] ✅ Successfully completed \(description)")
                onSuccess?(result)
                return .success(result)
            } catch {
                lastError = error
                print("🔥🔥🔥 DEBUG: [Persistence] ❌ Attempt \(attempt) failed for \(description): \(error.localizedDescription)")
                
                if attempt < maxRetries {
                    print("🔥🔥🔥 DEBUG: [Persistence] Retrying in \(retryDelay) seconds...")
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                }
            }
        }
        
        print("🔥🔥🔥 DEBUG: [Persistence] ❌❌❌ All retry attempts failed for \(description)")
        onFailure?(lastError ?? NSError(domain: "DataPersistence", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
        return .failure(lastError ?? NSError(domain: "DataPersistence", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
    }
    
    /// Verifies data was saved by attempting to read it back
    func verifySave<T: Equatable>(
        readOperation: @escaping () async throws -> [T],
        expectedItem: T,
        description: String
    ) async -> Bool {
        do {
            let items = try await readOperation()
            let found = items.contains { $0 == expectedItem }
            if found {
                print("🔥🔥🔥 DEBUG: [Persistence] ✅ Verified \(description) was saved")
            } else {
                print("🔥🔥🔥 DEBUG: [Persistence] ⚠️ Verification failed - \(description) not found after save")
            }
            return found
        } catch {
            print("🔥🔥🔥 DEBUG: [Persistence] ⚠️ Verification error for \(description): \(error.localizedDescription)")
            return false
        }
    }
    
    /// Waits for organization to load before proceeding with save operation
    /// This ensures all Firebase saves happen after organization is ready
    @MainActor
    func waitForOrganization(
        firebaseBackend: FirebaseBackend?,
        maxWaitSeconds: Int = 15
    ) async -> String? {
        guard let firebaseBackend = firebaseBackend else {
            print("🔥🔥🔥 DEBUG: [Persistence] ⚠️ Firebase backend not available")
            return nil
        }
        
        guard firebaseBackend.isAuthenticated else {
            print("🔥🔥🔥 DEBUG: [Persistence] ⚠️ User not authenticated")
            return nil
        }
        
        guard let userId = firebaseBackend.currentUser?.uid else {
            print("🔥🔥🔥 DEBUG: [Persistence] ⚠️ No user ID available")
            return nil
        }
        
        // If organization is already loaded, return immediately
        if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            print("🔥🔥🔥 DEBUG: [Persistence] ✅ Organization already loaded: \(organizationId)")
            return organizationId
        }
        
        // Try to actively load organization if not already loading
        print("🔥🔥🔥 DEBUG: [Persistence] 🔄 Attempting to load organization for user: \(userId)")
        await firebaseBackend.loadUserOrganization(userId: userId)
        
        // Check if organization loaded immediately after attempting load
        if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            print("🔥🔥🔥 DEBUG: [Persistence] ✅ Organization loaded immediately: \(organizationId)")
            return organizationId
        }
        
        // If still not loaded, try recovery
        if let userEmail = firebaseBackend.currentUser?.email {
            print("🔥🔥🔥 DEBUG: [Persistence] 🔧 Attempting to recover organization link...")
            let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
            if recovered {
                if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                    print("🔥🔥🔥 DEBUG: [Persistence] ✅ Organization recovered: \(organizationId)")
                    return organizationId
                }
            }
        }
        
        // Wait for organization to load (with timeout)
        print("🔥🔥🔥 DEBUG: [Persistence] ⏳ Waiting for organization to load (max \(maxWaitSeconds)s)...")
        for waitCount in 1...maxWaitSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                print("🔥🔥🔥 DEBUG: [Persistence] ✅ Organization loaded after \(waitCount) seconds: \(organizationId)")
                return organizationId
            }
            
            // Try loading again periodically
            if waitCount % 3 == 0 {
                print("🔥🔥🔥 DEBUG: [Persistence] 🔄 Retrying organization load... (\(waitCount)/\(maxWaitSeconds))")
                await firebaseBackend.loadUserOrganization(userId: userId)
            }
            
            if waitCount % 2 == 0 {
                print("🔥🔥🔥 DEBUG: [Persistence] ⏳ Still waiting for organization... (\(waitCount)/\(maxWaitSeconds))")
            }
        }
        
        print("🔥🔥🔥 DEBUG: [Persistence] ⚠️ Organization did not load within \(maxWaitSeconds) seconds")
        print("🔥🔥🔥 DEBUG: [Persistence] User authenticated: \(firebaseBackend.isAuthenticated)")
        print("🔥🔥🔥 DEBUG: [Persistence] Current organization: \(firebaseBackend.currentOrganization?.name ?? "nil")")
        return nil
    }
}

