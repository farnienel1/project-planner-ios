import XCTest
@testable import Project_Planner

/// iOS 1.33.1 (owner test on iPhone, 7 Nov): (a) Save in project / small works scheduling kept spinning although the
/// booking had saved; (b) editing a booking's time from Scheduling opened the whole Schedule booking screen instead of
/// the wheels in Edit booking. Guardrail 7: the edit writes exactly the fields it wrote before.
@MainActor
final class Booking1331SaveFlowTests: XCTestCase {
    nonisolated override func setUp() {
        super.setUp()
        JobAccessContext.updateViewer(nil)
    }

    nonisolated override func tearDown() {
        JobAccessContext.updateViewer(nil)
        super.tearDown()
    }

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: key))
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The body of `func name(` in `text`, up to the next `    private func ` / `    func ` at the same indent.
    private func body(of marker: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: marker), "\(marker) not found")
        let rest = text[start.upperBound...]
        let next = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
        return rest[..<(next?.lowerBound ?? rest.endIndex)]
    }

    // MARK: (a) the screen finishes when the save is done

    func testOutcomeIsDecidedFromThisSaveOnly() {
        let queued = BookingSaveResult.queued(BookingStore.pendingSyncMessage)
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.saved, .saved, .saved]), .confirmed)
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: []), .nothingToSave)
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.refused("Refused")]), .notSaved("Refused"))
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.refused("  ")]), .notSaved("This booking could not be saved."))
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.saved, .refused("Refused")]), .savedWithProblem("Refused"))
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [queued, .refused("Refused")]), .savedWithProblem("Refused"))

        // Every outcome ends the spinner with something on screen; only a save that did nothing keeps the choices.
        XCTAssertTrue(ScheduleBookingSaveOutcome.confirmed.closesScreen)
        XCTAssertTrue(ScheduleBookingSaveOutcome.pendingSync("x").closesScreen)
        XCTAssertTrue(ScheduleBookingSaveOutcome.savedWithProblem("x").closesScreen)
        XCTAssertTrue(ScheduleBookingSaveOutcome.nothingToSave.closesScreen)
        XCTAssertFalse(ScheduleBookingSaveOutcome.notSaved("x").closesScreen)
        XCTAssertFalse(ScheduleBookingSaveOutcome.notSaved("x").clearsSelection)
        XCTAssertTrue(ScheduleBookingSaveOutcome.savedWithProblem("x").clearsSelection)
        XCTAssertTrue(ScheduleBookingSaveOutcome.pendingSync("x").clearsSelection)
    }

    /// Review item 4: a timed-out (queued) save counts as saved with "Pending sync" wording — never "not saved", which
    /// made the booker retry — and only kept bookings send notices.
    func testAQueuedSaveIsSavedPendingSyncNotNotSaved() throws {
        let queued = BookingSaveResult.queued(BookingStore.pendingSyncMessage)
        let outcome = ScheduleBookingSaveOutcome.decide(results: [queued])
        XCTAssertEqual(outcome, .pendingSync(BookingStore.pendingSyncMessage))
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.saved, queued]), .pendingSync(BookingStore.pendingSyncMessage))
        XCTAssertEqual(ScheduleBookingSaveAlert(outcome: outcome, message: "x").title, "Booking saved — Pending sync")
        XCTAssertTrue(queued.keepsBooking)
        XCTAssertTrue(BookingSaveResult.saved.keepsBooking)
        XCTAssertFalse(BookingSaveResult.refused("x").keepsBooking)

        let wizard = try source("Views/ScheduleOperativeView.swift")
        let proceed = try body(of: "private func proceedWithBooking()", in: wizard)
        XCTAssertTrue(proceed.contains("ScheduleBookingSaveOutcome.decide(results: saveResults)"))
        XCTAssertEqual(
            proceed.components(separatedBy: "createdDatesByOperative[").count - 1, 2,
            "a booking is counted (and notified) only from its own kept outcome, for edits and for new bookings"
        )
        XCTAssertEqual(proceed.components(separatedBy: "if result.keepsBooking {").count - 1, 2)
    }

    func testAStaleStoreMessageIsNotReadAsThisEditFailing() async throws {
        let store = BookingStore()
        let monday = try day("2026-11-02")
        let booking = LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00")
        store.bookings = [booking]
        store.errorMessage = "Missing or insufficient permissions."  // left by an earlier load

        var edited = booking
        edited.workEndTime = "17:00"
        let result = await store.updateBookingReportingProblem(edited)

        // No server here, so the edit is kept on this phone (queued); the earlier load's message is not this save's.
        XCTAssertTrue(result.keepsBooking, "\(result)")
        XCTAssertEqual(store.bookings.first?.workEndTime, "17:00")
    }

    func testARefusedSaveReportsItsOwnMessage() async throws {
        var job = Project(
            jobNumber: "TEST-J1",
            siteName: "TEST-Kitchen refit",
            siteAddress: "1 Test Street",
            client: Client(name: "TEST-Client"),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        )
        job.storedManagerUserIds = ["TEST-someone-else"]
        JobAccessContext.updateJobs([job])
        defer { JobAccessContext.updateJobs([]) }
        JobAccessContext.updateViewer(JobAccessViewer(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false),
            projectsToggle: true,
            smallWorksToggle: true,
            uid: "TEST-manager",
            ids: ["TEST-manager"],
            email: "TEST-manager@x.t"
        ))
        let store = BookingStore()
        let booking = LogicFixtures.booking(on: try day("2026-11-02"), projectId: job.id)

        let results = await store.addBookingsReportingProblem([booking])

        guard case .refused(let message)? = results[booking.id] else {
            return XCTFail("a manager is refused on a job they do not manage, and the screen says so: \(results)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(store.bookings.contains { $0.id == booking.id })
    }

    // MARK: A write the server does not confirm in time stays with Firestore (never a second copy in the outbox)

    /// The bounded wait ends, and the error reads as "Firestore holds it" — never as a reason to queue a second copy.
    func testAWriteTheServerNeverConfirmsStopsWaitingAsPendingInFirestore() async {
        let started = Date()
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 0.2) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
            XCTFail("expected the bounded wait to end")
        } catch {
            XCTAssertTrue(error is FirestoreWriteAck.TimedOut)
            XCTAssertTrue(FirestoreWriteAck.isPendingInSDK(error))
            XCTAssertFalse(
                OfflineWriteSupport.shouldQueue(error: error, isOnline: true),
                "online, a timed-out write is never read as a reason to queue it in the app outbox"
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A timed-out write is remembered as pending (Pending sync on screen) until Firestore finishes it.
    func testATimedOutWriteIsPendingUntilFirestoreFinishesIt() async throws {
        SDKPendingWrites.shared.removeAll()
        defer { SDKPendingWrites.shared.removeAll() }
        let key = SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: "TEST-B1")
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 0.1, pendingKey: key) {
                try await Task.sleep(nanoseconds: 600_000_000)
            }
            XCTFail("expected the bounded wait to end")
        } catch {
            XCTAssertTrue(FirestoreWriteAck.isPendingInSDK(error))
        }
        XCTAssertTrue(SDKPendingWrites.shared.contains(path: key))
        XCTAssertTrue(SDKPendingWrites.shared.contains(collection: "bookings", documentId: "test-b1"), "ids without case")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(SDKPendingWrites.shared.contains(path: key), "cleared once Firestore finished the write")

        // A write confirmed in time is never marked.
        try await FirestoreWriteAck.run(timeoutSeconds: 5, pendingKey: key) {}
        XCTAssertFalse(SDKPendingWrites.shared.contains(path: key))
    }

    /// Test 1: a timed-out create is not put in the app outbox, and its outcome is Pending sync.
    func testATimedOutCreateIsQueuedInFirestoreNotTheAppOutbox() async {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let booking = LogicFixtures.booking(on: Date())
        var waits: [Double] = []
        let run = await BookingStore.performWrites(
            [BookingStore.BookingWrite(booking: booking, changedFields: nil)],
            organizationId: "TEST-ORG",
            isOnline: true
        ) { _, ackTimeout in
            waits.append(ackTimeout)
            throw FirestoreWriteAck.TimedOut()
        }
        XCTAssertEqual(run.results[booking.id], .queued(BookingStore.pendingSyncMessage))
        XCTAssertEqual(run.pendingCount, 1)
        XCTAssertTrue(run.refusedIds.isEmpty)
        XCTAssertTrue(OfflineOutboxStore.shared.entries.isEmpty, "Firestore already holds it: never a second copy")
        XCTAssertEqual(waits, [FirestoreWriteAck.defaultTimeoutSeconds])
        XCTAssertEqual(
            ScheduleBookingSaveOutcome.decide(results: Array(run.results.values)),
            .pendingSync(BookingStore.pendingSyncMessage)
        )
    }

    /// One timeout in a group save: the later writes are still handed over in order, with a short wait each.
    func testAfterOneTimeoutTheRestOfTheSaveWaitsBriefly() async {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let writes = (0..<3).map { _ in
            BookingStore.BookingWrite(booking: LogicFixtures.booking(on: Date()), changedFields: nil)
        }
        var order: [UUID] = []
        var waits: [Double] = []
        let run = await BookingStore.performWrites(writes, organizationId: "TEST-ORG", isOnline: true) { write, ackTimeout in
            order.append(write.booking.id)
            waits.append(ackTimeout)
            throw FirestoreWriteAck.TimedOut()
        }
        XCTAssertEqual(order, writes.map { $0.booking.id }, "same order, every write handed over")
        XCTAssertEqual(
            waits,
            [FirestoreWriteAck.defaultTimeoutSeconds, BookingStore.afterTimeoutAckSeconds, BookingStore.afterTimeoutAckSeconds]
        )
        XCTAssertEqual(run.pendingCount, 3)
        XCTAssertTrue(OfflineOutboxStore.shared.entries.isEmpty)
    }

    /// Test 2: an edit after a timed-out create is not refused (its read uses this device's cache, where the create
    /// is) and not dropped (nothing in the outbox merges it away; it is written through Firestore after the create).
    func testAnEditAfterATimedOutCreateIsNeitherRefusedNorDropped() async {
        OfflineOutboxStore.shared.clearAll()
        SDKPendingWrites.shared.removeAll()
        defer {
            OfflineOutboxStore.shared.clearAll()
            SDKPendingWrites.shared.removeAll()
        }
        var booking = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "16:00")
        let path = SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: booking.documentKey)
        var written: [Set<String>?] = []

        let create = await BookingStore.performWrites(
            [BookingStore.BookingWrite(booking: booking, changedFields: nil)],
            organizationId: "TEST-ORG",
            isOnline: true
        ) { write, _ in
            written.append(write.changedFields)
            try await FirestoreWriteAck.run(timeoutSeconds: 0.1, pendingKey: path) {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        XCTAssertEqual(create.results[booking.id], .queued(BookingStore.pendingSyncMessage))
        XCTAssertTrue(SDKPendingWrites.shared.contains(path: path))

        // The edit's existence check reads this device's cache while the create is on its way; a cache without it
        // writes the edited fields with `updateData` — never "not found".
        XCTAssertEqual(
            FirestoreWriteAck.editReadSource(pendingOnThisDevice: SDKPendingWrites.shared.contains(path: path)),
            .localCache
        )
        XCTAssertEqual(FirestoreWriteAck.editReadOutcome(answeredByServer: false, exists: true), .diffAgainstStored)
        XCTAssertEqual(FirestoreWriteAck.editReadOutcome(answeredByServer: false, exists: false), .writeUnchecked)
        // Only a server answer of "not there" refuses an edit (`editOfMissingDocumentIsRefused`).
        XCTAssertEqual(FirestoreWriteAck.editReadOutcome(answeredByServer: true, exists: false), .refuseMissing)
        XCTAssertEqual(FirestoreWriteAck.editReadSource(pendingOnThisDevice: false), .server)

        booking.workEndTime = "17:00"
        let edit = await BookingStore.performWrites(
            [BookingStore.BookingWrite(booking: booking, changedFields: ["workEndTime"])],
            organizationId: "TEST-ORG",
            isOnline: true
        ) { write, _ in
            written.append(write.changedFields)
            throw FirestoreWriteAck.TimedOut()
        }
        XCTAssertEqual(edit.results[booking.id], .queued(BookingStore.pendingSyncMessage), "not refused")
        XCTAssertEqual(written.count, 2, "the edit was handed to Firestore after the create")
        XCTAssertEqual(written.last ?? nil, Set(["workEndTime"]), "still only the edited field")
        XCTAssertTrue(OfflineOutboxStore.shared.entries.isEmpty, "nothing in the outbox to merge it into and drop")
    }

    /// The backend's edit paths read through `readBeforeEdit` (bounded server read, the cache while a write is
    /// pending) and keep the not-found refusal (code 5) for a server answer only.
    func testEditsNeverReadTheServerWithoutABound() throws {
        let backend = try source("FirebaseBackend.swift")
        let markers = [
            "func saveBooking(\n        _ booking: Booking,",
            "func saveManagerSiteBooking(_ booking: ManagerSiteBooking,",
        ]
        for marker in markers {
            let decl = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: marker, in: backend), marker)
            XCTAssertFalse(decl.contains("getDocument(source: .server)"), "\(marker): an unbounded read can spin for ever")
            XCTAssertTrue(decl.contains("readBeforeEdit(ref)"), marker)
            XCTAssertTrue(decl.contains("editReadOutcome(answeredByServer: read.answeredByServer"), marker)
            XCTAssertTrue(decl.contains("code: 5"), marker)
            XCTAssertTrue(decl.contains("pendingKey: ref.path"), marker)
        }
        let read = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: "static func readBeforeEdit(", in: backend))
        XCTAssertTrue(read.contains("boundedServerRead(ref)"))
        XCTAssertTrue(read.contains("getDocument(source: .cache)"))
    }

    /// Test 3: a delete after a timed-out create goes through Firestore (delete + tombstone in one batch, after the
    /// create), even when the app thinks it is offline; it is never a local drop.
    func testADeleteAfterATimedOutCreateWritesTheDeleteAndItsTombstone() async throws {
        OfflineOutboxStore.shared.clearAll()
        SDKPendingWrites.shared.removeAll()
        defer {
            OfflineOutboxStore.shared.clearAll()
            SDKPendingWrites.shared.removeAll()
        }
        let booking = LogicFixtures.booking(on: Date())
        let path = SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: booking.documentKey)
        _ = await BookingStore.performWrites(
            [BookingStore.BookingWrite(booking: booking, changedFields: nil)],
            organizationId: "TEST-ORG",
            isOnline: true
        ) { _, _ in
            try await FirestoreWriteAck.run(timeoutSeconds: 0.1, pendingKey: path) {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        let pending = SDKPendingWrites.shared.contains(collection: "bookings", documentId: booking.documentKey)
        XCTAssertTrue(pending)
        XCTAssertEqual(BookingStore.deleteRoute(queuesWhileOffline: false, pendingInFirestore: pending), .firestore)
        XCTAssertEqual(BookingStore.deleteRoute(queuesWhileOffline: true, pendingInFirestore: pending), .firestore)
        XCTAssertTrue(OfflineOutboxStore.shared.entries.isEmpty, "no queued create for a delete to drop")

        let store = try source("Core/BookingStore.swift")
        let delete = try body(of: "    func deleteBooking(_ booking: Booking) async {", in: store)
        XCTAssertTrue(delete.contains("Self.deleteRoute("))
        XCTAssertTrue(delete.contains("try await fb.deleteBooking(booking, organizationId: orgId)"))
        let backend = try source("FirebaseBackend.swift")
        let batch = try XCTUnwrap(
            AddUserSavedDataGuardTests.declaration(startingAt: "private func deleteBookingWithTombstone(", in: backend)
        )
        XCTAssertTrue(batch.contains("batch.deleteDocument("))
        XCTAssertTrue(batch.contains("batch.setData(tombstone"), "the tombstone goes in the same batch")
    }

    /// Test 4: an organisation switch during a save writes nothing to the other company. Outbox entries take the
    /// organisation the save captured, and a save whose organisation is no longer open writes nothing.
    func testAnOrganisationSwitchMidSaveWritesNothingToAnotherCompany() async throws {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        XCTAssertTrue(BookingStore.organizationChanged(captured: "TEST-ORG-A", open: "TEST-ORG-B"))
        XCTAssertFalse(BookingStore.organizationChanged(captured: "TEST-ORG-A", open: "TEST-ORG-A"))
        XCTAssertFalse(BookingStore.organizationChanged(captured: nil, open: "TEST-ORG-B"))
        XCTAssertFalse(BookingStore.organizationChanged(captured: "TEST-ORG-A", open: nil))

        // The connection drops before anything is handed to Firestore: queued under the captured organisation.
        let booking = LogicFixtures.booking(on: Date())
        let run = await BookingStore.performWrites(
            [BookingStore.BookingWrite(booking: booking, changedFields: nil)],
            organizationId: "TEST-ORG-A",
            isOnline: true
        ) { _, _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        }
        XCTAssertEqual(run.results[booking.id], .queued(BookingStore.pendingSyncMessage))
        XCTAssertEqual(OfflineOutboxStore.shared.entries.map { $0.organizationId }, ["TEST-ORG-A"])

        // The schedule screen captures the organisation once and passes it to every write and notice.
        let wizard = try source("Views/ScheduleOperativeView.swift")
        let proceed = try body(of: "private func proceedWithBooking()", in: wizard)
        XCTAssertTrue(proceed.contains("let savingOrganizationId = firebaseBackend.resolvedOrganizationIdForOfflineWrites()"))
        XCTAssertTrue(proceed.contains("updateBookingReportingProblem(replaced, organizationId: savingOrganizationId)"))
        XCTAssertTrue(proceed.contains("addBookingsReportingProblem(newBookings, organizationId: savingOrganizationId)"))
        XCTAssertTrue(proceed.contains("catalogue: catalogue,\n                        organizationId: savingOrganizationId"))
        let store = try source("Core/BookingStore.swift")
        let save = try body(of: "private func saveData(", in: store)
        XCTAssertEqual(
            save.components(separatedBy: "resolvedOrganizationIdForOfflineWrites()").count - 1, 1,
            "the organisation is resolved once per save and used for every write"
        )
    }

    /// Test 5: a booking created while the app knew it was offline is still dropped locally when deleted (RULEBOOK
    /// 1.33.0 §2 `dropLocal`), unchanged.
    func testAGenuinelyOfflineCreateThenDeleteIsStillDroppedLocally() {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG")
        XCTAssertEqual(BookingStore.deleteRoute(queuesWhileOffline: true, pendingInFirestore: false), .outbox)
        XCTAssertEqual(
            outbox.enqueueDeleteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG"),
            .droppedLocal
        )
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// A replayed outbox write that times out is with Firestore now: it leaves the outbox (never sent twice).
    func testAReplayThatTimesOutLeavesTheOutbox() throws {
        let coordinator = try source("Core/OfflineSyncCoordinator.swift")
        let process = try XCTUnwrap(
            AddUserSavedDataGuardTests.declaration(startingAt: "static func processOutbox(", in: coordinator)
        )
        let range = try XCTUnwrap(process.range(of: "if FirestoreWriteAck.isPendingInSDK(error) {"))
        let branch = process[range.upperBound...].prefix(600)
        XCTAssertTrue(branch.contains("outbox.removeEntry(id: entry.id)"))
        XCTAssertTrue(branch.contains("continue"))
    }

    func testAConfirmedOrRefusedWriteIsPassedThrough() async {
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 5) {}
        } catch {
            XCTFail("a confirmed write must not throw: \(error)")
        }
        struct Refused: Error {}
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 5) { throw Refused() }
            XCTFail("expected the refusal")
        } catch {
            XCTAssertTrue(error is Refused)
        }
    }

    func testScheduleBookingAndQuickAddDoNotWaitForTheNotices() throws {
        let wizard = try source("Views/ScheduleOperativeView.swift")
        let proceed = try body(of: "private func proceedWithBooking()", in: wizard)
        XCTAssertFalse(proceed.contains("await notificationService.notifyBookedUsers"))
        XCTAssertFalse(proceed.contains("bookingStore.errorMessage == nil"))
        XCTAssertTrue(proceed.contains("updateBookingReportingProblem"))

        let detail = try source("Views/ProjectDetailView.swift")
        let quickAdd = try body(of: "private func commitQuickAdd(", in: detail)
        XCTAssertFalse(quickAdd.contains("await notificationService.notifyBookedUsers"))
    }

    // MARK: (b) Edit booking from Scheduling

    func testTappingAGroupBookingOpensEditBookingNotTheScheduleScreen() throws {
        let detail = try source("Views/ProjectDetailView.swift")
        let tap = try body(of: "private func handleSchedulingCellTap(", in: detail)
        let operativeBranch = try XCTUnwrap(tap.range(of: "if let booking = day.operativeBooking {"))
        let managerBranch = try XCTUnwrap(tap.range(of: "if let booking = day.managerBooking {"))
        let branch = tap[operativeBranch.upperBound..<managerBranch.lowerBound]
        XCTAssertFalse(branch.contains("showingScheduleOperative"), "a tap on a booking never opens Schedule booking")
        XCTAssertTrue(branch.contains("bookingEditTarget = .operative("))
        XCTAssertEqual(detail.components(separatedBy: "showsInlineWheels: true").count - 1, 2, "labour and manager edit")
    }

    /// The closure's mapping before 1.33.1, kept here as written so the moved helper is held to it.
    private func oldLabourSave(_ booking: Booking, _ start: String, _ end: String, _ breakRemoved: Bool, _ rate: Double?, now: Date) -> Booking {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        updated.otMultiplierOverride = rate
        updated.updatedAt = now
        return updated
    }

    func testEditBookingWritesTheSameFieldsAsBefore() throws {
        let monday = try day("2026-11-02")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cases: [Booking] = [
            LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00"),
            LogicFixtures.booking(on: monday, slot: .fullDay),
            LogicFixtures.booking(on: monday, slot: .customHours, start: "06:00", end: "18:00", breakRemoved: true),
        ]
        cases[2].otMultiplierOverride = 2
        for stored in cases {
            let edits: [(String, String, Bool, Double?)] = [("07:30", "17:00", false, nil), ("08:00", "16:00", true, 1.5)]
            for (start, end, breakRemoved, rate) in edits {
                let new = ScheduleBookingEditSave.labour(stored, start: start, end: end, isBreakRemoved: breakRemoved, otMultiplierOverride: rate, now: now)
                let old = oldLabourSave(stored, start, end, breakRemoved, rate, now: now)
                XCTAssertEqual(new, old)
                XCTAssertEqual(
                    BookingWritePatch.changedLabourFields(from: stored, to: new),
                    BookingWritePatch.changedLabourFields(from: stored, to: old)
                )
                let policy = OrgPayrollTimePolicy.default
                XCTAssertEqual(
                    PayrollHoursEngine.compute(booking: new, day: monday, policy: policy).totalPaidHours,
                    PayrollHoursEngine.compute(booking: old, day: monday, policy: policy).totalPaidHours
                )
            }
        }
    }

    func testEditingOnePersonOfAGroupChangesOnlyTheirTimes() throws {
        let monday = try day("2026-11-02")
        var stored = LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00")
        stored.bookingGroupId = "TEST-group"
        let edited = ScheduleBookingEditSave.labour(stored, start: "07:30", end: "17:00", isBreakRemoved: false, otMultiplierOverride: nil)

        XCTAssertEqual(BookingWritePatch.changedLabourFields(from: stored, to: edited), ["workEndTime"])
        XCTAssertEqual(edited.bookingGroupId, "TEST-group", "the group stays; Edit group still finds it")
        XCTAssertEqual(edited.status, stored.status)
    }

    func testManagerSiteEditWritesTheSameFieldsAsBefore() throws {
        let monday = try day("2026-11-02")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = ManagerSiteBooking(
            userId: "TEST-manager",
            date: monday,
            timeSlot: .fullDay,
            locationType: .project,
            locationId: UUID()
        )
        let new = ScheduleBookingEditSave.managerSite(stored, start: "08:00", end: "15:30", isBreakRemoved: true, now: now)
        var old = stored
        old.timeSlot = .customHours
        old.workStartTime = "08:00"
        old.workEndTime = "15:30"
        old.isBreakRemoved = true
        old.updatedAt = now
        XCTAssertEqual(new, old)
        XCTAssertEqual(
            BookingWritePatch.changedManagerFields(from: stored, to: new),
            ["timeSlot", "workStartTime", "workEndTime", "isBreakRemoved"]
        )
    }

    // MARK: Review item 6: Save with no change keeps a Full day a Full day

    func testSaveWithNoChangeKeepsTheStoredSlot() throws {
        let monday = try day("2026-11-02")
        let policy = OrgPayrollTimePolicy.default
        let stored = LogicFixtures.booking(on: monday, slot: .fullDay)
        let opened = OperativeCustomHoursSheet.openingTimes(
            policy: policy,
            referenceDay: monday,
            initialChoice: OperativeDayBookingChoice(from: stored)
        )

        let unchanged = ScheduleBookingEditSave.labour(
            stored, start: opened.start, end: opened.end,
            isBreakRemoved: stored.isBreakRemoved, otMultiplierOverride: stored.otMultiplierOverride, openedTimes: opened
        )
        XCTAssertEqual(unchanged.timeSlot, .fullDay)
        XCTAssertEqual(unchanged.workStartTime, stored.workStartTime)
        XCTAssertEqual(unchanged.workEndTime, stored.workEndTime)
        XCTAssertEqual(BookingWritePatch.changedLabourFields(from: stored, to: unchanged), [], "nothing is written")
        XCTAssertEqual(
            PayrollHoursEngine.compute(booking: unchanged, day: monday, policy: policy).totalPaidHours,
            PayrollHoursEngine.compute(booking: stored, day: monday, policy: policy).totalPaidHours
        )

        let laterFinish = opened.end == "18:00" ? "17:00" : "18:00"
        let changed = ScheduleBookingEditSave.labour(
            stored, start: opened.start, end: laterFinish,
            isBreakRemoved: stored.isBreakRemoved, otMultiplierOverride: nil, openedTimes: opened
        )
        XCTAssertEqual(changed.timeSlot, .customHours, "a real change of times is custom hours, as before")
        XCTAssertEqual(changed.workStartTime, opened.start)
        XCTAssertEqual(changed.workEndTime, laterFinish)

        // Custom hours stay custom hours and take the times on screen.
        let custom = LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00")
        let customOpened = OperativeCustomHoursSheet.openingTimes(policy: policy, referenceDay: monday, initialChoice: OperativeDayBookingChoice(from: custom))
        XCTAssertEqual(customOpened.start, "07:30")
        XCTAssertEqual(customOpened.end, "16:00")
        let customSaved = ScheduleBookingEditSave.labour(custom, start: "07:30", end: "16:00", isBreakRemoved: custom.isBreakRemoved, otMultiplierOverride: nil, openedTimes: customOpened)
        XCTAssertEqual(BookingWritePatch.changedLabourFields(from: custom, to: customSaved), [])
    }

    func testManagerSaveWithNoChangeKeepsTheStoredSlot() throws {
        let monday = try day("2026-11-02")
        let policy = OrgPayrollTimePolicy.default
        let stored = ManagerSiteBooking(userId: "TEST-manager", date: monday, timeSlot: .fullDay, locationType: .project, locationId: UUID())
        let opened = OperativeCustomHoursSheet.openingTimes(policy: policy, referenceDay: monday, initialChoice: stored.hoursEditChoice(policy: policy))
        let unchanged = ScheduleBookingEditSave.managerSite(stored, start: opened.start, end: opened.end, isBreakRemoved: stored.isBreakRemoved, openedTimes: opened)
        XCTAssertEqual(unchanged.timeSlot, .fullDay)
        XCTAssertEqual(BookingWritePatch.changedManagerFields(from: stored, to: unchanged), [])
        let moved = ScheduleBookingEditSave.managerSite(stored, start: opened.start, end: "19:00", isBreakRemoved: stored.isBreakRemoved, openedTimes: opened)
        XCTAssertEqual(moved.timeSlot, .customHours)
    }

    func testProjectDetailPassesTheOpenedTimesToTheSave() throws {
        let detail = try source("Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("openedTimes: labourOpened"))
        XCTAssertTrue(detail.contains("openedTimes: managerOpened"))
    }
}
