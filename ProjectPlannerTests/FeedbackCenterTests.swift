import AVFoundation
import XCTest
@testable import Project_Planner

/// Feedback sounds and haptics (docs/design/feedback/feedback-sounds-haptics-guide.md v1.1; owner decisions 16 Nov).
/// Not a rulebook rule: a sound and a haptic AFTER an outcome the app already decided. These tests hold the event table
/// to guide §4, the service to §1/§3/§5, every call site to the outcome it reads, and the stores to "writes unchanged".
@MainActor
final class FeedbackCenterTests: XCTestCase {
    @MainActor
    private final class Spy: FeedbackPlaying {
        var events: [FeedbackEvent] = []
        var prepared = 0
        func play(_ event: FeedbackEvent) { events.append(event) }
        func prepare() { prepared += 1 }
    }

    @MainActor
    private final class SoundSpy: FeedbackSoundOutput {
        var played: [FeedbackSound] = []
        func play(_ sound: FeedbackSound) -> Bool {
            played.append(sound)
            return true
        }
    }

    @MainActor
    private final class HapticSpy: FeedbackHapticOutput {
        var played: [FeedbackHaptic] = []
        var prepared = 0
        func play(_ haptic: FeedbackHaptic) { played.append(haptic) }
        func prepare() { prepared += 1 }
    }

    private var savedPlayer: FeedbackPlaying?
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        savedPlayer = Feedback.player
        OfflineOutboxStore.shared.clearAll()
        SDKPendingWrites.shared.removeAll()
        JobAccessContext.updateViewer(nil)
        suiteName = "TEST-feedback-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let savedPlayer { Feedback.player = savedPlayer }
        defaults.removePersistentDomain(forName: suiteName)
        JobAccessContext.updateViewer(nil)
        JobAccessContext.updateJobs([])
        OfflineOutboxStore.shared.clearAll()
        SDKPendingWrites.shared.removeAll()
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: Guide §4: the event table, exhaustively

    /// Guide §4 "Sound" and "iOS haptic" columns, written out. A new event fails here until it is added to the guide.
    private static let guideTable: [FeedbackEvent: (sound: FeedbackSound?, haptic: FeedbackHaptic)] = [
        .bookingSaved: (.success, .success),
        .bookingEdited: (.success, .success),
        .bookingRequested: (.sent, .sent),
        .bookingApproved: (.approved, .success),
        .bookingDeclined: (.removed, .removed),
        .bookingDeleted: (.removed, .removed),
        .leaveRequested: (.sent, .sent),
        .leaveBooked: (.success, .success),
        .leaveApproved: (.approved, .success),
        .leaveDeclined: (.removed, .removed),
        .warningResolved: (.resolved, .success),
        .allWarningsClear: (.approved, .success),
        .timesheetSigned: (.approved, .success),
        .timesheetSaved: (.success, .success),
        .userInvited: (.sent, .sent),
        .savedOffline: (.queued, .sent),
        .leaveEdited: (.success, .success),
        .leaveRemoved: (.removed, .removed),
        .overtimeSent: (.sent, .sent),
        .overtimeReturned: (.approved, .success),
        .claimsApproved: (.approved, .success),
        .claimsDeclined: (.removed, .removed),
        .actionRefused: (.error, .error),
        .warningShown: (nil, .warn),
    ]

    func testEveryEventMapsToExactlyTheGuideSoundAndHaptic() {
        XCTAssertEqual(FeedbackEvent.allCases.count, 24, "guide v1.1 §4")
        XCTAssertEqual(Set(Self.guideTable.keys), Set(FeedbackEvent.allCases))
        for event in FeedbackEvent.allCases {
            guard let expected = Self.guideTable[event] else {
                XCTFail("\(event) is not in guide §4")
                continue
            }
            XCTAssertEqual(event.sound, expected.sound, "\(event) sound")
            XCTAssertEqual(event.haptic, expected.haptic, "\(event) haptic")
        }
    }

    func testTheSevenSoundsAreTheGuideFiles() {
        XCTAssertEqual(
            FeedbackSound.allCases.map(\.fileName),
            ["pp-success", "pp-sent", "pp-approved", "pp-resolved", "pp-removed", "pp-error", "pp-queued"]
        )
        // Every sound is used by at least one event, and only `warningShown` is silent.
        XCTAssertEqual(Set(FeedbackEvent.allCases.compactMap(\.sound)), Set(FeedbackSound.allCases))
        XCTAssertEqual(FeedbackEvent.allCases.filter { $0.sound == nil }, [.warningShown])
    }

    /// The `.wav` masters are bundled (the synchronized `Project Planner` folder copies `Resources/Sounds`), load, and
    /// are each under 650 ms (guide §1.4).
    func testEverySoundIsInTheAppBundleAndShort() throws {
        for sound in FeedbackSound.allCases {
            let url = try XCTUnwrap(BundleFeedbackSoundOutput.url(for: sound, in: .main), "\(sound.fileName).wav is not bundled")
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertGreaterThan(player.duration, 0.05, sound.fileName)
            XCTAssertLessThan(player.duration, 0.65, sound.fileName)
        }
    }

    // MARK: Guide §1, §5: settings, throttle, never crashing

    func testDefaultsAreOnAndOnlyAnExplicitFalseTurnsThemOff() {
        XCTAssertTrue(FeedbackCenter.soundsEnabled(defaults))
        XCTAssertTrue(FeedbackCenter.hapticsEnabled(defaults))
        defaults.set(false, forKey: FeedbackCenter.soundsKey)
        XCTAssertFalse(FeedbackCenter.soundsEnabled(defaults))
        XCTAssertTrue(FeedbackCenter.hapticsEnabled(defaults))
        XCTAssertEqual(FeedbackCenter.soundsKey, "pp.feedback.sounds")
        XCTAssertEqual(FeedbackCenter.hapticsKey, "pp.feedback.haptics")
    }

    func testOnePlayPlaysTheEventsSoundAndHaptic() {
        let sounds = SoundSpy()
        let haptics = HapticSpy()
        let center = FeedbackCenter(defaults: defaults, sounds: sounds, haptics: haptics)
        center.play(.leaveApproved)
        XCTAssertEqual(sounds.played, [.approved])
        XCTAssertEqual(haptics.played, [.success])
    }

    func testWarningShownIsAHapticOnly() {
        let sounds = SoundSpy()
        let haptics = HapticSpy()
        FeedbackCenter(defaults: defaults, sounds: sounds, haptics: haptics).play(.warningShown)
        XCTAssertEqual(sounds.played, [])
        XCTAssertEqual(haptics.played, [.warn])
    }

    func testAtMostOneFeedbackEvery400Milliseconds() {
        let sounds = SoundSpy()
        let haptics = HapticSpy()
        var clock = Date(timeIntervalSince1970: 1_000)
        let center = FeedbackCenter(defaults: defaults, sounds: sounds, haptics: haptics, now: { clock })
        center.play(.bookingSaved)
        clock = clock.addingTimeInterval(0.2)
        center.play(.actionRefused)
        clock = clock.addingTimeInterval(0.19)
        center.play(.actionRefused)
        XCTAssertEqual(sounds.played, [.success], "throttled within 400 ms of the last one played")
        clock = clock.addingTimeInterval(0.02)
        center.play(.bookingDeleted)
        XCTAssertEqual(sounds.played, [.success, .removed])
        XCTAssertEqual(haptics.played, [.success, .removed])
        XCTAssertEqual(FeedbackCenter.throttleInterval, 0.4)
    }

    func testSoundsOffStillPlaysTheHapticAndTheReverse() {
        let sounds = SoundSpy()
        let haptics = HapticSpy()
        var clock = Date(timeIntervalSince1970: 0)
        let center = FeedbackCenter(defaults: defaults, sounds: sounds, haptics: haptics, now: { clock })
        defaults.set(false, forKey: FeedbackCenter.soundsKey)
        center.play(.bookingSaved)
        XCTAssertEqual(sounds.played, [])
        XCTAssertEqual(haptics.played, [.success])

        clock = clock.addingTimeInterval(1)
        defaults.set(true, forKey: FeedbackCenter.soundsKey)
        defaults.set(false, forKey: FeedbackCenter.hapticsKey)
        center.play(.bookingSaved)
        XCTAssertEqual(sounds.played, [.success])
        XCTAssertEqual(haptics.played, [.success])
        center.prepare()
        XCTAssertEqual(haptics.prepared, 0, "haptics off: nothing is prepared")
    }

    /// Review of #239: the toggles are read before the throttle, so a play with nothing to play starts no window.
    func testTheThrottleStartsOnlyWhenSomethingPlays() {
        let sounds = SoundSpy()
        let haptics = HapticSpy()
        var clock = Date(timeIntervalSince1970: 0)
        let center = FeedbackCenter(defaults: defaults, sounds: sounds, haptics: haptics, now: { clock })
        defaults.set(false, forKey: FeedbackCenter.soundsKey)
        defaults.set(false, forKey: FeedbackCenter.hapticsKey)
        center.play(.bookingSaved)
        defaults.set(true, forKey: FeedbackCenter.soundsKey)
        defaults.set(true, forKey: FeedbackCenter.hapticsKey)
        clock = clock.addingTimeInterval(0.1)
        center.play(.bookingDeleted)
        XCTAssertEqual(sounds.played, [.removed], "the silent play did not throttle this one")
        XCTAssertEqual(haptics.played, [.removed])
        // Sounds off but haptics on still plays, so it still throttles.
        defaults.set(false, forKey: FeedbackCenter.soundsKey)
        clock = clock.addingTimeInterval(0.5)
        center.play(.bookingSaved)
        clock = clock.addingTimeInterval(0.1)
        center.play(.actionRefused)
        XCTAssertEqual(haptics.played, [.removed, .success])
    }

    /// Review of #239: Book labour's unpaid-break prompt plays `warningShown`; the conflict list of that same save does
    /// not play it again. Any other conflict list does.
    func testOneWarningHapticPerSave() {
        let spy = Spy()
        Feedback.player = spy
        let gate = BookingConflictGate()
        let row = BookingConflictItem.doubleBooking(personKey: "TEST-p", dayKey: "2026-11-02", personName: "TEST", detail: "Already booked")
        gate.skipsWarningHaptic = true
        gate.runChoices(rows: [row]) { _ in }
        gate.skipsWarningHaptic = false
        XCTAssertEqual(spy.events, [])
        XCTAssertNotNil(gate.pending, "the list itself is still shown")
        gate.pending = nil
        gate.runChoices(rows: [row]) { _ in }
        XCTAssertEqual(spy.events, [.warningShown])
    }

    func testPlayASampleUsesTheTogglesAndIgnoresTheThrottle() {
        let sounds = SoundSpy()
        let haptics = HapticSpy()
        let center = FeedbackCenter(defaults: defaults, sounds: sounds, haptics: haptics, now: { Date(timeIntervalSince1970: 0) })
        center.playSample()
        center.playSample()
        XCTAssertEqual(sounds.played, [.success, .success])
        defaults.set(false, forKey: FeedbackCenter.soundsKey)
        center.playSample()
        XCTAssertEqual(sounds.played, [.success, .success])
        XCTAssertEqual(haptics.played.count, 3)
    }

    func testAMissingSoundFileNeverCrashes() {
        // The test bundle carries no sounds: every play answers false and nothing throws.
        let output = BundleFeedbackSoundOutput(bundle: Bundle(for: FeedbackCenterTests.self))
        for sound in FeedbackSound.allCases {
            XCTAssertFalse(output.play(sound))
            XCTAssertFalse(output.play(sound), "a missing file is remembered, never looked up again")
        }
    }

    func testTheAudioSessionIsAmbientAndTheVolumeIs06() {
        XCTAssertEqual(BundleFeedbackSoundOutput.audioSessionCategory, .ambient)
        XCTAssertEqual(BundleFeedbackSoundOutput.volume, 0.6, accuracy: 0.0001)
        BundleFeedbackSoundOutput.configureAudioSession()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
    }

    /// Owner decision 12: players load on first use, never at launch. The app's launch code never touches the service.
    func testNothingLoadsAtLaunch() throws {
        let center = try source("Core/Feedback/FeedbackCenter.swift")
        XCTAssertEqual(center.components(separatedBy: "try AVAudioPlayer(contentsOf: url)").count - 1, 1)
        XCTAssertTrue(center.contains("private func player(for sound: FeedbackSound) -> AVAudioPlayer? {"))
        for launch in ["Project_PlannerApp.swift", "ProjectPlannerRootView.swift", "ContentView.swift"] {
            XCTAssertFalse(try source(launch).contains("Feedback"), launch)
        }
    }

    // MARK: The decision each call site reads (the app's own saved / Pending sync / refused)

    func testABookingOutcomePlaysSuccessOfflineOrRefused() {
        XCTAssertEqual(FeedbackDecision.event(for: .saved, success: .bookingSaved), .bookingSaved)
        XCTAssertEqual(FeedbackDecision.event(for: .queued(BookingStore.pendingSyncMessage), success: .bookingSaved), .savedOffline)
        XCTAssertEqual(FeedbackDecision.event(for: .refused("No"), success: .bookingEdited), .actionRefused)
        XCTAssertNil(FeedbackDecision.event(for: .alreadySaving, success: .bookingSaved), "a double tap's second call")
    }

    /// One sound for a bulk save; a partly saved one plays the error (owner decision 3); nothing to save is silent
    /// (owner decision 4).
    func testABulkSavePlaysOneSoundFromItsOwnOutcome() {
        let queued = BookingSaveResult.queued(BookingStore.pendingSyncMessage)
        XCTAssertEqual(FeedbackDecision.event(forResults: [.saved, .saved, .saved], success: .bookingSaved), .bookingSaved)
        XCTAssertEqual(FeedbackDecision.event(forResults: [.saved, queued], success: .bookingSaved), .savedOffline)
        XCTAssertEqual(FeedbackDecision.event(forResults: [.saved, .refused("No")], success: .bookingSaved), .actionRefused)
        XCTAssertEqual(FeedbackDecision.event(forResults: [.refused("No")], success: .bookingSaved), .actionRefused)
        XCTAssertNil(FeedbackDecision.event(forResults: [], success: .bookingSaved))
        XCTAssertNil(FeedbackDecision.event(for: .nothingToSave, success: .bookingSaved))
        XCTAssertEqual(FeedbackDecision.event(for: .savedWithProblem("x"), success: .bookingSaved), .actionRefused)
    }

    func testWarningsAndOtherSaves() {
        XCTAssertEqual(FeedbackDecision.warningResolved(remainingActiveCount: 0), .allWarningsClear)
        XCTAssertEqual(FeedbackDecision.warningResolved(remainingActiveCount: 3), .warningResolved)
        XCTAssertEqual(FeedbackDecision.event(refusal: nil, success: .timesheetSigned), .timesheetSigned)
        XCTAssertEqual(FeedbackDecision.event(refusal: "Couldn't save", success: .timesheetSigned), .actionRefused)
        XCTAssertEqual(FeedbackDecision.leaveEvent(pendingSync: true, success: .leaveRequested), .savedOffline)
        XCTAssertEqual(FeedbackDecision.leaveEvent(pendingSync: false, success: .leaveBooked), .leaveBooked)
        // Review of #239: from the plan's approved count, so an approval left unchanged (not written) still counts.
        XCTAssertEqual(FeedbackDecision.claimsReviewed(approvedCount: 1), .claimsApproved)
        XCTAssertEqual(FeedbackDecision.claimsReviewed(approvedCount: 0), .claimsDeclined)
    }

    func testADeleteIsReadFromWhatTheStoreShowsAfterwards() {
        XCTAssertEqual(BookingDeleteOutcome.decide(stillOnPhone: true, pendingSync: false, refusal: "No"), .refused("No"))
        XCTAssertEqual(BookingDeleteOutcome.decide(stillOnPhone: true, pendingSync: true, refusal: "No"), .refused("No"))
        XCTAssertEqual(
            BookingDeleteOutcome.decide(stillOnPhone: false, pendingSync: true, refusal: "No"),
            .queued(BookingStore.pendingSyncMessage)
        )
        XCTAssertEqual(BookingDeleteOutcome.decide(stillOnPhone: false, pendingSync: false, refusal: "No"), .saved)
    }

    /// With the spy in place: success fires once with its event, offline fires `savedOffline` (never the success
    /// event), a refusal fires `actionRefused`, and "already saving" fires nothing.
    func testTheSpySeesOneEventPerOutcome() {
        let spy = Spy()
        Feedback.player = spy
        Feedback.play(.saved, success: .bookingSaved)
        XCTAssertEqual(spy.events, [.bookingSaved])
        Feedback.play(.queued(BookingStore.pendingSyncMessage), success: .bookingSaved)
        XCTAssertEqual(spy.events, [.bookingSaved, .savedOffline])
        Feedback.play(.refused("No"), success: .bookingSaved)
        Feedback.play(.alreadySaving, success: .bookingSaved)
        Feedback.play(.nothingToSave, success: .bookingSaved)
        XCTAssertEqual(spy.events, [.bookingSaved, .savedOffline, .actionRefused])
        Feedback.prepare()
        XCTAssertEqual(spy.prepared, 1)
    }

    // MARK: Stores: writes unchanged, and they never play anything themselves

    /// A listener, a sync replay or another person's change never plays: no store, listener, sync or backend file
    /// calls the feedback service — only the screens do, after the person's own action (owner decision 2).
    func testNoStoreListenerOrSyncCodePlaysFeedback() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot.appendingPathComponent("Core"), includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/Core/Feedback/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("Feedback.play(") || text.contains("Feedback.prepare(") { offenders.append(url.lastPathComponent) }
        }
        for file in ["FirebaseBackend.swift", "Project_PlannerApp.swift"] {
            if try source(file).contains("Feedback.play(") { offenders.append(file) }
        }
        XCTAssertEqual(offenders, [])
    }

    /// The store results the screens read are the stores' own decisions, and a save writes the same with feedback on
    /// or off (nothing in a store reads the feedback settings).
    func testAddBookingReturnsTheStoresOwnOutcomeAndWritesTheSameWithFeedbackOnOrOff() async throws {
        let spy = Spy()
        Feedback.player = spy
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-02"))
        let booking = LogicFixtures.booking(on: day, slot: .customHours, start: "07:30", end: "16:00")
        let standard = UserDefaults.standard
        let before = (standard.object(forKey: FeedbackCenter.soundsKey), standard.object(forKey: FeedbackCenter.hapticsKey))
        defer {
            standard.set(before.0, forKey: FeedbackCenter.soundsKey)
            standard.set(before.1, forKey: FeedbackCenter.hapticsKey)
        }

        var written: [[Booking]] = []
        var outcomes: [BookingSaveResult] = []
        for on in [true, false] {
            standard.set(on, forKey: FeedbackCenter.soundsKey)
            standard.set(on, forKey: FeedbackCenter.hapticsKey)
            let store = BookingStore()
            let outcome = await store.addBooking(booking)
            outcomes.append(outcome)
            written.append(store.bookings)
        }
        XCTAssertEqual(written[0], written[1], "the same booking is kept with feedback on and off")
        XCTAssertEqual(outcomes[0], outcomes[1])
        XCTAssertTrue(outcomes[0].keepsBooking, "no server here: kept on this phone (\(outcomes[0]))")
        XCTAssertEqual(spy.events, [], "the store never plays feedback")

        // The same outcome the batch save reports for this booking.
        let batch = await BookingStore().addBookingsReportingProblem([booking])
        XCTAssertEqual(batch[booking.id]?.keepsBooking, outcomes[0].keepsBooking)
    }

    func testARefusedAddIsReportedAndNothingIsKept() async throws {
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
        JobAccessContext.updateViewer(JobAccessViewer(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false),
            projectsToggle: true,
            smallWorksToggle: true,
            uid: "TEST-manager",
            ids: ["TEST-manager"],
            email: "TEST-manager@x.t"
        ))
        let store = BookingStore()
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-02"))
        let booking = LogicFixtures.booking(on: day, projectId: job.id)
        let result = await store.addBooking(booking)
        guard case .refused(let message) = result else { return XCTFail("refused on a job they do not manage: \(result)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(store.bookings.contains { $0.id == booking.id })

        // A delete the rules refuse leaves the booking on this phone: the outcome is a refusal.
        store.bookings = [booking]
        await store.deleteBooking(booking)
        let deleteOutcome = store.deleteOutcome(of: booking)
        guard case .refused = deleteOutcome else {
            return XCTFail("a refused delete reads as refused: \(deleteOutcome)")
        }
        XCTAssertEqual(store.bookings.map(\.id), [booking.id])
    }

    func testADeleteWithNothingToSendReadsAsDone() async throws {
        let store = BookingStore()
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-02"))
        let booking = LogicFixtures.booking(on: day)
        store.bookings = [booking]
        await store.deleteBooking(booking)
        XCTAssertFalse(store.bookings.contains { $0.id == booking.id })
        XCTAssertEqual(store.deleteOutcome(of: booking), .saved)
    }

    func testTheOtherStoresReportTheirOwnOutcome() async throws {
        // No backend: nothing is written, and each says so (before, these returned nothing).
        let manager = ManagerScheduleStore()
        let site = ManagerSiteBooking(userId: "TEST-u", date: Date(), timeSlot: .fullDay, locationType: .office)
        let saved = await manager.saveBooking(site)
        XCTAssertFalse(saved.keepsBooking)
        let direct = await ManagerScheduleStore().saveBookingReportingProblem(site)
        XCTAssertEqual(saved, direct, "the same outcome as before")

        let leave = HolidayStore()
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-02"))
        let request = HolidayBooking(organizationId: "TEST-ORG", userId: "TEST-u", startDate: day, endDate: day, status: .pending)
        leave.bookings = [request]
        let approved = await leave.approveBooking(request, approvedByUserId: "TEST-m")
        let rejected = await leave.rejectBooking(request, rejectedByUserId: "TEST-m")
        let removed = await leave.deleteBooking(request)
        XCTAssertEqual(approved, .refused(HolidayStore.notSavedMessage))
        XCTAssertEqual(rejected, .refused(HolidayStore.notSavedMessage))
        XCTAssertEqual(removed, .refused(HolidayStore.notSavedMessage))
        XCTAssertEqual(leave.bookings, [request], "nothing changed")

        let subcontractors = SubcontractorStore()
        let firm = SubcontractorBooking(
            subcontractorId: UUID(),
            projectId: UUID(),
            date: day,
            timeSlot: .fullDay,
            bookedBy: "Project Planner",
            bookedContactIds: []
        )
        let firmResult = await subcontractors.saveBooking(firm)
        XCTAssertFalse(firmResult.keepsBooking)
        XCTAssertTrue(subcontractors.bookings.isEmpty)
    }

    /// The source of the changed store functions: the result is returned after the same write as before.
    func testTheStoreReturnValuesFollowTheExistingWrites() throws {
        let store = try source("Core/BookingStore.swift")
        XCTAssertTrue(store.contains("let results = await saveData(writes: [BookingWrite(booking: booking, changedFields: nil)])\n        // A booking the save never reported on was not written (as the Scheduling wizard reads it).\n        return results[booking.id] ?? .refused(\"This booking could not be saved.\")"))
        XCTAssertTrue(store.contains("func updateBooking(_ booking: Booking) async -> BookingSaveResult {\n        await updateBookingReturningResult(booking)\n    }"))
        XCTAssertTrue(store.contains("return await addBooking(updatedBooking)"))
        // Deletes keep their signature: the outcome is read afterwards (`deleteOutcome(of:)`), never changed inside.
        XCTAssertTrue(store.contains("    func deleteBooking(_ booking: Booking) async {"))
        let manager = try source("Core/ManagerScheduleStore.swift")
        XCTAssertTrue(manager.contains("func saveBooking(_ booking: ManagerSiteBooking) async -> BookingSaveResult {\n        await saveBookingReportingProblem(booking)\n    }"))
        XCTAssertTrue(manager.contains("    func deleteBooking(_ booking: ManagerSiteBooking) async {"))
        let holiday = try source("Core/HolidayStore.swift")
        XCTAssertTrue(holiday.contains("return result.pendingSync ? .queued(BookingStore.pendingSyncMessage) : .saved"))
        XCTAssertTrue(holiday.contains("return lastSaveWasPendingSync ? .queued(BookingStore.pendingSyncMessage) : .saved"))
    }

    // MARK: Call sites: each plays after the existing handling, from the outcome it already shows

    /// (file, the existing line the outcome comes from, the feedback line that must follow it within `window` chars).
    private static let callSites: [(file: String, anchor: String, feedback: String, window: Int)] = [
        // bookingSaved
        ("Views/ScheduleOperativeView.swift", "let outcome = ScheduleBookingSaveOutcome.decide(results: saveResults)", "Feedback.play(outcome, success: .bookingSaved)", 900),
        ("Views/BookLabourFlowView.swift", "let partyResults = saveResults", "Feedback.play(results: partyResults, success: .bookingSaved)", 600),
        ("Views/BookLabourFlowView.swift", "let finalResult = saveResult", "Feedback.play(finalResult, success: .bookingSaved)", 300),
        ("Views/ProjectDetailView.swift", "quickAddRequest = nil\n        Feedback.play(saveResult, success: .bookingSaved)", "return nil", 60),
        ("Views/MyScheduleView.swift", "let result = await save.value", "Feedback.play(results: results, success: .bookingSaved)", 200),
        ("Views/ScheduleSubcontractorView.swift", "let savedResults = results", "Feedback.play(results: savedResults, success: .bookingSaved)", 300),
        // bookingEdited
        ("Views/ProjectDetailView.swift", "queueBookingEditSaveAlert(ScheduleBookingSaveAlert.forEdit(result))", "Feedback.play(result, success: .bookingEdited)", 100),
        ("Views/DailyOverviewView.swift", "let result = await bookingStore.updateBooking(updated)", "Feedback.play(result, success: .bookingEdited)", 100),
        ("Views/DailyOverviewView.swift", "let result = await managerScheduleStore.saveBooking(updated)", "Feedback.play(result, success: .bookingEdited)", 100),
        ("Views/MyScheduleView.swift", "let result = await managerScheduleStore.saveBooking(updated)", "Feedback.play(result, success: .bookingEdited)", 100),
        ("Views/MyScheduleView.swift", "let result = await bookingStore.updateBooking(updated)", "Feedback.play(result, success: .bookingEdited)", 200),
        ("Views/SubcontractorBookingEditSheet.swift", "let result = await subcontractorStore.saveBooking(updated)", "Feedback.play(result, success: .bookingEdited)", 200),
        // bookingDeleted
        ("Views/ProjectDetailView.swift", "labourDeleteRefusalMessage = message\n                }", "Feedback.play(bookingStore.deleteOutcome(of: booking), success: .bookingDeleted)", 120),
        ("Views/MyScheduleView.swift", "labourDeleteRefusalMessage = message\n                }", "Feedback.play(bookingStore.deleteOutcome(of: booking), success: .bookingDeleted)", 120),
        ("Views/DailyOverviewView.swift", "labourDeleteRefusalMessage = message\n                }", "Feedback.play(bookingStore.deleteOutcome(of: booking), success: .bookingDeleted)", 120),
        ("Views/DailyOverviewView.swift", "await managerScheduleStore.deleteBooking(booking)", "Feedback.play(managerScheduleStore.deleteOutcome(of: booking), success: .bookingDeleted)", 120),
        ("Views/MyScheduleView.swift", "await bookingStore.deleteBooking(b)", "Feedback.play(bookingStore.deleteOutcome(of: b), success: .bookingDeleted)", 120),
        ("Views/MyScheduleView.swift", "await managerScheduleStore.deleteBooking(b)", "Feedback.play(managerScheduleStore.deleteOutcome(of: b), success: .bookingDeleted)", 120),
        ("Views/WarningsDetailView.swift", "await bookingStore.deleteBooking(booking)", "playClashBookingDeleted(bookingStore.deleteOutcome(of: booking))", 400),
        // leave
        ("Views/HolidayView.swift", "let requestPending = created.contains { holidayStore.isPendingSync($0) }", "Feedback.play(FeedbackDecision.leaveEvent(pendingSync: requestPending, success: .leaveRequested))", 400),
        ("Views/HolidayView.swift", "let savedPending = created.contains { holidayStore.isPendingSync($0) }", "success: selfBooks ? .leaveBooked : .leaveRequested", 1_000),
        ("Views/HolidayView.swift", "let result = await holidayStore.approveBooking(request, approvedByUserId: uid)", "Feedback.play(result, success: .leaveApproved)", 80),
        ("Views/HolidayView.swift", "let result = await holidayStore.rejectBooking(request, rejectedByUserId: uid, reason: reason)", "Feedback.play(result, success: .leaveDeclined)", 80),
        ("Views/HolidayView.swift", "let removed = await holidayStore.deleteBooking(request)", "Feedback.play(removed, success: .leaveRemoved)", 200),
        ("Views/HolidayView.swift", "await holidayStore.requestCancellation(booking, by: uid)", "success: .leaveEdited", 500),
        ("Views/HolidayView.swift", "try await holidayStore.saveBooking(updated)", "success: .leaveEdited", 600),
        ("Views/TasksDetailView.swift", "let removed = await holidayStore.deleteBooking(request)", "Feedback.play(removed, success: .leaveRemoved)", 200),
        ("Views/OperativeAnnualLeaveViews.swift", "let removed = await holidayStore.deleteBooking(booking)", "Feedback.play(removed, success: .leaveRemoved)", 200),
        ("Views/OperativeAnnualLeaveViews.swift", "successMessage = \"Annual leave booking updated.\"", "success: .leaveEdited", 300),
        ("Views/TasksDetailView.swift", "let result = await holidayStore.approveBooking(request, approvedByUserId: uid)", "Feedback.play(result, success: .leaveApproved)", 80),
        ("Views/TasksDetailView.swift", "let result = await holidayStore.rejectBooking(request, rejectedByUserId: uid)", "Feedback.play(result, success: .leaveDeclined)", 80),
        ("Views/OperativeAnnualLeaveViews.swift", "let result = await holidayStore.approveBooking(booking, approvedByUserId: uid)", "Feedback.play(result, success: .leaveApproved)", 80),
        ("Views/OperativeAnnualLeaveViews.swift", "let result = await holidayStore.rejectBooking(booking, rejectedByUserId: uid)", "Feedback.play(result, success: .leaveDeclined)", 80),
        ("Views/OperativeAnnualLeaveViews.swift", "successMessage = \"Annual leave booked.\"", "pendingSync: holidayStore.isPendingSync(booking), success: .leaveBooked", 300),
        // warnings
        ("Views/WarningsDetailView.swift", "if !warningsService.approveWarning(warning) {", "FeedbackDecision.warningResolved(remainingActiveCount: warningsService.activeWarnings.count)", 400),
        ("Views/WarningsDetailView.swift", "dismissedAny = true", "FeedbackDecision.warningResolved(remainingActiveCount: warningsService.activeWarnings.count)", 600),
        // timesheets
        ("Views/InvoicingView.swift", "let signSave = saveDraft(rebuildSnapshot: rebuild)", "playTimesheetFeedback(signSave, success: .timesheetSigned)", 80),
        ("Views/InvoicingView.swift", "let counterSignSave = onCounterSignSave()", "Feedback.play(FeedbackDecision.event(refusal: message, success: .timesheetSigned))", 2_000),
        ("Views/InvoicingView.swift", "let message = await applyEntryChangeSaving(clearingSignatures: clearingSignatures, change)", "Feedback.play(FeedbackDecision.event(refusal: message, success: .timesheetSaved))", 120),
        ("Views/Overtime/OvertimeViews.swift", "message = \"Report saved. Send it to payroll yourself.\"", "Feedback.play(.timesheetSaved)", 200),
        ("Views/Overtime/PayeClaimsViews.swift", "\n            notice = PayeClaimReportPDF.notice(made)", "Feedback.play(.timesheetSaved)", 200),
        ("Views/Overtime/PayeClaimsViews.swift", "saving = nil\n            dismiss()", "Feedback.play(.timesheetSaved)", 200),
        // owner decision 2
        ("Views/Overtime/OvertimeViews.swift", "message = \"Sent for approval.\"", "Feedback.play(.overtimeSent)", 300),
        ("Views/Overtime/OvertimeViews.swift", "message = result.message", "Feedback.play(returned ? .overtimeReturned : .actionRefused)", 300),
        ("Views/Overtime/PayeClaimsViews.swift", "notice = message", "Feedback.play(FeedbackDecision.claimsReviewed(approvedCount: approvedCount))", 300),
        // userInvited
        ("Views/AddUserView.swift", "errorMessage = userStore.errorMessage ?? \"Failed to add this person. Please try again.\"", "Feedback.play(success ? .userInvited : .actionRefused)", 300),
        ("Views/AddUserView.swift", "errorMessage = userStore.errorMessage ?? \"Failed to create user. Please try again.\"", "Feedback.play(success ? .userInvited : .actionRefused)", 300),
        // warningShown
        ("Views/BookLabourFlowView.swift", "breakWarningPrompt = BreakWarningPrompt(message: message, onConfirm: {", "Feedback.play(.warningShown)", 300),
        ("Views/MyScheduleView.swift", "breakWarningMessage = warning", "Feedback.play(.warningShown)", 80),
        ("Views/BookingHoursEditSheet.swift", "breakWarningMessage = warning", "Feedback.play(.warningShown)", 200),
        ("Views/BookingConflictRowsView.swift", "self.pending = next", "Feedback.play(.warningShown)", 300),
        ("Views/BookingConflictRowsView.swift", "        } else {\n            pending = next", "Feedback.play(.warningShown)", 80),
    ]

    func testEveryCallSitePlaysAfterItsExistingOutcome() throws {
        var problems: [String] = []
        for site in Self.callSites {
            let text = try source(site.file)
            guard let anchor = text.range(of: site.anchor) else {
                problems.append("\(site.file): anchor not found — \(site.anchor)")
                continue
            }
            let after = text[anchor.upperBound...].prefix(site.window)
            if !after.contains(site.feedback) {
                problems.append("\(site.file): \(site.feedback) does not follow \(site.anchor)")
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// Nothing plays when a button is pressed: every play is after an await or an outcome, never in a button label.
    func testFeedbackIsNeverPlayedForATapOrInSettings() throws {
        let settings = try source("Views/SettingsHubSupportViews.swift")
        XCTAssertFalse(settings.contains("Feedback.play("), "settings toggles are not in the v1 table")
        let card = try source("Views/FeedbackSettingsCard.swift")
        XCTAssertTrue(card.contains("@AppStorage(FeedbackCenter.soundsKey) private var soundsOn = true"))
        XCTAssertTrue(card.contains("@AppStorage(FeedbackCenter.hapticsKey) private var hapticsOn = true"))
        XCTAssertTrue(card.contains("Applies to this iPhone only."))
        XCTAssertTrue(card.contains("Play a sample"))
        XCTAssertTrue(settings.contains("FeedbackSettingsCard()"), "My notifications holds the Sounds & haptics group")
        XCTAssertFalse(card.contains("firebaseBackend"), "device only")
        XCTAssertFalse(try source("Core/Feedback/FeedbackCenter.swift").contains("firebaseBackend"), "device only")
    }

    /// The existing H&S, Deadlines and variation haptics are untouched; the helper only gains the outcome haptics.
    func testTheExistingHapticHelperIsExtendedNotDuplicated() throws {
        let theme = try source("Views/HSTheme.swift")
        for name in ["static func tap()", "static func select()", "static func success()", "static func warn()",
                     "static func sent()", "static func removed()", "static func error()", "static func prepareOutcome()"] {
            XCTAssertEqual(theme.components(separatedBy: name).count - 1, 1, name)
        }
        XCTAssertTrue(theme.contains("rigidImpact.impactOccurred(intensity: 0.6)"))
        XCTAssertTrue(theme.contains("notification.notificationOccurred(.error)"))
    }
}
