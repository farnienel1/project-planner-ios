//
//  WarningsComputation.swift
//  Project Planner
//
//  Heavy warnings generation off the main thread (Home freeze fix).
//

import Foundation

struct WarningsComputationInput {
    let operatives: [Operative]
    let bookings: [Booking]
    let projects: [Project]
    let users: [AppUser]
    let managerSiteBookings: [ManagerSiteBooking]
    let holidayBookings: [HolidayBooking]
    let payrollTimePolicy: OrgPayrollTimePolicy
    let coverageStart: Date
    let coverageEnd: Date
    let materialOrderCutOffEnabled: Bool
    let projectsWithTomorrowBookings: [Project]
}

enum WarningsComputation {
    /// Last row wins when duplicate ids exist (e.g. project listed in both projects and smallWorks).
    private static func keyedByUUID<Row>(_ rows: [Row], id: KeyPath<Row, UUID>) -> [UUID: Row] {
        var map: [UUID: Row] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            map[row[keyPath: id]] = row
        }
        return map
    }

    private static func keyedByString<Row>(_ rows: [Row], id: KeyPath<Row, String>) -> [String: Row] {
        var map: [String: Row] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            map[row[keyPath: id]] = row
        }
        return map
    }

    static func generate(_ input: WarningsComputationInput) -> [Warning] {
        var generated: [Warning] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let coverageStart = cal.startOfDay(for: input.coverageStart)
        let coverageEnd = cal.startOfDay(for: input.coverageEnd)

        let activeBookings = input.bookings.filter { $0.status == .confirmed || $0.status == .tentative }
        let coverageBookings = activeBookings.filter { booking in
            let day = cal.startOfDay(for: booking.date)
            return day >= coverageStart && day <= coverageEnd
        }
        let coverageManagerBookings = input.managerSiteBookings.filter { booking in
            let day = cal.startOfDay(for: booking.date)
            return day >= coverageStart && day <= coverageEnd
        }

        // `projects + smallWorks` can contain the same id twice — never use uniqueKeysWithValues here.
        let projectById = keyedByUUID(input.projects, id: \.id)
        let operativesById = keyedByUUID(input.operatives, id: \.id)
        var operativesByEmail: [String: Operative] = [:]
        operativesByEmail.reserveCapacity(input.operatives.count)
        for op in input.operatives {
            operativesByEmail[op.email.lowercased()] = op
        }
        let usersById = keyedByString(input.users, id: \.id)
        let managerAdminUserIds = Set(input.users.filter { user in
            !user.permissions.operativeMode &&
                (user.permissions.manager || user.permissions.adminAccess || user.role == .admin || user.isSuperAdmin)
        }.map(\.id))

        let scheduleIndex = WarningsScheduleIndex(
            calendar: cal,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            operativeBookings: coverageBookings,
            managerBookings: coverageManagerBookings,
            approvedHolidays: input.holidayBookings.filter { $0.status == .approved }
        )

        let operativeUsers = input.users.filter { $0.permissions.operativeMode && $0.isActive }
        let managerUsers = input.users.filter {
            !$0.permissions.operativeMode && !$0.isSuperAdmin && !$0.permissions.adminAccess
                && $0.permissions.manager && $0.isActive
        }

        func userDisplayName(userId: String) -> String {
            if let u = usersById[userId] {
                return u.fullName.isEmpty ? u.email : u.fullName
            }
            return userId
        }

        // Qualification expiry
        let oneMonthFromNow = cal.date(byAdding: .month, value: 1, to: today) ?? today
        for operative in input.operatives {
            for (qualificationId, expiryDate) in operative.qualificationExpiryDates {
                if expiryDate >= today && expiryDate <= oneMonthFromNow,
                   let qualification = operative.qualifications.first(where: { $0.id == qualificationId }) {
                    let daysUntilExpiry = cal.dateComponents([.day], from: today, to: expiryDate).day ?? 0
                    let severity: Warning.WarningSeverity = daysUntilExpiry <= 7 ? .high : (daysUntilExpiry <= 14 ? .medium : .low)
                    let key = "qual-\(operative.id.uuidString)-\(qualificationId.uuidString)"
                    generated.append(Warning(
                        resolutionKey: key,
                        type: .qualificationExpiry,
                        title: "Qualification expiry",
                        message: "\(operative.name)'s \(qualification.name) expires in \(daysUntilExpiry) day\(daysUntilExpiry == 1 ? "" : "s")",
                        severity: severity,
                        occurrenceDate: expiryDate
                    ))
                }
            }
        }

        // Operative not verified
        for operative in input.operatives {
            if let operativeUser = input.users.first(where: {
                $0.email.lowercased() == operative.email.lowercased() && $0.permissions.operativeMode
            }), !operativeUser.passwordSet {
                let daysSince = workingDaysBetween(operativeUser.createdAt, today, calendar: cal)
                if daysSince >= 3 {
                    let key = "unverified-\(operative.id.uuidString)"
                    generated.append(Warning(
                        resolutionKey: key,
                        type: .operativeNotVerified,
                        title: "Unverified operative",
                        message: "\(operative.name) has not verified their account",
                        severity: .medium,
                        operativeEmail: operative.email
                    ))
                }
            }
        }

        // HIGH: Operative clashes (coverage window only)
        var processedOpClash: Set<String> = []
        for (_, dayBookings) in scheduleIndex.operativeBookingsByDayKey {
            guard dayBookings.count > 1 else { continue }
            let sorted = dayBookings.sorted { $0.id.uuidString < $1.id.uuidString }
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let a = sorted[i]
                    let b = sorted[j]
                    guard OperativeBookingInterval.bookingsOverlap(a, b, policy: input.payrollTimePolicy) else { continue }
                    guard let ia = OperativeBookingInterval.clashInterval(for: a, policy: input.payrollTimePolicy),
                          let ib = OperativeBookingInterval.clashInterval(for: b, policy: input.payrollTimePolicy) else { continue }
                    let pairKey = [a.id.uuidString, b.id.uuidString].sorted().joined(separator: "|")
                    guard processedOpClash.insert(pairKey).inserted else { continue }
                    guard let operative = operativesById[a.operativeId] else { continue }
                    let day = cal.startOfDay(for: a.date)
                    let overlapMin = WarningTimelineMath.overlapMinutes(ia, ib)
                    let (summary, detail) = WarningTimelineMath.formatOverlapSummary(minutes: overlapMin)
                    let pA = projectById[a.projectId]
                    let pB = projectById[b.projectId]
                    let entryA = operativeTimelineEntry(booking: a, project: pA, policy: input.payrollTimePolicy)
                    let entryB = operativeTimelineEntry(booking: b, project: pB, policy: input.payrollTimePolicy)
                    let pALabel = pA?.jobNumber ?? "Job"
                    let pBLabel = pB?.jobNumber ?? "Job"
                    generated.append(Warning(
                        resolutionKey: "op-clash-\(pairKey)",
                        type: .operativeBookingClash,
                        title: "Operative booking clash",
                        message: "\(operative.name) has overlapping operative bookings (\(pALabel) & \(pBLabel)). Remove one booking to clear this warning.",
                        severity: .high,
                        occurrenceDate: day,
                        operativeClash: Warning.OperativeClashWarningDetails(
                            operativeId: operative.id,
                            operativeName: operative.name,
                            date: day,
                            bookingAId: a.id,
                            bookingBId: b.id,
                            entryA: entryA,
                            entryB: entryB,
                            overlapMinutes: overlapMin,
                            overlapSummary: summary,
                            overlapDetail: detail
                        )
                    ))
                }
            }
        }

        // MEDIUM: Manager / admin clashes
        var processedMgrClash: Set<String> = []
        for (_, dayBookings) in scheduleIndex.managerBookingsByDayKey {
            guard dayBookings.count > 1 else { continue }
            let sorted = dayBookings.sorted { $0.id.uuidString < $1.id.uuidString }
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let a = sorted[i]
                    let b = sorted[j]
                    guard managerAdminUserIds.contains(a.userId), managerAdminUserIds.contains(b.userId) else { continue }
                    guard ManagerScheduleInterval.bookingsOverlap(a, b, policy: input.payrollTimePolicy) else { continue }
                    guard let ia = ManagerScheduleInterval.clashInterval(for: a, policy: input.payrollTimePolicy),
                          let ib = ManagerScheduleInterval.clashInterval(for: b, policy: input.payrollTimePolicy) else { continue }
                    let pairKey = [a.id.uuidString, b.id.uuidString].sorted().joined(separator: "|")
                    guard processedMgrClash.insert(pairKey).inserted else { continue }
                    let person = userDisplayName(userId: a.userId)
                    let day = cal.startOfDay(for: a.date)
                    let overlapMin = WarningTimelineMath.overlapMinutes(ia, ib)
                    let (summary, detail) = WarningTimelineMath.formatOverlapSummary(minutes: overlapMin)
                    let entryA = managerTimelineEntry(booking: a, projects: input.projects, policy: input.payrollTimePolicy)
                    let entryB = managerTimelineEntry(booking: b, projects: input.projects, policy: input.payrollTimePolicy)
                    let locA = entryA.locationLabel
                    let locB = entryB.locationLabel
                    let isLocationClash = isOtherLocation(locA) || isOtherLocation(locB)
                    generated.append(Warning(
                        resolutionKey: "mgr-clash-\(pairKey)",
                        type: .managerLocationClash,
                        title: isLocationClash ? "Manager location clash" : "Manager schedule clash",
                        message: "\(person) has overlapping manager/admin bookings (\(locA) & \(locB)). Tick to include on the weekly report if intentional.",
                        severity: .medium,
                        occurrenceDate: day,
                        managerClash: Warning.ManagerClashWarningDetails(
                            userId: a.userId,
                            personName: person,
                            date: day,
                            bookingAId: a.id,
                            bookingBId: b.id,
                            entryA: entryA,
                            entryB: entryB,
                            overlapMinutes: overlapMin,
                            overlapSummary: summary,
                            overlapDetail: detail,
                            isLocationClash: isLocationClash
                        )
                    ))
                }
            }
        }

        // HIGH: Unbooked labour (indexed — one pass per weekday)
        var day = coverageStart
        while day <= coverageEnd {
            let weekday = cal.component(.weekday, from: day)
            if weekday >= 2 && weekday <= 6 {
                let names = scheduleIndex.unbookedNames(
                    on: day,
                    operativeUsers: operativeUsers,
                    managerUsers: managerUsers,
                    operativesByEmail: operativesByEmail,
                    policy: input.payrollTimePolicy
                )
                if !names.isEmpty {
                    generated.append(Warning(
                        resolutionKey: "unbooked-\(day.timeIntervalSince1970)",
                        type: .unbookedLabour,
                        title: "Unbooked labour",
                        message: "\(names.count) \(names.count == 1 ? "person" : "people") unbooked on \(dayFormatter.string(from: day)).",
                        severity: .high,
                        occurrenceDate: day,
                        unbookedLabour: Warning.UnbookedLabourWarningDetails(date: day, names: names)
                    ))
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // LOW: Materials after 16:00
        let hour = cal.component(.hour, from: Date())
        if input.materialOrderCutOffEnabled, hour >= 16 {
            let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
            for project in input.projectsWithTomorrowBookings {
                generated.append(Warning(
                    resolutionKey: "materials-\(project.id.uuidString)-\(tomorrow.timeIntervalSince1970)",
                    type: .materialsCutoff,
                    title: "Material order not placed",
                    message: "Materials for \(project.jobNumber) were not ordered by 16:00 for tomorrow's work.",
                    severity: .low,
                    occurrenceDate: tomorrow,
                    materialsCutoff: Warning.MaterialsCutoffWarningDetails(
                        projectId: project.id,
                        jobNumber: project.jobNumber,
                        siteName: project.siteName,
                        targetDate: tomorrow,
                        itemCount: nil
                    )
                ))
            }
        }

        return generated
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static func workingDaysBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
        var count = 0
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while current <= endDay {
            let w = calendar.component(.weekday, from: current)
            if w >= 2 && w <= 6 { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return count
    }

    private static func isOtherLocation(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("office") || l.contains("working from home") || l.contains("wfh") || l == "site survey"
    }

    private static func operativeTimelineEntry(booking: Booking, project: Project?, policy: OrgPayrollTimePolicy) -> Warning.ClashTimelineEntry {
        let iv = OperativeBookingInterval.clashInterval(for: booking, policy: policy) ?? (0, 8 * 60)
        let hours = booking.paidBookedHours(policy: policy)
        let hStr = ScheduleCoverageFormat.hours(hours)
        return Warning.ClashTimelineEntry(
            bookingId: booking.id,
            managerBookingId: nil,
            jobNumber: project?.jobNumber,
            siteName: project?.siteName,
            isSmallWorks: project?.jobType == .smallWorks,
            locationLabel: project.map { "\($0.jobNumber) \($0.siteName)" } ?? "Project",
            timeLabel: booking.scheduleLabel(policy: policy),
            startMinutes: iv.0,
            endMinutes: iv.1,
            hoursLabel: "\(hStr)h"
        )
    }

    private static func managerTimelineEntry(booking: ManagerSiteBooking, projects: [Project], policy: OrgPayrollTimePolicy) -> Warning.ClashTimelineEntry {
        let iv = ManagerScheduleInterval.clashInterval(for: booking, policy: policy) ?? (0, 8 * 60)
        let hours = booking.paidBookedHours(policy: policy)
        let hStr = ScheduleCoverageFormat.hours(hours)
        var jobNumber: String?
        var siteName: String?
        var isSW = false
        if booking.locationType == .project || booking.locationType == .smallWork,
           let id = booking.locationId,
           let p = projects.first(where: { $0.id == id }) {
            jobNumber = p.jobNumber
            siteName = p.siteName
            isSW = p.jobType == .smallWorks
        }
        let loc: String
        switch booking.locationType {
        case .office: loc = "Office"
        case .workingFromHome: loc = "Working from home"
        case .siteSurvey: loc = "Site survey"
        case .custom:
            let n = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            loc = n.isEmpty ? "Custom" : n
        case .project, .smallWork:
            loc = jobNumber ?? "Site"
        }
        return Warning.ClashTimelineEntry(
            bookingId: UUID(),
            managerBookingId: booking.id,
            jobNumber: jobNumber,
            siteName: siteName,
            isSmallWorks: isSW,
            locationLabel: loc,
            timeLabel: booking.scheduleLabel(policy: policy),
            startMinutes: iv.0,
            endMinutes: iv.1,
            hoursLabel: booking.timeSlot == .fullDay ? "Full day · \(hStr)h" : "\(hStr)h"
        )
    }
}

// MARK: - Schedule index (avoids O(days × users × all bookings))

private struct WarningsScheduleIndex {
    let calendar: Calendar
    let operativeBookingsByDayKey: [String: [Booking]]
    let managerBookingsByDayKey: [String: [ManagerSiteBooking]]
    private let holidayByUserId: [String: [(start: Date, end: Date)]]
    private let holidayByOperativeId: [UUID: [(start: Date, end: Date)]]

    init(
        calendar: Calendar,
        coverageStart: Date,
        coverageEnd: Date,
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        approvedHolidays: [HolidayBooking]
    ) {
        self.calendar = calendar
        var opMap: [String: [Booking]] = [:]
        for booking in operativeBookings {
            let day = calendar.startOfDay(for: booking.date)
            let key = "\(booking.operativeId.uuidString)-\(day.timeIntervalSince1970)"
            opMap[key, default: []].append(booking)
        }
        operativeBookingsByDayKey = opMap

        var mgrMap: [String: [ManagerSiteBooking]] = [:]
        for booking in managerBookings {
            let day = calendar.startOfDay(for: booking.date)
            let key = "\(booking.userId)-\(day.timeIntervalSince1970)"
            mgrMap[key, default: []].append(booking)
        }
        managerBookingsByDayKey = mgrMap

        var byUser: [String: [(Date, Date)]] = [:]
        var byOp: [UUID: [(Date, Date)]] = [:]
        for holiday in approvedHolidays {
            let start = calendar.startOfDay(for: holiday.startDate)
            let end = calendar.startOfDay(for: holiday.endDate)
            if let uid = holiday.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
                byUser[uid, default: []].append((start, end))
            }
            if let oid = holiday.operativeId {
                byOp[oid, default: []].append((start, end))
            }
        }
        holidayByUserId = byUser
        holidayByOperativeId = byOp
    }

    func unbookedNames(
        on day: Date,
        operativeUsers: [AppUser],
        managerUsers: [AppUser],
        operativesByEmail: [String: Operative],
        policy: OrgPayrollTimePolicy
    ) -> [String] {
        let dayStart = calendar.startOfDay(for: day)
        let dayKeySuffix = dayStart.timeIntervalSince1970

        func hasHoliday(userId: String, operativeId: UUID?) -> Bool {
            if let ranges = holidayByUserId[userId], ranges.contains(where: { dayStart >= $0.start && dayStart <= $0.end }) {
                return true
            }
            if let oid = operativeId, let ranges = holidayByOperativeId[oid],
               ranges.contains(where: { dayStart >= $0.start && dayStart <= $0.end }) {
                return true
            }
            return false
        }

        func operativeHasFullDay(_ operativeId: UUID) -> Bool {
            let key = "\(operativeId.uuidString)-\(dayKeySuffix)"
            let dayBookings = operativeBookingsByDayKey[key] ?? []
            if dayBookings.contains(where: { $0.timeSlot == .fullDay }) { return true }
            let hasAM = dayBookings.contains(where: { $0.timeSlot == .morning })
            let hasPM = dayBookings.contains(where: { $0.timeSlot == .afternoon })
            if hasAM && hasPM { return true }
            return dayBookings.contains { OperativeBookingInterval.coversFullStandardDay($0, policy: policy) }
        }

        func managerHasFullDay(_ userId: String) -> Bool {
            let key = "\(userId)-\(dayKeySuffix)"
            let dayMgr = (managerBookingsByDayKey[key] ?? []).filter {
                $0.locationType == .project || $0.locationType == .smallWork
            }
            if dayMgr.contains(where: { $0.timeSlot == .fullDay }) { return true }
            let hasAM = dayMgr.contains(where: { $0.timeSlot == .morning })
            let hasPM = dayMgr.contains(where: { $0.timeSlot == .afternoon })
            if hasAM && hasPM { return true }
            return dayMgr.contains { ManagerScheduleInterval.coversFullStandardDay($0, policy: policy) }
        }

        var names: [String] = []
        names.reserveCapacity(operativeUsers.count + managerUsers.count)

        for user in operativeUsers {
            let linked = operativesByEmail[user.email.lowercased()]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            if let oid = linked?.id, operativeHasFullDay(oid) { continue }
            names.append(linked?.name ?? (user.fullName.isEmpty ? user.email : user.fullName))
        }
        for user in managerUsers {
            if hasHoliday(userId: user.id, operativeId: nil) { continue }
            if managerHasFullDay(user.id) { continue }
            names.append(user.fullName.isEmpty ? user.email : user.fullName)
        }
        return names.sorted()
    }
}
