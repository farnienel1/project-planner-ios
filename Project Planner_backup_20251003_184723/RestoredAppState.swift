//
//  RestoredAppState.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Enhanced Data Models
struct ProjectOperative: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var phone: String
    var trade: String
    var hourlyRate: Double
    var startDate: Date
    var status: OperativeStatus
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(), name: String, email: String, phone: String, trade: String, hourlyRate: Double, startDate: Date, status: OperativeStatus, notes: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
        self.trade = trade
        self.hourlyRate = hourlyRate
        self.startDate = startDate
        self.status = status
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum OperativeStatus: String, CaseIterable, Identifiable, Codable {
    var id: String { rawValue }
    case active = "Active"
    case inactive = "Inactive"
    case onLeave = "On Leave"
}

struct ProjectManagerDetails: Identifiable, Codable, Hashable {
    let id: UUID
    var fullName: String
    var email: String
    var phone: String
    var role: String
    var department: String
    var startDate: Date
    var status: ManagerStatus
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(), fullName: String, email: String, phone: String, role: String, department: String, startDate: Date, status: ManagerStatus, notes: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.fullName = fullName
        self.email = email
        self.phone = phone
        self.role = role
        self.department = department
        self.startDate = startDate
        self.status = status
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ManagerStatus: String, CaseIterable, Identifiable, Codable {
    var id: String { rawValue }
    case active = "Active"
    case inactive = "Inactive"
}

struct ProjectBooking: Identifiable, Codable, Hashable {
    let id: UUID
    var operative: ProjectOperative
    var project: EnhancedProject
    var startDate: Date
    var endDate: Date
    var hours: Int
    var status: BookingStatus
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(), operative: ProjectOperative, project: EnhancedProject, startDate: Date, endDate: Date, hours: Int, status: BookingStatus, notes: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.operative = operative
        self.project = project
        self.startDate = startDate
        self.endDate = endDate
        self.hours = hours
        self.status = status
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum BookingStatus: String, CaseIterable, Identifiable, Codable {
    var id: String { rawValue }
    case confirmed = "Confirmed"
    case pending = "Pending"
    case cancelled = "Cancelled"
}

// MARK: - Enhanced Project Model
struct EnhancedProject: Identifiable, Codable, Hashable {
    let id: UUID
    var jobNumber: String
    var clientName: String
    var siteAddress: String
    var projectType: ProjectType
    var status: ProjectStatus
    var startDate: Date
    var endDate: Date
    var description: String
    var projectManager: String
    var estimatedHours: Int
    var actualHours: Int
    var materialsCost: Double
    var labourCost: Double
    var totalCost: Double
    var profitMargin: Double
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(), jobNumber: String, clientName: String, siteAddress: String, projectType: ProjectType, status: ProjectStatus, startDate: Date, endDate: Date, description: String, projectManager: String, estimatedHours: Int, actualHours: Int, materialsCost: Double, labourCost: Double, totalCost: Double, profitMargin: Double, notes: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.jobNumber = jobNumber
        self.clientName = clientName
        self.siteAddress = siteAddress
        self.projectType = projectType
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
        self.description = description
        self.projectManager = projectManager
        self.estimatedHours = estimatedHours
        self.actualHours = actualHours
        self.materialsCost = materialsCost
        self.labourCost = labourCost
        self.totalCost = totalCost
        self.profitMargin = profitMargin
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ProjectType: String, CaseIterable, Identifiable, Codable {
    var id: String { rawValue }
    case project = "Project"
    case smallWork = "Small Work"
}

enum ProjectStatus: String, CaseIterable, Identifiable, Codable {
    var id: String { rawValue }
    case planning = "Planning"
    case live = "Live"
    case completed = "Completed"
    case onHold = "On Hold"
}

// MARK: - Enhanced Client Model
struct EnhancedClient: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var contactPerson: String
    var email: String
    var phone: String
    var address: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(), name: String, contactPerson: String, email: String, phone: String, address: String, notes: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.contactPerson = contactPerson
        self.email = email
        self.phone = phone
        self.address = address
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Enhanced AppState
final class RestoredAppState: ObservableObject {
    @Published var projects: [EnhancedProject]
    @Published var operatives: [ProjectOperative]
    @Published var bookings: [ProjectBooking]
    @Published var clients: [EnhancedClient]
    @Published var managers: [ProjectManagerDetails]
    @Published var themePreference: ThemePreference = .light {
        didSet {
            saveData()
        }
    }
    @Published var isLoading: Bool = true
    @Published var currentOrganizationId: String?
    
    // Performance optimizations
    private var cachedLiveProjects: [EnhancedProject]?
    private var cachedLiveSmallWorks: [EnhancedProject]?
    private var lastProjectsUpdate: Date?
    
    init() {
        self.projects = []
        self.operatives = []
        self.bookings = []
        self.clients = []
        self.managers = []
        
        loadPersistedData()
        
        print("📱 RestoredAppState initialized with \(operatives.count) operatives and \(managers.count) managers")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isLoading = false
        }
    }
    
    func seedSampleData() {
        let date = Date()
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: date) ?? date
        
        // Custom dates for default operatives
        var components = DateComponents()
        components.day = 1
        components.month = 7
        components.year = 2023
        let july1_2023 = Calendar.current.date(from: components) ?? date
        
        // Sample Projects with full data
        let sampleProjects = [
            EnhancedProject(
                jobNumber: "2024-001",
                clientName: "ABC Construction Ltd",
                siteAddress: "123 Main Street, London",
                projectType: .project,
                status: .live,
                startDate: date,
                endDate: nextWeek,
                description: "Office renovation project",
                projectManager: "John Smith",
                estimatedHours: 160,
                actualHours: 45,
                materialsCost: 5000,
                labourCost: 8000,
                totalCost: 13000,
                profitMargin: 0.15,
                notes: "High priority project with tight deadline"
            ),
            EnhancedProject(
                jobNumber: "2024-002",
                clientName: "XYZ Properties",
                siteAddress: "456 Oak Avenue, Manchester",
                projectType: .smallWork,
                status: .completed,
                startDate: Calendar.current.date(byAdding: .day, value: -14, to: date) ?? date,
                endDate: Calendar.current.date(byAdding: .day, value: -7, to: date) ?? date,
                description: "Bathroom upgrade",
                projectManager: "Jane Doe",
                estimatedHours: 80,
                actualHours: 75,
                materialsCost: 2500,
                labourCost: 4000,
                totalCost: 6500,
                profitMargin: 0.20,
                notes: "Completed on time and under budget"
            )
        ]
        
        // Sample Operatives
        let sampleOperatives = [
            ProjectOperative(
                name: "Mike Johnson",
                email: "mike.johnson@raccordmep.co.uk",
                phone: "+44 7700 900001",
                trade: "Electrician",
                hourlyRate: 35.0,
                startDate: july1_2023,
                status: OperativeStatus.active,
                notes: "Experienced electrician with 10+ years"
            ),
            ProjectOperative(
                name: "Sarah Wilson",
                email: "sarah.wilson@raccordmep.co.uk",
                phone: "+44 7700 900002",
                trade: "Plumber",
                hourlyRate: 32.0,
                startDate: july1_2023,
                status: OperativeStatus.active,
                notes: "Specializes in commercial plumbing"
            ),
            ProjectOperative(
                name: "David Brown",
                email: "david.brown@raccordmep.co.uk",
                phone: "+44 7700 900003",
                trade: "HVAC Technician",
                hourlyRate: 38.0,
                startDate: july1_2023,
                status: OperativeStatus.active,
                notes: "Certified HVAC technician"
            )
        ]
        
        // Sample Clients
        let sampleClients = [
            EnhancedClient(
                name: "ABC Construction Ltd",
                contactPerson: "Robert Green",
                email: "robert@abcconstruction.co.uk",
                phone: "+44 20 7123 4567",
                address: "789 Business Park, London",
                notes: "Major construction company, regular client"
            ),
            EnhancedClient(
                name: "XYZ Properties",
                contactPerson: "Lisa Taylor",
                email: "lisa@xyzproperties.co.uk",
                phone: "+44 161 234 5678",
                address: "321 Property Lane, Manchester",
                notes: "Property development company"
            )
        ]
        
        // Sample Managers
        let sampleManagers = [
            ProjectManagerDetails(
                fullName: "John Smith",
                email: "john.smith@raccordmep.co.uk",
                phone: "+44 7700 900100",
                role: "Project Manager",
                department: "Operations",
                startDate: july1_2023,
                status: ManagerStatus.active,
                notes: "Senior project manager with 15+ years experience"
            ),
            ProjectManagerDetails(
                fullName: "Jane Doe",
                email: "jane.doe@raccordmep.co.uk",
                phone: "+44 7700 900101",
                role: "Operations Manager",
                department: "Operations",
                startDate: july1_2023,
                status: ManagerStatus.active,
                notes: "Operations manager overseeing all projects"
            )
        ]
        
        // Sample Bookings
        let sampleBookings = [
            ProjectBooking(
                operative: sampleOperatives[0],
                project: sampleProjects[0],
                startDate: date,
                endDate: Calendar.current.date(byAdding: .day, value: 5, to: date) ?? date,
                hours: 40,
                status: BookingStatus.confirmed,
                notes: "Electrical installation work"
            ),
            ProjectBooking(
                operative: sampleOperatives[1],
                project: sampleProjects[0],
                startDate: Calendar.current.date(byAdding: .day, value: 2, to: date) ?? date,
                endDate: Calendar.current.date(byAdding: .day, value: 7, to: date) ?? date,
                hours: 35,
                status: BookingStatus.confirmed,
                notes: "Plumbing installation"
            )
        ]
        
        // Only add sample data if arrays are empty
        if projects.isEmpty {
            projects = sampleProjects
        }
        if operatives.isEmpty {
            operatives = sampleOperatives
        }
        if bookings.isEmpty {
            bookings = sampleBookings
        }
        if clients.isEmpty {
            clients = sampleClients
        }
        if managers.isEmpty {
            managers = sampleManagers
        }
        
        saveData()
    }
    
    // MARK: - Data Management
    func clearAllData() {
        projects.removeAll()
        operatives.removeAll()
        bookings.removeAll()
        clients.removeAll()
        managers.removeAll()
        saveData()
    }
    
    func saveData() {
        if let projectsData = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(projectsData, forKey: "enhanced_projects")
        }
        if let operativesData = try? JSONEncoder().encode(operatives) {
            UserDefaults.standard.set(operativesData, forKey: "operatives")
        }
        if let bookingsData = try? JSONEncoder().encode(bookings) {
            UserDefaults.standard.set(bookingsData, forKey: "bookings")
        }
        if let clientsData = try? JSONEncoder().encode(clients) {
            UserDefaults.standard.set(clientsData, forKey: "enhanced_clients")
        }
        if let managersData = try? JSONEncoder().encode(managers) {
            UserDefaults.standard.set(managersData, forKey: "managers")
        }
        UserDefaults.standard.set(themePreference.rawValue, forKey: "themePreference")
    }
    
    func loadPersistedData() {
        if let projectsData = UserDefaults.standard.data(forKey: "enhanced_projects"),
           let decodedProjects = try? JSONDecoder().decode([EnhancedProject].self, from: projectsData) {
            projects = decodedProjects
        }
        if let operativesData = UserDefaults.standard.data(forKey: "operatives"),
           let decodedOperatives = try? JSONDecoder().decode([ProjectOperative].self, from: operativesData) {
            operatives = decodedOperatives
        }
        if let bookingsData = UserDefaults.standard.data(forKey: "bookings"),
           let decodedBookings = try? JSONDecoder().decode([ProjectBooking].self, from: bookingsData) {
            bookings = decodedBookings
        }
        if let clientsData = UserDefaults.standard.data(forKey: "enhanced_clients"),
           let decodedClients = try? JSONDecoder().decode([EnhancedClient].self, from: clientsData) {
            clients = decodedClients
        }
        if let managersData = UserDefaults.standard.data(forKey: "managers"),
           let decodedManagers = try? JSONDecoder().decode([ProjectManagerDetails].self, from: managersData) {
            managers = decodedManagers
        }
        if let themeRawValue = UserDefaults.standard.string(forKey: "themePreference"),
           let theme = ThemePreference(rawValue: themeRawValue) {
            themePreference = theme
        }
        
        if projects.isEmpty && operatives.isEmpty {
            seedSampleData()
        }
    }
    
    // MARK: - CRUD Operations
    func addProject(_ project: EnhancedProject) {
        projects.append(project)
        saveData()
    }
    
    func updateProject(_ project: EnhancedProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            saveData()
        }
    }
    
    func deleteProject(_ project: EnhancedProject) {
        projects.removeAll { $0.id == project.id }
        bookings.removeAll { $0.project.id == project.id }
        saveData()
    }
    
    func addOperative(_ operative: ProjectOperative) {
        operatives.append(operative)
        saveData()
    }
    
    func updateOperative(_ operative: ProjectOperative) {
        if let index = operatives.firstIndex(where: { $0.id == operative.id }) {
            operatives[index] = operative
            for i in bookings.indices {
                if bookings[i].operative.id == operative.id {
                    bookings[i].operative = operative
                }
            }
            saveData()
        }
    }
    
    func deleteOperative(_ operative: ProjectOperative) {
        operatives.removeAll { $0.id == operative.id }
        bookings.removeAll { $0.operative.id == operative.id }
        saveData()
    }
    
    func addBooking(_ booking: ProjectBooking) {
        bookings.append(booking)
        saveData()
    }
    
    func updateBooking(_ booking: ProjectBooking) {
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            bookings[index] = booking
            saveData()
        }
    }
    
    func deleteBooking(_ booking: ProjectBooking) {
        bookings.removeAll { $0.id == booking.id }
        saveData()
    }
    
    // MARK: - Computed Properties
    var liveProjects: [EnhancedProject] {
        if let cached = cachedLiveProjects,
           let lastUpdate = lastProjectsUpdate,
           Date().timeIntervalSince(lastUpdate) < 300 {
            return cached
        }
        
        let live = projects.filter { $0.status == .live }
        cachedLiveProjects = live
        lastProjectsUpdate = Date()
        return live
    }
    
    var smallWorks: [EnhancedProject] {
        projects.filter { $0.projectType == .smallWork }
    }
    
    var liveSmallWorks: [EnhancedProject] {
        if let cached = cachedLiveSmallWorks,
           let lastUpdate = lastProjectsUpdate,
           Date().timeIntervalSince(lastUpdate) < 300 {
            return cached
        }
        
        let live = projects.filter { $0.projectType == .smallWork && $0.status == .live }
        cachedLiveSmallWorks = live
        lastProjectsUpdate = Date()
        return live
    }
    
    var totalProjects: Int { projects.count }
    var totalOperatives: Int { operatives.count }
    var activeOperatives: Int { operatives.filter { $0.status == .active }.count }
    var totalBookings: Int { bookings.count }
    var confirmedBookings: Int { bookings.filter { $0.status == .confirmed }.count }
    var totalClients: Int { clients.count }
    var totalManagers: Int { managers.count }
    var activeManagers: Int { managers.filter { $0.status == .active }.count }
}
