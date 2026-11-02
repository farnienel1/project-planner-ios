//
//  WarningsComputation.swift
//  Project Planner
//
//  Warning generation from main-actor snapshots (Swift 6 safe detached compute).
//

import Foundation

// The scan window is CanonicalBusinessEngine.warningScanWindow (`coverageWindow`, `clashScanDays`).
// Qualification, unverified, unbooked, annual-leave, manager-clash and material cut-off rows come from
// that script (`materialCutOffWarningRows`). Clash timelines and the operative clash grouping stay here,
// on the organisation business calendar.

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
    /// Saturday and Sunday after a Monday–Friday week, only when unbooked labour includes weekends.
    var unbookedCoverageEnd: Date? = nil
    let materialOrderCutOffEnabled: Bool
    let materialCutOffOnSaturday: Bool
    let materialCutOffOnSunday: Bool
    /// Minutes since midnight from `materialCutOffClockMinutes`. Empty label means the script did not answer.
    var materialCutOffMinutes: Int = 0
    var materialCutOffLabel: String = ""
    let projectsWithTomorrowBookings: [Project]
    /// Material lines dated for tomorrow (loaded when computing warnings).
    let materialItemsForTomorrow: [MaterialItem]
    var dismissedQualificationKeys: Set<String> = []
    /// `organizations/{orgId}.settings.materialCutOff`. Nil means the script default (16:00, weekends off).
    var materialCutOff: OrgMaterialCutOff? = nil
    /// Bookings around tomorrow. `materialCutOffWarningRows` picks the active ones on tomorrow.
    var materialCutOffBookings: [Booking] = []
    /// Material send records for those jobs. An order record lists the lines it ordered.
    var materialSendRecords: [MaterialSendRecord] = []
    /// `clashScanDays.dayKeys`. Nil checks clashes on the coverage window only (script did not answer).
    var clashDayKeys: [String]? = nil
}

struct WarningsComputationSnapshot: Sendable {
    struct OperativeSnapshot: Sendable {
        struct QualificationExpirySnapshot: Sendable {
            let qualificationId: String
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
        /// `users/{uid}.formerUserIds`: invite placeholder ids this account replaced (web #189).
        var formerUserIds: [String] = []
        /// `users/{uid}.status` (e.g. `pending`). The script's own sign-up check reads it.
        var status: String? = nil
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

    /// One leave record as the rulebook reader returned it (`parseHolidayDocument`): the document id, the
    /// stored `userId` / `operativeId` strings and the organisation-zone day keys, never recomputed here.
    struct HolidaySnapshot: Sendable {
        let id: String
        let userId: String?
        let operativeId: String?
        let startDayKey: String
        let endDayKey: String
        let isApproved: Bool
        /// `FULL DAY`, `AM`, or `PM`. The script decides whether that is a clash or an open half.
        let timeSlot: String
    }

    struct MaterialItemSnapshot: Sendable {
        let projectId: UUID
        let dayStart: Date
        let isOrdered: Bool
        /// Material line id, raw status and organisation day key for `materialCutOffWarningRows`.
        var id: String = ""
        var status: String = ""
        var dayKey: String = ""
    }

    struct MaterialCutOffBookingSnapshot: Sendable {
        let projectId: String
        let status: String
        let dayKey: String
    }

    struct MaterialSendRecordSnapshot: Sendable {
        let requestType: String
        let materialIds: [String]
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
    var unbookedCoverageEnd: Date? = nil
    let materialOrderCutOffEnabled: Bool
    let materialCutOffOnSaturday: Bool
    let materialCutOffOnSunday: Bool
    var materialCutOffMinutes: Int = 0
    var materialCutOffLabel: String = ""
    let projectsWithTomorrowBookingIds: [UUID]
    let materialItemsForTomorrow: [MaterialItemSnapshot]
    /// Document ids from `organizations/{orgId}/dismissedWarnings`.
    var dismissedQualificationKeys: Set<String> = []
    var materialCutOff: OrgMaterialCutOff? = nil
    var materialCutOffBookings: [MaterialCutOffBookingSnapshot] = []
    var materialSendRecords: [MaterialSendRecordSnapshot] = []
    /// `clashScanDays.dayKeys`. Nil checks clashes on the coverage window.
    var clashDayKeys: Set<String>? = nil
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
            let qualificationNames: [String: String] = operative.qualifications.reduce(into: [:]) { acc, q in
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
                sameEmailUserIds: user.sameEmailUserIds,
                formerUserIds: user.formerUserIds,
                status: user.status
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
                isActiveStatus: CanonicalBusinessEngine.bookingOccupiesDay(booking.status.rawValue) == true,
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

        // RULEBOOK 1.5.0 §9: the reader's record goes to the rules unchanged (`labourHolidayInput`); the
        // scripts match ids without case (`normalizeDocumentId`), so no id is rewritten here.
        let holidayBookings: [WarningsComputationSnapshot.HolidaySnapshot] = input.holidayBookings.map { booking in
            WarningsComputationSnapshot.HolidaySnapshot(
                id: booking.documentId,
                userId: booking.userId,
                operativeId: booking.operativeIdRaw,
                startDayKey: booking.startDayKey,
                endDayKey: booking.endDayKey,
                isApproved: booking.isApproved,
                timeSlot: booking.timeSlot.rawValue
            )
        }

        let materialItemsForTomorrow: [WarningsComputationSnapshot.MaterialItemSnapshot] = input.materialItemsForTomorrow.map { item in
            WarningsComputationSnapshot.MaterialItemSnapshot(
                projectId: item.projectId,
                dayStart: cal.startOfDay(for: item.date),
                isOrdered: item.status == .ordered,
                id: item.id.uuidString,
                status: item.status.rawValue,
                dayKey: CanonicalBusinessEngine.dayKey(for: item.date, calendar: cal)
            )
        }
        let materialCutOffBookings: [WarningsComputationSnapshot.MaterialCutOffBookingSnapshot] = input.materialCutOffBookings.map { booking in
            WarningsComputationSnapshot.MaterialCutOffBookingSnapshot(
                projectId: booking.projectId.uuidString,
                status: booking.status.rawValue,
                dayKey: CanonicalBusinessEngine.dayKey(for: booking.date, calendar: cal)
            )
        }
        let materialSendRecords: [WarningsComputationSnapshot.MaterialSendRecordSnapshot] = input.materialSendRecords.map { record in
            WarningsComputationSnapshot.MaterialSendRecordSnapshot(
                requestType: record.requestType.rawValue,
                materialIds: record.lines.map { $0.materialId.uuidString }
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
            unbookedCoverageEnd: input.unbookedCoverageEnd.map { cal.startOfDay(for: $0) },
            materialOrderCutOffEnabled: input.materialOrderCutOffEnabled,
            materialCutOffOnSaturday: input.materialCutOffOnSaturday,
            materialCutOffOnSunday: input.materialCutOffOnSunday,
            materialCutOffMinutes: input.materialCutOffMinutes,
            materialCutOffLabel: input.materialCutOffLabel,
            projectsWithTomorrowBookingIds: input.projectsWithTomorrowBookings.map(\.id),
            materialItemsForTomorrow: materialItemsForTomorrow,
            dismissedQualificationKeys: input.dismissedQualificationKeys,
            materialCutOff: input.materialCutOff,
            materialCutOffBookings: materialCutOffBookings,
            materialSendRecords: materialSendRecords,
            clashDayKeys: input.clashDayKeys.map { Set($0) }
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
        generateWithLegacyKeys(input).warnings
    }

    /// The rows, and for each row the key forms older iOS builds saved approvals and dismissals under
    /// (`op-clash-{uuid}-{epoch}-{i}`, `materials-{uuid}-{epoch}`). `WarningResolutionStore` migrates them (D3).
    nonisolated static func generateWithLegacyKeys(
        _ input: WarningsComputationSnapshot
    ) -> (warnings: [Warning], legacyKeys: [String: [String]]) {
        var generated: [Warning] = []
        var legacyKeys: [String: [String]] = [:]
        let cal = CanonicalBusinessEngine.businessCalendar
        let now = Date()
        let coverageStart = cal.startOfDay(for: input.coverageStart)
        let coverageEnd = cal.startOfDay(for: input.coverageEnd)

        // `clashScanDays`: Full week also checks a booked Saturday or Sunday of this week. Without the
        // script's day list the coverage window is used.
        let clashDayKeys = input.clashDayKeys
        func isClashDay(_ day: Date) -> Bool {
            if let clashDayKeys {
                return clashDayKeys.contains(dayKeyString(day, calendar: cal))
            }
            return day >= coverageStart && day <= coverageEnd
        }
        let activeBookings = input.bookings.filter(\.isActiveStatus)
        let clashBookings = activeBookings.filter { isClashDay($0.dayStart) }
        let clashManagerBookings = input.managerSiteBookings.filter { isClashDay($0.dayStart) }

        let projectById = keyedByUUID(input.projects, id: \.id)
        let operativesById = keyedByUUID(input.operatives, id: \.id)
        let usersById = keyedByString(input.users, id: \.id)
        let managerOrAdminUsers = input.users.filter { user in
            user.isActive &&
                (user.isManager || user.hasAdminAccess || user.isAdminRole || user.isSuperAdmin)
        }
        let managerAdminUserIds = Set(managerOrAdminUsers.map(\.id))

        let scheduleIndex = WarningsScheduleIndex(calendar: cal)

        if let rows = qualificationRows(input, reference: now, dismissedKeys: input.dismissedQualificationKeys) {
            generated.append(contentsOf: rows)
        }

        if let rows = unverifiedRows(input, reference: now) {
            generated.append(contentsOf: rows)
        }

        let bookingPeople = WarningsBookingPeople(users: input.users, operatives: input.operatives)
        if input.warningDetection.detectClashes,
           let groups = scheduleIndex.canonicalOperativeClashGroups(
            input,
            operativeBookings: clashBookings,
            managerAdminUserIds: managerAdminUserIds
           ) {
            // `operativeClashGroups` decides the person (`bookingPersonKey`), which bookings overlap, every
            // overlapping pair and the key; manager and admin accounts are left out. Names and timelines stay here.
            // No Swift fallback: when the script does not answer there are no operative clash rows.
            var clusterIndexByPersonDay: [String: Int] = [:]
            for group in groups {
                let sortedCluster = group.bookings
                let personDay = "\(group.personKey)|\(group.dayKey)"
                let clusterIndex = clusterIndexByPersonDay[personDay, default: 0]
                clusterIndexByPersonDay[personDay] = clusterIndex + 1
                let first = sortedCluster[0].operativeId
                let person = bookingPeople.person(for: first)
                let catalogue = operativesById[first]
                    ?? person?.operativeId.flatMap(UUID.init(uuidString:)).flatMap { operativesById[$0] }
                let account = person?.accountId.flatMap { usersById[$0] }
                let operative = catalogue ?? WarningsComputationSnapshot.OperativeSnapshot(
                    id: first,
                    name: account?.displayName ?? unknownLabourPersonName,
                    emailLowercased: account?.emailLowercased ?? "",
                    isActive: true,
                    qualificationExpiries: []
                )
                let day = sortedCluster[0].dayStart
                let entries = sortedCluster.map { booking in
                    operativeTimelineEntry(booking: booking, project: projectById[booking.projectId])
                }
                let window = WarningTimelineMath.fitWindow(entries: entries)
                let analysis = WarningTimelineMath.analyse(entries: entries, window: window)
                let overlapMin = analysis.minutes
                let (summary, detail) = formatOverlapSummary(minutes: overlapMin)
                let place = WarningTimelineMath.placeWord(entries.count)
                // The key iOS saved before `clashResolutionKey` (D3 migration reads it).
                let legacyKey = "op-clash-\(operative.id.uuidString)-\(day.timeIntervalSince1970)-\(clusterIndex)"
                let resolutionKey = group.resolutionKey.isEmpty ? legacyKey : group.resolutionKey
                if resolutionKey != legacyKey {
                    legacyKeys[resolutionKey, default: []].append(legacyKey)
                }
                generated.append(Warning(
                    resolutionKey: resolutionKey,
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
                        entries: entries,
                        pairs: group.pairs
                    )
                ))
            }
        }

        if input.warningDetection.detectClashes {
            func appendManagerClash(_ sortedCluster: [WarningsScheduleIndex.ManagerPersonDayItem], userId: String, resolutionKey: String) {
                let user = usersById[userId]
                let kind = clashPersonKind(for: user)
                let person = user?.displayName ?? userId
                let day = sortedCluster[0].date
                let entries = sortedCluster.map { $0.timelineEntry(projectsById: projectById) }
                let window = WarningTimelineMath.fitWindow(entries: entries)
                let analysis = WarningTimelineMath.analyse(entries: entries, window: window)
                let overlapMin = analysis.minutes
                let (summary, detail) = formatOverlapSummary(minutes: overlapMin)
                let place = WarningTimelineMath.placeWord(entries.count)
                let isLocationClash = entries.contains { isOtherLocation($0.locationLabel) }
                generated.append(Warning(
                    resolutionKey: resolutionKey,
                    type: .managerLocationClash,
                    title: kind.bookingClashTitle,
                    message: "\(person) is booked in \(place) places on \(formatDay(day)). Approve if it's intentional and it'll be noted on the weekly report.",
                    severity: .medium,
                    occurrenceDate: day,
                    managerClash: Warning.ManagerClashWarningDetails(
                        userId: userId,
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

            // `managerClashGroups` decides who each booking belongs to (`personDayItems`, through
            // `resolveBookingPerson`), which bookings overlap, and the resolution key. Web asks the same.
            // No Swift fallback: when the script does not answer there are no manager clash rows.
            if let groups = scheduleIndex.canonicalManagerClashGroups(
                input,
                operativeBookings: clashBookings,
                managerBookings: clashManagerBookings,
                managerAdminUserIds: managerAdminUserIds
            ) {
                for group in groups {
                    guard group.items.count > 1 else { continue }
                    appendManagerClash(group.items, userId: group.userId, resolutionKey: group.resolutionKey)
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

        // `materialCutOffWarningRows` decides the clock, tomorrow, the weekend flags and which lines count as ordered.
        if let material = materialCutOffRows(input, now: now) {
            generated.append(contentsOf: material.warnings)
            for (key, legacy) in material.legacyKeys {
                legacyKeys[key, default: []].append(contentsOf: legacy)
            }
        }

        return (generated, legacyKeys)
    }

    /// `materialCutOffWarningRows` over tomorrow's bookings, lines and order send records. Nil when the script did not answer.
    nonisolated private static func materialCutOffRows(
        _ input: WarningsComputationSnapshot,
        now: Date
    ) -> (warnings: [Warning], legacyKeys: [String: [String]])? {
        guard input.materialOrderCutOffEnabled else { return ([], [:]) }
        let calendar = CanonicalBusinessEngine.businessCalendar
        let payload: [String: Any] = [
            "now": CanonicalBusinessEngine.isoString(from: now),
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "cutOff": input.materialCutOff?.canonicalMap() ?? NSNull(),
            "projects": input.projects.map { project -> [String: Any] in
                ["id": project.id.uuidString, "jobNumber": project.jobNumber, "siteName": project.siteName]
            },
            "bookings": input.materialCutOffBookings.map { booking -> [String: Any] in
                ["projectId": booking.projectId, "status": booking.status, "dayKey": booking.dayKey]
            },
            "materials": input.materialItemsForTomorrow.map { line -> [String: Any] in
                ["id": line.id, "projectId": line.projectId.uuidString, "status": line.status, "dayKey": line.dayKey]
            },
            "sendRecords": input.materialSendRecords.map { record -> [String: Any] in
                ["requestType": record.requestType, "materialIds": record.materialIds]
            },
        ]
        guard let rows = CanonicalBusinessEngine.materialCutOffWarningRows(payload) else { return nil }
        let projectById = keyedByUUID(input.projects, id: \.id)
        var legacyKeys: [String: [String]] = [:]
        let warnings: [Warning] = rows.compactMap { row in
            let id = (row["resolutionKey"] as? String) ?? (row["id"] as? String) ?? ""
            guard !id.isEmpty,
                  let message = row["message"] as? String,
                  let dayKey = row["dayKey"] as? String,
                  let date = CanonicalBusinessEngine.date(fromDayKey: dayKey, calendar: calendar),
                  let projectText = row["projectId"] as? String,
                  let projectId = UUID(uuidString: projectText) else {
                return nil
            }
            let unordered = (row["unorderedCount"] as? NSNumber)?.intValue ?? 0
            // The key iOS saved before the shared row (`materials-{uuid}-{epoch}`), for the D3 migration.
            let legacyKey = "materials-\(projectId.uuidString)-\(date.timeIntervalSince1970)"
            if legacyKey != id { legacyKeys[id, default: []].append(legacyKey) }
            return Warning(
                resolutionKey: id,
                type: .materialsCutoff,
                title: row["title"] as? String ?? "Material order not placed",
                message: message,
                severity: .low,
                occurrenceDate: date,
                materialsCutoff: Warning.MaterialsCutoffWarningDetails(
                    projectId: projectId,
                    jobNumber: row["jobNumber"] as? String ?? projectById[projectId]?.jobNumber ?? "",
                    siteName: projectById[projectId]?.siteName ?? "",
                    targetDate: date,
                    itemCount: unordered == 0 ? nil : unordered
                )
            )
        }
        return (warnings, legacyKeys)
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
                    "qualificationId": expiry.qualificationId,
                    "name": expiry.qualificationName,
                    "expiryIso": CanonicalBusinessEngine.isoString(from: expiry.expiryDate),
                ]
            }
            return [
                "id": operative.id.uuidString,
                "isActive": operative.isActive,
                "email": operative.emailLowercased,
                "name": operative.name,
                "expiries": expiries,
            ]
        }
        guard let rows = CanonicalBusinessEngine.objectRows(
            function: "qualificationExpiryRows",
            payload: [
                "referenceIso": CanonicalBusinessEngine.isoString(from: reference),
                "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
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
                "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
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

    /// The web scan passes the stored ids only. The script skips a row when the account
    /// it kept is in that list. Expanding the list to every alias hides a person the web app still shows.
    nonisolated static func storedExcludedUserIds(_ excluded: Set<String>) -> [String] {
        Array(Set(excluded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
    }

    /// The script keeps one account per email: the first that finished sign-up (its own `hasFinishedSignup`,
    /// which reads `passwordSet` and `status`), preferring an active one. Swift decides nothing about sign-up;
    /// it only fixes the order so every phone hands the script the same list: per email (sorted), accounts
    /// that are not excluded first, the kept id before a folded same-email alias, then the smaller id.
    /// People without an email follow in their original order.
    nonisolated static func orderedPeopleForUnbookedScript(
        _ people: [[String: Any]],
        excludedUserIds: Set<String> = []
    ) -> [[String: Any]] {
        func text(_ value: Any?) -> String {
            (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func folded(_ person: [String: Any]) -> Bool {
            (person[WarningsComputation.rosterFoldedIdMarker] as? Bool) == true
        }
        let excluded = Set(excludedUserIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        var groups: [String: [[String: Any]]] = [:]
        var withoutEmail: [[String: Any]] = []
        for person in people {
            let email = text(person["email"]).lowercased()
            guard !email.isEmpty else {
                withoutEmail.append(person)
                continue
            }
            groups[email, default: []].append(person)
        }
        var ordered: [[String: Any]] = []
        for email in groups.keys.sorted() {
            let sorted = (groups[email] ?? []).sorted { lhs, rhs in
                let lhsExcluded = excluded.contains(text(lhs["id"]))
                let rhsExcluded = excluded.contains(text(rhs["id"]))
                if lhsExcluded != rhsExcluded { return !lhsExcluded }
                let lhsFolded = folded(lhs)
                let rhsFolded = folded(rhs)
                if lhsFolded != rhsFolded { return !lhsFolded }
                return text(lhs["id"]) < text(rhs["id"])
            }
            ordered.append(contentsOf: sorted)
        }
        ordered.append(contentsOf: withoutEmail)
        return ordered.map { person in
            var row = person
            row.removeValue(forKey: WarningsComputation.rosterFoldedIdMarker)
            return row
        }
    }

    /// Marks a people row that is a folded same-email id, only while ordering; never sent to the script.
    nonisolated static let rosterFoldedIdMarker = "__rosterFoldedId"

    /// Daily Overview and Book labour for one London day. Same people, bookings, and stored exclusion ids as the warning scan.
    @MainActor
    static func unbookedLabourRowsOnDay(
        day: Date,
        users: [AppUser],
        operatives: [Operative],
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        holidays: [HolidayBooking],
        policy: OrgPayrollTimePolicy,
        includeWeekends: Bool,
        excludedUserIds: [String]
    ) -> [CanonicalUnbookedLabourRow] {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let dayStart = calendar.startOfDay(for: day)
        let dayKey = CanonicalBusinessEngine.dayKey(for: dayStart, calendar: calendar)
        let excluded = Set(excludedUserIds)
        var peopleRows: [[String: Any]] = []
        for user in users {
            var row: [String: Any] = [
                "id": user.id,
                "email": user.email.lowercased(),
                "name": user.fullName.isEmpty ? user.email : user.fullName,
                "isActive": user.isActive,
                "passwordSet": user.passwordSet,
                "isOperativeMode": user.permissions.operativeMode,
                "isManager": user.permissions.manager,
                "isAdmin": user.permissions.adminAccess || user.role == .admin,
                "isSuperAdmin": user.isSuperAdmin,
                "formerIds": user.formerUserIds,
            ]
            // `users/{uid}.status`: a pending invitee is not unbooked (the script's `hasFinishedSignup`).
            if let status = user.status { row["status"] = status }
            peopleRows.append(row)
            for alias in user.sameEmailUserIds where !alias.isEmpty && alias != user.id {
                var copy = row
                copy["id"] = alias
                // A folded same-email id (`rosterPeople`): it never wins the person key over the kept account.
                copy[WarningsComputation.rosterFoldedIdMarker] = true
                peopleRows.append(copy)
            }
        }
        let people = orderedPeopleForUnbookedScript(peopleRows, excludedUserIds: excluded)
        let operativeRows: [[String: Any]] = operatives.map { operative in
            let foldedName = operative.name.lowercased()
            let foldedEmail = operative.email.lowercased()
            return [
                "id": operative.id.uuidString,
                "email": operative.email.lowercased(),
                "name": operative.name,
                "isActive": operative.isActive,
                "isPlaceholder": foldedName.contains("placeholder") || foldedEmail.contains("placeholder") || foldedName.contains("initial"),
                "profileWeight": operative.qualifications.count
                    + operative.qualificationCertificateURLs.count
                    + operative.qualificationExpiryDates.count,
            ]
        }
        var bookingRows: [[String: Any]] = []
        for booking in operativeBookings where CanonicalBusinessEngine.bookingOccupiesDay(booking.status.rawValue) == true && calendar.isDate(booking.date, inSameDayAs: dayStart) {
            bookingRows.append([
                "personId": Booking.storedOperativeId(for: booking.operativeId),
                "dayKey": dayKey,
                "kind": "operative",
                "timeSlot": booking.timeSlot.rawValue,
                "workStart": booking.workStartTime ?? "",
                "workEnd": booking.workEndTime ?? "",
            ])
        }
        for booking in managerBookings where calendar.isDate(booking.date, inSameDayAs: dayStart) {
            bookingRows.append([
                "personId": booking.userId,
                "dayKey": dayKey,
                "kind": "manager",
                "timeSlot": booking.timeSlot.rawValue,
                "workStart": booking.workStartTime ?? "",
                "workEnd": booking.workEndTime ?? "",
            ])
        }
        // RULEBOOK 1.5.0 §9: the reader's stored ids and day keys (`labourHolidayInput`), unchanged.
        let holidayRows: [[String: Any]] = holidays.map { holiday in
            [
                "userId": holiday.userId ?? "",
                "operativeId": holiday.operativeIdRaw ?? "",
                "startDayKey": holiday.startDayKey,
                "endDayKey": holiday.endDayKey,
                "approved": holiday.isApproved,
            ]
        }
        let shared = shareCoverageAcrossEmail(
            bookings: bookingRows,
            holidays: holidayRows,
            people: people,
            operatives: operativeRows
        )
        let input = CanonicalUnbookedLabourDayInput(
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            dayKey: dayKey,
            includeWeekends: includeWeekends,
            excludedUserIds: storedExcludedUserIds(excluded),
            standardPaidHours: policy.standardPaidHours,
            saturdayCountsAsHours: policy.saturday.resolvedCountsAsHours(fallback: policy.standardPaidHours),
            sundayCountsAsHours: PayrollTimePolicyCatalog.resolvedSundaySettings(from: policy)
                .resolvedCountsAsHours(fallback: policy.standardPaidHours),
            standardDayStart: policy.standardDayStart,
            standardDayEnd: policy.standardDayEnd,
            breakWindowStart: policy.breakWindowStart,
            breakWindowEnd: policy.breakWindowEnd,
            people: people.compactMap(unbookedPerson),
            operatives: operativeRows.compactMap(unbookedOperative),
            bookings: shared.bookings.compactMap(unbookedBooking),
            holidays: shared.holidays.compactMap(unbookedHoliday)
        )
        return CanonicalBusinessEngine.unbookedLabourRowsOnDay(input) ?? []
    }

    nonisolated private static func unbookedText(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func unbookedFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    nonisolated private static func unbookedPerson(_ row: [String: Any]) -> CanonicalUnbookedLabourPerson? {
        let id = unbookedText(row["id"])
        guard !id.isEmpty else { return nil }
        return CanonicalUnbookedLabourPerson(
            id: id,
            email: unbookedText(row["email"]),
            name: unbookedText(row["name"]),
            isActive: unbookedFlag(row["isActive"]),
            passwordSet: unbookedFlag(row["passwordSet"]),
            isOperativeMode: unbookedFlag(row["isOperativeMode"]),
            isManager: unbookedFlag(row["isManager"]),
            isAdmin: unbookedFlag(row["isAdmin"]),
            isSuperAdmin: unbookedFlag(row["isSuperAdmin"]),
            status: {
                let status = unbookedText(row["status"])
                return status.isEmpty ? nil : status
            }(),
            formerIds: (row["formerIds"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    nonisolated private static func unbookedOperative(_ row: [String: Any]) -> CanonicalUnbookedLabourOperative? {
        let id = unbookedText(row["id"])
        guard !id.isEmpty else { return nil }
        let weight = (row["profileWeight"] as? NSNumber)?.intValue ?? (row["profileWeight"] as? Int) ?? 0
        return CanonicalUnbookedLabourOperative(
            id: id,
            email: unbookedText(row["email"]),
            name: unbookedText(row["name"]),
            isActive: unbookedFlag(row["isActive"]),
            isPlaceholder: unbookedFlag(row["isPlaceholder"]),
            profileWeight: weight
        )
    }

    nonisolated private static func unbookedBooking(_ row: [String: Any]) -> CanonicalUnbookedLabourBooking? {
        let personId = unbookedText(row["personId"])
        let dayKey = unbookedText(row["dayKey"])
        let kind = unbookedText(row["kind"])
        guard !personId.isEmpty, !dayKey.isEmpty, !kind.isEmpty else { return nil }
        return CanonicalUnbookedLabourBooking(
            personId: personId,
            dayKey: dayKey,
            kind: kind,
            timeSlot: unbookedText(row["timeSlot"]),
            workStart: unbookedText(row["workStart"]),
            workEnd: unbookedText(row["workEnd"])
        )
    }

    nonisolated private static func unbookedHoliday(_ row: [String: Any]) -> CanonicalUnbookedLabourHoliday? {
        let start = unbookedText(row["startDayKey"])
        let end = unbookedText(row["endDayKey"])
        guard !start.isEmpty, !end.isEmpty else { return nil }
        return CanonicalUnbookedLabourHoliday(
            userId: unbookedText(row["userId"]),
            operativeId: unbookedText(row["operativeId"]),
            startDayKey: start,
            endDayKey: end,
            approved: unbookedFlag(row["approved"])
        )
    }

    nonisolated private static func unbookedRows(
        _ input: WarningsComputationSnapshot,
        coverageStart: Date,
        coverageEnd: Date
    ) -> [Warning]? {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let rowEnd = input.unbookedCoverageEnd ?? coverageEnd
        var bookings: [[String: Any]] = []
        for booking in input.bookings where booking.isActiveStatus && booking.dayStart >= coverageStart && booking.dayStart <= rowEnd {
            bookings.append([
                "personId": Booking.storedOperativeId(for: booking.operativeId),
                "dayKey": dayKeyString(booking.dayStart, calendar: calendar),
                "kind": "operative",
                "timeSlot": booking.timeSlot,
                "workStart": booking.workStart ?? "",
                "workEnd": booking.workEnd ?? "",
            ])
        }
        for booking in input.managerSiteBookings where booking.dayStart >= coverageStart && booking.dayStart <= rowEnd {
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
            var row: [String: Any] = [
                "id": user.id,
                "email": user.emailLowercased,
                "name": user.displayName,
                "isActive": user.isActive,
                "passwordSet": user.passwordSet,
                "isOperativeMode": user.isOperativeMode,
                "isManager": user.isManager,
                "isAdmin": user.hasAdminAccess || user.isAdminRole,
                "isSuperAdmin": user.isSuperAdmin,
                "formerIds": user.formerUserIds,
            ]
            // `users/{uid}.status`: a pending invitee is not unbooked (the script's `hasFinishedSignup`).
            if let status = user.status { row["status"] = status }
            peopleRows.append(row)
            for alias in user.sameEmailUserIds where !alias.isEmpty && alias != user.id {
                var copy = row
                copy["id"] = alias
                // A folded same-email id (`rosterPeople`): it never wins the person key over the kept account.
                copy[WarningsComputation.rosterFoldedIdMarker] = true
                peopleRows.append(copy)
            }
        }
        let excludedIds = input.warningDetection.excludedUserIdsFromUnbookedWarnings
        let people: [[String: Any]] = orderedPeopleForUnbookedScript(peopleRows, excludedUserIds: excludedIds)
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
                "operativeId": holiday.operativeId ?? "",
                "startDayKey": holiday.startDayKey,
                "endDayKey": holiday.endDayKey,
                "approved": holiday.isApproved,
            ]
        }
        let shared = shareCoverageAcrossEmail(bookings: bookings, holidays: holidays, people: people, operatives: operatives)
        let excluded = storedExcludedUserIds(excludedIds)
        guard let rows = CanonicalBusinessEngine.objectRows(
            function: "unbookedLabourRows",
            payload: [
                "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
                "startDayKey": dayKeyString(coverageStart, calendar: calendar),
                "endDayKey": dayKeyString(rowEnd, calendar: calendar),
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
            people.append(CanonicalLeavePerson(
                personKey: user.id,
                name: user.displayName,
                userId: user.id,
                operativeIds: operativeIds
            ))
            if !email.isEmpty { claimedEmails.insert(email) }
            for alias in user.sameEmailUserIds where !alias.isEmpty && alias != user.id {
                people.append(CanonicalLeavePerson(
                    personKey: alias,
                    name: user.displayName,
                    userId: alias,
                    operativeIds: operativeIds
                ))
            }
        }
        for operative in input.operatives where !operative.isPlaceholder {
            let email = operative.emailLowercased
            if !email.isEmpty && claimedEmails.contains(email) { continue }
            if !email.isEmpty { claimedEmails.insert(email) }
            let ids = email.isEmpty
                ? [operative.id.uuidString]
                : (operativeIdsByEmail[email] ?? [operative.id.uuidString])
            people.append(CanonicalLeavePerson(
                personKey: operative.id.uuidString,
                name: operative.name,
                userId: nil,
                operativeIds: ids
            ))
        }

        let excluded = storedExcludedUserIds(input.warningDetection.excludedUserIdsFromUnbookedWarnings)

        var bookings: [CanonicalLeaveBooking] = []
        for booking in input.bookings where booking.isActiveStatus && booking.dayStart >= coverageStart && booking.dayStart <= coverageEnd {
            bookings.append(CanonicalLeaveBooking(
                id: booking.id.uuidString,
                personId: Booking.storedOperativeId(for: booking.operativeId),
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
                operativeId: holiday.operativeId,
                startDayKey: holiday.startDayKey,
                endDayKey: holiday.endDayKey,
                timeSlot: holiday.timeSlot,
                approved: holiday.isApproved
            )
        }

        let policy = input.payrollTimePolicy
        let inputPayload = CanonicalLeaveCoverageInput(
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
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

    nonisolated private static func formatDay(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = CanonicalBusinessEngine.businessCalendar.timeZone
        return formatter.string(from: day)
    }

    nonisolated private static func isOtherLocation(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("office") || l.contains("working from home") || l.contains("wfh") || l == "site survey"
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

    nonisolated init(calendar: Calendar) {
        self.calendar = calendar
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

    fileprivate struct CanonicalManagerClash {
        let userId: String
        let items: [ManagerPersonDayItem]
        let resolutionKey: String
    }

    /// `managerClashGroups` over this scan's bookings. Nil when the script did not answer.
    fileprivate nonisolated func canonicalManagerClashGroups(
        _ input: WarningsComputationSnapshot,
        operativeBookings: [WarningsComputationSnapshot.OperativeBookingSnapshot],
        managerBookings: [WarningsComputationSnapshot.ManagerBookingSnapshot],
        managerAdminUserIds: Set<String>
    ) -> [CanonicalManagerClash]? {
        func dayKey(_ date: Date) -> String {
            CanonicalBusinessEngine.dayKeyInOrganizationZone(date) ?? ""
        }
        var payload = clashPayloadBase(input, operativeBookings: operativeBookings, managerAdminUserIds: managerAdminUserIds)
        payload["managerBookings"] = managerBookings.map { booking -> [String: Any] in
            [
                "id": booking.id.uuidString,
                "userId": booking.userId,
                "dayKey": dayKey(booking.dayStart),
                "timeSlot": booking.timeSlot,
                "workStartTime": booking.workStart ?? NSNull(),
                "workEndTime": booking.workEnd ?? NSNull()
            ]
        }
        guard let groups = CanonicalBusinessEngine.managerClashGroups(payload) else { return nil }
        return groups.compactMap { group in
            guard let userId = group["userId"] as? String,
                  let resolutionKey = group["resolutionKey"] as? String,
                  let rows = group["items"] as? [[String: Any]] else { return nil }
            let items: [ManagerPersonDayItem] = rows.compactMap { row in
                guard let kind = row["kind"] as? String, let index = row["index"] as? Int else { return nil }
                if kind == "manager", managerBookings.indices.contains(index) {
                    let booking = managerBookings[index]
                    return ManagerPersonDayItem(userId: userId, date: booking.dayStart, managerBooking: booking, operativeBooking: nil)
                }
                if kind == "operative", operativeBookings.indices.contains(index) {
                    let booking = operativeBookings[index]
                    return ManagerPersonDayItem(userId: userId, date: booking.dayStart, managerBooking: nil, operativeBooking: booking)
                }
                return nil
            }
            return CanonicalManagerClash(userId: userId, items: items, resolutionKey: resolutionKey)
        }
    }

    fileprivate struct CanonicalOperativeClash {
        let personKey: String
        let dayKey: String
        /// The cluster's bookings in booking-id order (`items`).
        let bookings: [WarningsComputationSnapshot.OperativeBookingSnapshot]
        let pairs: [Warning.ClashPair]
        let resolutionKey: String
    }

    /// `operativeClashGroups` over this scan's labour bookings (manager and admin accounts left out).
    /// Nil when the script did not answer.
    fileprivate nonisolated func canonicalOperativeClashGroups(
        _ input: WarningsComputationSnapshot,
        operativeBookings: [WarningsComputationSnapshot.OperativeBookingSnapshot],
        managerAdminUserIds: Set<String>
    ) -> [CanonicalOperativeClash]? {
        let payload = clashPayloadBase(input, operativeBookings: operativeBookings, managerAdminUserIds: managerAdminUserIds)
        guard let groups = CanonicalBusinessEngine.operativeClashGroups(payload) else { return nil }
        return groups.compactMap { group in
            guard let personKey = group["personKey"] as? String,
                  let dayKey = group["dayKey"] as? String,
                  let resolutionKey = group["resolutionKey"] as? String,
                  let rows = group["items"] as? [[String: Any]] else { return nil }
            let bookings: [WarningsComputationSnapshot.OperativeBookingSnapshot] = rows.compactMap { row in
                guard let index = (row["index"] as? NSNumber)?.intValue, operativeBookings.indices.contains(index) else {
                    return nil
                }
                return operativeBookings[index]
            }
            guard bookings.count >= 2 else { return nil }
            let pairRows = group["pairs"] as? [[String: Any]] ?? []
            let pairs: [Warning.ClashPair] = pairRows.compactMap { row in
                guard let a = row["bookingAId"] as? String, let b = row["bookingBId"] as? String else { return nil }
                return Warning.ClashPair(bookingAId: a, bookingBId: b)
            }
            return CanonicalOperativeClash(
                personKey: personKey,
                dayKey: dayKey,
                bookings: bookings,
                pairs: pairs,
                resolutionKey: resolutionKey
            )
        }
    }

    /// `people`, `day`, `managerIds` and `operativeBookings`: the input `managerClashGroups` and
    /// `operativeClashGroups` share.
    fileprivate nonisolated func clashPayloadBase(
        _ input: WarningsComputationSnapshot,
        operativeBookings: [WarningsComputationSnapshot.OperativeBookingSnapshot],
        managerAdminUserIds: Set<String>
    ) -> [String: Any] {
        func dayKey(_ date: Date) -> String {
            CanonicalBusinessEngine.dayKeyInOrganizationZone(date) ?? ""
        }
        let policy = input.payrollTimePolicy
        let payload: [String: Any] = [
            "managerIds": Array(managerAdminUserIds).sorted(),
            "people": [
                "accounts": input.users.map { user -> [String: Any] in
                    [
                        "id": user.id,
                        "email": user.emailLowercased,
                        "formerIds": user.formerUserIds,
                        "aliasIds": user.sameEmailUserIds
                    ]
                },
                "operatives": input.operatives.map { ["id": $0.id.uuidString, "email": $0.emailLowercased] }
            ],
            "day": [
                "standardDayStart": policy.standardDayStart,
                "standardDayEnd": policy.standardDayEnd,
                "breakWindowStart": policy.breakWindowStart,
                "breakWindowEnd": policy.breakWindowEnd
            ],
            "operativeBookings": operativeBookings.map { booking -> [String: Any] in
                [
                    "id": booking.id.uuidString,
                    "operativeId": Booking.storedOperativeId(for: booking.operativeId),
                    "dayKey": dayKey(booking.dayStart),
                    "timeSlot": booking.timeSlot,
                    "workStartTime": booking.workStart ?? NSNull(),
                    "workEndTime": booking.workEnd ?? NSNull(),
                    "status": booking.isActiveStatus ? "Confirmed" : "Cancelled"
                ]
            }
        ]
        return payload
    }
}

/// Who a booking belongs to while warnings are built, from the rulebook's `bookingPersonKey` and
/// `resolveBookingPerson` (web's clash check asks the same functions). Each distinct id asks the script once.
nonisolated final class WarningsBookingPeople {
    private let input: CanonicalBusinessEngine.CanonicalBookingPersonInput
    private let accountIdByFormerId: [String: String]
    private var keys: [UUID: String] = [:]
    private var people: [UUID: CanonicalBusinessEngine.CanonicalResolvedBookingPerson?] = [:]

    init(users: [WarningsComputationSnapshot.UserSnapshot], operatives: [WarningsComputationSnapshot.OperativeSnapshot]) {
        input = CanonicalBusinessEngine.CanonicalBookingPersonInput(
            accounts: users.map {
                CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                    id: $0.id, email: $0.emailLowercased, formerIds: $0.formerUserIds, aliasIds: $0.sameEmailUserIds
                )
            },
            operatives: operatives.map {
                CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.id.uuidString, email: $0.emailLowercased)
            }
        )
        accountIdByFormerId = CanonicalBusinessEngine.formerIdAliases(
            users.map { CanonicalFormerIdPerson(id: $0.id, formerIds: $0.formerUserIds) }
        ) ?? [:]
    }

    func key(for operativeId: UUID) -> String {
        if let hit = keys[operativeId] { return hit }
        let stored = Booking.storedOperativeId(for: operativeId)
        let key = CanonicalBusinessEngine.bookingPersonKey(stored, input) ?? "id:\(stored.lowercased())"
        keys[operativeId] = key
        return key
    }

    func person(for operativeId: UUID) -> CanonicalBusinessEngine.CanonicalResolvedBookingPerson? {
        if let hit = people[operativeId] { return hit }
        let found = CanonicalBusinessEngine.resolveBookingPerson(Booking.storedOperativeId(for: operativeId), input)
        people[operativeId] = found
        return found
    }

    func currentAccountId(forStoredUserId id: String) -> String {
        accountIdByFormerId[id] ?? id
    }
}
