//
//  WarningsComputation.swift
//  Project Planner
//
//  Warning generation from main-actor snapshots (Swift 6 safe detached compute).
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

struct WarningsComputationSnapshot: Sendable {
    struct OperativeSnapshot: Sendable {
        struct QualificationExpirySnapshot: Sendable {
            let qualificationId: UUID
            let qualificationName: String
            let expiryDate: Date
        }

        let id: UUID
        let name: String
        let emailLowercased: String
        let isActive: Bool
        let qualificationExpiries: [QualificationExpirySnapshot]
    }

    struct UserSnapshot: Sendable {
        let id: String
        let emailLowercased: String
        let displayName: String
        let isActive: Bool
        let passwordSet: Bool
        let createdAt: Date
        let isOperativeMode: Bool
        let isManager: Bool
        let hasAdminAccess: Bool
        let isSuperAdmin: Bool
        let isAdminRole: Bool
    }

    struct ProjectSnapshot: Sendable {
        let id: UUID
        let jobNumber: String
        let siteName: String
        let isSmallWorks: Bool
    }

    struct OperativeBookingSnapshot: Sendable {
        let id: UUID
        let operativeId: UUID
        let projectId: UUID
        let date: Date
        let dayStart: Date
        let isActiveStatus: Bool
        let paidHours: Double
        let scheduleLabel: String
        let clashInterval: (Int, Int)?
    }

    enum ManagerLocationKind: Sendable {
        case project
        case smallWork
        case office
        case workingFromHome
        case siteSurvey
        case custom
    }

    struct ManagerBookingSnapshot: Sendable {
        let id: UUID
        let userId: String
        let date: Date
        let dayStart: Date
        let isFullDaySlot: Bool
        let locationKind: ManagerLocationKind
        let locationId: UUID?
        let customLocationName: String?
        let isProjectLikeLocation: Bool
        let paidHours: Double
        let scheduleLabel: String
        let clashInterval: (Int, Int)?
    }

    struct HolidaySnapshot: Sendable {
        let userId: String?
        let operativeId: UUID?
        let startDay: Date
        let endDay: Date
        let isApproved: Bool
    }

    struct MaterialItemSnapshot: Sendable {
        let projectId: UUID
        let dayStart: Date
        let isOrdered: Bool
    }

    struct WarningDetectionSnapshot: Sendable {
        let detectClashes: Bool
        let includeWeekendsForUnbookedLabour: Bool
    }

    struct PayrollPolicySnapshot: Sendable {
        let standardPaidHours: Double
    }

    let operatives: [OperativeSnapshot]
    let bookings: [OperativeBookingSnapshot]
    let projects: [ProjectSnapshot]
    let users: [UserSnapshot]
    let managerSiteBookings: [ManagerBookingSnapshot]
    let holidayBookings: [HolidaySnapshot]
    let payrollTimePolicy: PayrollPolicySnapshot
    let warningDetection: WarningDetectionSnapshot
    let coverageStart: Date
    let coverageEnd: Date
    let materialOrderCutOffEnabled: Bool
    let materialCutOffOnSaturday: Bool
    let materialCutOffOnSunday: Bool
    let projectsWithTomorrowBookingIds: [UUID]
    let materialItemsForTomorrow: [MaterialItemSnapshot]
}

enum WarningsComputation {
    @MainActor
    static func makeSnapshot(from input: WarningsComputationInput) -> WarningsComputationSnapshot {
        let cal = Calendar.current

        let operatives: [WarningsComputationSnapshot.OperativeSnapshot] = input.operatives.map { operative in
            let qualificationNames: [UUID: String] = operative.qualifications.reduce(into: [:]) { acc, q in
                acc[q.id] = q.name
            }
            var qualificationExpiries: [WarningsComputationSnapshot.OperativeSnapshot.QualificationExpirySnapshot] = []
            qualificationExpiries.reserveCapacity(operative.qualificationExpiryDates.count)
            for pair in operative.qualificationExpiryDates {
                let qualificationId = pair.key
                let expiryDate = pair.value
                guard let qualificationName = qualificationNames[qualificationId] else { continue }
                qualificationExpiries.append(
                    WarningsComputationSnapshot.OperativeSnapshot.QualificationExpirySnapshot(
                        qualificationId: qualificationId,
                        qualificationName: qualificationName,
                        expiryDate: expiryDate
                    )
                )
            }
            return WarningsComputationSnapshot.OperativeSnapshot(
                id: operative.id,
                name: operative.name,
                emailLowercased: operative.email.lowercased(),
                isActive: operative.isActive,
                qualificationExpiries: qualificationExpiries
            )
        }

        let users: [WarningsComputationSnapshot.UserSnapshot] = input.users.map { user in
            WarningsComputationSnapshot.UserSnapshot(
                id: user.id,
                emailLowercased: user.email.lowercased(),
                displayName: user.fullName.isEmpty ? user.email : user.fullName,
                isActive: user.isActive,
                passwordSet: user.passwordSet,
                createdAt: user.createdAt,
                isOperativeMode: user.permissions.operativeMode,
                isManager: user.permissions.manager,
                hasAdminAccess: user.permissions.adminAccess,
                isSuperAdmin: user.isSuperAdmin,
                isAdminRole: user.role == .admin
            )
        }

        let projects: [WarningsComputationSnapshot.ProjectSnapshot] = input.projects.map { project in
            WarningsComputationSnapshot.ProjectSnapshot(
                id: project.id,
                jobNumber: project.jobNumber,
                siteName: project.siteName,
                isSmallWorks: project.jobType == .smallWorks
            )
        }

        let bookings: [WarningsComputationSnapshot.OperativeBookingSnapshot] = input.bookings.map { booking in
            WarningsComputationSnapshot.OperativeBookingSnapshot(
                id: booking.id,
                operativeId: booking.operativeId,
                projectId: booking.projectId,
                date: booking.date,
                dayStart: cal.startOfDay(for: booking.date),
                isActiveStatus: booking.status == .confirmed || booking.status == .tentative,
                paidHours: booking.paidBookedHours(policy: input.payrollTimePolicy),
                scheduleLabel: booking.scheduleLabel(policy: input.payrollTimePolicy),
                clashInterval: OperativeBookingInterval.clashInterval(for: booking, policy: input.payrollTimePolicy)
            )
        }

        let managerSiteBookings: [WarningsComputationSnapshot.ManagerBookingSnapshot] = input.managerSiteBookings.map { booking in
            let locationKind: WarningsComputationSnapshot.ManagerLocationKind
            switch booking.locationType {
            case .project:
                locationKind = .project
            case .smallWork:
                locationKind = .smallWork
            case .office:
                locationKind = .office
            case .workingFromHome:
                locationKind = .workingFromHome
            case .siteSurvey:
                locationKind = .siteSurvey
            case .custom:
                locationKind = .custom
            }
            return WarningsComputationSnapshot.ManagerBookingSnapshot(
                id: booking.id,
                userId: booking.userId,
                date: booking.date,
                dayStart: cal.startOfDay(for: booking.date),
                isFullDaySlot: booking.timeSlot == .fullDay,
                locationKind: locationKind,
                locationId: booking.locationId,
                customLocationName: booking.customLocationName,
                isProjectLikeLocation: booking.locationType == .project || booking.locationType == .smallWork,
                paidHours: booking.paidBookedHours(policy: input.payrollTimePolicy),
                scheduleLabel: booking.scheduleLabel(policy: input.payrollTimePolicy),
                clashInterval: ManagerScheduleInterval.clashInterval(for: booking, policy: input.payrollTimePolicy)
            )
        }

        let holidayBookings: [WarningsComputationSnapshot.HolidaySnapshot] = input.holidayBookings.map { booking in
            WarningsComputationSnapshot.HolidaySnapshot(
                userId: booking.userId?.trimmingCharacters(in: .whitespacesAndNewlines),
                operativeId: booking.operativeId,
                startDay: cal.startOfDay(for: booking.startDate),
                endDay: cal.startOfDay(for: booking.endDate),
                isApproved: booking.status == .approved
            )
        }

        let materialItemsForTomorrow: [WarningsComputationSnapshot.MaterialItemSnapshot] = input.materialItemsForTomorrow.map { item in
            WarningsComputationSnapshot.MaterialItemSnapshot(
                projectId: item.projectId,
                dayStart: cal.startOfDay(for: item.date),
                isOrdered: item.status == .ordered
            )
        }

        return WarningsComputationSnapshot(
            operatives: operatives,
            bookings: bookings,
            projects: projects,
            users: users,
            managerSiteBookings: managerSiteBookings,
            holidayBookings: holidayBookings,
            payrollTimePolicy: .init(standardPaidHours: input.payrollTimePolicy.standardPaidHours),
            warningDetection: .init(
                detectClashes: input.warningDetection.detectClashes,
                includeWeekendsForUnbookedLabour: input.warningDetection.includeWeekendsForUnbookedLabour
            ),
            coverageStart: cal.startOfDay(for: input.coverageStart),
            coverageEnd: cal.startOfDay(for: input.coverageEnd),
            materialOrderCutOffEnabled: input.materialOrderCutOffEnabled,
            materialCutOffOnSaturday: input.materialCutOffOnSaturday,
            materialCutOffOnSunday: input.materialCutOffOnSunday,
            projectsWithTomorrowBookingIds: input.projectsWithTomorrowBookings.map(\.id),
            materialItemsForTomorrow: materialItemsForTomorrow
        )
    }

    nonisolated private static func keyedByUUID<Row>(_ rows: [Row], id: KeyPath<Row, UUID>) -> [UUID: Row] {
        var map: [UUID: Row] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            map[row[keyPath: id]] = row
        }
        return map
    }

    nonisolated private static func keyedByString<Row>(_ rows: [Row], id: KeyPath<Row, String>) -> [String: Row] {
        var map: [String: Row] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            map[row[keyPath: id]] = row
        }
        return map
    }

    nonisolated static func generate(_ input: WarningsComputationSnapshot) -> [Warning] {
        var generated: [Warning] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let coverageStart = cal.startOfDay(for: input.coverageStart)
        let coverageEnd = cal.startOfDay(for: input.coverageEnd)

        let activeBookings = input.bookings.filter(\.isActiveStatus)
        let coverageBookings = activeBookings.filter { booking in
            let day = booking.dayStart
            return day >= coverageStart && day <= coverageEnd
        }
        let coverageManagerBookings = input.managerSiteBookings.filter { booking in
            let day = booking.dayStart
            return day >= coverageStart && day <= coverageEnd
        }

        let projectById = keyedByUUID(input.projects, id: \.id)
        let operativesById = keyedByUUID(input.operatives, id: \.id)
        var operativesByEmail: [String: WarningsComputationSnapshot.OperativeSnapshot] = [:]
        operativesByEmail.reserveCapacity(input.operatives.count)
        for op in input.operatives {
            operativesByEmail[op.emailLowercased] = op
        }
        let usersById = keyedByString(input.users, id: \.id)
        let managerOrAdminUsers = input.users.filter { user in
            user.isActive &&
                (user.isManager || user.hasAdminAccess || user.isAdminRole || user.isSuperAdmin)
        }
        let managerAdminUserIds = Set(managerOrAdminUsers.map(\.id))

        let scheduleIndex = WarningsScheduleIndex(
            calendar: cal,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            operativeBookings: coverageBookings,
            managerBookings: coverageManagerBookings,
            approvedHolidays: input.holidayBookings.filter(\.isApproved)
        )

        let operativeUsers = input.users.filter {
            $0.isActive &&
                $0.isOperativeMode &&
                !$0.isManager &&
                !$0.hasAdminAccess &&
                !$0.isSuperAdmin &&
                !$0.isAdminRole
        }
        let managerUsers = managerOrAdminUsers

        let oneMonthFromNow = cal.date(byAdding: .month, value: 1, to: today) ?? today
        for operative in input.operatives {
            for expiry in operative.qualificationExpiries {
                let expiryDate = expiry.expiryDate
                if expiryDate >= today && expiryDate <= oneMonthFromNow {
                    let daysUntilExpiry = cal.dateComponents([.day], from: today, to: expiryDate).day ?? 0
                    let severity: Warning.WarningSeverity = daysUntilExpiry <= 7 ? .high : (daysUntilExpiry <= 14 ? .medium : .low)
                    let key = "qual-\(operative.id.uuidString)-\(expiry.qualificationId.uuidString)"
                    generated.append(Warning(
                        resolutionKey: key,
                        type: .qualificationExpiry,
                        title: "Qualification expiry",
                        message: "\(operative.name)'s \(expiry.qualificationName) expires in \(daysUntilExpiry) day\(daysUntilExpiry == 1 ? "" : "s")",
                        severity: severity,
                        occurrenceDate: expiryDate
                    ))
                }
            }
        }

        for operative in input.operatives {
            if let operativeUser = input.users.first(where: {
                $0.emailLowercased == operative.emailLowercased && $0.isOperativeMode
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
                        operativeEmail: operativeUser.emailLowercased
                    ))
                }
            }
        }

        var processedOpClash: Set<String> = []
        if input.warningDetection.detectClashes {
            for (_, dayBookings) in scheduleIndex.operativeBookingsByDayKey {
                guard dayBookings.count > 1 else { continue }
                let sorted = dayBookings.sorted { $0.id.uuidString < $1.id.uuidString }
                for i in 0..<sorted.count {
                    for j in (i + 1)..<sorted.count {
                        let a = sorted[i]
                        let b = sorted[j]
                        guard let ia = a.clashInterval, let ib = b.clashInterval, intervalsOverlap(ia, ib) else { continue }
                        let pairKey = [a.id.uuidString, b.id.uuidString].sorted().joined(separator: "|")
                        guard processedOpClash.insert(pairKey).inserted else { continue }
                        guard let operative = operativesById[a.operativeId] else { continue }
                        let day = a.dayStart
                        let overlapMin = overlapMinutes(ia, ib)
                        let (summary, detail) = formatOverlapSummary(minutes: overlapMin)
                        let pA = projectById[a.projectId]
                        let pB = projectById[b.projectId]
                        let entryA = operativeTimelineEntry(booking: a, project: pA)
                        let entryB = operativeTimelineEntry(booking: b, project: pB)
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
                        if a.operativeBooking != nil && b.operativeBooking != nil { continue }
                        guard scheduleIndex.managerPersonItemsOverlap(a, b),
                              let ia = a.clashInterval,
                              let ib = b.clashInterval else { continue }
                        let pairKey = [a.pairId, b.pairId].sorted().joined(separator: "|")
                        guard processedMgrClash.insert(pairKey).inserted else { continue }
                        let person = usersById[a.userId]?.displayName ?? a.userId
                        let day = a.date
                        let overlapMin = overlapMinutes(ia, ib)
                        let (summary, detail) = formatOverlapSummary(minutes: overlapMin)
                        let entryA = a.timelineEntry(projectsById: projectById)
                        let entryB = b.timelineEntry(projectsById: projectById)
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
                                bookingAId: a.bookingId,
                                bookingBId: b.bookingId,
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

        let activeOperatives = input.operatives.filter(\.isActive)
        let unbookedScanStart = max(coverageStart, today)
        var day = unbookedScanStart
        while day <= coverageEnd {
            let weekday = cal.component(.weekday, from: day)
            if isUnbookedLabourWeekday(weekday, includeWeekends: input.warningDetection.includeWeekendsForUnbookedLabour) {
                let names = scheduleIndex.unbookedNames(
                    on: day,
                    operativeUsers: operativeUsers,
                    managerUsers: managerUsers,
                    rosterOperatives: activeOperatives,
                    operativesByEmail: operativesByEmail,
                    usersById: usersById,
                    standardPaidHours: input.payrollTimePolicy.standardPaidHours
                )
                if !names.isEmpty {
                    generated.append(Warning(
                        resolutionKey: "unbooked-\(day.timeIntervalSince1970)",
                        type: .unbookedLabour,
                        title: "Unbooked labour", message: "\(names.count) \(names.count == 1 ? "person is" : "people are") below the standard paid day on \(formatDay(day)). Missing hours are shown per person below.",
                        severity: .high,
                        occurrenceDate: day,
                        unbookedLabour: Warning.UnbookedLabourWarningDetails(date: day, names: names)
                    ))
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

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
            for projectId in input.projectsWithTomorrowBookingIds {
                guard let project = projectById[projectId] else { continue }
                let tomorrowMaterials = input.materialItemsForTomorrow.filter {
                    $0.projectId == project.id && $0.dayStart == tomorrow
                }
                let needsMaterialsWarning: Bool
                if tomorrowMaterials.isEmpty {
                    needsMaterialsWarning = true
                } else {
                    needsMaterialsWarning = tomorrowMaterials.contains { !$0.isOrdered }
                }
                guard needsMaterialsWarning else { continue }
                let notOrderedCount = tomorrowMaterials.filter { !$0.isOrdered }.count
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

    nonisolated private static func workingDaysBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
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

    nonisolated private static func isUnbookedLabourWeekday(_ weekday: Int, includeWeekends: Bool) -> Bool {
        if includeWeekends {
            return weekday >= 1 && weekday <= 7
        }
        return weekday >= 2 && weekday <= 6
    }

    nonisolated private static func formatDay(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    nonisolated private static func isOtherLocation(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("office") || l.contains("working from home") || l.contains("wfh") || l == "site survey"
    }

    nonisolated fileprivate static func intervalsOverlap(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        a.0 < b.1 && b.0 < a.1
    }

    nonisolated private static func overlapMinutes(_ a: (Int, Int), _ b: (Int, Int)) -> Int {
        let start = max(a.0, b.0)
        let end = min(a.1, b.1)
        return max(0, end - start)
    }

    nonisolated private static func formatOverlapSummary(minutes: Int) -> (summary: String, detail: String) {
        let dayMinutes = 24 * 60
        if minutes >= dayMinutes - 30 {
            return ("Whole day clash", "Two locations booked at the same time")
        }
        let hours = Double(minutes) / 60.0
        let formattedHours: String
        if abs(hours - hours.rounded()) < 0.05 {
            formattedHours = String(format: "%.0f", hours.rounded())
        } else {
            formattedHours = String(format: "%.1f", hours)
        }
        return ("\(formattedHours)-hour overlap", "Both bookings active during the overlapping period")
    }

    nonisolated fileprivate static func formatHours(_ h: Double) -> String {
        let rounded = (h * 2).rounded() / 2
        if abs(rounded - rounded.rounded(.towardZero)) < 0.01 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    nonisolated fileprivate static func operativeTimelineEntry(
        booking: WarningsComputationSnapshot.OperativeBookingSnapshot,
        project: WarningsComputationSnapshot.ProjectSnapshot?
    ) -> Warning.ClashTimelineEntry {
        let iv = booking.clashInterval ?? (0, 8 * 60)
        let hStr = formatHours(booking.paidHours)
        return Warning.ClashTimelineEntry(
            bookingId: booking.id,
            managerBookingId: nil,
            jobNumber: project?.jobNumber,
            siteName: project?.siteName,
            isSmallWorks: project?.isSmallWorks ?? false,
            locationLabel: project.map { "\($0.jobNumber) \($0.siteName)" } ?? "Project",
            timeLabel: booking.scheduleLabel,
            startMinutes: iv.0,
            endMinutes: iv.1,
            hoursLabel: "\(hStr)h"
        )
    }

    nonisolated fileprivate static func managerTimelineEntry(
        booking: WarningsComputationSnapshot.ManagerBookingSnapshot,
        projectsById: [UUID: WarningsComputationSnapshot.ProjectSnapshot]
    ) -> Warning.ClashTimelineEntry {
        let iv = booking.clashInterval ?? (0, 8 * 60)
        let hStr = formatHours(booking.paidHours)
        var jobNumber: String?
        var siteName: String?
        var isSW = false
        switch booking.locationKind {
        case .project, .smallWork:
            if let id = booking.locationId, let p = projectsById[id] {
                jobNumber = p.jobNumber
                siteName = p.siteName
                isSW = p.isSmallWorks
            }
        case .office, .workingFromHome, .siteSurvey, .custom:
            break
        }
        let loc: String
        switch booking.locationKind {
        case .office:
            loc = "Office"
        case .workingFromHome:
            loc = "Working from home"
        case .siteSurvey:
            loc = "Site survey"
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
            timeLabel: booking.scheduleLabel,
            startMinutes: iv.0,
            endMinutes: iv.1,
            hoursLabel: booking.isFullDaySlot ? "Full day · \(hStr)h" : "\(hStr)h"
        )
    }
}

private struct WarningsScheduleIndex {
    let calendar: Calendar
    let operativeBookingsByDayKey: [String: [WarningsComputationSnapshot.OperativeBookingSnapshot]]
    let managerBookingsByDayKey: [String: [WarningsComputationSnapshot.ManagerBookingSnapshot]]
    private let holidayByUserId: [String: [(start: Date, end: Date)]]
    private let holidayByOperativeId: [UUID: [(start: Date, end: Date)]]

    nonisolated init(
        calendar: Calendar,
        coverageStart: Date,
        coverageEnd: Date,
        operativeBookings: [WarningsComputationSnapshot.OperativeBookingSnapshot],
        managerBookings: [WarningsComputationSnapshot.ManagerBookingSnapshot],
        approvedHolidays: [WarningsComputationSnapshot.HolidaySnapshot]
    ) {
        self.calendar = calendar
        var opMap: [String: [WarningsComputationSnapshot.OperativeBookingSnapshot]] = [:]
        for booking in operativeBookings {
            let day = booking.dayStart
            guard day >= coverageStart && day <= coverageEnd else { continue }
            let key = "\(booking.operativeId.uuidString)-\(day.timeIntervalSince1970)"
            opMap[key, default: []].append(booking)
        }
        operativeBookingsByDayKey = opMap

        var mgrMap: [String: [WarningsComputationSnapshot.ManagerBookingSnapshot]] = [:]
        for booking in managerBookings {
            let day = booking.dayStart
            guard day >= coverageStart && day <= coverageEnd else { continue }
            let key = "\(booking.userId)-\(day.timeIntervalSince1970)"
            mgrMap[key, default: []].append(booking)
        }
        managerBookingsByDayKey = mgrMap

        var byUser: [String: [(Date, Date)]] = [:]
        var byOp: [UUID: [(Date, Date)]] = [:]
        for holiday in approvedHolidays {
            let start = holiday.startDay
            let end = holiday.endDay
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

    nonisolated func unbookedNames(
        on day: Date,
        operativeUsers: [WarningsComputationSnapshot.UserSnapshot],
        managerUsers: [WarningsComputationSnapshot.UserSnapshot],
        rosterOperatives: [WarningsComputationSnapshot.OperativeSnapshot],
        operativesByEmail: [String: WarningsComputationSnapshot.OperativeSnapshot],
        usersById: [String: WarningsComputationSnapshot.UserSnapshot],
        standardPaidHours: Double
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

        let requiredPaidHours = max(standardPaidHours, 0)

        func operativePaidTotal(_ operativeId: UUID) -> Double {
            let key = "\(operativeId.uuidString)-\(dayKeySuffix)"
            let dayBookings = operativeBookingsByDayKey[key] ?? []
            return dayBookings.reduce(0.0) { sum, booking in
                sum + booking.paidHours
            }
        }

        func managerPaidTotal(_ userId: String) -> Double {
            let key = "\(userId)-\(dayKeySuffix)"
            let dayMgr = managerBookingsByDayKey[key] ?? []
            return dayMgr.reduce(0.0) { sum, booking in
                sum + booking.paidHours
            }
        }

        let operativeUserEmails = Set(operativeUsers.map(\.emailLowercased))
        var names: [String] = []
        names.reserveCapacity(operativeUsers.count + managerUsers.count + rosterOperatives.count)

        for user in operativeUsers {
            let linked = operativesByEmail[user.emailLowercased]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            if let oid = linked?.id {
                let paid = operativePaidTotal(oid) + managerPaidTotal(user.id)
                if paid >= requiredPaidHours { continue }
                let missing = max(0, requiredPaidHours - paid)
                names.append("\(linked!.name) (missing \(WarningsComputation.formatHours(missing))h)")
            } else {
                let paid = managerPaidTotal(user.id)
                if paid >= requiredPaidHours { continue }
                let missing = max(0, requiredPaidHours - paid)
                names.append("\(user.displayName) (missing \(WarningsComputation.formatHours(missing))h)")
            }
        }

        for op in rosterOperatives where op.isActive {
            let email = op.emailLowercased
            guard !operativeUserEmails.contains(email) else { continue }
            let linkedUserId = usersById.values.first(where: { $0.emailLowercased == email })?.id
            if hasHoliday(userId: linkedUserId, operativeId: op.id) { continue }
            let paid = operativePaidTotal(op.id)
            if paid >= requiredPaidHours { continue }
            let missing = max(0, requiredPaidHours - paid)
            names.append("\(op.name) (missing \(WarningsComputation.formatHours(missing))h)")
        }

        for user in managerUsers {
            let linked = operativesByEmail[user.emailLowercased]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            let paid = managerPaidTotal(user.id) + (linked.map { operativePaidTotal($0.id) } ?? 0)
            if paid >= requiredPaidHours { continue }
            let missing = max(0, requiredPaidHours - paid)
            names.append("\(user.displayName) (missing \(WarningsComputation.formatHours(missing))h)")
        }
        return names.sorted()
    }

    fileprivate struct ManagerPersonDayItem {
        let userId: String
        let date: Date
        let managerBooking: WarningsComputationSnapshot.ManagerBookingSnapshot?
        let operativeBooking: WarningsComputationSnapshot.OperativeBookingSnapshot?
        nonisolated var bookingId: UUID { managerBooking?.id ?? operativeBooking?.id ?? UUID() }
        nonisolated var clashInterval: (Int, Int)? { managerBooking?.clashInterval ?? operativeBooking?.clashInterval }
        nonisolated var pairId: String {
            if let m = managerBooking { return "m-\(m.id.uuidString)" }
            if let o = operativeBooking { return "o-\(o.id.uuidString)" }
            return "unknown-\(userId)-\(date.timeIntervalSince1970)"
        }
        nonisolated var sortKey: String { pairId }

        nonisolated func timelineEntry(projectsById: [UUID: WarningsComputationSnapshot.ProjectSnapshot]) -> Warning.ClashTimelineEntry {
            if let managerBooking {
                return WarningsComputation.managerTimelineEntry(booking: managerBooking, projectsById: projectsById)
            }
            if let operativeBooking {
                let project = projectsById[operativeBooking.projectId]
                return WarningsComputation.operativeTimelineEntry(booking: operativeBooking, project: project)
            }
            return Warning.ClashTimelineEntry(
                bookingId: UUID(),
                managerBookingId: nil,
                jobNumber: nil,
                siteName: nil,
                isSmallWorks: false,
                locationLabel: "Unknown",
                timeLabel: "Unknown",
                startMinutes: 0,
                endMinutes: 0,
                hoursLabel: "0h"
            )
        }
    }

    nonisolated func managerPersonDayItems(
        operativeBookings: [WarningsComputationSnapshot.OperativeBookingSnapshot],
        managerBookings: [WarningsComputationSnapshot.ManagerBookingSnapshot],
        operativesById: [UUID: WarningsComputationSnapshot.OperativeSnapshot],
        usersById: [String: WarningsComputationSnapshot.UserSnapshot],
        managerAdminUserIds: Set<String>
    ) -> [String: [ManagerPersonDayItem]] {
        var emailToUserId: [String: String] = [:]
        emailToUserId.reserveCapacity(usersById.count)
        for user in usersById.values where managerAdminUserIds.contains(user.id) {
            emailToUserId[user.emailLowercased] = user.id
        }

        var map: [String: [ManagerPersonDayItem]] = [:]

        for booking in managerBookings {
            guard managerAdminUserIds.contains(booking.userId) else { continue }
            let day = booking.dayStart
            let key = "\(booking.userId)-\(day.timeIntervalSince1970)"
            map[key, default: []].append(
                ManagerPersonDayItem(userId: booking.userId, date: day, managerBooking: booking, operativeBooking: nil)
            )
        }

        for booking in operativeBookings {
            guard let op = operativesById[booking.operativeId],
                  let userId = emailToUserId[op.emailLowercased] else { continue }
            let day = booking.dayStart
            let key = "\(userId)-\(day.timeIntervalSince1970)"
            map[key, default: []].append(
                ManagerPersonDayItem(userId: userId, date: day, managerBooking: nil, operativeBooking: booking)
            )
        }
        return map
    }

    nonisolated func managerPersonItemsOverlap(_ a: ManagerPersonDayItem, _ b: ManagerPersonDayItem) -> Bool {
        guard let ia = a.clashInterval, let ib = b.clashInterval else {
            return false
        }
        return WarningsComputation.intervalsOverlap(ia, ib)
    }
}
