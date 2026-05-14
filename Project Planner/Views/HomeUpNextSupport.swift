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

/// One calendar day in the Up next list (e.g. Monday 11th May).
struct HomeUpNextDaySection: Identifiable {
    let id: String
    let heading: String
    let rows: [HomeUpNextRow]
}

enum HomeUpNextSupport {
    private static let calendar = Calendar.current

    static func sortDate(operativeBooking b: Booking, policy: OrgPayrollTimePolicy = .default) -> Date {
        b.calendarBlock(on: b.date, policy: policy).start
    }

    static func sortDate(managerBooking b: ManagerSiteBooking, policy: OrgPayrollTimePolicy = .default) -> Date {
        let day = calendar.startOfDay(for: b.date)
        if let s = b.workStartTime, let mins = ManagerScheduleInterval.parseMinutes(s) {
            return calendar.date(byAdding: .minute, value: mins, to: day) ?? day
        }
        guard let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd),
              de > ds else {
            switch b.timeSlot {
            case .morning, .fullDay, .customHours:
                return calendar.date(byAdding: .hour, value: 8, to: day) ?? day
            case .afternoon:
                return calendar.date(byAdding: .hour, value: 13, to: day) ?? day
            }
        }
        let mid = ds + (de - ds) / 2
        switch b.timeSlot {
        case .morning, .fullDay, .customHours:
            return calendar.date(byAdding: .minute, value: ds, to: day) ?? day
        case .afternoon:
            return calendar.date(byAdding: .minute, value: mid, to: day) ?? day
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
        accentPurple: Color,
        payrollTimePolicy: OrgPayrollTimePolicy = .default
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
                let start = sortDate(operativeBooking: b, policy: payrollTimePolicy)
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
                let start = sortDate(managerBooking: b, policy: payrollTimePolicy)
                guard start >= now else { continue }
                let loc = managerLocationTitle(booking: b, allProjects: allProjects)
                let title = loc
                let timeStr = timeDotString(from: start)
                let slot = b.scheduleLabel(policy: payrollTimePolicy)
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

    /// Groups upcoming rows by calendar day. Shows up to `minDistinctDays` different days when data allows (each day lists all its rows from the merged set).
    static func upcomingDaySections(
        minDistinctDays: Int = 2,
        mergeRowLimit: Int = 48,
        now: Date,
        authUserId: String?,
        currentUserEmail: String?,
        operatives: [Operative],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        allProjects: [Project],
        organizationUsers: [AppUser],
        accentBlue: Color,
        accentPurple: Color,
        payrollTimePolicy: OrgPayrollTimePolicy = .default
    ) -> [HomeUpNextDaySection] {
        let merged = upcomingRows(
            limit: mergeRowLimit,
            now: now,
            authUserId: authUserId,
            currentUserEmail: currentUserEmail,
            operatives: operatives,
            bookings: bookings,
            managerBookings: managerBookings,
            allProjects: allProjects,
            organizationUsers: organizationUsers,
            accentBlue: accentBlue,
            accentPurple: accentPurple,
            payrollTimePolicy: payrollTimePolicy
        )
        guard !merged.isEmpty else { return [] }

        var byDay: [Date: [HomeUpNextRow]] = [:]
        for row in merged {
            let day = calendar.startOfDay(for: row.sortDate)
            byDay[day, default: []].append(row)
        }
        let sortedDays = byDay.keys.sorted()
        let dayCount = min(sortedDays.count, minDistinctDays)
        let chosenDays = Array(sortedDays.prefix(dayCount))

        return chosenDays.map { day in
            let rows = (byDay[day] ?? []).sorted { $0.sortDate < $1.sortDate }
            let heading = dayHeadingWithOrdinal(for: day)
            let id = String(day.timeIntervalSince1970)
            return HomeUpNextDaySection(id: id, heading: heading, rows: rows)
        }
    }

    private static func dayHeadingWithOrdinal(for day: Date) -> String {
        let d = calendar.component(.day, from: day)
        let suffix: String
        if (11...13).contains(d % 100) {
            suffix = "th"
        } else {
            switch d % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        let weekday = DateFormatter()
        weekday.locale = calendar.locale
        weekday.calendar = calendar
        weekday.dateFormat = "EEEE"
        let month = DateFormatter()
        month.locale = calendar.locale
        month.calendar = calendar
        month.dateFormat = "MMMM"
        return "\(weekday.string(from: day)) \(d)\(suffix) \(month.string(from: day))"
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
