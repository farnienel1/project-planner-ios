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
    let warningDetection: OrgWarningDetectionSettings
    let coverageStart: Date
    let coverageEnd: Date
    let materialOrderCutOffEnabled: Bool
    let materialCutOffOnSaturday: Bool
    let materialCutOffOnSunday: Bool
    let projectsWithTomorrowBookings: [Project]
    /// Material lines dated for tomorrow (loaded when computing warnings).
    let materialItemsForTomorrow: [MaterialItem]
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
        let managerOrAdminUsers = input.users.filter { user in
            user.isActive &&
                (user.permissions.manager || user.permissions.adminAccess || user.role == .admin || user.isSuperAdmin)
        }
        let managerAdminUserIds = Set(managerOrAdminUsers.map(\.id))

        let scheduleIndex = WarningsScheduleIndex(
            calendar: cal,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            operativeBookings: coverageBookings,
            managerBookings: coverageManagerBookings,
            approvedHolidays: input.holidayBookings.filter { $0.status == .approved }
        )

        let operativeUsers = input.users.filter {
            $0.isActive &&
                $0.permissions.operativeMode &&
                !$0.permissions.manager &&
                !$0.permissions.adminAccess &&
                !$0.isSuperAdmin &&
                $0.role != .admin
        }
        let managerUsers = managerOrAdminUsers

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
        if input.warningDetection.detectClashes {
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
        }

        // MEDIUM: Manager / admin clashes (manager site + project operative bookings for linked accounts)
        if input.warningDetection.detectClashes {
            var processedMgrClash: Set<String> = []
            let managerPersonDays = scheduleIndex.managerPersonDayItems(
                operativeBookings: coverageBookings,
                managerBookings: coverageManagerBookings,
                operativesById: operativesById,
                usersById: usersById,
                managerAdminUserIds: managerAdminUserIds
            )
            for (_, items) in managerPersonDays {
                guard items.count > 1 else { continue }
                let sorted = items.sorted { $0.sortKey < $1.sortKey }
                for i in 0..<sorted.count {
                    for j in (i + 1)..<sorted.count {
                        let a = sorted[i]
                        let b = sorted[j]
                        guard a.userId == b.userId else { continue }
                        // Operative-only pairs are surfaced as operative booking clashes.
                        if a.operativeBooking != nil && b.operativeBooking != nil { continue }
                        guard scheduleIndex.managerPersonItemsOverlap(a, b, policy: input.payrollTimePolicy),
                              let ia = a.clashInterval(policy: input.payrollTimePolicy),
                              let ib = b.clashInterval(policy: input.payrollTimePolicy) else { continue }
                        let pairKey = [a.pairId, b.pairId].sorted().joined(separator: "|")
                        guard processedMgrClash.insert(pairKey).inserted else { continue }
                        let person = userDisplayName(userId: a.userId)
                        let day = cal.startOfDay(for: a.date)
                        let overlapMin = WarningTimelineMath.overlapMinutes(ia, ib)
                        let (summary, detail) = WarningTimelineMath.formatOverlapSummary(minutes: overlapMin)
                        let entryA = a.timelineEntry(projects: input.projects, policy: input.payrollTimePolicy)
                        let entryB = b.timelineEntry(projects: input.projects, policy: input.payrollTimePolicy)
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
                                bookingAId: a.managerBookingId ?? a.operativeBookingId ?? UUID(),
                                bookingBId: b.managerBookingId ?? b.operativeBookingId ?? UUID(),
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
        }

        // HIGH: Unbooked labour (today → coverage end; includes roster operatives without login accounts)
        let activeOperatives = input.operatives.filter(\.isActive)
        let unbookedScanStart = max(coverageStart, today)
        var day = unbookedScanStart
        while day <= coverageEnd {
            let weekday = cal.component(.weekday, from: day)
            if input.warningDetection.isUnbookedLabourWeekday(weekday) {
                let names = scheduleIndex.unbookedNames(
                    on: day,
                    operativeUsers: operativeUsers,
                    managerUsers: managerUsers,
                    rosterOperatives: activeOperatives,
                    operativesByEmail: operativesByEmail,
                    usersById: usersById,
                    policy: input.payrollTimePolicy
                )
                if !names.isEmpty {
                    generated.append(Warning(
                        resolutionKey: "unbooked-\(day.timeIntervalSince1970)",
                        type: .unbookedLabour,
                        title: "Unbooked labour",
                        message: "\(names.count) \(names.count == 1 ? "person is" : "people are") below the standard paid day on \(dayFormatter.string(from: day)). Missing hours are shown per person below.",
                        severity: .high,
                        occurrenceDate: day,
                        unbookedLabour: Warning.UnbookedLabourWarningDetails(date: day, names: names)
                    ))
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // LOW: Materials not ordered by 16:00 (4pm) for tomorrow's work
        let hour = cal.component(.hour, from: Date())
        if input.materialOrderCutOffEnabled, hour >= 16 {
            let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
            let tomorrowWeekday = cal.component(.weekday, from: tomorrow)
            if tomorrowWeekday == 7 && !input.materialCutOffOnSaturday {
                return generated
            }
            if tomorrowWeekday == 1 && !input.materialCutOffOnSunday {
                return generated
            }
            for project in input.projectsWithTomorrowBookings {
                let tomorrowMaterials = input.materialItemsForTomorrow.filter {
                    $0.projectId == project.id && cal.isDate($0.date, inSameDayAs: tomorrow)
                }
                let needsMaterialsWarning: Bool
                if tomorrowMaterials.isEmpty {
                    needsMaterialsWarning = true
                } else {
                    needsMaterialsWarning = tomorrowMaterials.contains { $0.status != .ordered }
                }
                guard needsMaterialsWarning else { continue }
                let notOrderedCount = tomorrowMaterials.filter { $0.status != .ordered }.count
                let message: String
                if tomorrowMaterials.isEmpty {
                    message = "No materials have been ordered for \(project.jobNumber) tomorrow's work (cut-off 16:00)."
                } else {
                    message = "Materials for \(project.jobNumber) were not fully ordered by 16:00 for tomorrow's work (\(notOrderedCount) line\(notOrderedCount == 1 ? "" : "s") still not ordered)."
                }
                generated.append(Warning(
                    resolutionKey: "materials-\(project.id.uuidString)-\(tomorrow.timeIntervalSince1970)",
                    type: .materialsCutoff,
                    title: "Material order not placed",
                    message: message,
                    severity: .low,
                    occurrenceDate: tomorrow,
                    materialsCutoff: Warning.MaterialsCutoffWarningDetails(
                        projectId: project.id,
                        jobNumber: project.jobNumber,
                        siteName: project.siteName,
                        targetDate: tomorrow,
                        itemCount: tomorrowMaterials.isEmpty ? nil : notOrderedCount
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

    fileprivate static func operativeTimelineEntry(booking: Booking, project: Project?, policy: OrgPayrollTimePolicy) -> Warning.ClashTimelineEntry {
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

    fileprivate static func managerTimelineEntry(booking: ManagerSiteBooking, projects: [Project], policy: OrgPayrollTimePolicy) -> Warning.ClashTimelineEntry {
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
        rosterOperatives: [Operative],
        operativesByEmail: [String: Operative],
        usersById: [String: AppUser],
        policy: OrgPayrollTimePolicy
    ) -> [String] {
        let dayStart = calendar.startOfDay(for: day)
        let dayKeySuffix = dayStart.timeIntervalSince1970

        func hasHoliday(userId: String?, operativeId: UUID?) -> Bool {
            if let userId, let ranges = holidayByUserId[userId],
               ranges.contains(where: { dayStart >= $0.start && dayStart <= $0.end }) {
                return true
            }
            if let oid = operativeId, let ranges = holidayByOperativeId[oid],
               ranges.contains(where: { dayStart >= $0.start && dayStart <= $0.end }) {
                return true
            }
            return false
        }

        let requiredPaidHours = max(policy.standardPaidHours, 0)

        func operativePaidTotal(_ operativeId: UUID) -> Double {
            let key = "\(operativeId.uuidString)-\(dayKeySuffix)"
            let dayBookings = operativeBookingsByDayKey[key] ?? []
            return dayBookings.reduce(0.0) { sum, booking in
                sum + booking.paidBookedHours(policy: policy)
            }
        }

        func managerPaidTotal(_ userId: String) -> Double {
            let key = "\(userId)-\(dayKeySuffix)"
            let dayMgr = (managerBookingsByDayKey[key] ?? []).filter {
                $0.locationType == .project || $0.locationType == .smallWork
            }
            return dayMgr.reduce(0.0) { sum, booking in
                sum + booking.paidBookedHours(policy: policy)
            }
        }

        let operativeUserEmails = Set(operativeUsers.map { $0.email.lowercased() })
        var names: [String] = []
        names.reserveCapacity(operativeUsers.count + managerUsers.count + rosterOperatives.count)

        // Operative-mode users (same rules as Daily Overview).
        for user in operativeUsers {
            let linked = operativesByEmail[user.email.lowercased()]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            if let oid = linked?.id {
                let paid = operativePaidTotal(oid) + managerPaidTotal(user.id)
                if paid >= requiredPaidHours { continue }
                let missing = max(0, requiredPaidHours - paid)
                names.append("\(linked!.name) (missing \(ScheduleCoverageFormat.hours(missing))h)")
            } else {
                let paid = managerPaidTotal(user.id)
                if paid >= requiredPaidHours { continue }
                let missing = max(0, requiredPaidHours - paid)
                let display = user.fullName.isEmpty ? user.email : user.fullName
                names.append("\(display) (missing \(ScheduleCoverageFormat.hours(missing))h)")
            }
        }

        // Roster operatives without an operative-mode login (not already counted above).
        for op in rosterOperatives where op.isActive {
            let email = op.email.lowercased()
            guard !operativeUserEmails.contains(email) else { continue }
            let linkedUserId = usersById.values.first(where: { $0.email.lowercased() == email })?.id
            if hasHoliday(userId: linkedUserId, operativeId: op.id) { continue }
            let paid = operativePaidTotal(op.id)
            if paid >= requiredPaidHours { continue }
            let missing = max(0, requiredPaidHours - paid)
            names.append("\(op.name) (missing \(ScheduleCoverageFormat.hours(missing))h)")
        }

        for user in managerUsers {
            let linked = operativesByEmail[user.email.lowercased()]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            let paid = managerPaidTotal(user.id) + (linked.map { operativePaidTotal($0.id) } ?? 0)
            if paid >= requiredPaidHours { continue }
            let missing = max(0, requiredPaidHours - paid)
            let display = user.fullName.isEmpty ? user.email : user.fullName
            names.append("\(display) (missing \(ScheduleCoverageFormat.hours(missing))h)")
        }
        return names.sorted()
    }

    // MARK: - Manager person-day items (site + operative project bookings)

    fileprivate struct ManagerPersonDayItem {
        let userId: String
        let date: Date
        let managerBooking: ManagerSiteBooking?
        let operativeBooking: Booking?
        var managerBookingId: UUID? { managerBooking?.id }
        var operativeBookingId: UUID? { operativeBooking?.id }
        var pairId: String {
            if let m = managerBooking { return "m-\(m.id.uuidString)" }
            if let o = operativeBooking { return "o-\(o.id.uuidString)" }
            return UUID().uuidString
        }
        var sortKey: String { pairId }

        func clashInterval(policy: OrgPayrollTimePolicy) -> (Int, Int)? {
            if let m = managerBooking {
                return ManagerScheduleInterval.clashInterval(for: m, policy: policy)
            }
            if let o = operativeBooking {
                return OperativeBookingInterval.clashInterval(for: o, policy: policy)
            }
            return nil
        }

        func timelineEntry(projects: [Project], policy: OrgPayrollTimePolicy) -> Warning.ClashTimelineEntry {
            if let m = managerBooking {
                return WarningsComputation.managerTimelineEntry(booking: m, projects: projects, policy: policy)
            }
            let o = operativeBooking!
            let p = projects.first(where: { $0.id == o.projectId })
            return WarningsComputation.operativeTimelineEntry(booking: o, project: p, policy: policy)
        }
    }

    func managerPersonDayItems(
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        operativesById: [UUID: Operative],
        usersById: [String: AppUser],
        managerAdminUserIds: Set<String>
    ) -> [String: [ManagerPersonDayItem]] {
        var emailToUserId: [String: String] = [:]
        emailToUserId.reserveCapacity(usersById.count)
        for user in usersById.values where managerAdminUserIds.contains(user.id) {
            emailToUserId[user.email.lowercased()] = user.id
        }

        var map: [String: [ManagerPersonDayItem]] = [:]

        for booking in managerBookings {
            guard managerAdminUserIds.contains(booking.userId) else { continue }
            let day = calendar.startOfDay(for: booking.date)
            let key = "\(booking.userId)-\(day.timeIntervalSince1970)"
            map[key, default: []].append(
                ManagerPersonDayItem(userId: booking.userId, date: day, managerBooking: booking, operativeBooking: nil)
            )
        }

        for booking in operativeBookings {
            guard let op = operativesById[booking.operativeId],
                  let userId = emailToUserId[op.email.lowercased()] else { continue }
            let day = calendar.startOfDay(for: booking.date)
            let key = "\(userId)-\(day.timeIntervalSince1970)"
            map[key, default: []].append(
                ManagerPersonDayItem(userId: userId, date: day, managerBooking: nil, operativeBooking: booking)
            )
        }
        return map
    }

    func managerPersonItemsOverlap(_ a: ManagerPersonDayItem, _ b: ManagerPersonDayItem, policy: OrgPayrollTimePolicy) -> Bool {
        guard let ia = a.clashInterval(policy: policy), let ib = b.clashInterval(policy: policy) else {
            return false
        }
        return OperativeBookingInterval.closedIntervalsOverlap(ia, ib)
    }
}
