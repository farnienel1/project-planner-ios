//
//  Rulebook+JobAccess.swift
//  Project Planner
//
//  Rulebook 1.10.0 (docs/RULEBOOK.md §2, §16, §17): who sees which job, who adds and edits jobs and their manager
//  lists, who writes which booking, the job and booking queries an app may run (Firestore rules are not filters),
//  and what Daily Overview and warnings cover for a viewer. Web `lib/canonical/staffAccess.ts`, called through
//  `CanonicalBusinessEngine`; nothing is decided here.
//

import Foundation
import FirebaseAuth

// MARK: - The viewer

/// `JobAccessViewer`: the resolved role (`UserStore.staffAccountRole`), the account's Projects / Small works
/// add-edit-manage toggles for the open organisation, the Auth uid, every id of the person (`personIdSet`) and email.
nonisolated struct JobAccessViewer: Equatable, Sendable {
    var role: CanonicalBusinessEngine.CanonicalStaffAccountRole
    var projectsToggle: Bool
    var smallWorksToggle: Bool
    var uid: String
    var ids: [String]
    var email: String

    var json: [String: Any] {
        [
            "role": [
                "isSuperAdmin": role.isSuperAdmin,
                "isAdmin": role.isAdmin,
                "isManager": role.isManager,
                "isOperativeMode": role.isOperativeMode,
            ],
            "toggles": ["projects": projectsToggle, "smallWorks": smallWorksToggle],
            "uid": uid,
            "ids": ids,
            "email": email,
        ]
    }
}

/// The job kind a job belongs to (`WorkCatalogue`): the collection it is stored in.
nonisolated enum JobKind: String, Sendable, Codable {
    case projects
    case smallWorks
}

extension Project {
    /// `projects` or `smallWorks` (`JobKind`), as `canSeeJob` / `canEditJob` take it: the collection the document
    /// was read from (`sourceCollection`), never a guess from `jobType` (RULEBOOK §17 `jobKind`).
    var jobKind: JobKind { sourceCollection }

    /// The stored manager fields of this job (`JobManagerFields`): `managerIds` and `managerId` in their stored
    /// spelling, and the stored `managerUserIds`.
    var jobAccessFields: [String: Any] {
        var fields: [String: Any] = [
            "managerIds": managerIds.map { storedManagerId(for: $0) },
            "managerUserIds": storedManagerUserIds,
        ]
        if let managerId { fields["managerId"] = storedManagerId(for: managerId) }
        return fields
    }
}

// MARK: - Script calls

extension CanonicalBusinessEngine {
    /// `JOB_MANAGER_LIST_FIELDS`: the job fields that make up its manager list.
    nonisolated static var jobManagerListFields: [String] {
        constant("JOB_MANAGER_LIST_FIELDS", as: [String].self) ?? ["managerIds", "managerId", "assignedManagerUserIds", "managerUserIds"]
    }

    /// `seesEveryJob(role, kind, toggles)`: 1.33.0 admins and every manager outside operative mode, whatever the toggles.
    nonisolated static func seesEveryJob(_ viewer: JobAccessViewer, kind: JobKind?) -> Bool {
        let json = viewer.json
        return callJSON("seesEveryJob", arguments: [json["role"] as Any, kind?.rawValue ?? NSNull(), json["toggles"] as Any]) as? Bool ?? false
    }

    /// `canSeeJob(viewer, job, managers, kind)`. False when the script did not answer.
    nonisolated static func canSeeJob(_ viewer: JobAccessViewer, job: [String: Any], managers: [[String: Any]], kind: JobKind) -> Bool {
        callJSON("canSeeJob", arguments: [viewer.json, job, managers, kind.rawValue]) as? Bool ?? false
    }

    /// `canCreateJob(viewer, kind)`: Add Project / Add Small Works.
    nonisolated static func canCreateJob(_ viewer: JobAccessViewer, kind: JobKind) -> Bool {
        callJSON("canCreateJob", arguments: [viewer.json, kind.rawValue]) as? Bool ?? false
    }

    /// `canChangeJobManagers(viewer, kind)`: the manager picker on a job.
    nonisolated static func canChangeJobManagers(_ viewer: JobAccessViewer, kind: JobKind) -> Bool {
        callJSON("canChangeJobManagers", arguments: [viewer.json, kind.rawValue]) as? Bool ?? false
    }

    /// `canEditJob(viewer, job, kind, managers)`: Edit on a job.
    nonisolated static func canEditJob(_ viewer: JobAccessViewer, job: [String: Any], kind: JobKind, managers: [[String: Any]]) -> Bool {
        callJSON("canEditJob", arguments: [viewer.json, job, kind.rawValue, managers]) as? Bool ?? false
    }

    /// `canWriteBooking(viewer, booking, job, managers)`: create, edit or cancel a labour, manager site or
    /// subcontractor booking. `booking` is `{ collection, projectId?, userId?, locationType?, locationId? }`;
    /// `job` the stored job the booking names (nil when missing → admins only).
    nonisolated static func canWriteBooking(_ viewer: JobAccessViewer, booking: [String: Any], job: [String: Any]?, managers: [[String: Any]]) -> Bool {
        callJSON("canWriteBooking", arguments: [viewer.json, booking, job ?? NSNull(), managers]) as? Bool ?? false
    }

    /// `canDeleteBooking(viewer, booking, job, managers)`.
    nonisolated static func canDeleteBooking(_ viewer: JobAccessViewer, booking: [String: Any], job: [String: Any]?, managers: [[String: Any]]) -> Bool {
        callJSON("canDeleteBooking", arguments: [viewer.json, booking, job ?? NSNull(), managers]) as? Bool ?? false
    }

    /// `jobManagerUserIds(job, managers, accounts)`: `managerUserIds` to write beside `managerIds`. Nil when the
    /// script did not answer.
    nonisolated static func jobManagerUserIds(job: [String: Any], managers: [[String: Any]], accounts: [[String: Any]]) -> [String]? {
        callJSON("jobManagerUserIds", arguments: [job, managers, accounts]) as? [String]
    }

    /// `jobWriteWithoutManagerList(fields)` over the keys: the keys left once `JOB_MANAGER_LIST_FIELDS` are removed.
    nonisolated static func jobWriteKeysWithoutManagerList(_ keys: [String]) -> Set<String>? {
        var probe: [String: Any] = [:]
        for key in keys { probe[key] = true }
        guard let kept = callJSON("jobWriteWithoutManagerList", arguments: [probe]) as? [String: Any] else { return nil }
        return Set(kept.keys)
    }

    /// `jobQueryPlan(viewer, { documentIds, enforced })`. Nil when the script did not answer. `enforced` nil uses the
    /// rulebook's `ENFORCED_READS_ACTIVE` (1.10.1: off until the backfill); tests pass true to check enforced plans.
    nonisolated static func jobQueryPlan(_ viewer: JobAccessViewer, documentIds: [String], enforced: Bool? = nil) -> [String: Any]? {
        var options: [String: Any] = ["documentIds": documentIds]
        if let enforced { options["enforced"] = enforced }
        return callJSON("jobQueryPlan", arguments: [viewer.json, options]) as? [String: Any]
    }

    /// `bookingQueryPlan(viewer, visibleJobIds, { ownBookingIds })`. Nil when the script did not answer.
    nonisolated static func bookingQueryPlan(
        _ viewer: JobAccessViewer,
        visibleJobIds: [String],
        ownBookingIds: [String]?,
        enforced: Bool? = nil
    ) -> [String: Any]? {
        var options: [String: Any] = ownBookingIds.map { ["ownBookingIds": $0] } ?? [:]
        if let enforced { options["enforced"] = enforced }
        return callJSON("bookingQueryPlan", arguments: [viewer.json, visibleJobIds, options]) as? [String: Any]
    }

    /// `readsEveryBooking(viewer)`.
    nonisolated static func readsEveryBooking(_ viewer: JobAccessViewer, enforced: Bool? = nil) -> Bool {
        let options: [String: Any] = enforced.map { ["enforced": $0] } ?? [:]
        return callJSON("readsEveryBooking", arguments: [viewer.json, options]) as? Bool ?? false
    }

    /// `warningScopeFor({ viewer, visibleJobIds, bookings, managerBookings, people, operatives })`. `{ kind: 'all' }`
    /// when the script did not answer (the scan then behaves as before 1.10.0).
    nonisolated static func warningScopeFor(
        viewer: JobAccessViewer,
        visibleJobIds: [String],
        bookings: [[String: Any]],
        managerBookings: [[String: Any]],
        people: [[String: Any]],
        operatives: [[String: Any]],
        jobs: [[String: Any]] = [],
        managers: [[String: Any]] = [],
        roster: [[String: Any]] = [],
        enforced: Bool? = nil
    ) -> [String: Any] {
        // RULEBOOK 1.31.0 §5: `jobs` (stored manager fields), `managers` and `roster` (line-manager fields) decide a
        // manager's scope; `visibleJobIds`, `bookings` and `managerBookings` are no longer read by the script.
        var input: [String: Any] = [
            "viewer": viewer.json,
            "visibleJobIds": visibleJobIds,
            "bookings": bookings,
            "managerBookings": managerBookings,
            "people": people,
            "operatives": operatives,
            "jobs": jobs,
            "managers": managers,
            "roster": roster,
        ]
        if let enforced { input["enforced"] = enforced }
        return callJSON("warningScopeFor", arguments: [input]) as? [String: Any] ?? ["kind": "all"]
    }

    /// RULEBOOK 1.33.0 §6 `dailyOverviewScopeFor({ viewer, roster, people, operatives })`: admins everything
    /// (`{ kind: 'all' }`); a manager only themselves and their reports, with no job part. `{ kind: 'all' }` when the
    /// script did not answer.
    nonisolated static func dailyOverviewScopeFor(
        viewer: JobAccessViewer,
        roster: [[String: Any]],
        people: [[String: Any]],
        operatives: [[String: Any]],
        enforced: Bool? = nil
    ) -> [String: Any] {
        var input: [String: Any] = [
            "viewer": viewer.json,
            "roster": roster,
            "people": people,
            "operatives": operatives,
        ]
        if let enforced { input["enforced"] = enforced }
        return callJSON("dailyOverviewScopeFor", arguments: [input]) as? [String: Any] ?? ["kind": "all"]
    }

    /// RULEBOOK 1.33.0 §6 `isDailyOverviewRowInScope(scope, { personIds, email, subcontractor })`: a booked person, a
    /// person on leave, an unbooked person or their hours; a subcontractor booking only for `all`. No scope (nil) keeps
    /// every row; true when the script did not answer.
    nonisolated static func isDailyOverviewRowInScope(
        _ scope: [String: Any]?,
        personIds: [String],
        email: String?,
        subcontractor: Bool = false
    ) -> Bool {
        var row: [String: Any] = ["personIds": personIds, "email": email ?? NSNull()]
        if subcontractor { row["subcontractor"] = true }
        return callJSON("isDailyOverviewRowInScope", arguments: [scope ?? NSNull(), row]) as? Bool ?? true
    }

    /// `isJobInWarningScope(scope, jobId)`.
    nonisolated static func isJobInWarningScope(_ scope: [String: Any], jobId: String) -> Bool {
        callJSON("isJobInWarningScope", arguments: [scope, jobId]) as? Bool ?? true
    }

    /// `isPersonInWarningScope(scope, ids, email)`.
    nonisolated static func isPersonInWarningScope(_ scope: [String: Any], ids: [String], email: String?) -> Bool {
        callJSON("isPersonInWarningScope", arguments: [scope, ids, email ?? NSNull()]) as? Bool ?? true
    }
}

// MARK: - The signed-in viewer, for code that is not handed a store

extension Notification.Name {
    /// The inputs of `jobQueryPlan` / `bookingQueryPlan` changed (viewer, visible jobs, own booking ids or an
    /// operative's job ids): job and booking listeners re-plan their queries (§17).
    static let jobReadPlanDidChange = Notification.Name("jobReadPlanDidChange")
}

/// The signed-in account as the read plans see it (the real profile, never role testing: the security rules read the
/// real one), the managers list and accounts `jobManagerUserIds` resolves against, and the ids the plans take.
/// Updated by `UserStore`, `OperativeStore`, `ProjectStore` and `BookingStore`. App plumbing, not a rule.
nonisolated enum JobAccessContext {
    nonisolated(unsafe) private(set) static var readViewer: JobAccessViewer?
    /// `JobManagerRosterRow { id, email }` for `organizations/{orgId}/managers`.
    nonisolated(unsafe) private(set) static var managers: [[String: Any]] = []
    /// `JobManagerAccount { id, email, isActive }` for the roster.
    nonisolated(unsafe) private(set) static var accounts: [[String: Any]] = []
    /// The viewer's `bookingIdsForAccount` (stored spellings).
    nonisolated(unsafe) private(set) static var ownBookingIds: [String] = []
    /// The stored ids of the jobs this device loaded (a restricted manager's visible jobs).
    nonisolated(unsafe) private(set) static var visibleJobIds: [String] = []
    /// The job ids named by an operative's own bookings (single-document job reads).
    nonisolated(unsafe) private(set) static var operativeJobIds: [String] = []

    private static func post() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .jobReadPlanDidChange, object: nil)
        }
    }

    private static func sortedUnique(_ ids: [String]) -> [String] {
        Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    static func updateViewer(_ viewer: JobAccessViewer?) {
        guard viewer != readViewer else { return }
        readViewer = viewer
        post()
    }

    @MainActor static func updateManagers(_ rows: [Manager]) {
        managers = rows.map { ["id": $0.firestoreDocumentId, "email": $0.email] }
    }

    @MainActor static func updateAccounts(_ users: [AppUser]) {
        accounts = users.map { ["id": $0.id, "email": $0.email, "isActive": $0.isActive] }
    }

    nonisolated(unsafe) private static var ownAccount: CanonicalBusinessEngine.CanonicalBookingPersonAccount?
    nonisolated(unsafe) private static var operativeRows: [CanonicalBusinessEngine.CanonicalBookingPersonOperative] = []

    /// The signed-in account, for its own booking ids (`bookingIdsForAccount`).
    @MainActor static func updateOwnAccount(_ user: AppUser?) {
        let next = user.map {
            CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                id: $0.id, email: $0.email, formerIds: $0.formerUserIds, aliasIds: $0.sameEmailUserIds
            )
        }
        guard next != ownAccount else { return }
        ownAccount = next
        recomputeOwnBookingIds()
    }

    /// The operatives catalogue, for the signed-in account's own booking ids.
    @MainActor static func updateOperatives(_ operatives: [Operative]) {
        let next = operatives.map { CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email) }
        guard next != operativeRows else { return }
        operativeRows = next
        recomputeOwnBookingIds()
    }

    private static func recomputeOwnBookingIds() {
        guard let ownAccount else {
            updateOwnBookingIds([])
            return
        }
        let ids = CanonicalBusinessEngine.bookingIdsForAccount(ownAccount, operatives: operativeRows)
            ?? [ownAccount.id] + (ownAccount.formerIds ?? []) + (ownAccount.aliasIds ?? [])
        updateOwnBookingIds(ids)
    }

    /// Labour and manager site bookings on screen: the job ids an operative reads one by one (`jobQueryPlan`).
    /// Every labour booking's job, cancelled ones included, as web `replanOperativeJobs` passes them; the job lists
    /// still show only the jobs of bookings that occupy a day. Filtering here first meant iOS read fewer job
    /// documents than web for the same operative.
    @MainActor static func updateOperativeJobIds(bookings: [Booking], managerBookings: [ManagerSiteBooking]) {
        var ids = bookings.map(\.storedProjectId)
        for booking in managerBookings where booking.locationType == .project || booking.locationType == .smallWork {
            if let key = booking.locationKey ?? booking.locationId.map({ WorkDocumentKeys.storedId(for: $0) }) { ids.append(key) }
        }
        updateOperativeJobIds(ids)
    }

    static func updateOwnBookingIds(_ ids: [String]) {
        let next = sortedUnique(ids)
        guard next != ownBookingIds else { return }
        ownBookingIds = next
        post()
    }

    /// Stored manager fields of each loaded job, by lower-cased document id (the job a booking names).
    nonisolated(unsafe) private(set) static var jobFieldsById: [String: [String: Any]] = [:]

    /// Every loaded job as `{ id, ...stored manager fields }` (RULEBOOK 1.31.0 `warningScopeFor` `jobs`).
    nonisolated static var jobManagerRows: [[String: Any]] {
        jobFieldsById.map { key, fields in
            var row = fields
            row["id"] = key
            return row
        }
    }

    /// The jobs this device loaded: their ids for `bookingQueryPlan` and their manager fields for `canWriteBooking`.
    @MainActor static func updateJobs(_ projects: [Project]) {
        var fields: [String: [String: Any]] = [:]
        for job in projects { fields[job.documentId.lowercased()] = job.jobAccessFields }
        jobFieldsById = fields
        updateVisibleJobIds(projects.map(\.documentId))
        BookingJobCollectionContext.update(projects)
    }

    /// The refusal message when the signed-in account may not create, edit, cancel or delete this booking
    /// (`canWriteBooking` / `canDeleteBooking`, RULEBOOK 1.10.0 §2, §16), else nil. Nil too before the profile loads
    /// (the security rules still decide).
    static func bookingWriteRefusal(
        collection: String,
        projectId: String? = nil,
        userId: String? = nil,
        locationType: String? = nil,
        locationId: String? = nil,
        isDelete: Bool = false
    ) -> String? {
        guard let viewer = readViewer else { return nil }
        var booking: [String: Any] = ["collection": collection]
        if let projectId { booking["projectId"] = projectId }
        if let userId { booking["userId"] = userId }
        if let locationType { booking["locationType"] = locationType }
        if let locationId { booking["locationId"] = locationId }
        let jobKey = (collection == "managerSiteBookings" ? locationId : projectId)?.lowercased() ?? ""
        let job = jobKey.isEmpty ? nil : jobFieldsById[jobKey]
        let allowed = isDelete
            ? CanonicalBusinessEngine.canDeleteBooking(viewer, booking: booking, job: job, managers: managers)
            : CanonicalBusinessEngine.canWriteBooking(viewer, booking: booking, job: job, managers: managers)
        if allowed { return nil }
        if viewer.role.isOperativeMode || !(viewer.role.isManager || viewer.role.isAdmin || viewer.role.isSuperAdmin) {
            return "Only admins and the job's managers can change bookings."
        }
        return "You can only change bookings on jobs you manage."
    }

    /// RULEBOOK 1.33.0 §2 `bookingRemoveAction(viewer, booking, job, managers)`: the one remove control a booking
    /// screen shows — `delete` (with its tombstone) for exactly the people `canDeleteBooking` allows, `none` for
    /// everyone else; there is no cancel. `delete` before the profile loads (the security rules still decide).
    static func bookingRemoveAction(
        collection: String,
        projectId: String? = nil,
        userId: String? = nil,
        locationType: String? = nil,
        locationId: String? = nil
    ) -> String {
        guard let viewer = readViewer else { return "delete" }
        var booking: [String: Any] = ["collection": collection]
        if let projectId { booking["projectId"] = projectId }
        if let userId { booking["userId"] = userId }
        if let locationType { booking["locationType"] = locationType }
        if let locationId { booking["locationId"] = locationId }
        let jobKey = (collection == "managerSiteBookings" ? locationId : projectId)?.lowercased() ?? ""
        let job = jobKey.isEmpty ? nil : jobFieldsById[jobKey]
        return CanonicalBusinessEngine.bookingRemoveAction(viewer, booking: booking, job: job, managers: managers)
    }

    static func updateVisibleJobIds(_ ids: [String]) {
        let next = sortedUnique(ids)
        guard next != visibleJobIds else { return }
        visibleJobIds = next
        post()
    }

    static func updateOperativeJobIds(_ ids: [String]) {
        let next = sortedUnique(ids)
        guard next != operativeJobIds else { return }
        operativeJobIds = next
        post()
    }

    /// Organisation switch and sign-out: another company's job ids and managers never plan this one's reads.
    /// The viewer is set again by `UserStore` when the profile of the new organisation loads.
    static func resetForOrganizationSwitch() {
        operativeRows = []
        jobFieldsById = [:]
        BookingJobCollectionContext.reset()
        managers = []
        accounts = []
        ownBookingIds = []
        visibleJobIds = []
        operativeJobIds = []
    }

    /// `jobManagerUserIds(job, managers, accounts)` against the loaded managers list and roster. Nil when the
    /// script did not answer or neither list is loaded (the save then leaves the stored list alone).
    @MainActor static func managerUserIds(for job: Project) -> [String]? {
        guard !accounts.isEmpty else { return nil }
        return CanonicalBusinessEngine.jobManagerUserIds(job: job.jobAccessFields, managers: managers, accounts: accounts)
    }
}

extension UserStore {
    /// The viewer for `user` (`personIdSet` ids against the roster, the Projects / Small works toggles).
    func jobAccessViewer(for user: AppUser) -> JobAccessViewer {
        let authUid = Auth.auth().currentUser?.uid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 1.33.1 (owner report: Projects took ~20 s): screens read the viewer many times per render, and each read ran
        // `personIdSet` over the whole roster in the script. The answer is kept until the person, the roster or the
        // signed-in account changes (unchanged arrays compare in O(1)).
        let key = JobAccessViewerMemo.Key(user: user, roster: organizationUsers, authUid: authUid, currentUserId: currentUser?.id)
        if let hit = JobAccessViewerMemo.shared.value(for: key) { return hit }
        let viewer = buildJobAccessViewer(for: user, authUid: authUid)
        JobAccessViewerMemo.shared.store(viewer, for: key)
        return viewer
    }

    private func buildJobAccessViewer(for user: AppUser, authUid: String) -> JobAccessViewer {
        let ids = RulebookPeople.ownerIds(for: user, users: organizationUsers)
        return JobAccessViewer(
            role: Self.staffAccountRole(for: user),
            projectsToggle: user.permissions.projects,
            smallWorksToggle: user.permissions.smallWorks,
            uid: user.id == currentUser?.id && !authUid.isEmpty ? authUid : user.id,
            ids: ids,
            email: user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// The viewer the screens gate on (respects role testing). Nil before the profile loads.
    var displayJobAccessViewer: JobAccessViewer? {
        displayUser.map { jobAccessViewer(for: $0) }
    }

    /// Recomputes the read viewer from the real profile (never role testing) and the roster accounts.
    func refreshJobAccessContext() {
        JobAccessContext.updateAccounts(organizationUsers)
        JobAccessContext.updateOwnAccount(currentUser)
        JobAccessContext.updateViewer(currentUser.map { jobAccessViewer(for: $0) })
    }

    // MARK: Gates the screens call

    /// `canCreateJob`: Add Project (`.projects`) / Add Small Works (`.smallWorks`).
    func canCreateJob(kind: JobKind) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        return CanonicalBusinessEngine.canCreateJob(viewer, kind: kind)
    }

    /// `canEditJob`: Edit on this job.
    func canEditJob(_ job: Project) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        return CanonicalBusinessEngine.canEditJob(viewer, job: job.jobAccessFields, kind: job.jobKind, managers: JobAccessContext.managers)
    }

    /// `canChangeJobManagers`: the manager picker on a job of this kind.
    func canChangeJobManagers(kind: JobKind) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        return CanonicalBusinessEngine.canChangeJobManagers(viewer, kind: kind)
    }

    /// `canSeeJob` for one job.
    func canSeeJob(_ job: Project) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        return CanonicalBusinessEngine.canSeeJob(viewer, job: job.jobAccessFields, managers: JobAccessContext.managers, kind: job.jobKind)
    }

    /// `canWriteBooking` for a labour (`bookings`) or subcontractor (`subcontractorBookings`) booking on `job`.
    func canWriteBooking(collection: String = "bookings", on job: Project?) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        var booking: [String: Any] = ["collection": collection]
        if let job { booking["projectId"] = job.documentId }
        return CanonicalBusinessEngine.canWriteBooking(viewer, booking: booking, job: job?.jobAccessFields, managers: JobAccessContext.managers)
    }

    /// `canDeleteBooking` for a labour or subcontractor booking on `job`.
    func canDeleteBooking(collection: String = "bookings", on job: Project?) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        var booking: [String: Any] = ["collection": collection]
        if let job { booking["projectId"] = job.documentId }
        return CanonicalBusinessEngine.canDeleteBooking(viewer, booking: booking, job: job?.jobAccessFields, managers: JobAccessContext.managers)
    }

    /// `canWriteBooking` for a manager site booking of `userId` at a job (`job`, project or small works) or at a
    /// place with no job (office, working from home, site survey, custom: `job` nil, `locationType` that place).
    func canWriteManagerSiteBooking(userId: String, locationType: String, job: Project?) -> Bool {
        guard let viewer = displayJobAccessViewer else { return false }
        var booking: [String: Any] = ["collection": "managerSiteBookings", "userId": userId, "locationType": locationType]
        if let job { booking["locationId"] = job.documentId }
        return CanonicalBusinessEngine.canWriteBooking(viewer, booking: booking, job: job?.jobAccessFields, managers: JobAccessContext.managers)
    }
}

// MARK: - Daily Overview and warning scope (§17)

/// `warningScopeFor({ viewer, visibleJobIds, bookings, managerBookings, people, operatives })` for the signed-in
/// account (the real profile, as the reads are). Nil when the scope is everything (`{ kind: 'all' }`) or the profile
/// is not loaded, so callers keep their unscoped call.
@MainActor
enum WarningScopeSupport {
    static func scope(
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        users: [AppUser],
        operatives: [Operative]
    ) -> [String: Any]? {
        guard let viewer = JobAccessContext.readViewer else { return nil }
        // RULEBOOK 1.31.0 §5 (owner decision): admins see everything; a manager — whatever their Projects / Small works
        // toggles — themselves, their reports and the jobs they manage. Admins skip building the inputs.
        if (viewer.role.isAdmin || viewer.role.isSuperAdmin) && !viewer.role.isOperativeMode { return nil }
        let scope = CanonicalBusinessEngine.warningScopeFor(
            viewer: viewer,
            visibleJobIds: JobAccessContext.visibleJobIds,
            bookings: bookings.map { ["projectId": $0.storedProjectId, "operativeId": $0.storedOperativeId] },
            managerBookings: managerBookings.map { booking -> [String: Any] in
                var row: [String: Any] = ["userId": booking.userId, "locationType": booking.locationType.rawValue]
                if let key = booking.locationKey ?? booking.locationId.map({ WorkDocumentKeys.storedId(for: $0) }) { row["locationId"] = key }
                return row
            },
            people: users.map { ["id": $0.id, "email": $0.email, "formerIds": $0.formerUserIds + $0.sameEmailUserIds] },
            operatives: operatives.map { ["id": $0.documentId, "email": $0.email] },
            jobs: JobAccessContext.jobManagerRows,
            managers: JobAccessContext.managers,
            roster: RulebookPeople.roster(users),
            // RULEBOOK 1.26.0 §17: with `enforcedReads` on a restricted viewer does not read every booking.
            enforced: SecuritySwitchContext.enforcedReads
        )
        return (scope["kind"] as? String) == "all" ? nil : scope
    }

    /// The scope as JSON for `WarningsComputationInput.warningScopeJSON`.
    static func scopeJSON(
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        users: [AppUser],
        operatives: [Operative]
    ) -> Data? {
        scope(bookings: bookings, managerBookings: managerBookings, users: users, operatives: operatives)
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }
}

/// RULEBOOK 1.33.0 §6 (owner decision 5 Nov, Q-D1 6 Nov): Daily Overview and the Home on-site / on-leave figures cover
/// the viewer's `dailyOverviewScopeFor` — admins everyone and every subcontractor booking; a manager only themselves
/// and their reports. The inputs are the ones `WarningScopeSupport` passes (web `orgDailyOverviewScope` uses the same
/// roster rows as `orgWarningScope`). The answer is kept per input (roster, operatives, viewer) and each row's answer
/// per scope, so a screen can ask for every row on every render. Nil scope means everything. No rule is decided here.
@MainActor
enum DailyOverviewScopeSupport {
    private static var cached: (key: Int, scope: [String: Any]?)?
    private static var rowAnswers: [String: Bool] = [:]

    /// The signed-in viewer's scope; nil when it is everything (`{ kind: 'all' }`) or the profile is not loaded.
    static func scope(users: [AppUser], operatives: [Operative]) -> [String: Any]? {
        guard let viewer = JobAccessContext.readViewer else { return nil }
        var hasher = Hasher()
        hasher.combine(viewer.uid)
        hasher.combine(viewer.ids)
        hasher.combine(viewer.email)
        hasher.combine(viewer.role.isSuperAdmin)
        hasher.combine(viewer.role.isAdmin)
        hasher.combine(viewer.role.isManager)
        hasher.combine(viewer.role.isOperativeMode)
        hasher.combine(users)
        for operative in operatives {
            hasher.combine(operative.documentId)
            hasher.combine(operative.email)
        }
        let key = hasher.finalize()
        if let cached, cached.key == key { return cached.scope }
        let scope = CanonicalBusinessEngine.dailyOverviewScopeFor(
            viewer: viewer,
            roster: RulebookPeople.roster(users),
            people: users.map { ["id": $0.id, "email": $0.email, "formerIds": $0.formerUserIds + $0.sameEmailUserIds] },
            operatives: operatives.map { ["id": $0.documentId, "email": $0.email] },
            enforced: SecuritySwitchContext.enforcedReads
        )
        let result = (scope["kind"] as? String) == "all" ? nil : scope
        cached = (key, result)
        rowAnswers.removeAll(keepingCapacity: true)
        return result
    }

    /// The scope as JSON (for work that leaves the main actor). Nil is everything.
    static func scopeJSON(users: [AppUser], operatives: [Operative]) -> Data? {
        scope(users: users, operatives: operatives).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    /// `isDailyOverviewRowInScope(scope, row)`, remembered per scope and row.
    static func isRowInScope(_ scope: [String: Any]?, personIds: [String], email: String?, subcontractor: Bool = false) -> Bool {
        guard let scope else { return true }
        let rowKey = personIds.joined(separator: "\u{1F}") + "|" + (email ?? "") + "|" + (subcontractor ? "s" : "p")
        if let hit = rowAnswers[rowKey] { return hit }
        let answer = CanonicalBusinessEngine.isDailyOverviewRowInScope(
            scope, personIds: personIds, email: email, subcontractor: subcontractor
        )
        if rowAnswers.count > 4096 { rowAnswers.removeAll(keepingCapacity: true) }
        rowAnswers[rowKey] = answer
        return answer
    }
}

/// The last few `jobAccessViewer(for:)` answers, by their inputs (main actor only).
@MainActor
final class JobAccessViewerMemo {
    struct Key: Equatable {
        let user: AppUser
        let roster: [AppUser]
        let authUid: String
        let currentUserId: String?
    }

    static let shared = JobAccessViewerMemo()
    private var entries: [(key: Key, viewer: JobAccessViewer)] = []
    private let limit = 4

    func value(for key: Key) -> JobAccessViewer? {
        entries.first { $0.key == key }?.viewer
    }

    func store(_ viewer: JobAccessViewer, for key: Key) {
        entries.removeAll { $0.key == key }
        entries.insert((key, viewer), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}
