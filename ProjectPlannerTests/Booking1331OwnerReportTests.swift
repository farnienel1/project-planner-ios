import XCTest
@testable import Project_Planner

/// 1.33.1 owner device report (10 Nov, build 6d27490): Warnings first open, slow booking Save, ✕ on a clash row,
/// the lunch-warning default, and My Projects empty on first open. Screen flow only: every business answer still comes
/// from the rulebook (`bookingConflictsHeading`, `customHoursBreakWarning`, `myWorksList`, …).
@MainActor
final class Booking1331OwnerReportTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    private func summary(unactioned: Bool, effectiveDays: Int) -> SchedulePersonConflictSummary {
        SchedulePersonConflictSummary(
            operativeId: UUID(),
            rows: [],
            triangle: .none,
            hasUnactionedRows: unactioned,
            effectiveSelectedDates: (0..<effectiveDays).map { Date(timeIntervalSince1970: Double($0) * 86_400) },
            droppedApprovedLeaveDates: []
        )
    }

    // MARK: 3. ✕ on a conflict row enables Save, as ✓ does (RULEBOOK 1.16.0 §5, web `conflictsResolved`)

    func testDroppingThePersonsOnlyDayCountsAsResolved() {
        // Before: a person whose every day was ✕-dropped had no effective day, and Save stayed grey.
        XCTAssertTrue(
            ScheduleBookingConflictEngine.rowsResolvedForSave([summary(unactioned: false, effectiveDays: 0)], anyPersonSelected: true),
            "✕ on the only clash enables Save (nothing is booked for that day)"
        )
        XCTAssertTrue(
            ScheduleBookingConflictEngine.rowsResolvedForSave([summary(unactioned: false, effectiveDays: 1)], anyPersonSelected: true),
            "✓ enables Save"
        )
        XCTAssertFalse(
            ScheduleBookingConflictEngine.rowsResolvedForSave([summary(unactioned: true, effectiveDays: 1)], anyPersonSelected: true),
            "a row neither ticked nor dropped keeps Save off"
        )
        XCTAssertFalse(
            ScheduleBookingConflictEngine.rowsResolvedForSave([], anyPersonSelected: false),
            "nobody chosen: nothing to save"
        )
    }

    func testTheClashReviewConfirmIsOnOnceEveryPersonIsTickedOrDropped() {
        // ✕ on the only clashing person: that person leaves the selection; Confirm must still turn on.
        XCTAssertTrue(ScheduleBookingSaveOutcome.clashReviewConfirmEnabled(
            selectedCount: 0, droppedCount: 1, awaitingDecisionCount: 0, hasDates: true, isBooking: false
        ))
        XCTAssertTrue(ScheduleBookingSaveOutcome.clashReviewConfirmEnabled(
            selectedCount: 1, droppedCount: 0, awaitingDecisionCount: 0, hasDates: true, isBooking: false
        ))
        XCTAssertFalse(ScheduleBookingSaveOutcome.clashReviewConfirmEnabled(
            selectedCount: 1, droppedCount: 1, awaitingDecisionCount: 1, hasDates: true, isBooking: false
        ), "a person still to decide keeps Confirm off")
        XCTAssertFalse(ScheduleBookingSaveOutcome.clashReviewConfirmEnabled(
            selectedCount: 0, droppedCount: 0, awaitingDecisionCount: 0, hasDates: true, isBooking: false
        ))
        XCTAssertFalse(ScheduleBookingSaveOutcome.clashReviewConfirmEnabled(
            selectedCount: 1, droppedCount: 0, awaitingDecisionCount: 0, hasDates: true, isBooking: true
        ))
    }

    func testEveryFlowWithConflictRowsUsesTheSharedRule() throws {
        let engine = try source("Core/ScheduleBookingConflictSupport.swift")
        XCTAssertFalse(engine.contains("if summary?.effectiveSelectedDates.isEmpty == true { return false }"))
        let wizard = try source("Views/ScheduleOperativeView.swift")
        XCTAssertTrue(wizard.contains("ScheduleBookingSaveOutcome.clashReviewConfirmEnabled("))
        XCTAssertTrue(wizard.contains("droppedClashOperativeIds.insert(operativeId)"))
        // The one-button flows already enable Book on every row decided (`BookingConflictResolution.resolved`).
        let sheet = try source("Views/BookingConflictRowsView.swift")
        XCTAssertTrue(sheet.contains(".disabled(!resolved)"))
    }

    // MARK: 5. "Keep the break" is the default; a stored break choice is saved as stored (guardrail 7)

    func testKeepTheBreakIsTheHighlightedDefault() throws {
        XCTAssertEqual(UnpaidBreakWarningChoice.highlighted, .keepBreak)
        let sheet = try source("Views/BookingHoursEditSheet.swift")
        let keep = try XCTUnwrap(sheet.range(of: "title: \"Keep the break\""))
        let pay = try XCTUnwrap(sheet.range(of: "title: \"Pay the full day\""))
        XCTAssertLessThan(keep.lowerBound, pay.lowerBound, "Keep the break is offered first")
    }

    func testKeepTheBreakNeverChangesTheToggle() {
        XCTAssertTrue(UnpaidBreakWarningChoice.keepBreak.breakIncluded(after: true))
        XCTAssertFalse(UnpaidBreakWarningChoice.keepBreak.breakIncluded(after: false))
        XCTAssertFalse(UnpaidBreakWarningChoice.payFullDay.breakIncluded(after: true))
    }

    /// An edit of a booking stored with `isBreakRemoved = true` saves it unchanged unless the person changes it.
    func testABookingStoredWithItsBreakRemovedIsSavedAsStored() {
        let stored = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "16:00", breakRemoved: true)
        let choice = OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: "07:30",
            workEndTime: "16:00",
            isBreakRemoved: stored.isBreakRemoved,
            otMultiplierOverride: nil
        )
        // The sheet opens on the stored break (off), "Keep the break" leaves it, Save writes `!breakIncluded`.
        let opened = OperativeCustomHoursSheet.initialBreakIncluded(initialChoice: choice, showsBreakControls: true)
        XCTAssertFalse(opened)
        let afterKeep = UnpaidBreakWarningChoice.keepBreak.breakIncluded(after: opened)
        var saved = stored
        saved.isBreakRemoved = !afterKeep
        XCTAssertTrue(saved.isBreakRemoved, "never flipped to false on save")
        XCTAssertFalse(
            BookingWritePatch.changedLabourFields(from: stored, to: saved).contains("isBreakRemoved"),
            "nothing about the break is written"
        )
        // Only the person's own change writes it.
        var changed = stored
        changed.isBreakRemoved = false
        XCTAssertTrue(BookingWritePatch.changedLabourFields(from: stored, to: changed).contains("isBreakRemoved"))
    }

    // MARK: 4. Save returns quickly; the server's confirmation follows in the background

    func testOneBookingSaveIsBackWithinItsBudget() {
        let session = BookingWriteSession(organizationId: "TEST-ORG")
        XCTAssertEqual(session.ackSeconds, BookingWriteSession.firstWaitSeconds)
        XCTAssertLessThanOrEqual(BookingWriteSession.firstWaitSeconds, 2)
        XCTAssertLessThanOrEqual(session.organizationCheckSeconds, 2)
        // Worst case on a link that never answers: the organisation check times out, then one short write wait.
        var total = session.organizationCheckSeconds
        session.noteTimeout()
        total += session.ackSeconds
        XCTAssertLessThanOrEqual(total, BookingWriteSession.budgetSeconds)
        XCTAssertLessThanOrEqual(BookingWriteSession.budgetSeconds, 4)
    }

    func testEveryManagerScheduleSaveIsBounded() throws {
        // Quick Add, My Schedule and Daily Overview passed no session: 15 s per write and an unbounded org check.
        let store = try source("Core/ManagerScheduleStore.swift")
        XCTAssertTrue(store.contains("let session = session ?? BookingWriteSession(organizationId: orgId)"))
        let labour = try source("Core/BookingStore.swift")
        XCTAssertTrue(labour.contains("let session = session ?? BookingWriteSession(organizationId: organizationId)"))
    }

    /// A write the server never answers is reported Pending sync and is never copied into the app outbox (Firestore
    /// holds it); a refusal is never swallowed (it comes back from the write itself).
    func testATimedOutWriteIsPendingAndARefusalIsNotSwallowed() async {
        OfflineOutboxStore.shared.clearAll()
        defer { OfflineOutboxStore.shared.clearAll() }
        let pending = LogicFixtures.booking(on: Date())
        let refused = LogicFixtures.booking(on: Date())
        let run = await BookingStore.performWrites(
            [
                BookingStore.BookingWrite(booking: pending, changedFields: nil),
                BookingStore.BookingWrite(booking: refused, changedFields: nil)
            ],
            organizationId: "TEST-ORG",
            isOnline: true
        ) { write, _ in
            if write.booking.id == pending.id { throw FirestoreWriteAck.TimedOut() }
            throw NSError(domain: "FIRFirestoreErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."])
        }
        XCTAssertEqual(run.results[pending.id], .queued(BookingStore.pendingSyncMessage))
        guard case .refused? = run.results[refused.id] else {
            return XCTFail("a permission refusal is reported as refused, never as saved or Pending sync")
        }
        XCTAssertTrue(run.refusedIds.contains(refused.id))
        XCTAssertTrue(OfflineOutboxStore.shared.entries.isEmpty)
    }

    func testNothingInTheAppTurnsTheFirestoreNetworkOff() throws {
        let fm = FileManager.default
        let files = fm.enumerator(at: appRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(".disableNetwork("), file.lastPathComponent)
        }
    }

    // MARK: 1. Warnings first open

    func testWarningsKeepTryingUntilAScanPublishes() {
        XCTAssertTrue(WarningsFirstOpenPolicy.keepWaiting(cancelled: false, hasCompletedLiveDetection: false))
        XCTAssertFalse(WarningsFirstOpenPolicy.keepWaiting(cancelled: false, hasCompletedLiveDetection: true))
        XCTAssertFalse(WarningsFirstOpenPolicy.keepWaiting(cancelled: true, hasCompletedLiveDetection: false))
        var pause = WarningsFirstOpenPolicy.firstPauseNanoseconds
        for _ in 0..<10 { pause = WarningsFirstOpenPolicy.nextPause(after: pause) }
        XCTAssertEqual(pause, WarningsFirstOpenPolicy.maxPauseNanoseconds, "never more than 2 s between tries")
        XCTAssertTrue(WarningsFirstOpenPolicy.shouldReload(lastLoadFailed: true, isLoading: false))
        XCTAssertFalse(WarningsFirstOpenPolicy.shouldReload(lastLoadFailed: true, isLoading: true))
        XCTAssertTrue(WarningsFirstOpenPolicy.settingsUsable(serverReadAnswered: false, listenerLoadedThisOrganization: true))
        XCTAssertFalse(WarningsFirstOpenPolicy.settingsUsable(serverReadAnswered: false, listenerLoadedThisOrganization: false))
    }

    func testIncompleteDataNoLongerEndsTheFirstOpenLoop() throws {
        let view = try source("Views/WarningsDetailView.swift")
        XCTAssertFalse(view.contains("if warningsService.incompleteDataMessage != nil { break }"))
        XCTAssertTrue(view.contains("WarningsFirstOpenPolicy.keepWaiting("))
        let backend = try source("FirebaseBackend.swift")
        XCTAssertTrue(backend.contains("timeoutSeconds: WarningsFirstOpenPolicy.organizationReadSeconds"))
    }

    // MARK: 6. My Projects on first open

    func testACachedMissingSnapshotIsNotShownAsTheList() {
        let model = MyWorksPicksModel()
        model.receive(picks: .neverSaved, error: nil, fromCache: true, exists: false)
        XCTAssertFalse(model.listKnown, "the pre-fill is not shown as the saved list before the server answers")
        model.receive(picks: MyWorksPicks(projects: ["P1"], smallWorks: nil), error: nil, fromCache: false, exists: true)
        XCTAssertTrue(model.listKnown)
    }

    func testACachedCopyIsShownAtOnce() {
        let model = MyWorksPicksModel()
        model.receive(picks: MyWorksPicks(projects: ["P1"], smallWorks: nil), error: nil, fromCache: true, exists: true)
        XCTAssertTrue(model.listKnown)
    }

    func testTheListenerStartsWhenTheSignedInUidArrives() throws {
        XCTAssertEqual(MyWorksPicksModel.listenKey(organizationId: "ORG", uid: nil, hasMyList: true), "")
        XCTAssertEqual(MyWorksPicksModel.listenKey(organizationId: "ORG", uid: "U1", hasMyList: true), "ORG/U1")
        XCTAssertEqual(MyWorksPicksModel.listenKey(organizationId: "ORG", uid: "U1", hasMyList: false), "")
        for view in ["Views/ProjectsView.swift", "Views/SmallWorksView.swift"] {
            let text = try source(view)
            XCTAssertTrue(text.contains(".onChange(of: MyWorksPicksModel.listenKey("), view)
            XCTAssertTrue(text.contains("loaded: myWorks.listKnown"), view)
        }
    }
}
