//
//  WeeklyReportPayInputs.swift
//  Project Planner
//
//  RULEBOOK 1.51.0 §7 (owner decisions 15 Nov, Q1–Q4): maps the app's stores into the plain input of
//  `CanonicalBusinessEngine.weeklyReportPayRows` (people, bookings, approved weeks, payment runs, rate history, the
//  working-hours state, range, viewer, roster, currency) and of `weeklyReportLeaveRows`. Nothing is priced, counted or
//  decided here: every figure on the weekly report's Pay Summary, Project Breakdown and Additional Schedule is the
//  script's. The Weekly Report screen and the tests build their input with this one function.
//

import Foundation

enum WeeklyReportPayInputs {
    struct Sources {
        /// Every users document of the organisation.
        var users: [AppUser]
        /// The users `LabourBookingPeople` resolves labour bookings against (`UserStore.bookingNameUsers`).
        var bookingNameUsers: [AppUser]
        var operatives: [Operative]
        var bookings: [Booking]
        var managerBookings: [ManagerSiteBooking]
        var projects: [Project]
        var smallWorks: [Project]
        var history: OperativeDayRateHistoryCollection
        /// The working-hours state (`openOrganizationPayrollPolicyState`) or one parsed policy for every day.
        var organization: [String: Any]
        var startDayKey: String
        var endDayKey: String
        /// `WeeklyReportTimesheetFeed.rulebookWeeksJSON()`.
        var timesheetWeeks: [[String: Any]] = []
        /// `WeeklyReportTimesheetFeed.sheets`.
        var sheets: [[String: Any]] = []
        /// The signed-in user (`UserStore.payViewerRow`); nil hides every figure.
        var viewer: [String: Any]?
        var currency: String = OrganizationRulebookContext.currencyCode
        /// The report's role label for a person ("Admin User", "Operative").
        var roleLabel: (AppUser?) -> String
    }

    /// One person on the report, for rendering (name, role, trade) and for `weeklyReportLeaveRows`.
    struct Person {
        let id: String
        let name: String
        let role: String
        let user: AppUser?
        let operative: Operative?
        var ids: [String]
        var operativeIds: [String]
    }

    struct Built {
        let input: [String: Any]
        let people: [String: Person]
    }

    /// The `weeklyReportPayRows` input and the people it names (by person id).
    static func build(_ s: Sources) -> Built {
        let inRange: (Date) -> Bool = { date in
            let key = OrganizationRulebookContext.dayKey(date)
            return key >= s.startDayKey && key <= s.endDayKey
        }
        let labour = s.bookings.filter { inRange($0.date) }
        // RULEBOOK 1.54.0 §4.8 / §8: every manager site booking in the range, whatever the schedule options say.
        let manager = s.managerBookings.filter { inRange($0.date) }
        let people = buildPeople(s, labour: labour, manager: manager)
        let roster = RulebookPeople.roster(s.users)

        let jobs = s.projects + s.smallWorks
        let smallWorkKeys = Set(s.smallWorks.flatMap { [$0.documentId.lowercased(), $0.id.uuidString.lowercased()] })
        var bookingRows: [[String: Any]] = []
        let labourInputs = OvertimeBookingInputs.withJobs(labour.map { OvertimeBookingInputs.labour($0) }, jobs: jobs)
        for row in labourInputs {
            var json = row.json
            let isSmallWork = row.jobId.map { smallWorkKeys.contains($0.lowercased()) } ?? false
            json["locationKind"] = isSmallWork ? ManagerLocationType.smallWork.rawValue : ManagerLocationType.project.rawValue
            bookingRows.append(json)
        }
        let managerInputs = OvertimeBookingInputs.withJobs(manager.map { OvertimeBookingInputs.managerSite($0) }, jobs: jobs)
        for (booking, row) in zip(manager, managerInputs) {
            var json = row.json
            json["locationKind"] = booking.locationType.rawValue
            bookingRows.append(json)
        }

        let history: [[String: Any]] = s.history.allEntries.map { entry in
            [
                "id": entry.documentId ?? entry.id.uuidString,
                "userId": RulebookJSON.orNull(entry.userId),
                "operativeId": RulebookJSON.orNull(entry.operativeId?.uuidString),
                "dayRate": RulebookJSON.orNull(entry.dayRate.flatMap { $0.isFinite ? $0 : nil }),
                "payBasis": RulebookJSON.orNull(entry.payBasis),
                "effectiveAt": CanonicalBusinessEngine.isoString(from: entry.effectiveAt),
                "createdAt": CanonicalBusinessEngine.isoString(from: entry.createdAt),
            ]
        }

        var input: [String: Any] = [
            "people": people.values.sorted { $0.id < $1.id }.map { personJSON($0, roster: roster) },
            "bookings": bookingRows,
            "timesheetWeeks": s.timesheetWeeks,
            "sheets": s.sheets,
            "roster": s.users.map(\.payAccessSubject),
            "organization": s.organization,
            "payRateHistory": history,
            "range": ["start": s.startDayKey, "end": s.endDayKey],
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "currency": s.currency,
        ]
        // Never `showAllPay` in the app: with no viewer every figure is hidden (`reportPayForViewer`).
        input["viewer"] = s.viewer.map { $0 as Any } ?? NSNull()
        return Built(input: input, people: people)
    }

    /// Web #342 `pricedUserIds`: the users documents whose pay this report reads — the people of its bookings, approved
    /// timesheet weeks and timesheets in the range, matched over every id each person goes by, without case (first
    /// person wins), as `weeklyReportPayRows` matches them. The report waits only for these people's pay.
    static func pricedUserIds(_ built: Built) -> Set<String> {
        var owner: [String: Person] = [:]
        for person in built.people.values.sorted(by: { $0.id < $1.id }) {
            for id in [person.id] + person.ids {
                let key = normalizedId(id)
                if !key.isEmpty, owner[key] == nil { owner[key] = person }
            }
        }
        var out = Set<String>()
        func note(_ id: Any?) {
            guard let id = id as? String, let person = owner[normalizedId(id)], let user = person.user else { return }
            out.insert(user.id)
        }
        for row in built.input["bookings"] as? [[String: Any]] ?? [] { note(row["personId"]) }
        for row in built.input["timesheetWeeks"] as? [[String: Any]] ?? [] { note(row["userId"]) }
        for row in built.input["sheets"] as? [[String: Any]] ?? [] { note(row["personId"]) }
        return out
    }

    /// Web #347 item 4 `pricedCatalogueOperativeIds`: the catalogue `operatives` rows (people with no account) whose pay
    /// this report reads, matched as `pricedUserIds` matches users. Row document ids, as stored.
    static func pricedCatalogueOperativeIds(_ built: Built) -> Set<String> {
        var owner: [String: Person] = [:]
        for person in built.people.values.sorted(by: { $0.id < $1.id }) {
            for id in [person.id] + person.ids {
                let key = normalizedId(id)
                if !key.isEmpty, owner[key] == nil { owner[key] = person }
            }
        }
        var out = Set<String>()
        func note(_ id: Any?) {
            guard let id = id as? String, let person = owner[normalizedId(id)],
                  person.user == nil, person.operative != nil else { return }
            out.insert(person.id)
        }
        for row in built.input["bookings"] as? [[String: Any]] ?? [] { note(row["personId"]) }
        for row in built.input["timesheetWeeks"] as? [[String: Any]] ?? [] { note(row["userId"]) }
        for row in built.input["sheets"] as? [[String: Any]] ?? [] { note(row["personId"]) }
        return out
    }

    /// `weeklyReportLeaveRows` people: every person with all their ids and their email.
    static func leavePeople(_ people: [String: Person]) -> [[String: Any]] {
        people.values.sorted { $0.id < $1.id }.map { person in
            [
                "id": person.id,
                "name": person.name,
                "role": person.role,
                "ids": person.ids + person.operativeIds,
                "email": person.user?.email ?? person.operative?.email ?? "",
            ]
        }
    }

    /// `weeklyReportLeaveRows` records from the leave store (`HolidayBooking`, read by `parseHolidayDocument`).
    static func leaveRecords(_ bookings: [HolidayBooking]) -> [[String: Any]] {
        bookings.map { booking in
            [
                "id": booking.documentId,
                "userId": RulebookJSON.orNull(booking.userId),
                "operativeId": RulebookJSON.orNull(booking.operativeIdRaw),
                "startDayKey": booking.startDayKey,
                "endDayKey": booking.endDayKey,
                "timeSlot": booking.timeSlot.rawValue,
                "status": booking.status.rawValue,
            ]
        }
    }

    // MARK: - People

    private static func personJSON(_ person: Person, roster: [[String: Any]]) -> [String: Any] {
        var row: [String: Any] = [
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "ids": person.ids,
            "operativeIds": person.operativeIds,
        ]
        if let user = person.user {
            var userRow = user.overtimeEmploymentPayload
            userRow["id"] = user.id
            userRow["payBasis"] = RulebookJSON.orNull(user.payBasis)
            userRow["dayRate"] = RulebookJSON.orNull(user.dayRate)
            userRow["hourlyRate"] = RulebookJSON.orNull(user.hourlyRate)
            row["user"] = userRow
            row["ghost"] = user.isGhost
            // `hasActiveLineManager(person, roster)`: only an active line manager counts (review of #235).
            row["hasLineManager"] = CanonicalBusinessEngine.overtimeHasActiveLineManager(person: RulebookPeople.person(user), roster: roster)
            row["paySubject"] = user.payAccessSubject
        } else {
            row["user"] = NSNull()
        }
        let payOperative = person.user == nil
            ? person.operative
            : StaffEmailIdentity.operativeUsedForPay(user: person.user, operative: person.operative)
        if let operative = payOperative {
            row["operative"] = [
                "id": operative.documentId,
                "payBasis": RulebookJSON.orNull(operative.payBasis),
                "dayRate": RulebookJSON.orNull(operative.dayRate),
                "hourlyRate": RulebookJSON.orNull(operative.hourlyRate),
            ] as [String: Any]
        }
        return row
    }

    /// One person per kept users document (same-email documents folded in, `StaffEmailIdentity.preferredUser`) and one
    /// per catalogue `operatives` row with no account. Each person's ids are `overtimePersonIds` plus the same-email ids
    /// and every stored booking person id the app's booking resolver (`resolveBookingPerson`) gives them.
    private static func buildPeople(_ s: Sources, labour: [Booking], manager: [ManagerSiteBooking]) -> [String: Person] {
        var people: [String: Person] = [:]
        var extraIds: [String: Set<String>] = [:]

        func kept(_ user: AppUser) -> AppUser {
            StaffEmailIdentity.preferredUser(sharing: user.email, in: s.users) ?? user
        }
        func accountFor(_ operative: Operative) -> AppUser? {
            guard !operative.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return StaffEmailIdentity.preferredUser(sharing: operative.email, in: s.users)
        }
        func addUser(_ user: AppUser) -> String {
            let keptUser = kept(user)
            if people[keptUser.id] == nil {
                var ids = OvertimeScreenSupport.personIds(for: keptUser, users: s.users, operatives: s.operatives)
                ids.append(contentsOf: StaffEmailIdentity.userIds(sharing: keptUser.email, in: s.users).sorted())
                let linkedOperative = payOperative(personIds: ids, operatives: s.operatives)
                people[keptUser.id] = Person(
                    id: keptUser.id,
                    name: displayName(keptUser),
                    role: s.roleLabel(keptUser),
                    user: keptUser,
                    operative: linkedOperative,
                    ids: ids,
                    operativeIds: PayrollRateResolver.personOperativeIds(
                        user: keptUser, operative: linkedOperative, operatives: s.operatives
                    )
                )
            }
            if keptUser.id != user.id { extraIds[keptUser.id, default: []].insert(user.id) }
            return keptUser.id
        }
        func addCatalogue(_ operative: Operative) -> String {
            let id = operative.documentId
            if people[id] == nil {
                let name = operative.name.trimmingCharacters(in: .whitespacesAndNewlines)
                people[id] = Person(
                    id: id,
                    name: name.isEmpty ? unknownLabourPersonName : name,
                    role: s.roleLabel(nil),
                    user: nil,
                    operative: operative,
                    ids: [id, operative.id.uuidString],
                    operativeIds: [operative.id.uuidString]
                )
            }
            return id
        }

        for user in s.users { _ = addUser(user) }
        for operative in s.operatives where accountFor(operative) == nil { _ = addCatalogue(operative) }

        let resolver = LabourBookingPeople(operatives: s.operatives, users: s.bookingNameUsers)
        for booking in labour {
            let found = resolver.person(for: booking.operativeId)
            let account = found.operative.flatMap(accountFor) ?? found.user.map(kept)
            let personId: String?
            if let account {
                personId = addUser(account)
            } else if let operative = found.operative {
                personId = addCatalogue(operative)
            } else {
                personId = nil
            }
            if let personId { extraIds[personId, default: []].insert(booking.storedOperativeId) }
        }
        let formerAliases = CanonicalBusinessEngine.formerIdAliases(
            s.users.map { CanonicalFormerIdPerson(id: $0.id, formerIds: $0.formerUserIds) }
        ) ?? [:]
        // Manager site bookings match `userId` without case (`normalizeDocumentId`, review of #235 / web B11).
        let usersByKey = Dictionary(s.users.map { (normalizedId($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let formerByKey = Dictionary(formerAliases.map { (normalizedId($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        for booking in manager {
            let key = normalizedId(booking.userId)
            let currentKey = usersByKey[key] != nil ? key : normalizedId(formerByKey[key] ?? booking.userId)
            guard let user = usersByKey[currentKey] else { continue }
            let personId = addUser(user)
            extraIds[personId, default: []].insert(booking.userId)
        }

        for (personId, ids) in extraIds {
            guard var person = people[personId] else { continue }
            for id in ids.sorted() where !person.ids.contains(id) { person.ids.append(id) }
            people[personId] = person
        }
        return people
    }

    /// `normalizeDocumentId` (trimmed, lower case) for an id match.
    private static func normalizedId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Guardrail 1 (review of #235): the person's `operatives` row for the live-rate fallback is chosen from the rows
    /// the person-ids rule gives them (`overtimePersonIds`: their own, former and same-email ids and the rows on their
    /// email), never "the first row on the email": the row linked to one of their ids first, else one with a rate.
    private static func payOperative(personIds: [String], operatives: [Operative]) -> Operative? {
        let keys = Set(personIds.map(normalizedId))
        let rows = operatives.filter { keys.contains(normalizedId($0.documentId)) || keys.contains(normalizedId($0.id.uuidString)) }
        if let linked = rows.first(where: { row in row.linkedUserId.map { keys.contains(normalizedId($0)) } ?? false }) {
            return linked
        }
        return rows.first { $0.dayRate != nil || $0.hourlyRate != nil } ?? rows.first
    }

    private static func displayName(_ user: AppUser) -> String {
        let name = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? unknownLabourPersonName : email
    }
}
