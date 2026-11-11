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
        XCTAssertEqual(waits, [BookingWriteSession.firstWaitSeconds])
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
            [BookingWriteSession.firstWaitSeconds, BookingStore.afterTimeoutAckSeconds, BookingStore.afterTimeoutAckSeconds]
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
            "func saveManagerSiteBooking(\n        _ booking: ManagerSiteBooking,",
        ]
        for marker in markers {
            let decl = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: marker, in: backend), marker)
            XCTAssertFalse(decl.contains("getDocument(source: .server)"), "\(marker): an unbounded read can spin for ever")
            XCTAssertTrue(decl.contains("readBeforeEdit(ref, session: session)"), marker)
            XCTAssertTrue(decl.contains("editReadOutcome(answeredByServer: read.answeredByServer"), marker)
            XCTAssertTrue(decl.contains("code: 5"), marker)
            XCTAssertTrue(decl.contains("pendingKey: ref.path"), marker)
        }
        let read = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: "static func readBeforeEdit(", in: backend))
        XCTAssertTrue(read.contains("boundedServerRead(ref, timeoutSeconds:"))
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
        XCTAssertTrue(proceed.contains("updateBookingReportingProblem(\n                            replaced,\n                            organizationId: savingOrganizationId,\n                            session: writeSession"))
        XCTAssertTrue(proceed.contains("addBookingsReportingProblem(\n                    newBookings,\n                    organizationId: savingOrganizationId,\n                    session: writeSession"))
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
        // RULEBOOK 1.41.0: the tap opens a chooser for a tile with several bookings, then `openSchedulingBooking`.
        let tap = try body(of: "private func openSchedulingBooking(", in: detail)
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

    // MARK: 1.33.1 final review (items 1–5)

    /// Review item 1: one Confirm shares one "a wait timed out" state. The first wait is the full one; after any
    /// timeout (a write, a read before an edit, the organisation check) every later wait is 1 s at most, and a save
    /// that has run for its budget waits no longer either.
    func testOneSaveSharesItsTimeoutAcrossEditsCreatesAndReads() async {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let session = BookingWriteSession(organizationId: "TEST-ORG", now: { clock })
        XCTAssertEqual(session.organizationCheckSeconds, BookingWriteSession.organizationReadSeconds)
        XCTAssertEqual(session.editReadSeconds, BookingWriteSession.firstWaitSeconds)

        // The organisation check times out once; it is not run again for the next booking.
        var checks = 0
        let first = try? await session.organization("TEST-ORG") { seconds in
            checks += 1
            XCTAssertEqual(seconds, BookingWriteSession.organizationReadSeconds)
            return ("TEST-ORG", true)
        }
        let second = try? await session.organization(" TEST-ORG ") { _ in
            checks += 1
            return ("TEST-ORG", false)
        }
        XCTAssertEqual(first, "TEST-ORG")
        XCTAssertEqual(second, "TEST-ORG")
        XCTAssertEqual(checks, 1, "the organisation is checked once per save, never once per booking")
        XCTAssertTrue(session.timedOut)

        // Every later wait of the save — edits (read and write) and creates — is short.
        XCTAssertEqual(session.ackSeconds, BookingWriteSession.afterTimeoutWaitSeconds)
        XCTAssertEqual(session.editReadSeconds, BookingWriteSession.afterTimeoutWaitSeconds)
        XCTAssertEqual(
            FirestoreWriteAck.editReadSource(pendingOnThisDevice: false, afterTimeout: session.timedOut),
            .localCache,
            "after a timeout the read before an edit goes to this device's cache"
        )
        let edit = BookingStore.BookingWrite(
            booking: LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "16:00"),
            changedFields: ["workEndTime"]
        )
        let create = BookingStore.BookingWrite(booking: LogicFixtures.booking(on: Date()), changedFields: nil)
        var waits: [Double] = []
        _ = await BookingStore.performWrites([edit], organizationId: "TEST-ORG", isOnline: true, session: session) { _, wait in
            waits.append(wait)
            throw FirestoreWriteAck.TimedOut()
        }
        _ = await BookingStore.performWrites([create], organizationId: "TEST-ORG", isOnline: true, session: session) { _, wait in
            waits.append(wait)
        }
        XCTAssertEqual(waits, [BookingWriteSession.afterTimeoutWaitSeconds, BookingWriteSession.afterTimeoutWaitSeconds])

        // A new save whose first edit's read timed out: the creates after it wait briefly too.
        let fresh = BookingWriteSession(organizationId: "TEST-ORG", now: { clock })
        fresh.note(FirestoreWriteAck.ReadTimedOut())
        XCTAssertEqual(fresh.ackSeconds, BookingWriteSession.afterTimeoutWaitSeconds)

        // The budget: a save that has already run its budget waits at most 1 s, however slow the link.
        let slow = BookingWriteSession(organizationId: "TEST-ORG", now: { clock })
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(slow.ackSeconds, BookingWriteSession.firstWaitSeconds)
        clock = clock.addingTimeInterval(BookingWriteSession.budgetSeconds)
        XCTAssertEqual(slow.ackSeconds, BookingWriteSession.afterTimeoutWaitSeconds)
        XCTAssertFalse(slow.timedOut)
    }

    /// Review item 1, worst case: a Confirm of several edits and creates on a dead link. Every wait is bounded by the
    /// session, so the whole Confirm stays near 20 s however many bookings it has (8 s organisation check, then 1 s each).
    func testADeadLinkConfirmStaysNearTwentySeconds() throws {
        let session = BookingWriteSession(organizationId: "TEST-ORG")
        var total = session.organizationCheckSeconds  // times out
        session.noteTimeout()
        for _ in 0..<6 {
            total += 0  // read before the edit: this device's cache, no server wait
            total += session.ackSeconds  // edit
        }
        for _ in 0..<6 { total += session.ackSeconds }  // creates
        XCTAssertLessThanOrEqual(total, 20.0)

        // The wiring: one session for the whole Confirm, passed to every edit and create, and to the backend writes.
        let wizard = try source("Views/ScheduleOperativeView.swift")
        XCTAssertEqual(wizard.components(separatedBy: "BookingWriteSession(organizationId: savingOrganizationId)").count - 1, 1)
        XCTAssertEqual(wizard.components(separatedBy: "session: writeSession").count - 1, 2)
        let store = try source("Core/BookingStore.swift")
        XCTAssertTrue(store.contains("ackTimeoutSeconds: ackTimeout,\n                        session: session"))
        let backend = try source("FirebaseBackend.swift")
        XCTAssertTrue(backend.contains("resolveWritableOrganizationId(preferred: organizationId, session: session)"))
    }

    /// Review item 2: Edit booking from the Scheduling grid saves with the organisation captured at Save and shows
    /// this save's own outcome once the sheet closes — never a fire-and-forget write.
    func testGridEditReportsItsOutcomeAndKeepsTheOrganisation() async throws {
        let detail = try source("Views/ProjectDetailView.swift")
        XCTAssertFalse(detail.contains("Task { await bookingStore.updateBooking(updated) }"))
        XCTAssertFalse(detail.contains("Task { await managerScheduleStore.saveBooking(updated) }"))
        XCTAssertTrue(detail.contains("bookingStore.updateBookingReportingProblem(\n                                    updated,\n                                    organizationId: savingOrganizationId"))
        XCTAssertTrue(detail.contains("managerScheduleStore.saveBookingReportingProblem(\n                                    updated,\n                                    organizationId: savingOrganizationId"))
        XCTAssertEqual(detail.components(separatedBy: "queueBookingEditSaveAlert(ScheduleBookingSaveAlert.forEdit(result))").count - 1, 2)

        let saved = try XCTUnwrap(ScheduleBookingSaveAlert.forEdit(.saved))
        XCTAssertEqual(saved.title, "Booking saved")
        XCTAssertEqual(saved.message, ScheduleBookingSaveAlert.editSavedMessage)
        let pending = try XCTUnwrap(ScheduleBookingSaveAlert.forEdit(.queued(BookingStore.pendingSyncMessage)))
        XCTAssertEqual(pending.title, "Booking saved — Pending sync")
        XCTAssertEqual(pending.message, BookingStore.pendingSyncMessage)
        let refused = try XCTUnwrap(ScheduleBookingSaveAlert.forEdit(.refused("Refused here")))
        XCTAssertEqual(refused.title, "Booking not saved")
        XCTAssertEqual(refused.message, "Refused here")

        // The manager schedule save reports its own outcome and refuses once another organisation is open.
        let store = ManagerScheduleStore()
        let result = await store.saveBookingReportingProblem(
            ManagerSiteBooking(userId: "TEST-u", date: Date(), timeSlot: .fullDay, locationType: .office),
            organizationId: "TEST-ORG-A"
        )
        XCTAssertFalse(result.keepsBooking, "no backend here: nothing written, and the outcome says so")
        let managerStore = try source("Core/ManagerScheduleStore.swift")
        let save = try body(of: "    func saveBookingReportingProblem(", in: managerStore)
        XCTAssertTrue(save.contains("BookingStore.organizationChanged(captured: capturedOrganizationId, open: openOrganizationId)"))
        XCTAssertTrue(save.contains("guard let orgId = capturedOrganizationId ?? openOrganizationId"))
        XCTAssertTrue(save.contains("return .queued(BookingStore.pendingSyncMessage)"))
    }

    /// Review item 3: a write Firestore holds (its wait timed out) shows "Pending sync" on the booking's row, labour and
    /// manager schedule alike; the Scheduling rows pass the booking so the indicator can tell.
    func testRowsShowPendingSyncWhileFirestoreHoldsTheWrite() throws {
        SDKPendingWrites.shared.removeAll()
        defer { SDKPendingWrites.shared.removeAll() }
        let booking = LogicFixtures.booking(on: Date())
        let store = BookingStore()
        XCTAssertFalse(store.isPendingSync(booking))
        SDKPendingWrites.shared.mark(SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: booking.documentKey))
        XCTAssertTrue(store.isPendingSync(booking))
        XCTAssertTrue(BookingPendingSync.isPending(entityId: booking.id.uuidString, collection: "bookings", documentKey: booking.documentKey))
        XCTAssertFalse(
            BookingPendingSync.isPending(entityId: booking.id.uuidString, collection: "managerSiteBookings", documentKey: booking.documentKey),
            "a labour write does not mark a manager schedule booking"
        )

        let manager = ManagerSiteBooking(userId: "TEST-u", date: Date(), timeSlot: .fullDay, locationType: .office)
        let managerStore = ManagerScheduleStore()
        XCTAssertFalse(managerStore.isPendingSync(manager))
        SDKPendingWrites.shared.mark(
            SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "managerSiteBookings", documentId: manager.documentKey)
        )
        XCTAssertTrue(managerStore.isPendingSync(manager))

        let detail = try source("Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("PendingSyncIndicator(booking: booking)"))
        XCTAssertTrue(detail.contains("PendingSyncIndicator(managerBooking: booking)"))
        let views = try source("Core/Offline/OfflinePolicyViews.swift")
        XCTAssertTrue(views.contains("BookingPendingSync.isPending(entityId: entityId, collection: collection, documentKey: documentKey)"))
        XCTAssertTrue(views.contains("@ObservedObject private var sdkPending = SDKPendingWrites.shared"))
    }

    /// Review item 4: a write the server refuses after its wait timed out tells the person and drops the local copy.
    func testALateRefusalIsSaidAndTheLocalCopyGoes() async throws {
        SDKPendingWrites.shared.removeAll()
        OfflineOutboxStore.shared.lastRefusalMessage = nil
        defer {
            SDKPendingWrites.shared.removeAll()
            OfflineOutboxStore.shared.lastRefusalMessage = nil
        }
        let parts = try XCTUnwrap(SDKPendingWrites.pathParts("organizations/TEST-ORG/bookings/TEST-B1"))
        XCTAssertEqual(parts.organizationId, "TEST-ORG")
        XCTAssertEqual(parts.collection, "bookings")
        XCTAssertEqual(parts.documentId, "TEST-B1")
        XCTAssertNil(SDKPendingWrites.pathParts("organizations/TEST-ORG/deletedBookings"))
        XCTAssertTrue(BookingPendingSync.sameOrganization("TEST-ORG", " test-org "))
        XCTAssertFalse(BookingPendingSync.sameOrganization("TEST-ORG-A", "TEST-ORG-B"))

        let booking = LogicFixtures.booking(on: Date())
        let key = SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: booking.documentKey)
        final class Received: @unchecked Sendable {
            var info: [String: String] = [:]
        }
        let box = Received()
        let observer = NotificationCenter.default.addObserver(
            forName: SDKPendingWrites.lateRefusalNotification, object: nil, queue: nil
        ) { note in
            box.info = (note.userInfo as? [String: String]) ?? [:]
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        struct Refused: Error {}
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 0.1, pendingKey: key) {
                try await Task.sleep(nanoseconds: 300_000_000)
                throw Refused()
            }
            XCTFail("expected the timeout")
        } catch {
            XCTAssertTrue(FirestoreWriteAck.isPendingInSDK(error))
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(SDKPendingWrites.shared.contains(path: key))
        // Review NIT 4: plain wording for a late refusal; the replay message stays for real outbox replay refusals.
        XCTAssertEqual(OfflineOutboxStore.shared.lastRefusalMessage, SDKPendingWrites.lateRefusalMessage)
        XCTAssertEqual(SDKPendingWrites.lateRefusalMessage, "This change couldn't be saved. Please check the booking and try again.")
        XCTAssertNotEqual(SDKPendingWrites.lateRefusalMessage, CanonicalBusinessEngine.bookingReplayRefusedMessage)
        XCTAssertTrue(try source("Core/OfflineSyncCoordinator.swift").contains("CanonicalBusinessEngine.bookingReplayRefusedMessage"))
        XCTAssertEqual(box.info["collection"], "bookings")
        XCTAssertEqual(box.info["documentId"]?.lowercased(), booking.documentKey.lowercased())

        let store = BookingStore()
        store.bookings = [booking]
        store.dropLocalCopyAfterLateRefusal(documentId: booking.documentKey.uppercased())
        XCTAssertTrue(store.bookings.isEmpty, "the listener's next snapshot is the truth")
    }

    /// Review item 5: a delete through Firestore removes that booking's queued outbox changes (labour and manager
    /// schedule), as an offline delete replaces a queued edit — none can replay after the tombstone.
    func testADeleteThroughFirestoreRemovesTheQueuedEdit() throws {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "16:00")
        outbox.enqueueSaveBooking(booking, changedFields: ["workEndTime"], organizationId: "TEST-ORG", baselineFingerprint: "TEST-baseline")
        let other = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(other, changedFields: ["workEndTime"], organizationId: "TEST-ORG")
        XCTAssertEqual(outbox.discardQueuedBookingSaves(bookingId: booking.id), .edit(baseline: "TEST-baseline"))
        XCTAssertEqual(outbox.entries.map(\.entityId), [other.id.uuidString], "only that booking's queued change goes")
        XCTAssertEqual(outbox.discardQueuedBookingSaves(bookingId: booking.id), .nothing)

        let manager = ManagerSiteBooking(userId: "TEST-u", date: Date(), timeSlot: .fullDay, locationType: .office)
        outbox.enqueueSaveManagerSiteBooking(manager, changedFields: ["timeSlot"], organizationId: "TEST-ORG", baselineFingerprint: nil)
        XCTAssertEqual(outbox.discardQueuedBookingSaves(bookingId: manager.id), .edit(baseline: nil))

        let created = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(created, changedFields: nil, organizationId: "TEST-ORG")
        XCTAssertEqual(outbox.discardQueuedBookingSaves(bookingId: created.id), .create, "never sent: nothing to delete")
        XCTAssertFalse(outbox.hasPendingSync(bookingId: created.id))

        let store = try source("Core/BookingStore.swift")
        let delete = try body(of: "    func deleteBooking(_ booking: Booking) async {", in: store)
        XCTAssertTrue(delete.contains("outbox.takeQueuedBookingSaves(bookingId: booking.id)"))
        XCTAssertTrue(delete.contains("fingerprint: queuedFingerprint"))
        let managerStore = try source("Core/ManagerScheduleStore.swift")
        let managerDelete = try body(of: "    func deleteBooking(_ booking: ManagerSiteBooking) async {", in: managerStore)
        XCTAssertTrue(managerDelete.contains("outbox.takeQueuedBookingSaves(bookingId: booking.id)"))
    }

    /// Review NIT: a write that finishes early cancels its timer, so the timeout never fires after the fact.
    func testAnEarlyFinishCancelsTheTimer() async throws {
        SDKPendingWrites.shared.removeAll()
        defer { SDKPendingWrites.shared.removeAll() }
        let key = SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: "TEST-EARLY")
        try await FirestoreWriteAck.run(timeoutSeconds: 0.2, pendingKey: key) {}
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(SDKPendingWrites.shared.contains(path: key))
        let ack = try source("Core/FirestoreWriteAck.swift")
        XCTAssertTrue(ack.contains("timer.cancel()"))
        // 1.36 (#209): the timer also stops when the write already resumed the caller (`gate.isOpen`).
        XCTAssertTrue(ack.contains("guard !Task.isCancelled, gate.isOpen else { return }"))
    }

    // MARK: Review round 3 (1.33.1)

    /// Fix 1: a delete through Firestore takes the booking's queued saves out of the queue and keeps them; a refused or
    /// failed delete puts them back, so the edit the booking is restored with still syncs. They are thrown away only
    /// once the delete went through.
    func testARefusedDeletePutsTheQueuedEditBack() throws {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "16:00")
        outbox.enqueueSaveBooking(booking, changedFields: ["workEndTime"], organizationId: "TEST-ORG", baselineFingerprint: "TEST-baseline")

        let taken = outbox.takeQueuedBookingSaves(bookingId: booking.id)
        XCTAssertEqual(taken.kind, .edit(baseline: "TEST-baseline"))
        XCTAssertEqual(taken.entries.count, 1)
        XCTAssertFalse(outbox.hasPendingSync(bookingId: booking.id), "out of the queue while the delete runs")

        outbox.requeueBookingSaves(taken.entries)
        XCTAssertEqual(outbox.entries.map(\.id), taken.entries.map(\.id), "the same entry is back, in its place")
        outbox.requeueBookingSaves(taken.entries)
        XCTAssertEqual(outbox.entries.count, 1, "putting it back twice adds nothing")
        let pending = outbox.pendingLabourBookings(organizationId: "TEST-ORG")
        XCTAssertEqual(pending.saves.map(\.id), [booking.id])

        // A save of the same booking queued while the delete ran is merged with it: fields added up, older baseline.
        _ = outbox.takeQueuedBookingSaves(bookingId: booking.id)
        var later = booking
        later.workStartTime = "08:00"
        outbox.enqueueSaveBooking(later, changedFields: ["workStartTime"], organizationId: "TEST-ORG", baselineFingerprint: "TEST-newer")
        outbox.requeueBookingSaves(taken.entries)
        XCTAssertEqual(outbox.entries.count, 1)
        let merged = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(merged.changedFields, ["workEndTime", "workStartTime"])
        XCTAssertEqual(merged.baselineFingerprint, "TEST-baseline")
        XCTAssertEqual(merged.booking.workStartTime, "08:00", "the newer copy is written")
        XCTAssertEqual(outbox.entries.first?.id, taken.entries.first?.id)

        // Never put back while a delete of that booking is queued (the delete replaces the edit, RULEBOOK §2).
        outbox.clearAll()
        outbox.enqueueDeleteBooking(booking, fingerprint: "TEST-fp", organizationId: "TEST-ORG")
        outbox.requeueBookingSaves(taken.entries)
        XCTAssertEqual(outbox.entries.map(\.operation), [.deleteBooking])

        // Both stores: taken before the write, put back in the refusal branch, never discarded up front.
        for (file, marker) in [
            ("Core/BookingStore.swift", "    func deleteBooking(_ booking: Booking) async {"),
            ("Core/ManagerScheduleStore.swift", "    func deleteBooking(_ booking: ManagerSiteBooking) async {"),
        ] {
            let delete = try body(of: marker, in: try source(file))
            XCTAssertFalse(delete.contains("discardQueuedBookingSaves"), file)
            let take = try XCTUnwrap(delete.range(of: "outbox.takeQueuedBookingSaves(bookingId: booking.id)"), file)
            let requeue = try XCTUnwrap(delete.range(of: "outbox.requeueBookingSaves(taken.entries)"), file)
            XCTAssertLessThan(take.lowerBound, requeue.lowerBound, file)
            // A refusal after the wait timed out puts the queued changes back (1.36: the confirmed branch sends the
            // delete's reopen notice, #209 review item 2).
            let late = try XCTUnwrap(delete.range(of: "onSettledAfterTimeout: { error in"), file)
            let refusedBranch = try XCTUnwrap(delete.range(of: "if error != nil {", range: late.upperBound..<delete.endIndex), file)
            let lateRequeue = try XCTUnwrap(
                delete.range(of: "OfflineOutboxStore.shared.requeueBookingSaves(takenEntries)", range: refusedBranch.upperBound..<delete.endIndex),
                file
            )
            let confirmedBranch = try XCTUnwrap(delete.range(of: "} else {", range: refusedBranch.upperBound..<delete.endIndex), file)
            XCTAssertLessThan(lateRequeue.lowerBound, confirmedBranch.lowerBound, "\(file): requeued in the refused branch")
        }
    }

    /// Fix 1: a write's late outcome reaches its caller only when its wait timed out, and before the stores hear of a
    /// refusal.
    func testTheLateOutcomeOfATimedOutWriteReachesItsCaller() async throws {
        SDKPendingWrites.shared.removeAll()
        defer { SDKPendingWrites.shared.removeAll() }
        final class Outcomes: @unchecked Sendable {
            var values: [String] = []
        }
        let outcomes = Outcomes()
        struct Refused: Error {}
        let key = SDKPendingWrites.key(organizationId: "TEST-ORG", collection: "bookings", documentId: "TEST-LATE")
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 0.1, pendingKey: key, onSettledAfterTimeout: { error in
                outcomes.values.append(error == nil ? "ok" : "refused")
            }) {
                try await Task.sleep(nanoseconds: 300_000_000)
                throw Refused()
            }
            XCTFail("expected the timeout")
        } catch {
            XCTAssertTrue(FirestoreWriteAck.isPendingInSDK(error))
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(outcomes.values, ["refused"])

        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 0.1, pendingKey: key, onSettledAfterTimeout: { error in
                outcomes.values.append(error == nil ? "ok" : "refused")
            }) {
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            XCTFail("expected the timeout")
        } catch {
            XCTAssertTrue(FirestoreWriteAck.isPendingInSDK(error))
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(outcomes.values, ["refused", "ok"])

        try await FirestoreWriteAck.run(timeoutSeconds: 1, pendingKey: key, onSettledAfterTimeout: { _ in
            outcomes.values.append("early")
        }) {}
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(outcomes.values, ["refused", "ok"], "a write confirmed in time is the caller's own outcome")

        let ack = try source("Core/FirestoreWriteAck.swift")
        let callback = try XCTUnwrap(ack.range(of: "onSettledAfterTimeout?(failure)"))
        let settle = try XCTUnwrap(ack.range(of: "SDKPendingWrites.shared.settle(pendingKey, error: failure, ticket: token.ticket)"))
        XCTAssertLessThan(callback.lowerBound, settle.lowerBound)
    }

    /// Fix 2: after a late refusal the local copy goes and the booking is read again, so it reappears when the server
    /// has it even if the listener had already published it.
    func testALateRefusalReadsTheBookingAgain() throws {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let booking = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "16:00")
        let store = BookingStore()
        store.bookings = [booking]
        XCTAssertTrue(store.dropLocalCopyAfterLateRefusal(documentId: booking.documentKey.lowercased()))
        XCTAssertFalse(store.dropLocalCopyAfterLateRefusal(documentId: booking.documentKey), "nothing left to drop")

        store.applyLateRefusalReread(.found(booking), organizationId: "TEST-ORG")
        XCTAssertEqual(store.bookings.map(\.id), [booking.id], "the server's copy is back")
        store.applyLateRefusalReread(.found(booking), organizationId: "TEST-ORG")
        XCTAssertEqual(store.bookings.count, 1, "never twice")

        store.bookings = []
        store.applyLateRefusalReread(.missing, organizationId: "TEST-ORG")
        XCTAssertTrue(store.bookings.isEmpty, "gone on the server: stays gone")

        // A change still queued for it shows on top; a queued delete keeps it gone.
        var edited = booking
        edited.workEndTime = "17:00"
        OfflineOutboxStore.shared.enqueueSaveBooking(edited, changedFields: ["workEndTime"], organizationId: "TEST-ORG")
        store.applyLateRefusalReread(.found(booking), organizationId: "TEST-ORG")
        XCTAssertEqual(store.bookings.first?.workEndTime, "17:00")
        store.bookings = []
        OfflineOutboxStore.shared.enqueueDeleteBooking(booking, fingerprint: "TEST-fp", organizationId: "TEST-ORG")
        store.applyLateRefusalReread(.found(booking), organizationId: "TEST-ORG")
        XCTAssertTrue(store.bookings.isEmpty)

        let storeText = try source("Core/BookingStore.swift")
        let apply = try body(of: "    func applyLateRefusalReread(", in: storeText)
        XCTAssertTrue(apply.contains("case .unknown:\n            loadData()"), "no answer: a full reload")
        let backend = try String(contentsOf: appRoot.appendingPathComponent("FirebaseBackend.swift"), encoding: .utf8)
        let reread = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: "func rereadBookingAfterLateRefusal(", in: backend))
        XCTAssertTrue(reread.contains("getDocumentWithServerTimeoutAndCacheFallback(ref, timeoutSeconds: 8)"), "bounded")
        XCTAssertTrue(reread.contains("CanonicalBusinessEngine.parseBookingDocuments(payload)"), "the rulebook reader")
    }

    /// Fix 3: while the outbox replays a booking's queued create, a delete of that booking goes through Firestore after
    /// it (never "nothing to send"), and the replay never runs an entry a delete took out of the queue meanwhile.
    func testADeleteWaitsForAReplayInFlight() async throws {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        XCTAssertFalse(outbox.isInFlight(bookingId: booking.id))
        outbox.markInFlight(entityId: booking.id.uuidString.lowercased())
        XCTAssertTrue(outbox.isInFlight(bookingId: booking.id), "ids without case")
        XCTAssertEqual(BookingStore.deleteRoute(queuesWhileOffline: true, pendingInFirestore: outbox.isInFlight(bookingId: booking.id)), .firestore)

        let started = Date()
        await outbox.waitUntilNotInFlight(bookingId: booking.id, timeoutSeconds: 0.3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "bounded wait")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            outbox.clearInFlight(entityId: booking.id.uuidString)
        }
        let second = Date()
        await outbox.waitUntilNotInFlight(bookingId: booking.id, timeoutSeconds: 5)
        XCTAssertLessThan(Date().timeIntervalSince(second), 2, "returns once the replay finished")
        XCTAssertFalse(outbox.isInFlight(bookingId: booking.id))

        let coordinator = try source("Core/OfflineSyncCoordinator.swift")
        let process = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: "static func processOutbox(", in: coordinator))
        let skip = try XCTUnwrap(process.range(of: "guard outbox.entries.contains(where: { $0.id == entry.id }) else { continue }"))
        let mark = try XCTUnwrap(process.range(of: "outbox.markInFlight(entityId: entry.entityId)"))
        let execute = try XCTUnwrap(process.range(of: "try await execute(entry: entry, firebaseBackend: firebaseBackend)"))
        XCTAssertLessThan(skip.lowerBound, mark.lowerBound)
        XCTAssertLessThan(mark.lowerBound, execute.lowerBound)
        XCTAssertTrue(process.contains("defer { outbox.clearInFlight(entityId: entry.entityId) }"))
        for (file, marker) in [
            ("Core/BookingStore.swift", "    func deleteBooking(_ booking: Booking) async {"),
            ("Core/ManagerScheduleStore.swift", "    func deleteBooking(_ booking: ManagerSiteBooking) async {"),
        ] {
            let delete = try body(of: marker, in: try source(file))
            XCTAssertTrue(delete.contains("let replayInFlight = outbox.isInFlight(bookingId: booking.id)"), file)
            XCTAssertTrue(delete.contains("let pendingInFirestore = replayInFlight"), file)
            let wait = try XCTUnwrap(delete.range(of: "await outbox.waitUntilNotInFlight(bookingId: booking.id"), file)
            let take = try XCTUnwrap(delete.range(of: "outbox.takeQueuedBookingSaves(bookingId: booking.id)"), file)
            XCTAssertLessThan(wait.lowerBound, take.lowerBound, "the replay finishes before the queue is read")
        }
    }

    /// NIT 5: a double tap's second save is "already saving" — no alert and never reported as saved.
    func testADoubleTapIsAlreadySavingNotSaved() throws {
        XCTAssertNil(ScheduleBookingSaveAlert.forEdit(.alreadySaving))
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.alreadySaving]), .nothingToSave)
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.saved, .alreadySaving]), .confirmed)
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(results: [.refused("No"), .alreadySaving]), .notSaved("No"))
        let managerStore = try source("Core/ManagerScheduleStore.swift")
        let save = try body(of: "    func saveBookingReportingProblem(", in: managerStore)
        let guardRange = try XCTUnwrap(save.range(of: "if pendingSemanticKeys.contains(key) {"))
        XCTAssertTrue(save[guardRange.upperBound...].prefix(300).contains("return .alreadySaving"))
    }

    /// NIT 6: an Edit booking outcome that arrives while another sheet is up waits and is shown once it closes.
    func testAnEditOutcomeWaitsForOtherSheetsToClose() throws {
        let detail = try source("Views/ProjectDetailView.swift")
        let blocked = try body(of: "    private var bookingEditAlertBlocked: Bool {", in: detail)
        for state in ["bookingEditTarget != nil", "leaveGate.pending != nil", "quickAddRequest != nil", "bookingEditSaveAlert != nil"] {
            XCTAssertTrue(blocked.contains(state), state)
        }
        XCTAssertTrue(detail.contains(".onChange(of: bookingEditAlertBlocked) { _, blocked in\n            // 1.33.1 review NIT 6"))
        XCTAssertTrue(detail.contains("if !blocked { deliverPendingBookingEditSaveAlert() }"))
        let deliver = try body(of: "    private func deliverPendingBookingEditSaveAlert() {", in: detail)
        XCTAssertTrue(deliver.contains("guard !bookingEditAlertBlocked, let alert = pendingBookingEditSaveAlert else { return }"))
        XCTAssertFalse(detail.contains("bookingEditSaveAlert = ScheduleBookingSaveAlert.forEdit(result)"), "always through the queue")
    }
}
