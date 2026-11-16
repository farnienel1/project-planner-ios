import XCTest
@testable import Project_Planner

/// Fixes from the 16 Nov full platform scan (iOS findings). Each test names the failure it locks out.
@MainActor
final class IOSScanFixesTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of `func <name>(` up to the next function at the same indent.
    private func functionBody(_ name: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "func \(name)("), "func \(name) not found")
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    nonisolated static func ", "\n    @discardableResult"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    override func setUp() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    override func tearDown() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    // MARK: 1. Writes go to the open organisation, never the home company (AGENTS rule 2, RULEBOOK §14)

    /// Failure before: a member of companies A (home, `users/{uid}.organizationId`) and B who switched to B had their
    /// clients, job types, health & safety, deadlines, variations and catalogue items written into A.
    func testAPersonWhoSwitchedToTheirSecondCompanyWritesThere() {
        XCTAssertEqual(FirebaseBackend.openOrganizationIdForWrites(requested: "ORG-B", openOrganizationId: "ORG-B"), "ORG-B")
        // A queued record names its own company: that one, whatever is open now.
        XCTAssertEqual(FirebaseBackend.openOrganizationIdForWrites(requested: " ORG-B ", openOrganizationId: "ORG-C"), "ORG-B")
        // No company named: the open one.
        XCTAssertEqual(FirebaseBackend.openOrganizationIdForWrites(requested: nil, openOrganizationId: "ORG-B"), "ORG-B")
        XCTAssertEqual(FirebaseBackend.openOrganizationIdForWrites(requested: "  ", openOrganizationId: "ORG-B"), "ORG-B")
    }

    func testWithNoOrganisationOpenTheWriteIsRefused() {
        XCTAssertNil(FirebaseBackend.openOrganizationIdForWrites(requested: nil, openOrganizationId: nil))
        XCTAssertNil(FirebaseBackend.openOrganizationIdForWrites(requested: "", openOrganizationId: "  "))
    }

    func testTheResolverNeverReadsTheUsersDocument() throws {
        let backend = try source("Project Planner/FirebaseBackend.swift")
        let body = try functionBody("resolveOrganizationIdForFirebaseWrites", in: backend)
        XCTAssertFalse(body.contains("collection(\"users\")"), "the home company in users/{uid} is never a write target")
        XCTAssertFalse(body.contains("organizationIdFromFirestore"))
        let materials = try functionBody("resolveOrganizationIdForMaterials", in: backend)
        XCTAssertFalse(materials.contains("Falling back"), "no second company when the open one cannot be read")
        let store = try source("Project Planner/Core/VariationStore.swift")
        XCTAssertFalse(store.contains("resolveOrganizationIdForFirebaseWrites(preferredFallback: nil)"))
        for path in ["Project Planner/Views/ProjectDeadlinesView.swift", "Project Planner/Views/ProjectHealthSafetyView.swift"] {
            XCTAssertFalse(try source(path).contains("?? userStore.currentUser?.organizationId"), path)
        }
    }

    // MARK: 2. Every email goes through the authenticated `sendEmail` function

    /// Failure before: invites, reset links, timesheet exports and leave emails posted HTML to the open
    /// `sendProjectPlannerEmail` with no ID token, so the open relay could not be retired.
    func testNoCodeCallsTheOpenEmailFunction() throws {
        let fileManager = FileManager.default
        let root = repoRoot.appendingPathComponent("Project Planner")
        let enumerator = try XCTUnwrap(fileManager.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertFalse(code.contains("sendProjectPlannerEmail"), url.lastPathComponent)
            XCTAssertFalse(code.contains("api.resend.com"), url.lastPathComponent)
            XCTAssertFalse(code.contains("ResendEmailService"), url.lastPathComponent)
        }
    }

    func testInviteAndResetSendOnlyTheInvitationId() {
        let body = AppEmailPayload.body(
            organizationId: "ORG-B",
            template: .inviteSetup,
            to: [" Ada@Example.com "],
            data: AppEmailPayload.invitationData(invitationId: "550E8400-E29B-41D4-A716-446655440000")
        )
        XCTAssertEqual(body["template"] as? String, "invite_setup")
        XCTAssertEqual(body["orgId"] as? String, "ORG-B")
        XCTAssertEqual(body["to"] as? [String], ["ada@example.com"])
        XCTAssertEqual((body["data"] as? [String: Any])?["invitationId"] as? String, "550E8400-E29B-41D4-A716-446655440000")
        XCTAssertNil(body["html"], "the phone never sends HTML")
        XCTAssertNil(body["subject"])
        XCTAssertNil(body["fromName"])
        XCTAssertNil(body["attachments"])
        XCTAssertEqual(AppEmailTemplate.passwordResetLink.rawValue, "password_reset_link")
    }

    func testTimesheetExportCarriesItsFieldsAndOnlyStorageLinks() {
        let data = AppEmailPayload.timesheetExportData(
            weekTitle: "26 Oct - 1 Nov",
            paymentRunStamp: "26.10.26 01.11.26",
            timesheetCount: 2,
            downloadLinks: [
                (fileName: "a.pdf", url: "https://firebasestorage.googleapis.com/v0/b/x/o/a.pdf"),
                (fileName: "b.pdf", url: "https://example.com/b.pdf"),
            ]
        )
        XCTAssertEqual(data["weekTitle"] as? String, "26 Oct - 1 Nov")
        XCTAssertEqual(data["paymentRunStamp"] as? String, "26.10.26 01.11.26")
        XCTAssertEqual(data["timesheetCount"] as? Int, 2)
        let links = data["downloadLinks"] as? [[String: Any]] ?? []
        XCTAssertEqual(links.count, 1, "the function refuses any link that is not Firebase Storage")
        let pdf = Data("%PDF-1.4".utf8)
        let body = AppEmailPayload.body(
            organizationId: "ORG-B",
            template: .timesheetExport,
            to: ["me@example.com"],
            data: data,
            attachments: [(fileName: "a.pdf", data: pdf)],
            requestId: "1234567890-abcdef"
        )
        let rows = body["attachments"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["filename"] as? String, "a.pdf")
        XCTAssertEqual(rows.first?["content"] as? String, pdf.base64EncodedString())
        XCTAssertEqual(body["requestId"] as? String, "1234567890-abcdef")
        XCTAssertTrue(AppEmailPayload.attachmentsFit([(fileName: "a.pdf", data: pdf)]))
        XCTAssertFalse(AppEmailPayload.attachmentsFit([(fileName: "big.pdf", data: Data(count: AppEmailPayload.maxAttachmentBytes + 1))]))
    }

    func testLeaveCancelledSendsOnlyTheDates() {
        let data = AppEmailPayload.leaveCancelledData(dateText: " 3 Nov 2026 ")
        XCTAssertEqual(data["dateText"] as? String, "3 Nov 2026")
        XCTAssertEqual(data.count, 1)
    }

    // MARK: 3. Material line edits (RULEBOOK §1 partial writes, `editOfMissingDocumentIsRefused`)

    /// Failure before: an edit of a line deleted on web re-created it (whole `setData`).
    func testAMaterialEditIsNeverACreate() {
        let line = MaterialItem(quantity: 2, unit: .number, material: "Pipe", addedBy: "TEST-User", projectId: UUID(), date: Date())
        XCTAssertEqual(FirebaseBackend.materialSaveMode(material: line, opened: nil), .create)
        XCTAssertEqual(FirebaseBackend.materialSaveMode(material: line, opened: line), .update)
        var queuedEdit = line
        queuedEdit.editedAt = Date()
        XCTAssertEqual(FirebaseBackend.materialSaveMode(material: queuedEdit, opened: nil), .update, "an older queued edit")
        XCTAssertEqual(RecordWritePlan.action(mode: .update, documentExists: false), .refuseDeletedElsewhere)
    }

    func testAMaterialEditDiffsAgainstTheCopyTheUserOpened() throws {
        let body = try functionBody("saveMaterialItem", in: try source("Project Planner/FirebaseBackend.swift"))
        XCTAssertTrue(body.contains("refuseDeletedElsewhere"))
        XCTAssertTrue(body.contains("materialLinePayload(opened"), "only the user's own changes are written")
        for path in ["Project Planner/Views/EditMaterialView.swift", "Project Planner/Views/MaterialsAddWithCatalogueSheet.swift"] {
            XCTAssertTrue(try source(path).contains("opened:"), path)
        }
    }

    // MARK: 4. Materials, material emails and deadlines are online only (RULEBOOK §2 `OFFLINE_ACTIONS`)

    func testUnlistedActionsAreOnlineOnly() {
        for action in UnlistedOfflineAction.allCases {
            XCTAssertEqual(OfflinePolicy.availability(action), .onlineOnly, action.rawValue)
            XCTAssertFalse(OfflinePolicy.isEnabled(action, isOnline: false), action.rawValue)
            XCTAssertTrue(OfflinePolicy.isEnabled(action, isOnline: true), action.rawValue)
            XCTAssertThrowsError(try OfflinePolicy.requireAvailable(action, isOnline: false))
        }
        XCTAssertEqual(OnlineOnlyActionError(actionId: "x").localizedDescription, "Connect to the internet to change this")
    }

    func testOfflineMaterialAndDeadlineWritesAreNeverQueued() throws {
        let service = try source("Project Planner/Core/MaterialOfflineService.swift")
        XCTAssertFalse(service.contains("enqueueSaveMaterialItem"))
        XCTAssertFalse(service.contains("enqueueDeleteMaterialItem"))
        XCTAssertFalse(service.contains("enqueueSendMaterialRequest"))
        XCTAssertFalse(try source("Project Planner/Views/ProjectDeadlinesView.swift").contains("enqueueSaveDeadlines"))
    }

    // MARK: 5. Deadline saves write only the person's changes and never drop them silently

    private func deadline(_ id: UUID, _ title: String, progress: Double = 0) -> DLDeadline {
        DLDeadline(id: id, title: title, due: Date(timeIntervalSince1970: 1_800_000_000), progress: progress)
    }

    /// Failure before: a save wrote the whole list; when the server was newer every local edit was dropped silently.
    func testOnlyThePersonsChangesAreLaidOverTheStoredList() {
        let a = UUID(), b = UUID(), c = UUID()
        let base = [deadline(a, "A"), deadline(b, "B")]
        // Someone else edited B and added C after this person loaded.
        let stored = [deadline(a, "A"), deadline(b, "B", progress: 0.5), deadline(c, "C")]
        // This person edited A.
        let next = [deadline(a, "A", progress: 1), deadline(b, "B")]
        let merge = FirebaseBackend.mergeDeadlineChanges(stored: stored, base: base, next: next)
        XCTAssertTrue(merge.changed)
        XCTAssertTrue(merge.notApplied.isEmpty)
        XCTAssertEqual(merge.items.first { $0.id == a }?.progress, 1)
        XCTAssertEqual(merge.items.first { $0.id == b }?.progress, 0.5, "the other person's edit is kept")
        XCTAssertNotNil(merge.items.first { $0.id == c }, "the other person's new deadline is kept")
    }

    func testAConflictingEditIsReportedNotDropped() {
        let a = UUID()
        let base = [deadline(a, "A")]
        let stored = [deadline(a, "A", progress: 0.5)]
        let next = [deadline(a, "A", progress: 1)]
        let merge = FirebaseBackend.mergeDeadlineChanges(stored: stored, base: base, next: next)
        XCTAssertFalse(merge.changed)
        XCTAssertEqual(merge.notApplied.map(\.id), [a])
        XCTAssertEqual(merge.items.first?.progress, 0.5)
    }

    func testDeletesAndAddsApplyAndAnEditOfADeletedDeadlineIsReported() {
        let a = UUID(), b = UUID(), d = UUID()
        let base = [deadline(a, "A"), deadline(b, "B")]
        let stored = [deadline(a, "A")] // B was deleted elsewhere.
        let next = [deadline(b, "B", progress: 1), deadline(d, "D")] // This person deleted A, edited B, added D.
        let merge = FirebaseBackend.mergeDeadlineChanges(stored: stored, base: base, next: next)
        XCTAssertTrue(merge.changed)
        XCTAssertNil(merge.items.first { $0.id == a }, "A deleted")
        XCTAssertNotNil(merge.items.first { $0.id == d }, "D added")
        XCTAssertNil(merge.items.first { $0.id == b }, "B is never re-created")
        XCTAssertEqual(merge.notApplied.map(\.id), [b])
    }

    func testDeadlinesUseServerTimeAndNoWholeListOverwrite() throws {
        let backend = try source("Project Planner/FirebaseBackend.swift")
        XCTAssertFalse(backend.contains("mergeDeadlinesFirstWriterWins"))
        let body = try functionBody("saveDeadlineChanges", in: backend)
        XCTAssertTrue(body.contains("FieldValue.serverTimestamp()"))
        XCTAssertFalse(body.contains("Timestamp(date: Date())"))
    }

    // MARK: 6. "Assigned to me" is the rulebook's `tasksAssignedToViewer`

    /// Failure before: the iPhone matched the first `operatives` row on the email only, so a task assigned to the
    /// person's second row was missing from "Assigned to me" while Home and web counted it.
    func testATaskOnTheSecondOperativesRowIsTheViewers() {
        let viewer = LogicFixtures.selfEmployedUser(id: "user-1", email: "ada@example.com")
        let first = LogicFixtures.operative(id: UUID(), email: "ada@example.com")
        let second = LogicFixtures.operative(id: UUID(), email: "Ada@Example.com")
        let other = LogicFixtures.operative(id: UUID(), email: "someone@example.com")
        let mine = ProjectTask(projectId: UUID(), title: "Mine", createdBy: "TEST", assignedOperativeIds: [second.id])
        let theirs = ProjectTask(projectId: UUID(), title: "Theirs", createdBy: "TEST", assignedOperativeIds: [other.id])
        let assigned = TaskAssignmentRulebook.assignedTasks(
            [mine, theirs],
            viewer: viewer,
            organizationUsers: [viewer],
            operatives: [first, second, other],
            managers: []
        )
        XCTAssertEqual(assigned.map(\.id), [mine.id])
        XCTAssertTrue(TaskAssignmentRulebook.isAssigned(mine, viewer: viewer, organizationUsers: [viewer], operatives: [first, second, other], managers: []))
        XCTAssertFalse(TaskAssignmentRulebook.isAssigned(theirs, viewer: viewer, organizationUsers: [viewer], operatives: [first, second, other], managers: []))
        XCTAssertTrue(TaskAssignmentRulebook.assignedTasks([mine], viewer: nil, organizationUsers: [], operatives: [second], managers: []).isEmpty)
    }

    func testTheOwnTaskMatcherIsGone() throws {
        XCTAssertFalse(try source("Project Planner/Models/ProjectTask.swift").contains("func isAssignedToUser("))
        for path in ["Project Planner/Views/TasksDetailView.swift", "Project Planner/Views/ProjectDetailView.swift",
                     "Project Planner/Views/HomeView.swift", "Project Planner/Core/WorkAccess.swift"] {
            XCTAssertFalse(try source(path).contains("isAssignedToUser("), path)
        }
    }

    // MARK: 7. Low

    /// Failure before: with the script silent or the profile not loaded, a manager's Warnings and Daily Overview
    /// showed the whole company (`{ kind: 'all' }`).
    func testTheScopeFailsClosed() {
        let none = CanonicalBusinessEngine.noWarningScope
        XCTAssertNotEqual(none["kind"] as? String, "all")
        XCTAssertEqual((none["personIds"] as? [Any])?.count, 0)
        XCTAssertFalse(CanonicalBusinessEngine.isDailyOverviewRowInScope(none, personIds: ["user-1"], email: "a@example.com"))
        let previousViewer = JobAccessContext.readViewer
        let previousSignedIn = JobAccessContext.signedIn
        defer {
            JobAccessContext.updateSignedIn(previousSignedIn)
            JobAccessContext.updateViewer(previousViewer)
        }
        // Signed in, profile still loading.
        JobAccessContext.updateViewer(nil)
        JobAccessContext.updateSignedIn(true)
        XCTAssertTrue(JobAccessContext.viewerPending)
        let daily = DailyOverviewScopeSupport.scope(users: [], operatives: [])
        XCTAssertNotNil(daily, "nil would mean everyone")
        XCTAssertFalse(DailyOverviewScopeSupport.isRowInScope(daily, personIds: ["user-1"], email: nil))
        XCTAssertNotNil(WarningScopeSupport.scope(bookings: [], managerBookings: [], users: [], operatives: []))
        // Nobody signed in (as in unit tests): nothing to wait for, the unscoped rules apply as before.
        JobAccessContext.updateSignedIn(false)
        XCTAssertFalse(JobAccessContext.viewerPending)
        XCTAssertNil(DailyOverviewScopeSupport.scope(users: [], operatives: []))
    }

    func testTheJobTasksTileUsesTheOrganisationDay() throws {
        let page = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertFalse(page.contains("return cal.startOfDay(for: due) < startOfToday"))
        XCTAssertTrue(page.contains("CanonicalBusinessEngine.isTaskOverdue(status: $0.status.rawValue, dueDate: $0.dueDate)"))
    }

    func testTheBookingLoadStartUsesTheOrganisationWeek() throws {
        let body = try functionBody("launchScheduleLowerBound", in: try source("Project Planner/FirebaseBackend.swift"))
        XCTAssertTrue(body.contains("organizationWeekStartDayKey"))
        // 18 Nov 2026 is a Wednesday: its organisation week starts on Monday 16 Nov (London).
        let wednesday = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18T11:06:40Z
        XCTAssertEqual(CanonicalBusinessEngine.organizationWeekStartDayKey(containing: wednesday, timeZone: "Europe/London"), "2026-11-16")
    }

    /// Failure before: a save put back after a failed delete lost the copy before the first edit, so the PAYE person
    /// was never told their overtime line reopened.
    func testARequeuedSaveKeepsTheCopyBeforeTheFirstEdit() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "18:00")
        var first = synced
        first.workEndTime = "17:00"
        outbox.enqueueSaveBooking(first, changedFields: ["workEndTime"], organizationId: "TEST-ORG", previous: synced)
        let taken = outbox.takeQueuedBookingSaves(bookingId: synced.id)
        XCTAssertTrue(outbox.entries.isEmpty)
        var second = first
        second.workStartTime = "08:00"
        outbox.enqueueSaveBooking(second, changedFields: ["workStartTime"], organizationId: "TEST-ORG", previous: first)
        outbox.requeueBookingSaves(taken.entries)
        XCTAssertEqual(outbox.entries.count, 1)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(payload.previousBooking?.workEndTime, "18:00", "the copy the server had before the first edit")
        XCTAssertEqual(payload.booking.workStartTime, "08:00")
    }

    func testAnOfflineDeleteIsComparedInItsOwnCompanysZone() {
        XCTAssertEqual(
            FirebaseBackend.offlineDeleteTimeZone(sameOrganization: true, openTimeZone: "Europe/London", entryCountryCode: .none),
            "Europe/London"
        )
        XCTAssertEqual(
            FirebaseBackend.offlineDeleteTimeZone(sameOrganization: false, openTimeZone: "Europe/London", entryCountryCode: .some("IE")),
            CanonicalBusinessEngine.organizationTimeZoneIdentifier(countryCode: "IE")
        )
        XCTAssertNil(
            FirebaseBackend.offlineDeleteTimeZone(sameOrganization: false, openTimeZone: "Europe/London", entryCountryCode: .none),
            "unknown zone: the fingerprint check is skipped, never run in the wrong zone"
        )
    }

    func testASiteAuditPhotoNeverStoresAGsAddress() throws {
        let body = try functionBody("uploadSiteAuditImage", in: try source("Project Planner/FirebaseBackend.swift"))
        XCTAssertFalse(body.contains("gs://"))
        XCTAssertTrue(body.contains("downloadURLOrRemoveUpload"))
    }
}
