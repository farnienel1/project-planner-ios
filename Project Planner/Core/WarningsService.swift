//
//  WarningsService.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import Foundation
import Combine

struct Warning: Identifiable, Hashable {
    let id: UUID = UUID()
    let type: WarningType
    let message: String
    let severity: WarningSeverity
    
    // Booking clash specific details
    var bookingClashDetails: BookingClashDetails?
    
    // Operative not verified - store operative email for resend
    var operativeEmail: String?
    
    struct BookingClashDetails: Hashable {
        var user1Name: String
        var user2Name: String
        var project1Number: String?
        var project1Name: String?
        var project2Number: String?
        var project2Name: String?
        var smallWork1Number: String?
        var smallWork1Name: String?
        var smallWork2Number: String?
        var smallWork2Name: String?
        var timeSlot1: String
        var timeSlot2: String
        var date: Date
        var operativeName: String
    }
    
    enum WarningType: Hashable {
        case qualificationExpiry
        case bookingClash
        case operativeNotVerified
    }
    
    enum WarningSeverity: Hashable {
        case low
        case medium
        case high
    }
    
    init(type: WarningType, message: String, severity: WarningSeverity, bookingClashDetails: BookingClashDetails? = nil, operativeEmail: String? = nil) {
        self.type = type
        self.message = message
        self.severity = severity
        self.bookingClashDetails = bookingClashDetails
        self.operativeEmail = operativeEmail
    }
}

class WarningsService: ObservableObject {
    @Published var warnings: [Warning] = []
    
    func updateWarnings(
        operatives: [Operative],
        bookings: [Booking],
        projects: [Project],
        managers: [Manager],
        users: [AppUser] = []
    ) {
        // Helper function to get user/manager name from bookedBy (which might be email or name)
        func getManagerName(from bookedBy: String) -> String {
            // If bookedBy is already a name (not an email), return it
            if !bookedBy.contains("@") {
                return bookedBy
            }
            
            // First, try to find manager by email
            if let manager = managers.first(where: { $0.email == bookedBy }) {
                return manager.fullName
            }
            
            // Then, try to find user by email
            if let user = users.first(where: { $0.email == bookedBy }) {
                return user.fullName
            }
            
            // If it's an email but not found, try to find by name match
            // (in case bookedBy was set to name in some cases)
            if let manager = managers.first(where: { $0.fullName == bookedBy }) {
                return manager.fullName
            }
            
            // Fallback: return the bookedBy value (might be email or name)
            return bookedBy
        }
        var newWarnings: [Warning] = []
        
        // Helper to check if a date is a working day (Monday-Friday)
        func isWorkingDay(_ date: Date) -> Bool {
            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: date)
            return weekday >= 2 && weekday <= 6 // Monday = 2, Friday = 6
        }
        
        // Helper to count working days between two dates
        func workingDaysBetween(_ start: Date, _ end: Date) -> Int {
            var count = 0
            var current = start
            while current <= end {
                if isWorkingDay(current) {
                    count += 1
                }
                if let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: current) {
                    current = nextDay
                } else {
                    break
                }
                if current > end { break }
            }
            return count
        }
        
        // Check for operatives not verified in 3 working days
        let today = Date()
        for operative in operatives {
            // Find the corresponding AppUser for this operative
            if let operativeUser = users.first(where: { user in
                user.email.lowercased() == operative.email.lowercased() && user.permissions.operativeMode
            }) {
                // Check if operative hasn't verified (passwordSet is false) and was created more than 3 working days ago
                if !operativeUser.passwordSet {
                    let daysSinceCreation = workingDaysBetween(operativeUser.createdAt, today)
                    if daysSinceCreation >= 3 {
                        newWarnings.append(Warning(
                            type: .operativeNotVerified,
                            message: "\(operative.name) has not verified their account",
                            severity: .medium,
                            bookingClashDetails: nil,
                            operativeEmail: operative.email
                        ))
                    }
                }
            }
        }
        
        // Check for qualification expiry warnings (1 month away)
        let oneMonthFromNow = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        
        for operative in operatives {
            for (qualificationId, expiryDate) in operative.qualificationExpiryDates {
                if expiryDate >= today && expiryDate <= oneMonthFromNow {
                    if let qualification = operative.qualifications.first(where: { $0.id == qualificationId }) {
                        let daysUntilExpiry = Calendar.current.dateComponents([.day], from: today, to: expiryDate).day ?? 0
                        let severity: Warning.WarningSeverity = daysUntilExpiry <= 7 ? .high : (daysUntilExpiry <= 14 ? .medium : .low)
                        
                        newWarnings.append(Warning(
                            type: .qualificationExpiry,
                            message: "\(operative.name)'s \(qualification.name) expires in \(daysUntilExpiry) day\(daysUntilExpiry == 1 ? "" : "s")",
                            severity: severity
                        ))
                    }
                }
            }
        }
        
        // Check for booking clashes
        let activeBookings = bookings.filter { $0.status == .confirmed || $0.status == .tentative }
        let bookingsByOperativeAndDate = Dictionary(grouping: activeBookings) { booking in
            "\(booking.operativeId.uuidString)-\(Calendar.current.startOfDay(for: booking.date).timeIntervalSince1970)"
        }
        
        for (_, dayBookings) in bookingsByOperativeAndDate {
            if dayBookings.count > 1 {
                // Group by time slot to detect clashes
                var timeSlots: [TimeSlot: [Booking]] = [:]
                for booking in dayBookings {
                    timeSlots[booking.timeSlot, default: []].append(booking)
                }
                
                // Check for clashes
                var processedClashes: Set<String> = []
                
                // Check for multiple bookings in same slot
                for (slot, slotBookings) in timeSlots {
                    if slotBookings.count > 1 {
                        // Multiple bookings in same slot (AM/AM, PM/PM, FULL DAY/FULL DAY)
                        let clashKey = "\(slot.rawValue)-\(slotBookings.map { $0.id.uuidString }.sorted().joined())"
                        if !processedClashes.contains(clashKey) {
                            processedClashes.insert(clashKey)
                            
                            // Get detailed information for the clash
                            let booking1 = slotBookings[0]
                            let booking2 = slotBookings[1]
                            
                            let user1Name = getManagerName(from: booking1.bookedBy)
                            let user2Name = getManagerName(from: booking2.bookedBy)
                            
                            let operative = operatives.first(where: { $0.id == booking1.operativeId })
                            let operativeName = operative?.name ?? "Unknown Operative"
                            
                            let project1 = projects.first(where: { $0.id == booking1.projectId })
                            let project2 = projects.first(where: { $0.id == booking2.projectId })
                            
                            // Check if it's a small work
                            let isSmallWork1 = project1?.jobType == .smallWorks
                            let isSmallWork2 = project2?.jobType == .smallWorks
                            
                            let timeSlot1 = slot.displayName
                            let timeSlot2 = slot.displayName
                            
                            let clashDate = booking1.date
                            
                            let clashDetails = Warning.BookingClashDetails(
                                user1Name: user1Name,
                                user2Name: user2Name,
                                project1Number: isSmallWork1 ? nil : project1?.jobNumber,
                                project1Name: isSmallWork1 ? nil : project1?.siteName,
                                project2Number: isSmallWork2 ? nil : project2?.jobNumber,
                                project2Name: isSmallWork2 ? nil : project2?.siteName,
                                smallWork1Number: isSmallWork1 ? project1?.jobNumber : nil,
                                smallWork1Name: isSmallWork1 ? project1?.siteName : nil,
                                smallWork2Number: isSmallWork2 ? project2?.jobNumber : nil,
                                smallWork2Name: isSmallWork2 ? project2?.siteName : nil,
                                timeSlot1: timeSlot1,
                                timeSlot2: timeSlot2,
                                date: clashDate,
                                operativeName: operativeName
                            )
                            
                            let clashDescription: String
                            if slot == .fullDay {
                                clashDescription = "FULL DAY"
                            } else if slot == .morning {
                                clashDescription = "AM"
                            } else if slot == .afternoon {
                                clashDescription = "PM"
                            } else {
                                clashDescription = slot.displayName
                            }
                            
                            let project1Display = isSmallWork1 ? (project1?.jobNumber ?? "Unknown") : (project1?.jobNumber ?? "Unknown")
                            let project2Display = isSmallWork2 ? (project2?.jobNumber ?? "Unknown") : (project2?.jobNumber ?? "Unknown")
                            
                            newWarnings.append(Warning(
                                type: .bookingClash,
                                message: "Booking clash: \(user1Name) and \(user2Name) - \(project1Display) & \(project2Display) - \(clashDescription)",
                                severity: .high,
                                bookingClashDetails: clashDetails
                            ))
                        }
                    }
                }
                
                // Check for FULL DAY clashing with AM or PM
                if let fullDayBookings = timeSlots[.fullDay], !fullDayBookings.isEmpty {
                    for (slot, slotBookings) in timeSlots {
                        if slot != .fullDay && !slotBookings.isEmpty {
                            // Full day clashes with AM or PM
                            let allClashingBookings = fullDayBookings + slotBookings
                            let clashKey = "FULL-\(allClashingBookings.map { $0.id.uuidString }.sorted().joined())"
                            
                            if !processedClashes.contains(clashKey) {
                                processedClashes.insert(clashKey)
                                
                                let booking1 = allClashingBookings[0]
                                let booking2 = allClashingBookings[1]
                                
                                let user1Name = getManagerName(from: booking1.bookedBy)
                                let user2Name = getManagerName(from: booking2.bookedBy)
                                
                                let operative = operatives.first(where: { $0.id == booking1.operativeId })
                                let operativeName = operative?.name ?? "Unknown Operative"
                                
                                let project1 = projects.first(where: { $0.id == booking1.projectId })
                                let project2 = projects.first(where: { $0.id == booking2.projectId })
                                
                                // Check if it's a small work
                                let isSmallWork1 = project1?.jobType == .smallWorks
                                let isSmallWork2 = project2?.jobType == .smallWorks
                                
                                let timeSlot1 = "FULL DAY"
                                let timeSlot2 = slot.displayName
                                
                                let clashDate = booking1.date
                                
                                let clashDetails = Warning.BookingClashDetails(
                                    user1Name: user1Name,
                                    user2Name: user2Name,
                                    project1Number: isSmallWork1 ? nil : project1?.jobNumber,
                                    project1Name: isSmallWork1 ? nil : project1?.siteName,
                                    project2Number: isSmallWork2 ? nil : project2?.jobNumber,
                                    project2Name: isSmallWork2 ? nil : project2?.siteName,
                                    smallWork1Number: isSmallWork1 ? project1?.jobNumber : nil,
                                    smallWork1Name: isSmallWork1 ? project1?.siteName : nil,
                                    smallWork2Number: isSmallWork2 ? project2?.jobNumber : nil,
                                    smallWork2Name: isSmallWork2 ? project2?.siteName : nil,
                                    timeSlot1: timeSlot1,
                                    timeSlot2: timeSlot2,
                                    date: clashDate,
                                    operativeName: operativeName
                                )
                                
                                let clashDescription: String
                                if slot == .morning {
                                    clashDescription = "AM with FULL DAY"
                                } else if slot == .afternoon {
                                    clashDescription = "PM with FULL DAY"
                                } else {
                                    clashDescription = "\(slot.displayName) with FULL DAY"
                                }
                                
                                let project1Display = isSmallWork1 ? (project1?.jobNumber ?? "Unknown") : (project1?.jobNumber ?? "Unknown")
                                let project2Display = isSmallWork2 ? (project2?.jobNumber ?? "Unknown") : (project2?.jobNumber ?? "Unknown")
                                
                                newWarnings.append(Warning(
                                    type: .bookingClash,
                                    message: "Booking clash: \(user1Name) and \(user2Name) - \(project1Display) & \(project2Display) - \(clashDescription)",
                                    severity: .high,
                                    bookingClashDetails: clashDetails
                                ))
                            }
                        }
                    }
                }
            }
        }
        
        warnings = newWarnings
    }
    
    var warningCount: Int {
        warnings.count
    }
}

