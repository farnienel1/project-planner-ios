import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.9.0 §1 "Live screens" and "Never re-save what you didn't change", §8, §9, §13 and the H&S removal
/// rules, through `CanonicalBusinessEngine` (expected values checked in Node against the packed script).
@MainActor
final class Rulebook190WriteDisciplineTests: XCTestCase {
    // MARK: syncWriteAllowed

    func testOnlyAUserActionOrItsReplayMayWrite() {
        XCTAssertEqual(CanonicalBusinessEngine.syncWriteTriggers, SyncWriteTrigger.allCases.map(\.rawValue),
                       "the Swift trigger list is the script's SYNC_WRITE_TRIGGERS")
        XCTAssertTrue(CanonicalBusinessEngine.syncWriteAllowed(.userAction))
        XCTAssertTrue(CanonicalBusinessEngine.syncWriteAllowed(.offlineReplay))
        for trigger in [SyncWriteTrigger.launch, .foreground, .reconnect, .backgroundSync, .pullToRefresh, .listenerSnapshot] {
            XCTAssertFalse(CanonicalBusinessEngine.syncWriteAllowed(trigger), trigger.rawValue)
            XCTAssertFalse(SyncWriteGate.allows(trigger, "test"), trigger.rawValue)
        }
    }

    func testAChangeSetBuiltOutsideAUserActionWritesNothing() {
        let client = Client(id: UUID(), name: "TEST-Client", contactPerson: nil, email: "", phone: "", address: "")
        var changes = ProjectStoreChangeSet.createClient(client)
        XCTAssertEqual(changes.clientsToSave(from: [client]).count, 1)
        changes.trigger = .foreground
        XCTAssertTrue(changes.clientsToSave(from: [client]).isEmpty, "a foreground re-save is refused")
    }

    func testRecordsToSaveKeepsOnlyTheChangedIdsWithoutCase() {
        XCTAssertEqual(CanonicalBusinessEngine.recordsToSave(recordIds: ["ABC", "def"], changedIds: ["abc"]), ["ABC"])
        XCTAssertEqual(CanonicalBusinessEngine.recordsToSave(recordIds: ["ABC"], changedIds: []), [])
    }

    func testAnEditOfAMissingDocumentIsRefusedAndReplayIsFinal() {
        XCTAssertEqual(CanonicalBusinessEngine.editOfMissingDocumentIsRefused(isCreate: false, exists: false), true)
        XCTAssertEqual(CanonicalBusinessEngine.editOfMissingDocumentIsRefused(isCreate: true, exists: false), false)
        XCTAssertEqual(CanonicalBusinessEngine.editOfMissingDocumentIsRefused(isCreate: nil, exists: false), false)
        XCTAssertEqual(CanonicalBusinessEngine.editOfMissingDocumentIsRefused(isCreate: false, errorCode: 5), true)
        XCTAssertTrue(CanonicalBusinessEngine.replayRefusedIsFinal(errorCode: 7, isCreate: nil))
        XCTAssertTrue(CanonicalBusinessEngine.replayRefusedIsFinal(errorCode: 5, isCreate: false))
        XCTAssertFalse(CanonicalBusinessEngine.replayRefusedIsFinal(errorCode: 5, isCreate: true))
        XCTAssertFalse(CanonicalBusinessEngine.replayRefusedIsFinal(errorCode: 5, isCreate: nil))
        XCTAssertEqual(RecordDeletedElsewhereError.message, "This was deleted on another device.")
        XCTAssertEqual(RecordDeletedElsewhereError.message, CanonicalBusinessEngine.editOfMissingDocumentMessage)
    }

    // MARK: LIVE_COLLECTIONS coverage

    func testEveryListenCollectionHasAnIOSListener() {
        let rows = CanonicalBusinessEngine.liveCollections
        XCTAssertFalse(rows.isEmpty, "LIVE_COLLECTIONS loaded from the packed script")
        XCTAssertEqual(IOSLiveListenerCoverage.uncoveredListenIds(rows), [],
                       "add an iOS listener (and an IOSLiveListenerCoverage entry) for every listen: true collection")
        let known = Set(rows.map(\.id))
        for id in IOSLiveListenerCoverage.listeners.keys {
            XCTAssertTrue(known.contains(id), "\(id) is not a LIVE_COLLECTIONS id")
            XCTAssertTrue(CanonicalBusinessEngine.screenMustListen(id), "\(id) is listed as a listener but may load on open")
        }
        XCTAssertFalse(CanonicalBusinessEngine.screenMustListen("taxIds"))
        XCTAssertTrue(CanonicalBusinessEngine.screenMustListen("TEST-unknown"), "an unknown id is live")
        XCTAssertEqual(CanonicalBusinessEngine.liveCollection("Wholesalers")?.id, "wholesalers")
    }

    // MARK: timesheetChangedFields

    func testAReviewerSaveKeepsTheOwnerSignature() {
        let signed = Timestamp(seconds: 100, nanoseconds: 0)
        let base: [String: Any] = [
            "managerNote": "",
            "operativeSignedAt": signed,
            "operativeSignedByName": "TEST-Owner",
            "managerSignedAt": NSNull(),
        ]
        var next = base
        next["managerSignedAt"] = Timestamp(seconds: 200, nanoseconds: 0)
        next["managerSignedByName"] = "TEST-Manager"
        // The reviewer's copy lost the owner's signature fields it never edited: they are not part of `next`.
        next.removeValue(forKey: "operativeSignedAt")
        next.removeValue(forKey: "operativeSignedByName")
        let write = CanonicalBusinessEngine.timesheetChangedFields(base: base, next: next)
        XCTAssertEqual(write?.setKeys, ["managerSignedAt", "managerSignedByName"])
        XCTAssertEqual(write?.removeKeys, [])
        XCTAssertFalse(write?.setKeys.contains("operativeSignedAt") ?? true, "the owner's signature is never resent")
    }

    // MARK: notificationCreateFields / notificationRelatedId

    func testAnInboxRowIsCreatedOnceAndNeverRandomlyRelated() {
        func create(storedExists: Bool, userId: String? = "TEST-uid") -> [String: Any]? {
            CanonicalBusinessEngine.notificationCreateFields(
                organizationId: "TEST-org",
                type: "push_test",
                title: "t",
                message: "m",
                userId: userId,
                actorUserId: "TEST-uid",
                relatedId: nil,
                requiresPermission: nil,
                deepLinkUserId: nil,
                deepLinkWeekStart: nil,
                dayKey: nil,
                catalogue: nil,
                createdAt: Timestamp(seconds: 1, nanoseconds: 0),
                storedExists: storedExists
            )
        }
        XCTAssertNil(create(storedExists: true), "a stored row (dedupe hit) is left alone, its read state kept")
        XCTAssertNil(create(storedExists: false, userId: nil), "a row without userId is not an inbox row")
        let row = create(storedExists: false)
        XCTAssertEqual(row?["isRead"] as? Bool, false)
        XCTAssertEqual(row?["actorUserId"] as? String, "TEST-uid")
        XCTAssertTrue(row?["createdAt"] is Timestamp, "the native timestamp is restored")
        XCTAssertNil(CanonicalBusinessEngine.notificationRelatedId(type: "push_test", ids: ["jobId": "J"]))
        XCTAssertEqual(CanonicalBusinessEngine.notificationRelatedId(type: "booking_created", ids: ["jobId": "J", "userId": "U"]), "J")
        XCTAssertEqual(CanonicalBusinessEngine.notificationRelatedId(type: "hs_toolbox_reminder", ids: ["issueId": "I1"]), "I1")
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationRelatedId(type: "timesheet_submission_reminder", ids: ["paymentDayKey": "2026-11-06"]),
            "2026-11-06"
        )
    }

    // MARK: Health & safety removal

    func testRemovingARecipientOrIssueRemovesOnlyTheirSignatures() {
        let stored: [String: Any] = [
            "signatureRecords": [
                "i1__u1": ["issueId": "I1", "userId": "U1"],
                "i1__u2": ["issueId": "I1", "userId": "U2"],
                "i2__u1": ["issueId": "I2", "userId": "U1"],
            ],
            "signatures": [["issueId": "I1", "userId": "U1"], ["issueId": "I2", "userId": "U1"]],
        ]
        let recipient = CanonicalBusinessEngine.healthSafetySignatureRemovalWrites(stored: stored, removals: [(issueId: "i1", userId: "u1")])
        XCTAssertEqual(recipient??.removeFieldPaths, [["signatureRecords", "i1__u1"]])
        XCTAssertEqual(recipient??.signatures?.count, 1)
        let issue = CanonicalBusinessEngine.healthSafetySignatureRemovalWrites(stored: stored, removals: [(issueId: "I2", userId: nil)])
        XCTAssertEqual(issue??.removeFieldPaths, [["signatureRecords", "i2__u1"]])
        let none = CanonicalBusinessEngine.healthSafetySignatureRemovalWrites(stored: stored, removals: [(issueId: "I9", userId: nil)])
        XCTAssertNotNil(none, "the script answered")
        XCTAssertNil(none ?? nil, "nothing matches: no write")
    }

    func testRemovingTheLastIssueOrJobTypeIsWrittenOnlyWhenDeliberate() {
        let stored: [String: Any] = ["issues": [["id": "I1", "status": "awaiting"]]]
        let deliberate = CanonicalBusinessEngine.healthSafetyDocumentWriteFields(
            stored: stored, next: ["issues": []], removedIds: ["issues": ["i1"]]
        )
        XCTAssertEqual((deliberate?.set["issues"] as? [Any])?.count, 0)
        let failedLoad = CanonicalBusinessEngine.healthSafetyDocumentWriteFields(stored: stored, next: ["issues": []])
        XCTAssertNil(failedLoad?.set["issues"], "an empty list without a removal is a failed load: not written")
        XCTAssertEqual(CanonicalBusinessEngine.jobTypesWriteFields(stored: ["Cat A"], next: [], removed: ["Cat A"]), .some(.some([])))
        XCTAssertEqual(CanonicalBusinessEngine.jobTypesWriteFields(stored: ["Cat A"], next: []), .some(nil))
    }

    // MARK: leaveRecordsForAccount / leaveDaysInRange

    func testMyLeaveMatchesEveryIdOfTheAccountWithoutCase() {
        let records: [(userId: String?, operativeId: String?)] = [
            (userId: "TEST-UID-1", operativeId: nil),
            (userId: "test-old-id", operativeId: nil),
            (userId: nil, operativeId: "TEST-OP-1"),
            (userId: "TEST-someone", operativeId: nil),
            (userId: "test-uid-1", operativeId: nil),
        ]
        let indexes = CanonicalBusinessEngine.leaveRecordsForAccount(
            records: records,
            account: CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                id: "test-uid-1", email: "test-a@example.com", formerIds: ["TEST-OLD-ID"], aliasIds: nil
            ),
            operatives: [CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: "test-op-1", email: "TEST-A@example.com")]
        )
        XCTAssertEqual(indexes, [0, 1, 2, 4])
    }

    func testWeeklyReportLeaveDaysSkipWeekendsAndCountHalfDays() {
        XCTAssertEqual(CanonicalBusinessEngine.leaveDaysInRange(
            startDayKey: "2026-11-06", endDayKey: "2026-11-10", timeSlot: "FULL DAY",
            rangeStartDayKey: "2026-11-02", rangeEndDayKey: "2026-11-08", timeZone: "Europe/London"
        ), 1)
        XCTAssertEqual(CanonicalBusinessEngine.leaveDaysInRange(
            startDayKey: "2026-11-04", endDayKey: "2026-11-04", timeSlot: "AM",
            rangeStartDayKey: "2026-11-02", rangeEndDayKey: "2026-11-08", timeZone: "Europe/London"
        ), 0.5)
    }

    // MARK: Create shapes

    func testAnnualLeavePendingOmitsOnlyUnstoredUneditedFigures() {
        XCTAssertEqual(
            CanonicalBusinessEngine.annualLeavePendingOmitFields(pending: true, storedKeys: ["daysPerYear"], edited: ["annualLeaveCarriesOver"]),
            ["annualLeaveYearStartMonth", "annualLeaveYearEndMonth"]
        )
        XCTAssertEqual(CanonicalBusinessEngine.annualLeavePendingOmitFields(pending: false, storedKeys: [], edited: []), [])
        XCTAssertEqual(CanonicalBusinessEngine.userAnnualLeaveFigureFields.count, 4)
    }

    func testInvitationAndTaxIdsCreateShapes() throws {
        let created = Timestamp(seconds: 5, nanoseconds: 0)
        let fields = try InvitationDocument.createFields(from: [
            "email": "TEST-A@Example.com",
            "organizationId": "TEST-org",
            "invitedBy": "TEST-admin",
            "firstName": "TEST",
            "surname": "Person",
            "permissions": ["manager": true],
            "createdAt": Timestamp(seconds: 1, nanoseconds: 0),
            "isUsed": false,
        ], createdAt: created)
        XCTAssertEqual(fields["email"] as? String, "test-a@example.com")
        XCTAssertEqual(fields["inviteType"] as? String, "new_user")
        XCTAssertEqual(fields["isUsed"] as? Bool, false)
        XCTAssertEqual((fields["createdAt"] as? Timestamp)?.seconds, 5)
        XCTAssertThrowsError(try InvitationDocument.createFields(from: ["email": ""]))
        XCTAssertEqual(InvitationDocument.usedFields(usedAt: created)["isUsed"] as? Bool, true)
        let tax = CanonicalBusinessEngine.taxIdsDocumentFields(utrNumber: " 123 ", vatNumber: "", updatedByUserId: "TEST-uid")
        XCTAssertEqual(tax?["utrNumber"] as? String, "123")
        XCTAssertEqual(tax?["vatNumber"] as? String, "")
    }
}
