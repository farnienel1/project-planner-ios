//
//  HomeUpNextSupport.swift
//  Project Planner
//
//  Next upcoming schedule rows for the home dashboard (operative + manager bookings).
//

import SwiftUI

struct HomeUpNextRow: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let sortDate: Date
    let accentColor: Color
}

enum HomeUpNextSupport {
    private static let calendar = Calendar.current

    static func sortDate(operativeBooking b: Booking) -> Date {
        let day = calendar.startOfDay(for: b.date)
        switch b.timeSlot {
        case .morning, .fullDay:
            return calendar.date(byAdding: .hour, value: 8, to: day) ?? day
        case .afternoon:
            return calendar.date(byAdding: .hour, value: 13, to: day) ?? day
        case .evening, .overtime:
            return calendar.date(byAdding: .hour, value: 17, to: day) ?? day
        }
    }

    static func sortDate(managerBooking b: ManagerSiteBooking) -> Date {
        let day = calendar.startOfDay(for: b.date)
        switch b.timeSlot {
        case .morning, .fullDay:
            return calendar.date(byAdding: .hour, value: 8, to: day) ?? day
        case .afternoon:
            return calendar.date(byAdding: .hour, value: 13, to: day) ?? day
        }
    }

    static func project(forProjectId id: UUID, allProjects: [Project]) -> Project? {
        allProjects.first(where: { $0.id == id })
    }

    static func managerLocationTitle(
        booking: ManagerSiteBooking,
        allProjects: [Project]
    ) -> String {
        switch booking.locationType {
        case .office, .workingFromHome, .siteSurvey:
            return booking.locationType.displayName
        case .custom:
            let n = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return n.isEmpty ? "Custom" : n
        case .project, .smallWork:
            guard let lid = booking.locationId,
                  let p = project(forProjectId: lid, allProjects: allProjects) else {
                return "Site"
            }
            return p.siteName
        }
    }

    /// Next upcoming operative + manager site bookings, merged and sorted (max `limit`).
    static func upcomingRows(
        limit: Int,
        now: Date,
        authUserId: String?,
        currentUserEmail: String?,
        operatives: [Operative],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        allProjects: [Project],
        organizationUsers: [AppUser],
        accentBlue: Color,
        accentPurple: Color
    ) -> [HomeUpNextRow] {
        var rows: [HomeUpNextRow] = []
        let emailKey = currentUserEmail?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let emailKey, !emailKey.isEmpty,
           let op = operatives.first(where: {
               $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == emailKey
           }) {
            let mine = bookings.filter { b in
                b.operativeId == op.id && b.status != .cancelled && b.status != .completed
            }
            for b in mine {
                let start = sortDate(operativeBooking: b)
                guard start >= now else { continue }
                let proj = project(forProjectId: b.projectId, allProjects: allProjects)
                let site = proj?.siteName ?? "Scheduled work"
                let title = site
                let timeStr = timeDotString(from: start)
                let booker = displayName(forUserId: b.bookedBy, users: organizationUsers)
                let job = proj?.jobNumber
                let subtitle: String
                if let job, !job.isEmpty, !booker.isEmpty {
                    subtitle = "\(timeStr) · \(job) · \(booker)"
                } else if let job, !job.isEmpty {
                    subtitle = "\(timeStr) · \(job)"
                } else if !booker.isEmpty {
                    subtitle = "\(timeStr) · \(booker)"
                } else {
                    subtitle = timeStr
                }
                rows.append(HomeUpNextRow(
                    id: b.id,
                    title: title,
                    subtitle: subtitle,
                    sortDate: start,
                    accentColor: accentBlue
                ))
            }
        }

        if let authUserId {
            let mine = managerBookings.filter { $0.userId == authUserId }
            for b in mine {
                let start = sortDate(managerBooking: b)
                guard start >= now else { continue }
                let loc = managerLocationTitle(booking: b, allProjects: allProjects)
                let title = loc
                let timeStr = timeDotString(from: start)
                let slot = b.timeSlot.displayName
                let subtitle = "\(timeStr) · \(slot)"
                rows.append(HomeUpNextRow(
                    id: b.id,
                    title: title,
                    subtitle: subtitle,
                    sortDate: start,
                    accentColor: accentPurple
                ))
            }
        }

        rows.sort { $0.sortDate < $1.sortDate }
        if rows.count <= limit { return rows }
        return Array(rows.prefix(limit))
    }

    private static func timeDotString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func displayName(forUserId userId: String, users: [AppUser]) -> String {
        guard let u = users.first(where: { $0.id == userId }) else { return "" }
        let full = "\(u.firstName) \(u.surname)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        return u.email.components(separatedBy: "@").first ?? ""
    }
}
