//
//  WarningsComputation.swift
//  Project Planner
//
//  Warning generation from main-actor snapshots (Swift 6 safe detached compute).
//

import Foundation

// The scan window is CanonicalBusinessEngine.warningBounds (lib/canonical).
// Qualification, unverified, unbooked, and annual-leave rows come from that script.
// Clash timelines and material cut-off copy stay here, on the London business calendar.

struct WarningsComputationInput: @unchecked Sendable {
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
    var dismissedQualificationKeys: Set<String> = []
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
        var isPlaceholder: Bool = false
        var profileWeight: Int = 0
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
        var sameEmailUserIds: [String] = []
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
        /// Raw slot label for the shared script (`AM`, `PM`, `FULL DAY`, `CUSTOM_HOURS`).
        let timeSlot: String
        let workStart: String?
        let workEnd: String?
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
        let isBreakRemoved: Bool
        let hasCustomClockTimes: Bool
        let locationKind: ManagerLocationKind
        let locationId: UUID?
        let customLocationName: String?
        let isProjectLikeLocation: Bool
        let paidHours: Double
        let scheduleLabel: String
        let clashInterval: (Int, Int)?
        let timeSlot: String
        let workStart: String?
        let workEnd: String?
    }

    struct HolidaySnapshot: Sendable {
        let id: String
        let userId: String?
        let operativeId: UUID?
        let startDay: Date
        let endDay: Date
        let isApproved: Bool
        /// `FULL DAY`, `AM`, or `PM`. The script decides whether that is a clash or an open half.
        let timeSlot: String
    }

    struct MaterialItemSnapshot: Sendable {
        let projectId: UUID
        let dayStart: Date
        let isOrdered: Bool
    }

    struct WarningDetectionSnapshot: Sendable {
        let detectClashes: Bool
        let includeWeekendsForUnbookedLabour: Bool
        let excludedUserIdsFromUnbookedWarnings: Set<String>
    }

    struct PayrollPolicySnapshot: Sendable {
        let standardPaidHours: Double
        let standardDayStart: String
        let standardDayEnd: String
        let breakWindowStart: String
        let breakWindowEnd: String
        let standardUnpaidBreakHours: Double
        let saturdayCountsAsHours: Double
        let sundayCountsAsHours: Double
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
    /// Document ids from `organizations/{orgId}/dismissedWarnings`.
    var dismissedQualificationKeys: Set<String> = []
}

enum WarningsComputation {
    /// Builds the sendable snapshot on the MainActor.
    /// With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, model types/methods are
    /// MainActor-isolated — this must not be `nonisolated`. Callers should window
    /// bookings first; only `generate` runs in `Task.detached`.
    @MainActor
    static func makeSnapshot(from input: WarningsComputationInput) -> WarningsComputationSnapshot {
        let cal = CanonicalBusinessEngine.businessCalendar

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
            let foldedName = operative.name.lowercased()
            let foldedEmail = operative.email.lowercased()
            return WarningsComputationSnapshot.OperativeSnapshot(
                id: operative.id,
                name: operative.name,
                emailLowercased: operative.email.lowercased(),
                isActive: operative.isActive,
                qualificationExpiries: qualificationExpiries,
                isPlaceholder: foldedName.contains("placeholder") || foldedEmail.contains("placeholder") || foldedName.contains("initial"),
                profileWeight: operative.qualifications.count + operative.qualificationCertificateURLs.count + operative.qualificationExpiryDates.count
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
                isAdminRole: user.role == .admin,
                sameEmailUserIds: user.sameEmailUserIds
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
                clashInterval: OperativeBookingInterval.clashInterval(for: booking, policy: input.payrollTimePolicy),
                timeSlot: booking.timeSlot.rawValue,
                workStart: booking.workStartTime,
                workEnd: booking.workEndTime
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
                isBreakRemoved: booking.isBreakRemoved,
                hasCustomClockTimes: {
                    let s = booking.workStartTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let e = booking.workEndTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return !s.isEmpty && !e.isEmpty
                }(),
                locationKind: locationKind,
                locationId: booking.locationId,
                customLocationName: booking.customLocationName,
                isProjectLikeLocation: booking.locationType == .project || booking.locationType == .smallWork,
                paidHours: booking.paidBookedHours(policy: input.payrollTimePolicy),
                scheduleLabel: booking.scheduleLabel(policy: input.payrollTimePolicy),
                clashInterval: ManagerScheduleInterval.clashInterval(for: booking, policy: input.payrollTimePolicy),
                timeSlot: booking.timeSlot.rawValue,
                workStart: booking.workStartTime,
                workEnd: booking.workEndTime
            )
        }

        let holidayBookings: [WarningsComputationSnapshot.HolidaySnapshot] = input.holidayBookings.map { booking in
            let rawUserId = booking.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedUserId: String? = {
                guard let rawUserId, !rawUserId.isEmpty else { return nil }
                if let user = input.users.first(where: { $0.id.caseInsensitiveCompare(rawUserId) == .orderedSame }) {
                    return user.id
                }
                if rawUserId.contains("@"),
                   let user = input.users.first(where: { $0.email.caseInsensitiveCompare(rawUserId) == .orderedSame }) {
                    return user.id
                }
                return rawUserId
            }()
            return WarningsComputationSnapshot.HolidaySnapshot(
                id: booking.id.uuidString,
                userId: resolvedUserId,
                operativeId: booking.operativeId,
                startDay: cal.startOfDay(for: booking.startDate),
                endDay: cal.startOfDay(for: booking.endDate),
                isApproved: booking.status == .approved,
                timeSlot: booking.timeSlot.rawValue
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
            payrollTimePolicy: .init(
                standardPaidHours: input.payrollTimePolicy.standardPaidHours,
                standardDayStart: input.payrollTimePolicy.standardDayStart,
                standardDayEnd: input.payrollTimePolicy.standardDayEnd,
                breakWindowStart: input.payrollTimePolicy.breakWindowStart,
                breakWindowEnd: input.payrollTimePolicy.breakWindowEnd,
                standardUnpaidBreakHours: input.payrollTimePolicy.standardUnpaidBreakHours,
                saturdayCountsAsHours: input.payrollTimePolicy.saturday.resolvedCountsAsHours(
                    fallback: input.payrollTimePolicy.standardPaidHours
                ),
                sundayCountsAsHours: PayrollTimePolicyCatalog.resolvedSundaySettings(from: input.payrollTimePolicy)
                    .resolvedCountsAsHours(fallback: input.payrollTimePolicy.standardPaidHours)
            ),
            warningDetection: .init(
                detectClashes: input.warningDetection.detectClashes,
                includeWeekendsForUnbookedLabour: input.warningDetection.includeWeekendsForUnbookedLabour,
                excludedUserIdsFromUnbookedWarnings: Set(input.warningDetection.excludedUserIdsFromUnbookedWarnings)
            ),
            coverageStart: cal.startOfDay(for: input.coverageStart),
            coverageEnd: cal.startOfDay(for: input.coverageEnd),
            materialOrderCutOffEnabled: input.materialOrderCutOffEnabled,
            materialCutOffOnSaturday: input.materialCutOffOnSaturday,
            materialCutOffOnSunday: input.materialCutOffOnSunday,
            projectsWithTomorrowBookingIds: input.projectsWithTomorrowBookings.map(\.id),
            materialItemsForTomorrow: materialItemsForTomorrow,
            dismissedQualificationKeys: input.dismissedQualificationKeys
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
        let cal = CanonicalBusinessEngine.businessCalendar
        let now = Date()
        let today = cal.startOfDay(for: now)
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

        if let rows = qualificationRows(input, reference: now, dismissedKeys: input.dismissedQualificationKeys) {
            for row in rows {
                generated.append(row)
            }
        } else {
            let oneMonthFromNow = cal.date(byAdding: .month, value: 1, to: today) ?? today
            for operative in input.operatives where operative.isActive {
                for expiry in operative.qualificationExpiries {
                    let expiryDate = expiry.expiryDate
                    guard expiryDate <= oneMonthFromNow else { continue }
                    let daysUntilExpiry = cal.dateComponents([.day], from: today, to: expiryDate).day ?? 0
                    let message: String
                    if daysUntilExpiry < 0 {
                        let ago = abs(daysUntilExpiry)
                        message = "\(operative.name)'s \(expiry.qualificationName) expired \(ago) day\(ago == 1 ? "" : "s") ago"
                    } else if daysUntilExpiry == 0 {
                        message = "\(operative.name)'s \(expiry.qualificationName) expires today"
                    } else {
                        message = "\(operative.name)'s \(expiry.qualificationName) expires in \(daysUntilExpiry) day\(daysUntilExpiry == 1 ? "" : "s")"
                    }
                    let key = "qual-\(operative.id.uuidString)-\(expiry.qualificationId.uuidString)"
                    generated.append(Warning(
                        resolutionKey: key,
                        type: .qualificationExpiry,
                        title: daysUntilExpiry < 0 ? "Qualification expired" : "Qualification expiry",
                        message: message,
                        severity: .low,
                        occurrenceDate: expiryDate
                    ))
                }
            }
        }

        if let rows = unverifiedRows(input, reference: now) {
            generated.append(contentsOf: rows)
        } else {
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
                            severity: .low,
                            operativeEmail: operativeUser.emailLowercased
                        ))
                    }
                }
            }
        }

        var processedOpClash: Set<String> = []
        let managerAdminEmails = Set(managerOrAdminUsers.map(\.emailLowercased))
        if input.warningDetection.detectClashes {
            for (_, dayBookings) in scheduleIndex.operativeBookingsByDayKey {
                guard dayBookings.count > 1 else { continue }
                guard let operative = operativesById[dayBookings[0].operativeId] else { continue }
                if managerAdminEmails.contains(operative.emailLowercased) { continue }
                let clusters = overlappingClusters(dayBookings) { a, b in
                    guard let ia = a.clashInterval, let ib = b.clashInterval else { return false }
                    return intervalsOverlap(ia, ib)
                }
                for (clusterIndex, cluster) in clusters.enumerated() {
                    let sortedCluster = cluster.sorted { $0.id.uuidString < $1.id.uuidString }
                    let pairKey = sortedCluster.map(\.id.uuidString).joined(separator: "|")
                    guard processedOpClash.insert(pairKey).inserted else { continue }
                    let day = sortedCluster[0].dayStart
                    let entries = sortedCluster.map { booking in
                        operativeTimelineEntry(booking: booking, project: projectById[booking.projectId])
                    }
                    let window = WarningTimelineMath.fitWindow(entries: entries)
                    let analysis = WarningTimelineMath.analyse(entries: entries, window: window)
                    let overlapMin = analysis.minutes
                    let (summary, detail) = formatOverlapSummary(minutes: overlapMin)
                    let place = WarningTimelineMath.placeWord(entries.count)
                    generated.append(Warning(
                        resolutionKey: "op-clash-\(operative.id.uuidString)-\(day.timeIntervalSince1970)-\(clusterIndex)",
                        type: .operativeBookingClash,
                        title: Warning.ClashPersonKind.operative.bookingClashTitle,
                        message: "\(operative.name) is booked in \(place) places on \(formatDay(day)). Approve if it's intentional and it'll be noted on the weekly report.",
                        severity: .high,
                        occurrenceDate: day,
                        operativeClash: Warning.OperativeClashWarningDetails(
                            operativeId: operative.id,
                            operativeName: operative.name,
                            date: day,
                            bookingAId: sortedCluster[0].id,
                            bookingBId: sortedCluster[1].id,
                            entryA: entries[0],
                            entryB: entries[1],
                            overlapMinutes: overlapMin,
                            overlapSummary: summary,
                            overlapDetail: detail,
                            entries: entries
                        )
                    ))
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
                let clusters = overlappingClusters(items) { a, b in
                    scheduleIndex.managerPersonItemsOverlap(a, b)
                }
                for (clusterIndex, cluster) in clusters.enumerated() {
                    let sortedCluster = cluster.sorted { $0.sortKey < $1.sortKey }
                    let pairKey = sortedCluster.map(\.pairId).joined(separator: "|")
                    guard processedMgrClash.insert(pairKey).inserted else { continue }
                    let user = usersById[sortedCluster[0].userId]
                    let kind = clashPersonKind(for: user)
                    let person = user?.displayName ?? sortedCluster[0].userId
                    let day = sortedCluster[0].date
                    let entries = sortedCluster.map { $0.timelineEntry(projectsById: projectById) }
                    let window = WarningTimelineMath.fitWindow(entries: entries)
                    let analysis = WarningTimelineMath.analyse(entries: entries, window: window)
                    let overlapMin = analysis.minutes
                    let (summary, detail) = formatOverlapSummary(minutes: overlapMin)
                    let place = WarningTimelineMath.placeWord(entries.count)
                    let isLocationClash = entries.contains { isOtherLocation($0.locationLabel) }
                    generated.append(Warning(
                        resolutionKey: "mgr-clash-\(sortedCluster[0].userId)-\(day.timeIntervalSince1970)-\(clusterIndex)",
                        type: .managerLocationClash,
                        title: kind.bookingClashTitle,
                        message: "\(person) is booked in \(place) places on \(formatDay(day)). Approve if it's intentional and it'll be noted on the weekly report.",
                        severity: .medium,
                        occurrenceDate: day,
                        managerClash: Warning.ManagerClashWarningDetails(
                            userId: sortedCluster[0].userId,
                            personName: person,
                            date: day,
                            bookingAId: sortedCluster[0].bookingId,
                            bookingBId: sortedCluster[1].bookingId,
                            entryA: entries[0],
                            entryB: entries[1],
                            overlapMinutes: overlapMin,
                            overlapSummary: summary,
                            overlapDetail: detail,
                            isLocationClash: isLocationClash,
                            personKind: kind,
                            entries: entries
                        )
                    ))
                }
            }
        }

        // Unbooked labour comes only from canonical-business.js. A second loop that
        // treats any booking as a full day would hide a morning gap.
        if let rows = unbookedRows(input, coverageStart: coverageStart, coverageEnd: coverageEnd) {
            generated.append(contentsOf: rows)
        }

        // Leave clash and half-day cover come only from the script. Swift does not decide
        // which half is open or whether a booking sits inside the leave.
        if let rows = leaveRows(input, coverageStart: coverageStart, coverageEnd: coverageEnd) {
            generated.append(contentsOf: rows)
        }

        let hour = cal.component(.hour, from: now)
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

    nonisolated private static func dayKeyString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    nonisolated private static func qualificationRows(
        _ input: WarningsComputationSnapshot,
        reference: Date,
        dismissedKeys: Set<String>
    ) -> [Warning]? {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let operatives: [[String: Any]] = input.operatives.map { operative in
            let expiries: [[String: Any]] = operative.qualificationExpiries.map { expiry in
                [
                    "qualificationId": expiry.qualificationId.uuidString,
                    "name": expiry.qualificationName,
                    "expiryIso": CanonicalBusinessEngine.isoString(from: expiry.expiryDate),
                ]
            }
            return [
                "id": operative.id.uuidString,
                "isActive": operative.isActive,
                "name": operative.name,
                "expiries": expiries,
            ]
        }
        guard let rows = CanonicalBusinessEngine.objectRows(
            function: "qualificationExpiryRows",
            payload: [
                "referenceIso": CanonicalBusinessEngine.isoString(from: reference),
                "timeZone": "Europe/London",
                "operatives": operatives,
            ]
        ) else {
            return nil
        }
        let visible = CanonicalBusinessEngine.withoutDismissedQualificationRows(
            rows,
            dismissedKeys: Array(dismissedKeys)
        ) ?? rows
        return visible.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let title = row["title"] as? String,
                  let message = row["message"] as? String,
                  let dayKey = row["dayKey"] as? String,
                  let date = CanonicalBusinessEngine.date(fromDayKey: dayKey, calendar: calendar) else {
                return nil
            }
            let operativeId = row["operativeId"] as? String ?? ""
            let qualificationId = row["qualificationId"] as? String ?? ""
            let daysUntilExpiry = (row["daysUntilExpiry"] as? NSNumber)?.intValue
                ?? (row["daysUntilExpiry"] as? Int)
                ?? 0
            let storedKey = (row["dismissKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dismissKey = storedKey.isEmpty
                ? (CanonicalBusinessEngine.qualificationDismissKey(
                    operativeId: operativeId,
                    qualificationId: qualificationId,
                    expiryDayKey: dayKey
                ) ?? "")
                : storedKey
            return Warning(
                resolutionKey: id,
                type: .qualificationExpiry,
                title: title,
                message: message,
                severity: .low,
                occurrenceDate: date,
                qualificationExpiry: Warning.QualificationExpiryWarningDetails(
                    operativeId: operativeId,
                    qualificationId: qualificationId,
                    expiryDayKey: dayKey,
                    dismissKey: dismissKey,
                    daysUntilExpiry: daysUntilExpiry
                )
            )
        }
    }

    nonisolated private static func unverifiedRows(_ input: WarningsComputationSnapshot, reference: Date) -> [Warning]? {
        let operatives: [[String: Any]] = input.operatives.map { operative in
            [
                "id": operative.id.uuidString,
                "email": operative.emailLowercased,
                "name": operative.name,
            ]
        }
        let people: [[String: Any]] = input.users.map { user in
            [
                "email": user.emailLowercased,
                "passwordSet": user.passwordSet,
                "createdAtIso": CanonicalBusinessEngine.isoString(from: user.createdAt),
                "isOperativeMode": user.isOperativeMode,
            ]
        }
        guard let rows = CanonicalBusinessEngine.objectRows(
            function: "unverifiedOperativeRows",
            payload: [
                "referenceIso": CanonicalBusinessEngine.isoString(from: reference),
                "timeZone": "Europe/London",
                "operatives": operatives,
                "people": people,
            ]
        ) else {
            return nil
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let message = row["message"] as? String else {
                return nil
            }
            let title = row["title"] as? String ?? "Unverified operative"
            let email = row["email"] as? String
            return Warning(
                resolutionKey: id,
                type: .operativeNotVerified,
                title: title,
                message: message,
                severity: .low,
                operativeEmail: email
            )
        }
    }

    /// The shared script looks up one user id and one operative id. Repeat each
    /// manager booking and holiday onto every id that shares the email so that
    /// lookup sees the whole person. Identical clock spans merge inside the script.
    nonisolated static func shareCoverageAcrossEmail(
        bookings: [[String: Any]],
        holidays: [[String: Any]],
        people: [[String: Any]],
        operatives: [[String: Any]]
    ) -> (bookings: [[String: Any]], holidays: [[String: Any]]) {
        func text(_ value: Any?) -> String {
            (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func email(_ value: Any?) -> String {
            text(value).lowercased()
        }
        var emailByUser: [String: String] = [:]
        var usersByEmail: [String: [String]] = [:]
        for person in people {
            let id = text(person["id"])
            let key = email(person["email"])
            guard !id.isEmpty, !key.isEmpty else { continue }
            emailByUser[id] = key
            if usersByEmail[key]?.contains(id) != true {
                usersByEmail[key, default: []].append(id)
            }
        }
        var emailByOperative: [String: String] = [:]
        var operativesByEmail: [String: [String]] = [:]
        for operative in operatives {
            let id = text(operative["id"])
            let key = email(operative["email"])
            guard !id.isEmpty, !key.isEmpty else { continue }
            emailByOperative[id] = key
            if operativesByEmail[key]?.contains(id) != true {
                operativesByEmail[key, default: []].append(id)
            }
        }

        var kept: [[String: Any]] = []
        var managerSlotsByEmail: [String: [String: [String: Any]]] = [:]
        for booking in bookings {
            let kind = text(booking["kind"])
            let personId = text(booking["personId"])
            let ownerEmail = emailByUser[personId] ?? emailByOperative[personId]
            guard kind == "manager", let key = ownerEmail else {
                kept.append(booking)
                continue
            }
            let signature = [
                text(booking["dayKey"]),
                text(booking["timeSlot"]),
                text(booking["workStart"]),
                text(booking["workEnd"])
            ].joined(separator: "|")
            managerSlotsByEmail[key, default: [:]][signature] = booking
        }
        for (key, slots) in managerSlotsByEmail {
            for id in usersByEmail[key] ?? [] {
                for slot in slots.values {
                    var copy = slot
                    copy["personId"] = id
                    kept.append(copy)
                }
            }
        }

        var expandedHolidays: [[String: Any]] = []
        var seenHolidays = Set<String>()
        func emit(_ holiday: [String: Any], userId: String, operativeId: String) {
            let marker = [
                userId,
                operativeId,
                text(holiday["startDayKey"]),
                text(holiday["endDayKey"])
            ].joined(separator: "|")
            guard seenHolidays.insert(marker).inserted else { return }
            var copy = holiday
            copy["userId"] = userId
            copy["operativeId"] = operativeId
            expandedHolidays.append(copy)
        }
        for holiday in holidays {
            let userId = text(holiday["userId"])
            let operativeId = text(holiday["operativeId"])
            let key = emailByUser[userId] ?? emailByOperative[operativeId]
            guard let key else {
                emit(holiday, userId: userId, operativeId: operativeId)
                continue
            }
            let userIds = usersByEmail[key] ?? []
            let operativeIds = operativesByEmail[key] ?? []
            let users = userIds.isEmpty ? [userId] : userIds
            let ops = operativeIds.isEmpty ? [operativeId] : operativeIds
            for uid in users {
                for oid in ops {
                    emit(holiday, userId: uid, operativeId: oid)
                }
            }
        }
        return (kept, expandedHolidays)
    }

    /// The exclusion list names user ids. One email is one person, so every account
    /// that shares an excluded email is excluded from the warning rows too.
    nonisolated static func expandedExcludedUserIds(_ excluded: Set<String>, people: [[String: Any]]) -> [String] {
        func text(_ value: Any?) -> String {
            (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var emailById: [String: String] = [:]
        var idsByEmail: [String: [String]] = [:]
        for person in people {
            let id = text(person["id"])
            let email = text(person["email"]).lowercased()
            guard !id.isEmpty, !email.isEmpty else { continue }
            emailById[id] = email
            if idsByEmail[email]?.contains(id) != true {
                idsByEmail[email, default: []].append(id)
            }
        }
        var expanded = Set(excluded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for id in excluded {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let email = emailById[trimmed], !email.isEmpty else { continue }
            for alias in idsByEmail[email] ?? [] {
                expanded.insert(alias)
            }
        }
        return Array(expanded)
    }

    /// The script keeps the first finished account it sees for an email. Put the same
    /// account first on every phone: the finished, active account with the smaller id.
    nonisolated static func orderedPeopleForUnbookedScript(_ people: [[String: Any]]) -> [[String: Any]] {
        func text(_ value: Any?) -> String {
            (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func finished(_ person: [String: Any]) -> Bool {
            (person["passwordSet"] as? Bool) == true && (person["isActive"] as? Bool) == true
        }
        var groups: [String: [[String: Any]]] = [:]
        for person in people {
            let email = text(person["email"]).lowercased()
            guard !email.isEmpty else { continue }
            groups[email, default: []].append(person)
        }
        var placed = Set<String>()
        var ordered: [[String: Any]] = []
        for email in groups.keys.sorted() {
            let winner = groups[email]?.filter(finished).min { text($0["id"]) < text($1["id"]) }
            if let winner {
                ordered.append(winner)
                placed.insert(text(winner["id"]))
            }
        }
        for person in people where !placed.contains(text(person["id"])) {
            ordered.append(person)
        }
        return ordered
    }

    /// A full-day "missing" row is wrong when this email's bookings already cover the
    /// standard day. The script links accounts by email from the people rows Swift sends; this
    /// guard stays for paid hours Swift knows about that are not in those rows.
    nonisolated static func unbookedRowIsAlreadyCovered(
        paidHours: Double,
        missingHours: Double,
        requiredHours: Double
    ) -> Bool {
        guard requiredHours > 0.08 else { return false }
        guard paidHours + 0.08 >= requiredHours else { return false }
        return missingHours + 0.2 >= requiredHours
    }

    nonisolated private static func unbookedRows(
        _ input: WarningsComputationSnapshot,
        coverageStart: Date,
        coverageEnd: Date
    ) -> [Warning]? {
        let calendar = CanonicalBusinessEngine.businessCalendar
        var bookings: [[String: Any]] = []
        for booking in input.bookings where booking.isActiveStatus && booking.dayStart >= coverageStart && booking.dayStart <= coverageEnd {
            bookings.append([
                "personId": booking.operativeId.uuidString,
                "dayKey": dayKeyString(booking.dayStart, calendar: calendar),
                "kind": "operative",
                "timeSlot": booking.timeSlot,
                "workStart": booking.workStart ?? "",
                "workEnd": booking.workEnd ?? "",
            ])
        }
        for booking in input.managerSiteBookings where booking.dayStart >= coverageStart && booking.dayStart <= coverageEnd {
            bookings.append([
                "personId": booking.userId,
                "dayKey": dayKeyString(booking.dayStart, calendar: calendar),
                "kind": "manager",
                "timeSlot": booking.timeSlot,
                "workStart": booking.workStart ?? "",
                "workEnd": booking.workEnd ?? "",
            ])
        }
        var peopleRows: [[String: Any]] = []
        for user in input.users {
            let row: [String: Any] = [
                "id": user.id,
                "email": user.emailLowercased,
                "name": user.displayName,
                "isActive": user.isActive,
                "passwordSet": user.passwordSet,
                "isOperativeMode": user.isOperativeMode,
                "isManager": user.isManager,
                "isAdmin": user.hasAdminAccess || user.isAdminRole,
                "isSuperAdmin": user.isSuperAdmin,
            ]
            peopleRows.append(row)
            for alias in user.sameEmailUserIds where !alias.isEmpty && alias != user.id {
                var copy = row
                copy["id"] = alias
                peopleRows.append(copy)
            }
        }
        let people: [[String: Any]] = orderedPeopleForUnbookedScript(peopleRows)
        let operatives: [[String: Any]] = input.operatives.map { operative in
            [
                "id": operative.id.uuidString,
                "email": operative.emailLowercased,
                "name": operative.name,
                "isActive": operative.isActive,
                "isPlaceholder": operative.isPlaceholder,
                "profileWeight": operative.profileWeight,
            ]
        }
        let holidays: [[String: Any]] = input.holidayBookings.map { holiday in
            [
                "userId": holiday.userId ?? "",
                "operativeId": holiday.operativeId?.uuidString ?? "",
                "startDayKey": dayKeyString(holiday.startDay, calendar: calendar),
                "endDayKey": dayKeyString(holiday.endDay, calendar: calendar),
                "approved": holiday.isApproved,
            ]
        }
        var emailById: [String: String] = [:]
        for user in input.users where !user.emailLowercased.isEmpty {
            emailById[user.id] = user.emailLowercased
            for alias in user.sameEmailUserIds where !alias.isEmpty {
                emailById[alias] = user.emailLowercased
            }
        }
        for operative in input.operatives where !operative.emailLowercased.isEmpty {
            emailById[operative.id.uuidString] = operative.emailLowercased
        }
        var paidByEmailDay: [String: Double] = [:]
        let standardDay = input.payrollTimePolicy.standardPaidHours
        func notePaid(email: String, day: Date, hours: Double, coversStandardDay: Bool) {
            guard !email.isEmpty else { return }
            let key = "\(email)|\(dayKeyString(day, calendar: calendar))"
            if coversStandardDay {
                paidByEmailDay[key] = max(paidByEmailDay[key] ?? 0, standardDay)
            } else if hours > 0 {
                paidByEmailDay[key, default: 0] += hours
            }
        }
        func legacyFullDay(_ slot: String, _ start: String?, _ end: String?) -> Bool {
            let name = slot.trimmingCharacters(in: .whitespacesAndNewlines)
            let startText = start?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let endText = end?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name == "FULL DAY" && startText.isEmpty && endText.isEmpty
        }
        for booking in input.bookings where booking.isActiveStatus {
            notePaid(
                email: emailById[booking.operativeId.uuidString] ?? "",
                day: booking.dayStart,
                hours: booking.paidHours,
                coversStandardDay: legacyFullDay(booking.timeSlot, booking.workStart, booking.workEnd)
            )
        }
        for booking in input.managerSiteBookings {
            notePaid(
                email: emailById[booking.userId] ?? "",
                day: booking.dayStart,
                hours: booking.paidHours,
                coversStandardDay: booking.isFullDaySlot
                    && (booking.workStart ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (booking.workEnd ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        let shared = shareCoverageAcrossEmail(bookings: bookings, holidays: holidays, people: people, operatives: operatives)
        let excluded = expandedExcludedUserIds(
            input.warningDetection.excludedUserIdsFromUnbookedWarnings,
            people: people
        )
        guard let rows = CanonicalBusinessEngine.objectRows(
            function: "unbookedLabourRows",
            payload: [
                "timeZone": "Europe/London",
                "startDayKey": dayKeyString(coverageStart, calendar: calendar),
                "endDayKey": dayKeyString(coverageEnd, calendar: calendar),
                "includeWeekends": input.warningDetection.includeWeekendsForUnbookedLabour,
                "excludedUserIds": excluded,
                "standardDayStart": input.payrollTimePolicy.standardDayStart,
                "standardDayEnd": input.payrollTimePolicy.standardDayEnd,
                "breakWindowStart": input.payrollTimePolicy.breakWindowStart,
                "breakWindowEnd": input.payrollTimePolicy.breakWindowEnd,
                "standardPaidHours": input.payrollTimePolicy.standardPaidHours,
                "saturdayCountsAsHours": input.payrollTimePolicy.saturdayCountsAsHours,
                "sundayCountsAsHours": input.payrollTimePolicy.sundayCountsAsHours,
                "people": people,
                "operatives": operatives,
                "bookings": shared.bookings,
                "holidays": shared.holidays,
            ]
        ) else {
            return nil
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let message = row["message"] as? String,
                  let dayKey = row["dayKey"] as? String,
                  let date = CanonicalBusinessEngine.date(fromDayKey: dayKey, calendar: calendar) else {
                return nil
            }
            let name = row["operativeName"] as? String ?? ""
            let personKey = row["personKey"] as? String ?? ""
            let hours = (row["missingHours"] as? NSNumber)?.doubleValue ?? 0
            let email = emailById[personKey] ?? ""
            let paid = paidByEmailDay["\(email)|\(dayKey)"] ?? 0
            if unbookedRowIsAlreadyCovered(
                paidHours: paid,
                missingHours: hours,
                requiredHours: input.payrollTimePolicy.standardPaidHours
            ) {
                return nil
            }
            return Warning(
                resolutionKey: id,
                type: .unbookedLabour,
                title: "Unbooked labour",
                message: message,
                severity: .high,
                occurrenceDate: date,
                unbookedLabour: Warning.UnbookedLabourWarningDetails(
                    date: date,
                    names: ["\(name) (missing \(formatHours(hours))h)"],
                    personKeys: personKey.isEmpty ? [] : [personKey]
                )
            )
        }
    }

    /// `leave_clash` and `leave_cover` rows for approved leave inside the coverage window.
    /// People are one entry per user (that user id, every alias id, and every operative id on the
    /// email) plus a roster operative who has no user account. The script chooses the rows.
    nonisolated private static func leaveRows(
        _ input: WarningsComputationSnapshot,
        coverageStart: Date,
        coverageEnd: Date
    ) -> [Warning]? {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let startKey = dayKeyString(coverageStart, calendar: calendar)
        let endKey = dayKeyString(coverageEnd, calendar: calendar)

        var operativeIdsByEmail: [String: [String]] = [:]
        for operative in input.operatives where !operative.emailLowercased.isEmpty {
            let id = operative.id.uuidString
            if operativeIdsByEmail[operative.emailLowercased]?.contains(id) != true {
                operativeIdsByEmail[operative.emailLowercased, default: []].append(id)
            }
        }

        var people: [CanonicalLeavePerson] = []
        var claimedEmails = Set<String>()
        for user in input.users {
            let email = user.emailLowercased
            let operativeIds = email.isEmpty ? [] : (operativeIdsByEmail[email] ?? [])
            let personKey = email.isEmpty ? user.id : email
            let entry = CanonicalLeavePerson(
                personKey: personKey,
                name: user.displayName,
                userId: user.id,
                operativeIds: operativeIds
            )
            people.append(entry)
            if !email.isEmpty { claimedEmails.insert(email) }
            for alias in user.sameEmailUserIds where !alias.isEmpty && alias != user.id {
                people.append(CanonicalLeavePerson(
                    personKey: personKey,
                    name: user.displayName,
                    userId: alias,
                    operativeIds: operativeIds
                ))
            }
        }
        var rosterByEmail: [String: [WarningsComputationSnapshot.OperativeSnapshot]] = [:]
        for operative in input.operatives where operative.isActive && !operative.isPlaceholder {
            let email = operative.emailLowercased
            if email.isEmpty {
                people.append(CanonicalLeavePerson(
                    personKey: operative.id.uuidString,
                    name: operative.name,
                    userId: nil,
                    operativeIds: [operative.id.uuidString]
                ))
            } else if !claimedEmails.contains(email) {
                rosterByEmail[email, default: []].append(operative)
            }
        }
        for (email, operatives) in rosterByEmail {
            let ids = operatives.map(\.id.uuidString)
            let name = operatives.max { $0.profileWeight < $1.profileWeight }?.name ?? operatives[0].name
            people.append(CanonicalLeavePerson(
                personKey: email,
                name: name,
                userId: nil,
                operativeIds: ids
            ))
        }

        let peopleRows: [[String: Any]] = input.users.map { user in
            ["id": user.id, "email": user.emailLowercased]
        }
        let excluded = expandedExcludedUserIds(
            input.warningDetection.excludedUserIdsFromUnbookedWarnings,
            people: peopleRows
        )

        var bookings: [CanonicalLeaveBooking] = []
        for booking in input.bookings where booking.isActiveStatus && booking.dayStart >= coverageStart && booking.dayStart <= coverageEnd {
            bookings.append(CanonicalLeaveBooking(
                id: booking.id.uuidString,
                personId: booking.operativeId.uuidString,
                kind: "operative",
                dayKey: dayKeyString(booking.dayStart, calendar: calendar),
                timeSlot: booking.timeSlot,
                workStartTime: booking.workStart,
                workEndTime: booking.workEnd,
                label: booking.scheduleLabel
            ))
        }
        for booking in input.managerSiteBookings where booking.dayStart >= coverageStart && booking.dayStart <= coverageEnd {
            bookings.append(CanonicalLeaveBooking(
                id: booking.id.uuidString,
                personId: booking.userId,
                kind: "manager",
                dayKey: dayKeyString(booking.dayStart, calendar: calendar),
                timeSlot: booking.timeSlot,
                workStartTime: booking.workStart,
                workEndTime: booking.workEnd,
                label: booking.scheduleLabel
            ))
        }

        let leave: [CanonicalLeaveRecord] = input.holidayBookings.map { holiday in
            CanonicalLeaveRecord(
                id: holiday.id,
                userId: holiday.userId,
                operativeId: holiday.operativeId?.uuidString,
                startDayKey: dayKeyString(holiday.startDay, calendar: calendar),
                endDayKey: dayKeyString(holiday.endDay, calendar: calendar),
                timeSlot: holiday.timeSlot,
                approved: holiday.isApproved
            )
        }

        let policy = input.payrollTimePolicy
        let inputPayload = CanonicalLeaveCoverageInput(
            timeZone: "Europe/London",
            startDayKey: startKey,
            endDayKey: endKey,
            day: CanonicalStandardDayInput(
                standardDayStart: policy.standardDayStart,
                standardDayEnd: policy.standardDayEnd,
                breakWindowStart: policy.breakWindowStart,
                breakWindowEnd: policy.breakWindowEnd
            ),
            includeWeekends: input.warningDetection.includeWeekendsForUnbookedLabour,
            excludedUserIds: excluded,
            people: people,
            leave: leave,
            bookings: bookings
        )
        guard let rows = CanonicalBusinessEngine.leaveCoverageRows(inputPayload) else { return nil }
        return rows.compactMap { row in
            guard let date = CanonicalBusinessEngine.date(fromDayKey: row.dayKey, calendar: calendar) else { return nil }
            let severity: Warning.WarningSeverity = row.kind == "leave_clash" || row.severity == "high" ? .high : .medium
            let ranges = row.missing.map { formatClockRange($0.start, $0.end) }
            return Warning(
                resolutionKey: row.id,
                type: .annualLeave,
                title: row.title,
                message: row.message,
                severity: severity,
                occurrenceDate: date,
                annualLeave: Warning.AnnualLeaveWarningDetails(
                    kind: row.kind,
                    personName: row.personName,
                    missingRanges: ranges,
                    missingHours: row.missingHours
                )
            )
        }
    }

    nonisolated private static func formatClockRange(_ start: Int, _ end: Int) -> String {
        func clock(_ minutes: Int) -> String {
            let clamped = max(0, min(minutes, 24 * 60))
            return String(format: "%02d:%02d", clamped / 60, clamped % 60)
        }
        return "\(clock(start))–\(clock(end))"
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

    nonisolated private static func clashPersonKind(
        for user: WarningsComputationSnapshot.UserSnapshot?
    ) -> Warning.ClashPersonKind {
        guard let user else { return .manager }
        if user.hasAdminAccess || user.isAdminRole || user.isSuperAdmin { return .admin }
        if user.isManager { return .manager }
        return .operative
    }

    /// Connected components of overlapping items (one warning per person-day cluster).
    nonisolated private static func overlappingClusters<T>(
        _ items: [T],
        overlap: (T, T) -> Bool
    ) -> [[T]] {
        let n = items.count
        guard n >= 2 else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x { x = parent[x] }
            var y = i
            while parent[y] != y {
                let next = parent[y]
                parent[y] = x
                y = next
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var hasEdge = Array(repeating: false, count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                if overlap(items[i], items[j]) {
                    union(i, j)
                    hasEdge[i] = true
                    hasEdge[j] = true
                }
            }
        }
        var groups: [Int: [T]] = [:]
        for i in 0..<n where hasEdge[i] {
            groups[find(i), default: []].append(items[i])
        }
        return groups.values.filter { $0.count >= 2 }
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
        let iv = booking.clashInterval ?? (8 * 60, 17 * 60)
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
        let iv = booking.clashInterval ?? (8 * 60, 17 * 60)
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

    struct UnbookedPerson {
        let personKey: String
        let displayName: String
        let displayLine: String
    }

    nonisolated func unbookedNames(
        on day: Date,
        operativeUsers: [WarningsComputationSnapshot.UserSnapshot],
        managerUsers: [WarningsComputationSnapshot.UserSnapshot],
        rosterOperatives: [WarningsComputationSnapshot.OperativeSnapshot],
        operativesByEmail: [String: WarningsComputationSnapshot.OperativeSnapshot],
        usersById: [String: WarningsComputationSnapshot.UserSnapshot],
        managerAdminUserIds: Set<String>,
        excludedUserIds: Set<String>,
        standardPaidHours: Double
    ) -> [String] {
        unbookedPeople(
            on: day,
            operativeUsers: operativeUsers,
            managerUsers: managerUsers,
            rosterOperatives: rosterOperatives,
            operativesByEmail: operativesByEmail,
            usersById: usersById,
            managerAdminUserIds: managerAdminUserIds,
            excludedUserIds: excludedUserIds,
            standardPaidHours: standardPaidHours
        ).map(\.displayLine)
    }

    nonisolated func unbookedPeople(
        on day: Date,
        operativeUsers: [WarningsComputationSnapshot.UserSnapshot],
        managerUsers: [WarningsComputationSnapshot.UserSnapshot],
        rosterOperatives: [WarningsComputationSnapshot.OperativeSnapshot],
        operativesByEmail: [String: WarningsComputationSnapshot.OperativeSnapshot],
        usersById: [String: WarningsComputationSnapshot.UserSnapshot],
        managerAdminUserIds: Set<String>,
        excludedUserIds: Set<String>,
        standardPaidHours: Double
    ) -> [UnbookedPerson] {
        let dayStart = calendar.startOfDay(for: day)
        let dayKeySuffix = dayStart.timeIntervalSince1970

        func isExcluded(userId: String?) -> Bool {
            guard let userId, !userId.isEmpty else { return false }
            return excludedUserIds.contains { $0.caseInsensitiveCompare(userId) == .orderedSame }
        }

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

        func hasOperativeLabour(_ operativeId: UUID) -> Bool {
            let key = "\(operativeId.uuidString)-\(dayKeySuffix)"
            return !(operativeBookingsByDayKey[key] ?? []).isEmpty
        }

        func hasManagerLabour(_ userId: String) -> Bool {
            let key = "\(userId)-\(dayKeySuffix)"
            return !(managerBookingsByDayKey[key] ?? []).isEmpty
        }

        let operativeUserEmails = Set(operativeUsers.map(\.emailLowercased))
        var seenEmails = Set<String>()
        var people: [UnbookedPerson] = []
        people.reserveCapacity(operativeUsers.count + managerUsers.count + rosterOperatives.count)

        func verifiedUser(for email: String) -> WarningsComputationSnapshot.UserSnapshot? {
            let matches = usersById.values.filter { $0.emailLowercased == email }
            return matches.first(where: { $0.passwordSet && $0.isActive })
                ?? matches.first(where: { $0.passwordSet })
        }

        // Unbooked labour is for people who have finished signup and are expected
        // on the board. Pending invitees (`passwordSet == false`) are scheduled from
        // Daily Overview / Manage Users if needed, and surface as unverified after
        // 3 working days — not as a daily unbooked-labour warning.
        func appendIfUnbooked(personKey: String, name: String, emailKey: String, hasBooking: Bool) {
            guard seenEmails.insert(emailKey).inserted else { return }
            guard !hasBooking else { return }
            people.append(
                UnbookedPerson(
                    personKey: personKey,
                    displayName: name,
                    displayLine: "\(name) (missing \(WarningsComputation.formatHours(requiredPaidHours))h)"
                )
            )
        }

        for user in operativeUsers {
            if isExcluded(userId: user.id) { continue }
            let linked = operativesByEmail[user.emailLowercased]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            let hasBooking = (linked.map { hasOperativeLabour($0.id) } ?? false) || hasManagerLabour(user.id)
            appendIfUnbooked(personKey: user.id, name: user.displayName, emailKey: user.emailLowercased, hasBooking: hasBooking)
        }

        for user in managerUsers {
            if isExcluded(userId: user.id) { continue }
            let linked = operativesByEmail[user.emailLowercased]
            if hasHoliday(userId: user.id, operativeId: linked?.id) { continue }
            let hasBooking = hasManagerLabour(user.id) || (linked.map { hasOperativeLabour($0.id) } ?? false)
            appendIfUnbooked(personKey: user.id, name: user.displayName, emailKey: user.emailLowercased, hasBooking: hasBooking)
        }

        for op in rosterOperatives where op.isActive {
            let email = op.emailLowercased
            guard !operativeUserEmails.contains(email) else { continue }
            let matchedUser = verifiedUser(for: email)
            if matchedUser == nil,
               usersById.values.contains(where: { $0.emailLowercased == email }) {
                // Invite sent, signup not finished — not unbooked labour.
                continue
            }
            if let matchedUser, managerAdminUserIds.contains(matchedUser.id) {
                continue
            }
            let linkedUserId = matchedUser?.id
            if isExcluded(userId: linkedUserId) { continue }
            if hasHoliday(userId: linkedUserId, operativeId: op.id) { continue }
            let hasBooking = hasOperativeLabour(op.id) || (linkedUserId.map { hasManagerLabour($0) } ?? false)
            appendIfUnbooked(
                personKey: linkedUserId ?? op.id.uuidString,
                name: matchedUser?.displayName ?? op.name,
                emailKey: email,
                hasBooking: hasBooking
            )
        }
        return people.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
