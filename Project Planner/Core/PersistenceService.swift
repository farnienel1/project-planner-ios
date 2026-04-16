//
//  PersistenceService.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation

final class PersistenceService: @unchecked Sendable {
    private let userDefaults = UserDefaults.standard
    private let currentUserIdLock = NSLock()
    private var _currentUserId: String?
    
    // MARK: - Keys
    
    private enum Keys: @unchecked Sendable {
        static let projects = "projects"
        static let clients = "clients"
        static let operatives = "operatives"
        static let managers = "managers"
        static let bookings = "bookings"
        static let appSettings = "app_settings"
    }
    
    // MARK: - User Management
    
    func setCurrentUser(_ userId: String?) {
        currentUserIdLock.lock()
        defer { currentUserIdLock.unlock() }
        _currentUserId = userId
    }
    
    private func getUserSpecificKey(_ baseKey: String) -> String {
        // Thread-safe access to currentUserId
        let userId: String? = {
            currentUserIdLock.lock()
            defer { currentUserIdLock.unlock() }
            return _currentUserId
        }()
        
        guard let userId = userId else {
            return baseKey // Fallback to global key if no user
        }
        return "\(userId)_\(baseKey)"
    }
    
    // MARK: - Project Data
    
    func saveProjectData(projects: [Project], clients: [Client]) async throws {
        let projectsKey = getUserSpecificKey(Keys.projects)
        let clientsKey = getUserSpecificKey(Keys.clients)
        
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                do {
                    let projectsData = try JSONEncoder().encode(projects)
                    let clientsData = try JSONEncoder().encode(clients)
                    
                    // UserDefaults is thread-safe, no need for MainActor
                    userDefaults.set(projectsData, forKey: projectsKey)
                    userDefaults.set(clientsData, forKey: clientsKey)
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func loadProjectData() async throws -> (projects: [Project], clients: [Client]) {
        let projectsKey = getUserSpecificKey(Keys.projects)
        let clientsKey = getUserSpecificKey(Keys.clients)
        // Capture key strings before entering detached task
        let legacyProjectsKey = Keys.projects
        let legacyClientsKey = Keys.clients
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults, projectsKey, clientsKey, legacyProjectsKey, legacyClientsKey] in
                do {
                    var projects: [Project] = []
                    var clients: [Client] = []
                    
                    // UserDefaults is thread-safe, no need for MainActor
                    // Try user-specific key first, then fall back to global key for backward compatibility
                    if let projectsData = userDefaults.data(forKey: projectsKey) {
                        print("🔥🔥🔥 DEBUG: Found projects data with key: \(projectsKey)")
                        projects = try JSONDecoder().decode([Project].self, from: projectsData)
                        print("🔥🔥🔥 DEBUG: Decoded \(projects.count) projects from local storage")
                    } else if projectsKey != legacyProjectsKey, let legacyData = userDefaults.data(forKey: legacyProjectsKey) {
                        // Fallback to legacy global key
                        print("🔥🔥🔥 DEBUG: Found projects data with legacy key: \(legacyProjectsKey)")
                        projects = try JSONDecoder().decode([Project].self, from: legacyData)
                        print("🔥🔥🔥 DEBUG: Decoded \(projects.count) projects from legacy local storage")
                    } else {
                        print("🔥🔥🔥 DEBUG: No projects data found in local storage (checked keys: \(projectsKey), \(legacyProjectsKey))")
                    }
                    
                    if let clientsData = userDefaults.data(forKey: clientsKey) {
                        print("🔥🔥🔥 DEBUG: Found clients data with key: \(clientsKey)")
                        clients = try JSONDecoder().decode([Client].self, from: clientsData)
                        print("🔥🔥🔥 DEBUG: Decoded \(clients.count) clients from local storage")
                    } else if clientsKey != legacyClientsKey, let legacyData = userDefaults.data(forKey: legacyClientsKey) {
                        // Fallback to legacy global key
                        print("🔥🔥🔥 DEBUG: Found clients data with legacy key: \(legacyClientsKey)")
                        clients = try JSONDecoder().decode([Client].self, from: legacyData)
                        print("🔥🔥🔥 DEBUG: Decoded \(clients.count) clients from legacy local storage")
                    } else {
                        print("🔥🔥🔥 DEBUG: No clients data found in local storage (checked keys: \(clientsKey), \(legacyClientsKey))")
                    }
                    
                    continuation.resume(returning: (projects, clients))
                } catch {
                    print("🔥🔥🔥 DEBUG: Error loading project data from local storage: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Operative Data
    
    func saveOperativeData(operatives: [Operative], managers: [Manager]) async throws {
        let operativesKey = getUserSpecificKey(Keys.operatives)
        let managersKey = getUserSpecificKey(Keys.managers)
        
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                do {
                    let operativesData = try JSONEncoder().encode(operatives)
                    let managersData = try JSONEncoder().encode(managers)
                    
                    // UserDefaults is thread-safe, no need for MainActor
                    userDefaults.set(operativesData, forKey: operativesKey)
                    userDefaults.set(managersData, forKey: managersKey)
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func loadOperativeData() async throws -> (operatives: [Operative], managers: [Manager]) {
        let operativesKey = getUserSpecificKey(Keys.operatives)
        let managersKey = getUserSpecificKey(Keys.managers)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                do {
                    var operatives: [Operative] = []
                    var managers: [Manager] = []
                    
                    // UserDefaults is thread-safe, no need for MainActor
                    if let operativesData = userDefaults.data(forKey: operativesKey) {
                        operatives = try JSONDecoder().decode([Operative].self, from: operativesData)
                    }
                    
                    if let managersData = userDefaults.data(forKey: managersKey) {
                        managers = try JSONDecoder().decode([Manager].self, from: managersData)
                    }
                    
                    continuation.resume(returning: (operatives, managers))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Booking Data
    
    func saveBookingData(bookings: [Booking]) async throws {
        let key = getUserSpecificKey(Keys.bookings)
        
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                do {
                    let bookingsData = try JSONEncoder().encode(bookings)
                    // UserDefaults is thread-safe, no need for MainActor
                    userDefaults.set(bookingsData, forKey: key)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func loadBookingData() async throws -> [Booking] {
        let key = getUserSpecificKey(Keys.bookings)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                do {
                    var bookings: [Booking] = []
                    
                    // UserDefaults is thread-safe, no need for MainActor
                    if let bookingsData = userDefaults.data(forKey: key) {
                        bookings = try JSONDecoder().decode([Booking].self, from: bookingsData)
                    }
                    
                    continuation.resume(returning: bookings)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - App Settings
    
    func saveAppSettings(_ settings: AppSettings) async throws {
        let key = getUserSpecificKey(Keys.appSettings)
        
        // Pass settings to detached task - AppSettings is now fully nonisolated
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults, settings] in
                do {
                    // Encode in detached task (nonisolated context) - AppSettings.init and encode are nonisolated
                    let settingsData = try JSONEncoder().encode(settings)
                    // UserDefaults is thread-safe, no need for MainActor
                    userDefaults.set(settingsData, forKey: key)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func loadAppSettings() async throws -> AppSettings {
        let key = getUserSpecificKey(Keys.appSettings)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                // UserDefaults is thread-safe, no need for MainActor
                if let settingsData = userDefaults.data(forKey: key) {
                    do {
                        // Decode in detached task (nonisolated context)
                        let settings = try JSONDecoder().decode(AppSettings.self, from: settingsData)
                        continuation.resume(returning: settings)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    // Create default settings in nonisolated context
                    let defaultSettings = AppSettings()
                    continuation.resume(returning: defaultSettings)
                }
            }
        }
    }
    
    // MARK: - Clear All Data
    
    func clearAllData() async {
        let keys = [Keys.projects, Keys.clients, Keys.operatives, Keys.managers, Keys.bookings, Keys.appSettings]
        let userKeys = keys.map { getUserSpecificKey($0) }
        
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) { [userDefaults] in
                // UserDefaults is thread-safe, no need for MainActor
                userKeys.forEach { userDefaults.removeObject(forKey: $0) }
                continuation.resume()
            }
        }
    }
    
    // MARK: - Clear All User Data (for sign out)
    
    func clearUserData(for userId: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                let keys = [Keys.projects, Keys.clients, Keys.operatives, Keys.managers, Keys.bookings, Keys.appSettings]
                keys.forEach { self.userDefaults.removeObject(forKey: "\(userId)_\($0)") }
                continuation.resume()
            }
        }
    }
}
