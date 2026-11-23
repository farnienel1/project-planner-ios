import XCTest
@testable import Project_Planner

/// Owner issues 17 Nov #17–#19 (user profile summary on iOS): a person's qualifications are read from every
/// `operatives` row of that person (`taskPersonKeys`, guardrail 1), each with its stored expiry (the
/// `qualificationExpiryDates` map, else the assignment's `endDate`) and a safe certificate link. Display only.
@MainActor
final class PersonQualificationsTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func operative(
        _ docId: String,
        email: String,
        linkedUserId: String? = nil,
        isActive: Bool = true,
        qualifications: [Qualification] = [],
        expiry: [String: Date] = [:],
        certificates: [String: String] = [:]
    ) -> Operative {
        var row = Operative(
            id: WorkDocumentKeys.inAppId(for: docId),
            firstName: "Row",
            lastName: docId,
            email: email,
            startDate: Date(timeIntervalSince1970: 0),
            qualifications: qualifications,
            qualificationExpiryDates: expiry,
            qualificationCertificateURLs: certificates,
            dayRate: 200
        )
        row.firestoreDocumentId = docId
        row.linkedUserId = linkedUserId
        row.isActive = isActive
        return row
    }

    private func user(_ id: String, email: String, ghost: Bool = false, formerUserIds: [String] = []) -> AppUser {
        var row = LogicFixtures.selfEmployedUser(id: id, email: email)
        row.isGhost = ghost
        row.formerUserIds = formerUserIds
        return row
    }

    // MARK: Who the person is (guardrail 1)

    func testRowsOnTheEmailAndRowsLinkedToTheAccountAreThePersonsAnotherPersonsAreNot() throws {
        let ada = user("u-ada", email: "ada@site.com")
        let pat = user("u-pat", email: "pat@site.com")
        let onEmail = operative("op-ada", email: "ADA@site.com")
        let linked = operative("op-ada-old", email: "ada.old@site.com", linkedUserId: "U-ADA")
        let other = operative("op-pat", email: "pat@site.com")
        let rows = try XCTUnwrap(PersonQualifications.operativeRows(
            for: ada,
            users: [ada, pat],
            operatives: [onEmail, linked, other],
            managers: []
        ))
        XCTAssertEqual(Set(rows.map(\.documentId)), ["op-ada", "op-ada-old"])
    }

    func testAConvertedGhostsOldRowIsTheGhosts() throws {
        // RULEBOOK 1.34.0 §11: users/ROW-A is the ghost; its old row keeps the id with the email cleared.
        let ghost = user("ROW-A", email: "", ghost: true, formerUserIds: ["row-b"])
        let kept = operative("row-a", email: "", linkedUserId: "ROW-A")
        let duplicate = operative("row-b", email: "gus@old.com", linkedUserId: "row-a", isActive: false)
        let rows = try XCTUnwrap(PersonQualifications.operativeRows(
            for: ghost,
            users: [ghost],
            operatives: [kept, duplicate],
            managers: []
        ))
        XCTAssertEqual(Set(rows.map(\.documentId)), ["row-a", "row-b"])
    }

    func testAnAdminWithNoOperativesRowHasNoQualifications() throws {
        let admin = user("u-admin", email: "boss@site.com")
        let rows = try XCTUnwrap(PersonQualifications.rows(
            for: admin,
            users: [admin],
            operatives: [operative("op-pat", email: "pat@site.com", qualifications: [Qualification(id: "Q1", name: "CSCS")])],
            managers: []
        ))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: Expiry (#19)

    func testTheExpiryMapIsReadUnderTheIdInAnyCaseThenTheAssignmentEndDate() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let fromMap = Qualification(id: "q-abc", name: "SSSTS", hasEndDate: false)
        XCTAssertEqual(PersonQualifications.expiryDate(qualification: fromMap, expiryDates: ["Q-ABC": date]), date)
        XCTAssertEqual(PersonQualifications.expiryDate(qualification: fromMap, expiryDates: ["q-abc": date]), date)
        let fromRow = Qualification(id: "q-row", name: "IPAF", hasEndDate: true, endDate: date)
        XCTAssertEqual(PersonQualifications.expiryDate(qualification: fromRow, expiryDates: [:]), date)
        let none = Qualification(id: "q-none", name: "First aid", hasEndDate: false, endDate: nil)
        XCTAssertNil(PersonQualifications.expiryDate(qualification: none, expiryDates: [:]))
    }

    func testADateInTheMapIsNeverShownAsNoExpiry() {
        // Web read only `hasEndDate && endDate` and showed "No expiry" for a date kept in the map.
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = reference.addingTimeInterval(400 * day)
        let q = Qualification(id: "Q1", name: "CSCS", hasEndDate: false)
        let rows = PersonQualifications.rows(
            fromOwnRows: [operative("op", email: "a@b.com", qualifications: [q], expiry: ["Q1": expiry])],
            reference: reference
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.expiry, expiry)
        XCTAssertTrue(PersonQualifications.expiryText(rows[0]).hasPrefix("Expires "))
        XCTAssertEqual(rows.first?.tone, PersonQualificationRow.Tone.none)
    }

    func testAnExpiredQualificationIsMarkedExpiredByTheWarningsRule() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let q = Qualification(id: "Q1", name: "CSCS")
        let soonQ = Qualification(id: "Q2", name: "IPAF")
        let rows = PersonQualifications.rows(
            fromOwnRows: [operative(
                "op",
                email: "a@b.com",
                qualifications: [q, soonQ],
                expiry: ["Q1": reference.addingTimeInterval(-10 * day), "Q2": reference.addingTimeInterval(10 * day)]
            )],
            reference: reference
        )
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId["Q1"]?.tone, .expired)
        XCTAssertTrue(PersonQualifications.expiryText(byId["Q1"]!).hasPrefix("Expired "))
        XCTAssertEqual(byId["Q2"]?.tone, .expiringSoon)
    }

    func testNoExpiryReadsNoExpiry() {
        let rows = PersonQualifications.rows(
            fromOwnRows: [operative("op", email: "a@b.com", qualifications: [Qualification(id: "Q1", name: "CSCS")])]
        )
        XCTAssertEqual(PersonQualifications.expiryText(rows[0]), "No expiry")
    }

    func testTheEditorShowsDerivedExpiriesButNeverWritesThem() {
        // Review of #269 item 2: derived expiries are display only; the stored map is the write map.
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let fromRow = Qualification(id: "Q-ROW", name: "IPAF", hasEndDate: true, endDate: date)
        let otherCase = Qualification(id: "Q-CASE", name: "CSCS")
        let stored = Qualification(id: "Q-STORED", name: "SMSTS")
        let op = operative(
            "op",
            email: "a@b.com",
            qualifications: [fromRow, otherCase, stored],
            expiry: ["q-case": date, "Q-STORED": date]
        )
        let derived = PersonQualifications.derivedExpiryDates(for: op)
        XCTAssertEqual(derived, ["Q-ROW": date, "Q-CASE": date])
        // The stored map (what a save starts from) is untouched.
        XCTAssertEqual(op.qualificationExpiryDates, ["q-case": date, "Q-STORED": date])
    }

    // MARK: A save changes only what the person changed (review of #269)

    private let loadedDay = Date(timeIntervalSince1970: 1_900_000_000)

    func testAnExpiryUnderAnotherSpellingIsNeverDeletedWhenThePersonDidNotTouchIt() {
        // The #19 case: "q-case" is the stored key for qualification "Q-CASE". A save of something else keeps it.
        let loaded: [String: Date] = ["q-case": loadedDay, "Q-OTHER": loadedDay]
        var editor = loaded
        editor["Q-OTHER"] = loadedDay.addingTimeInterval(30 * day)
        let changes = OperativeQualificationPatch.changes(
            baselineExpiry: loaded,
            editorExpiry: editor,
            selectedIds: ["Q-CASE", "Q-OTHER"],
            baselineCertificates: [:],
            editorCertificates: [:]
        )
        XCTAssertTrue(changes.removeExpiry.isEmpty)
        XCTAssertEqual(Array(changes.setExpiry.keys), ["Q-OTHER"])
        XCTAssertEqual(changes.applied(expiry: loaded)["q-case"], loadedDay)
    }

    func testAnExpiryOrCertificateSavedOnAnotherDeviceAfterLoadIsKept() {
        // This phone loaded nothing for Q2; another device then set its expiry and uploaded its certificate.
        let loadedExpiry: [String: Date] = ["Q1": loadedDay]
        let loadedCerts = ["Q1": "https://example.com/q1.pdf"]
        let liveStoredExpiry: [String: Date] = ["Q1": loadedDay, "Q2": loadedDay]
        let liveStoredCerts = ["Q1": "https://example.com/q1.pdf", "Q2": "https://example.com/other-device.pdf"]
        // The person changed only Q1's expiry here.
        let changes = OperativeQualificationPatch.changes(
            baselineExpiry: loadedExpiry,
            editorExpiry: ["Q1": loadedDay.addingTimeInterval(10 * day)],
            selectedIds: ["Q1", "Q2"],
            baselineCertificates: loadedCerts,
            editorCertificates: loadedCerts
        )
        XCTAssertTrue(changes.removeExpiry.isEmpty)
        XCTAssertTrue(changes.removeCertificates.isEmpty)
        XCTAssertTrue(changes.setCertificates.isEmpty)
        XCTAssertEqual(changes.applied(expiry: liveStoredExpiry)["Q2"], loadedDay)
        XCTAssertEqual(changes.applied(certificates: liveStoredCerts)["Q2"], "https://example.com/other-device.pdf")
    }

    func testAnExpiryOrCertificateThePersonClearedIsRemoved() {
        let loadedExpiry: [String: Date] = ["Q1": loadedDay, "Q2": loadedDay]
        let loadedCerts = ["Q1": "https://example.com/q1.pdf"]
        let changes = OperativeQualificationPatch.changes(
            baselineExpiry: loadedExpiry,
            editorExpiry: ["Q2": loadedDay],
            selectedIds: ["Q1", "Q2"],
            baselineCertificates: loadedCerts,
            editorCertificates: [:]
        )
        XCTAssertEqual(changes.removeExpiry, ["Q1"])
        XCTAssertTrue(changes.setExpiry.isEmpty, "an unchanged expiry is never re-saved")
        XCTAssertEqual(changes.removeCertificates, ["Q1"])
    }

    func testARenewedCertificateRemovesOnlyOtherSpellingsOfItsId() {
        let known = [
            "q1": "https://example.com/old.pdf",
            "Q2": "https://example.com/other.pdf",
        ]
        let changes = OperativeQualificationPatch.changes(
            baselineExpiry: [:],
            editorExpiry: [:],
            selectedIds: [],
            baselineCertificates: [:],
            editorCertificates: [:],
            uploaded: ["Q1": "https://example.com/new.pdf"],
            knownCertificates: known
        )
        XCTAssertEqual(changes.setCertificates, ["Q1": "https://example.com/new.pdf"])
        XCTAssertEqual(changes.removeCertificates, ["q1"])
        XCTAssertEqual(
            changes.applied(certificates: known),
            ["Q1": "https://example.com/new.pdf", "Q2": "https://example.com/other.pdf"]
        )
    }

    // MARK: Certificates (#18, #16)

    func testACertificateIsOfferedOnlyAsAnHttpsLink() {
        let q1 = Qualification(id: "Q1", name: "CSCS")
        let q2 = Qualification(id: "Q2", name: "IPAF")
        let rows = PersonQualifications.rows(fromOwnRows: [operative(
            "op",
            email: "a@b.com",
            qualifications: [q1, q2],
            certificates: ["q1": "https://firebasestorage.googleapis.com/v0/b/x/o/cert.pdf", "Q2": "javascript:alert(1)"]
        )])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId["Q1"]?.certificateURL?.scheme, "https")
        XCTAssertNil(byId["Q2"]?.certificateURL)
    }

    func testOneQualificationOnTwoRowsIsShownOnceTheCopyWithACertificateWins() {
        let q = Qualification(id: "Q1", name: "CSCS")
        let withCert = operative(
            "op-b",
            email: "a@b.com",
            qualifications: [q],
            certificates: ["Q1": "https://example.com/new.pdf"]
        )
        let without = operative("op-a", email: "a@b.com", qualifications: [Qualification(id: "q1", name: "CSCS")])
        let rows = PersonQualifications.rows(fromOwnRows: [without, withCert])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operativeDocumentId, "op-b")
        XCTAssertEqual(rows.first?.certificateURL?.absoluteString, "https://example.com/new.pdf")
    }

    func testARenewedCertificateReplacesTheOldLinkUnderEverySpellingOfTheId() throws {
        // The editor's two-step merge (issue #16): remove every spelling of the renewed id, then add the new link.
        let existing = ["q1": "https://example.com/old.pdf", "Q2": "https://example.com/other.pdf"]
        let uploaded = ["Q1": "https://example.com/new.pdf"]
        let cleared = try XCTUnwrap(CanonicalBusinessEngine.mergeQualificationCertificateUrls(
            existing: existing, uploaded: [:], removedIds: Array(uploaded.keys)
        ))
        let merged = try XCTUnwrap(CanonicalBusinessEngine.mergeQualificationCertificateUrls(existing: cleared, uploaded: uploaded))
        XCTAssertEqual(merged, ["Q1": "https://example.com/new.pdf", "Q2": "https://example.com/other.pdf"])
        XCTAssertEqual(
            CanonicalBusinessEngine.qualificationCertificateUrl(urls: merged, qualificationId: "q1"),
            "https://example.com/new.pdf"
        )
    }

    // MARK: A save never sticks on "Saving…" (#16)

    func testBoundedWaitGivesUpOnWorkThatNeverAnswers() async {
        let started = Date()
        do {
            _ = try await BoundedWait.run(seconds: 0.2) { () async throws -> String in
                // Ignores cancellation, as a Firestore write waiting for the server does.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return "never"
            }
            XCTFail("expected a timeout")
        } catch let error as BoundedWait.TimedOut {
            XCTAssertEqual(error.seconds, 0.2)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testBoundedWaitStopsAtOnceWhenTheCallerIsCancelled() async {
        let started = Date()
        let waiter = Task { () -> Error? in
            do {
                _ = try await BoundedWait.run(seconds: 60) { () async throws -> String in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return "never"
                }
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        let error = await waiter.value
        XCTAssertTrue(error is CancellationError, "got \(String(describing: error))")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testBoundedWaitReturnsTheAnswerAndPassesErrorsOn() async throws {
        let value = try await BoundedWait.run(seconds: 5) { "done" }
        XCTAssertEqual(value, "done")
        struct Refused: Error {}
        do {
            _ = try await BoundedWait.run(seconds: 5) { () async throws -> Int in throw Refused() }
            XCTFail("expected the error")
        } catch is Refused {
        }
    }
}
