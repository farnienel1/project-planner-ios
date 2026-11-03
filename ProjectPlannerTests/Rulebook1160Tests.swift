import XCTest
@testable import Project_Planner

/// RULEBOOK 1.15.0, 1.16.0 and 1.16.1 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was
/// checked in node against the packed `canonical-business.js` (sha256 586f1b0b…5c8).
@MainActor
final class Rulebook1160Tests: XCTestCase {
    // MARK: Health & safety file links (1.16.1)

    /// `mergeHealthSafetyRowCopies`: one row per id (case ignored), the first copy's order, but the copy that still
    /// has a `fileURL` wins; the rows come back as the native maps passed in.
    func testMergeHealthSafetyRowCopiesKeepsTheCopyWithALink() throws {
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let primary: [[String: Any]] = [
            ["id": "RAMS-1", "fileURL": "", "title": "Lost link", "uploadedAt": stamp],
            ["id": "RAMS-2", "fileURL": "https://x/2", "title": "Two"],
        ]
        let secondary: [[String: Any]] = [
            ["id": "rams-1", "fileURL": "https://x/1", "title": "With link"],
            ["id": "RAMS-3", "title": "Three"],
        ]
        let merged = try XCTUnwrap(CanonicalBusinessEngine.mergeHealthSafetyRowCopies(primary: primary, secondary: secondary))
        XCTAssertEqual(merged.compactMap { $0["id"] as? String }, ["rams-1", "RAMS-2", "RAMS-3"])
        XCTAssertEqual(merged.first?["fileURL"] as? String, "https://x/1")
        XCTAssertEqual(merged.first?["title"] as? String, "With link")
        XCTAssertNil(merged.first?["__hsCopyIndex"], "the position marker never reaches the stored map")
    }

    /// The two settings copies of a job read as one: the RAMS row keeps the copy with the download link.
    func testMergedHealthSafetyDocumentsKeepTheDownloadLink() {
        let settingsCopy: [String: Any] = ["ramsDocuments": [["id": "R1", "title": "RAMS", "fileURL": ""]]]
        let olderCopy: [String: Any] = ["ramsDocuments": [["id": "r1", "title": "RAMS", "fileURL": "https://x/r1.pdf"]]]
        let merged = FirebaseBackend.mergedHealthSafetyDocuments([settingsCopy, olderCopy])
        let rows = merged["ramsDocuments"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["fileURL"] as? String, "https://x/r1.pdf")
    }

    /// `healthSafetyDocumentWriteFields`: a blank `fileURL` / `fileName` never overwrites a stored link.
    func testBlankFileLinkNeverOverwritesStoredLink() throws {
        let stored: [String: Any] = [
            "ramsDocuments": [["id": "d1", "fileURL": "https://x", "fileName": "a.pdf", "title": "A"]],
        ]
        let write = try XCTUnwrap(CanonicalBusinessEngine.healthSafetyDocumentWriteFields(
            stored: stored,
            next: ["ramsDocuments": [["id": "D1", "fileURL": "", "fileName": "", "title": "B"]]]
        ))
        let rows = write.set["ramsDocuments"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["fileURL"] as? String, "https://x")
        XCTAssertEqual(rows.first?["fileName"] as? String, "a.pdf")
        XCTAssertEqual(rows.first?["title"] as? String, "B")
    }

    /// Stored file references: a download URL with a token opens as is; `gs://`, bare Storage paths and token-less
    /// Firebase URLs are resolved through Storage (`fileReportStoragePath`); `file://` and blanks cannot be opened.
    func testStoredFileTargets() {
        XCTAssertEqual(
            StoredFileTarget.target(for: "gs://b.appspot.com/organizations/o/healthSafety/x/rams/a.pdf"),
            .storage("organizations/o/healthSafety/x/rams/a.pdf")
        )
        XCTAssertEqual(StoredFileTarget.target(for: "organizations/o/x.pdf"), .storage("organizations/o/x.pdf"))
        XCTAssertEqual(
            StoredFileTarget.target(for: "https://firebasestorage.googleapis.com/v0/b/b.appspot.com/o/organizations%2Fo%2Fx.pdf?alt=media"),
            .storage("organizations/o/x.pdf")
        )
        let tokened = "https://firebasestorage.googleapis.com/v0/b/b.appspot.com/o/organizations%2Fo%2Fx.pdf?alt=media&token=t"
        XCTAssertEqual(StoredFileTarget.target(for: tokened), .url(URL(string: tokened)!))
        XCTAssertNil(StoredFileTarget.target(for: "file:///var/x.pdf"))
        XCTAssertNil(StoredFileTarget.target(for: "  "))
    }

    // MARK: Notification centre (1.16.0 §13)

    private let roster: [[String: Any]] = [
        ["id": "MGR-1", "email": "mgr@x.test", "isActive": true, "role": "manager", "passwordSet": true],
        ["id": "OP-INVITE", "email": "op@x.test", "isActive": true, "role": "operative", "passwordSet": false],
        ["id": "OP-LIVE", "email": "op@x.test", "isActive": true, "role": "operative", "passwordSet": true],
    ]
    private let catalogue: [[String: Any]] = [["id": "CAT-OP-1", "email": "OP@x.test"]]

    /// `bookingCreatedRecipients(bookedIds, booker, roster, catalogue)`: a catalogue id resolves to the signed-up
    /// account; booking yourself writes nothing; an id the roster cannot resolve is dropped.
    func testBookingCreatedRecipientsResolveTheAccount() {
        let booker: [String: Any] = ["id": "MGR-1", "email": "mgr@x.test"]
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingCreatedRecipients(bookedIds: ["cat-op-1"], booker: booker, roster: roster, catalogue: catalogue),
            ["OP-LIVE"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingCreatedRecipients(bookedIds: ["MGR-1"], booker: booker, roster: roster, catalogue: catalogue),
            []
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingCreatedRecipients(bookedIds: ["UNKNOWN"], booker: "MGR-1", roster: roster, catalogue: catalogue),
            []
        )
        XCTAssertEqual(CanonicalBusinessEngine.notificationRecipientAccountId("op-invite", roster: roster), "OP-LIVE")
    }

    /// The roster payload carries `passwordSet`, which picks the account (`notificationRecipientAccountId`).
    func testRosterPayloadCarriesPasswordSet() {
        let user = AppUser(
            id: "OP-LIVE",
            email: "op@x.test",
            organizationId: "TEST-org",
            role: .operative,
            firstName: "Olly",
            surname: "Op",
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true)
        )
        XCTAssertEqual(RulebookPeople.person(user)["passwordSet"] as? Bool, true)
    }

    /// `pushPayloadFields`: the one push payload, an unknown catalogue left out.
    func testPushPayloadFields() {
        let fields = CanonicalBusinessEngine.pushPayloadFields([
            "notificationId": "N1", "type": "booking_created", "relatedId": "J1", "dayKey": "2026-11-03",
            "catalogue": "x", "userId": "U", "organizationId": "ORG-2",
        ])
        XCTAssertEqual(fields, [
            "notificationId": "N1", "type": "booking_created", "relatedId": "J1", "dayKey": "2026-11-03",
            "userId": "U", "organizationId": "ORG-2",
        ])
        XCTAssertEqual(
            CanonicalBusinessEngine.pushPayloadKeys,
            ["notificationId", "type", "relatedId", "dayKey", "catalogue", "userId", "organizationId"]
        )
        // An in-app tap's `pp_` keys read as the same fields.
        let info = NotificationDeepLink.userInfo(type: .bookingCreated, relatedIdText: "J1", organizationId: "ORG-2")
        XCTAssertEqual(NotificationDeepLink.payloadFields(from: info)?["organizationId"], "ORG-2")
        XCTAssertEqual(NotificationDeepLink.payloadFields(from: info)?["relatedId"], "J1")
    }

    /// `notificationOrganizationSwitch`: switch only to another company the person belongs to.
    func testNotificationOrganizationSwitch() {
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationOrganizationSwitch(rowOrganizationId: "org-2", openOrganizationId: "ORG-1", membershipIds: ["ORG-1", "ORG-2"]),
            "org-2"
        )
        XCTAssertNil(CanonicalBusinessEngine.notificationOrganizationSwitch(rowOrganizationId: "ORG-3", openOrganizationId: "ORG-1", membershipIds: ["ORG-1", "ORG-2"]))
        XCTAssertNil(CanonicalBusinessEngine.notificationOrganizationSwitch(rowOrganizationId: "org-1", openOrganizationId: "ORG-1", membershipIds: ["ORG-1"]))
    }

    /// Due-now rows allow `INBOX_CREATED_AT_SKEW_MS` (5 min) of clock skew; scheduled types wait for `createdAt`.
    func testInboxVisibilityIsSkewTolerantForDueNowRows() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let nowMs = now.timeIntervalSince1970 * 1000
        XCTAssertEqual(CanonicalBusinessEngine.inboxNotificationVisibleToUser(
            rowUserId: "U", userIds: ["U"], createdAtMs: nowMs + 60_000, now: now, type: "booking_created"
        ), true)
        XCTAssertEqual(CanonicalBusinessEngine.inboxNotificationVisibleToUser(
            rowUserId: "U", userIds: ["U"], createdAtMs: nowMs + 60_000, now: now, type: "deadline_reminder"
        ), false)
        XCTAssertEqual(CanonicalBusinessEngine.inboxNotificationVisibleToUser(
            rowUserId: "U", userIds: ["U"], createdAtMs: nowMs + 600_000, now: now, type: "booking_created"
        ), false)
        let rows = [
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "U", isRead: false),
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "U", isRead: false),
        ]
        XCTAssertEqual(CanonicalBusinessEngine.unreadNotificationBadgeCount(
            rows: rows, userIds: ["U"], createdAtMs: [nowMs + 60_000, nowMs + 60_000], now: now,
            types: ["booking_created", "deadline_due"]
        ), 1)
    }

    /// `notificationCreateFields` with `serverTimestamp`: a due-now row is written with the server time; a
    /// scheduled type keeps its own due instant.
    func testNotificationCreateFieldsUseServerTimeForDueNowRows() throws {
        let due = Date(timeIntervalSince1970: 1_790_000_000)
        func created(_ type: String) throws -> Any? {
            try XCTUnwrap(CanonicalBusinessEngine.notificationCreateFields(
                organizationId: "TEST-org", type: type, title: "t", message: "m", userId: "U", actorUserId: "A",
                relatedId: nil, requiresPermission: nil, deepLinkUserId: nil, deepLinkWeekStart: nil, dayKey: nil,
                catalogue: nil, createdAt: due, serverTimestamp: "SERVER-TIME", storedExists: false
            ))["createdAt"]
        }
        XCTAssertEqual(try created("booking_created") as? String, "SERVER-TIME")
        XCTAssertEqual(try created("deadline_reminder") as? Date, due)
    }
}
