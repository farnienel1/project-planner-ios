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
    /// RULEBOOK 1.53.0: the organisation zone, never the device's.
    private static var calendar: Calendar { OrganizationRulebookContext.calendar }

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

    /// RULEBOOK 1.53.0 §23 `CanonicalBusinessEngine.homeUpNextRows`: the signed-in person's labour and manager site
    /// bookings from today on (organisation day — today's stay all day, Completed shows), matched under every id they
    /// go by without case, in start order, grouped by the first `minDistinctDays` days. Swift only adds the titles.
    static func upcomingDaySections(
        minDistinctDays: Int = 2,
        mergeRowLimit: Int = 48,
        now: Date,
        authUserId: String?,
        currentUserEmail: String?,
        currentUserFirstName: String? = nil,
        currentUserSurname: String? = nil,
        operatives: [Operative],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        allProjects: [Project],
        organizationUsers: [AppUser],
        accentBlue: Color,
        accentPurple: Color,
        payrollTimePolicy: OrgPayrollTimePolicy = .default
    ) -> [HomeUpNextDaySection] {
        let uid = authUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerUser = organizationUsers.first { $0.id == uid }
        let viewer: [String: Any] = [
            "id": uid,
            "email": currentUserEmail ?? viewerUser?.email ?? "",
            "formerUserIds": viewerUser?.formerUserIds ?? [],
            "sameEmailUserIds": viewerUser?.sameEmailUserIds ?? [],
        ]
        let labourById = Dictionary(bookings.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let managerById = Dictionary(managerBookings.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        guard let answer = CanonicalBusinessEngine.homeUpNextRows(
            now: now,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            viewer: viewer,
            roster: RulebookPeople.roster(organizationUsers),
            operatives: operatives.map { ["id": $0.documentId, "email": $0.email] },
            bookings: bookings.map {
                RulebookHomeUpNextBooking(
                    id: $0.id.uuidString,
                    personId: $0.storedOperativeId,
                    dayKey: OrganizationRulebookContext.dayKey($0.date),
                    status: $0.status.rawValue,
                    timeSlot: $0.timeSlot.rawValue,
                    workStartTime: $0.workStartTime,
                    workEndTime: $0.workEndTime
                )
            },
            managerSiteBookings: managerBookings.map {
                RulebookHomeUpNextBooking(
                    id: $0.id.uuidString,
                    personId: $0.userId,
                    dayKey: OrganizationRulebookContext.dayKey($0.date),
                    status: nil,
                    timeSlot: $0.timeSlot.rawValue,
                    workStartTime: $0.workStartTime,
                    workEndTime: $0.workEndTime
                )
            },
            policy: CanonicalBusinessEngine.bookingDayInput(policy: payrollTimePolicy),
            limit: mergeRowLimit,
            minDistinctDays: minDistinctDays
        ) else { return [] }

        return answer.days.map { day in
            let rows: [HomeUpNextRow] = day.rows.compactMap { row in
                let sortDate = OrganizationRulebookContext.date(fromDayKey: row.dayKey)?.addingTimeInterval(TimeInterval(row.startMinutes * 60)) ?? now
                if row.kind == "manager", let booking = managerById[row.id] {
                    let slot = row.timeRange.isEmpty ? booking.timeSlot.displayName : row.timeRange
                    return HomeUpNextRow(
                        id: booking.id,
                        title: managerLocationTitle(booking: booking, allProjects: allProjects),
                        subtitle: "\(row.startText) · \(slot)",
                        sortDate: sortDate,
                        accentColor: accentPurple
                    )
                }
                guard let booking = labourById[row.id] else { return nil }
                let proj = project(forProjectId: booking.projectId, allProjects: allProjects)
                let booker = displayName(forUserId: booking.bookedBy, users: organizationUsers)
                let parts = [row.startText, proj?.jobNumber ?? "", booker].filter { !$0.isEmpty }
                return HomeUpNextRow(
                    id: booking.id,
                    title: proj?.siteName ?? "Scheduled work",
                    subtitle: parts.joined(separator: " · "),
                    sortDate: sortDate,
                    accentColor: accentBlue
                )
            }
            return HomeUpNextDaySection(id: day.dayKey, heading: dayHeadingWithOrdinal(for: day.dayKey), rows: rows)
        }
    }

    /// "Monday 11th May" for an organisation day key.
    private static func dayHeadingWithOrdinal(for dayKey: String) -> String {
        guard let day = OrganizationRulebookContext.date(fromDayKey: dayKey) else { return dayKey }
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

    private static func displayName(forUserId userId: String, users: [AppUser]) -> String {
        guard let u = users.first(where: { $0.id == userId }) else { return "" }
        let full = "\(u.firstName) \(u.surname)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        return u.email.components(separatedBy: "@").first ?? ""
    }
}
