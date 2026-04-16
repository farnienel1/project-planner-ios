//
//  Models.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import SwiftUI

struct Client: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    
    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

extension Client {
    static let defaultClients: [Client] = [
        Client(name: "CBC"),
        Client(name: "Claremont"),
        Client(name: "GMS"),
        Client(name: "Kempton Smith"),
        Client(name: "Nicholas Stephens"),
        Client(name: "Pryer Construction"),
        Client(name: "RCDC"),
        Client(name: "RED Construction"),
        Client(name: "Roots")
    ]
}

enum JobType: String, CaseIterable, Identifiable, Codable {
    case CAT_A = "CAT A"
    case CAT_B = "CAT B"
    case Small_Works = "Small Works"

    var id: String { rawValue }
}

enum Manager: String, CaseIterable, Identifiable, Codable {
    case Adam
    case Andrew
    case Billey
    case Charley
    case Farnie
    case Fin
    case Greg
    case Morgan

    var id: String { rawValue }
}

enum BookingPart: String, CaseIterable, Identifiable, Codable {
    case AM
    case PM
    case Full_Day = "FULL DAY"

    var id: String { rawValue }
}

enum SkillBadge: String, CaseIterable, Identifiable, Codable, Hashable {
    case AM2 = "AM2"
    case Apprentice = "Apprentice"
    case Black_Card = "Black Card"
    case Gold_Card = "Gold Card"
    case Labourer_Card = "Labourer Card"
    case Testing = "Testing"

    var id: String { rawValue }
}

enum TradeSkill: String, CaseIterable, Identifiable, Codable, Hashable {
    case Second_Fix = "2nd Fix"
    case Access_Control = "Access Control"
    case BMS = "BMS"
    case Cable_Pulling = "Cable Pulling"
    case Containment = "Containment"
    case Data = "Data"
    case Distribution = "Distribution"
    case Entryphone = "Entryphone"
    case Fire_Alarm = "Fire Alarm"
    case Lighting_Control = "Lighting Control"

    var id: String { rawValue }
}

struct Operative: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var startDate: Date
    var skills: Set<TradeSkill>
    var qualifications: Set<SkillBadge>

    init(id: UUID = UUID(), name: String, email: String, startDate: Date, skills: Set<TradeSkill>, qualifications: Set<SkillBadge>) {
        self.id = id
        self.name = name
        self.email = email
        self.startDate = startDate
        self.skills = skills
        self.qualifications = qualifications
    }
}

struct Booking: Identifiable, Codable, Hashable {
    let id: UUID
    var operativeId: UUID
    var projectId: UUID
    var date: Date
    var part: BookingPart
    var bookedBy: String

    init(id: UUID = UUID(), operativeId: UUID, projectId: UUID, date: Date, part: BookingPart, bookedBy: String) {
        self.id = id
        self.operativeId = operativeId
        self.projectId = projectId
        self.date = date
        self.part = part
        self.bookedBy = bookedBy
    }
}

struct ManagerDetails: Identifiable, Codable, Hashable {
    let id: UUID
    var firstName: String
    var lastName: String
    var mobileNumber: String
    var email: String

    init(id: UUID = UUID(), firstName: String, lastName: String, mobileNumber: String, email: String) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.mobileNumber = mobileNumber
        self.email = email
    }
}

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var jobNumber: String
    var siteName: String
    var siteAddress: String
    var client: Client
    var startDate: Date
    var endDate: Date
    var jobType: JobType
    var manager: Manager
    var isLive: Bool

    init(id: UUID = UUID(), jobNumber: String, siteName: String, siteAddress: String, client: Client, startDate: Date, endDate: Date, jobType: JobType, manager: Manager, isLive: Bool) {
        self.id = id
        self.jobNumber = jobNumber
        self.siteName = siteName
        self.siteAddress = siteAddress
        self.client = client
        self.startDate = startDate
        self.endDate = endDate
        self.jobType = jobType
        self.manager = manager
        self.isLive = isLive
    }
}

enum ThemePreference: String, CaseIterable, Codable {
    case light = "light"
    case dark = "dark"
    case system = "system"
}