//
//  SmartCacheService.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
#if canImport(Network)
import Network
#endif

// MARK: - Smart Cache Service for Offline Functionality

@MainActor
class SmartCacheService: ObservableObject {
    @Published var isOnline = true
    @Published var isSyncing = false
    
    #if canImport(Network)
    private let networkMonitor = NWPathMonitor()
    #endif
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    // In-memory cache for offline functionality
    private var cachedProjects: [Project] = []
    private var cachedClients: [Client] = []
    private var cachedOperatives: [Operative] = []
    private var cachedManagers: [Manager] = []
    private var cachedBookings: [Booking] = []
    private var cachedSkills: Set<String> = []
    private var cachedQualifications: [Qualification] = []
    
    // Offline queue for pending changes
    private var pendingChanges: [PendingChange] = []
    
    init() {
        startNetworkMonitoring()
    }
    
    deinit {
        #if canImport(Network)
        networkMonitor.cancel()
        #endif
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        #if canImport(Network)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
                if self?.isOnline == true {
                    self?.syncPendingChanges()
                }
            }
        }
        networkMonitor.start(queue: queue)
        #else
        // Fallback: assume online if Network framework not available
        isOnline = true
        #endif
    }
    
    // MARK: - Cache Management
    
    func cacheProjects(_ projects: [Project]) {
        cachedProjects = projects
    }
    
    func cacheClients(_ clients: [Client]) {
        cachedClients = clients
    }
    
    func cacheOperatives(_ operatives: [Operative]) {
        cachedOperatives = operatives
    }
    
    func cacheManagers(_ managers: [Manager]) {
        cachedManagers = managers
    }
    
    func cacheBookings(_ bookings: [Booking]) {
        cachedBookings = bookings
    }
    
    func cacheSkills(_ skills: Set<String>) {
        cachedSkills = skills
    }
    
    func cacheQualifications(_ qualifications: [Qualification]) {
        cachedQualifications = qualifications
    }
    
    // MARK: - Cache Retrieval
    
    func getCachedProjects() -> [Project] {
        return cachedProjects
    }
    
    func getCachedClients() -> [Client] {
        return cachedClients
    }
    
    func getCachedOperatives() -> [Operative] {
        return cachedOperatives
    }
    
    func getCachedManagers() -> [Manager] {
        return cachedManagers
    }
    
    func getCachedBookings() -> [Booking] {
        return cachedBookings
    }
    
    func getCachedSkills() -> Set<String> {
        return cachedSkills
    }
    
    func getCachedQualifications() -> [Qualification] {
        return cachedQualifications
    }
    
    // MARK: - Offline Queue Management
    
    func queueChange(_ change: PendingChange) {
        pendingChanges.append(change)
        print("🔥🔥🔥 DEBUG: Queued offline change: \(change.type) for \(change.entityType)")
    }
    
    func syncPendingChanges() {
        guard isOnline && !pendingChanges.isEmpty else { return }
        
        isSyncing = true
        print("🔥🔥🔥 DEBUG: 🔄 Syncing \(pendingChanges.count) pending changes to Firebase")
        
        Task { @MainActor in
            // Post notification to trigger stores to sync their data
            NotificationCenter.default.post(name: .syncOfflineChanges, object: nil)
            
            // Clear pending changes after sync is triggered
            pendingChanges.removeAll()
            isSyncing = false
            print("🔥🔥🔥 DEBUG: ✅ Offline sync triggered - stores will sync their data")
        }
    }
    
    private func processPendingChange(_ change: PendingChange) async {
        // This will be implemented to sync changes with Firebase
        // For now, just log the change
        print("🔥🔥🔥 DEBUG: Processing pending change: \(change.type) for \(change.entityType)")
    }
    
    // MARK: - Cache Clearing
    
    func clearAllCache() {
        cachedProjects.removeAll()
        cachedClients.removeAll()
        cachedOperatives.removeAll()
        cachedManagers.removeAll()
        cachedBookings.removeAll()
        cachedSkills.removeAll()
        cachedQualifications.removeAll()
        pendingChanges.removeAll()
        print("🔥🔥🔥 DEBUG: All cache cleared")
    }
}

// MARK: - Pending Change Model

struct PendingChange: Identifiable, Codable {
    var id = UUID()
    let type: ChangeType
    let entityType: EntityType
    let entityId: String
    let data: Data
    let timestamp: Date
    
    enum ChangeType: String, Codable {
        case create = "create"
        case update = "update"
        case delete = "delete"
    }
    
    enum EntityType: String, Codable {
        case project = "project"
        case client = "client"
        case operative = "operative"
        case manager = "manager"
        case booking = "booking"
        case skill = "skill"
        case qualification = "qualification"
    }
}
