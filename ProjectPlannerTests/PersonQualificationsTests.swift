import XCTest
@testable import Project_Planner

/// Owner issues 17 Nov #17–#19 and 23 Nov gap 1 (RULEBOOK 1.73.0 §5): a person's qualifications are read from every
/// `operatives` row of that person (`operativeRowsForPerson`, guardrail 1) through `personQualifications`, each with
/// its expiry (`qualificationExpiryDate` over the `qualificationExpiryDates` map; the assignment's `endDate` is never
/// an expiry) and a safe certificate link. Display only.
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
            operatives: [onEmail, linked, other]
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
            operatives: [kept, duplicate]
        ))
        XCTAssertEqual(Set(rows.map(\.documentId)), ["row-a", "row-b"])
    }

    func testAnAdminWithNoOperativesRowHasNoQualifications() throws {
        let admin = user("u-admin", email: "boss@site.com")
        let rows = try XCTUnwrap(PersonQualifications.rows(
            for: admin,
            users: [admin],
            operatives: [operative("op-pat", email: "pat@site.com", qualifications: [Qualification(id: "Q1", name: "CSCS")])]
        ))
        XCTAssertTrue(rows.isEmpty)
    }

    func testAPlaceholderRowIsNeverThePersons() throws {
        // RULEBOOK 1.73.0 `isPlaceholderOperativeRow`: the starter rows older builds wrote are never a person.
        let ada = user("u-ada", email: "ada@site.com")
        var placeholder = operative("op-placeholder", email: "ada@site.com")
        placeholder.firstName = "Placeholder"
        let real = operative("op-ada", email: "ada@site.com")
        let rows = try XCTUnwrap(PersonQualifications.operativeRows(
            for: ada,
            users: [ada],
            operatives: [placeholder, real]
        ))
        XCTAssertEqual(rows.map(\.documentId), ["op-ada"])
    }

    // MARK: Expiry (#19, RULEBOOK 1.73.0 `qualificationExpiryDate`)

    func testTheExpiryMapIsReadUnderTheIdInAnyCaseAndTheAssignmentEndDateIsNeverAnExpiry() throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(PersonQualifications.expiryDate(qualificationId: "q-abc", expiryDates: ["Q-ABC": date]), date)
        XCTAssertEqual(PersonQualifications.expiryDate(qualificationId: "q-abc", expiryDates: ["q-abc": date]), date)
        XCTAssertNil(PersonQualifications.expiryDate(qualificationId: "q-none", expiryDates: [:]))
        // An assignment row's own `endDate` is not an expiry (web read it before 1.73.0; iOS did too).
        let fromRow = Qualification(id: "q-row", name: "IPAF", hasEndDate: true, endDate: date)
        let rows = try XCTUnwrap(PersonQualifications.rows(
            fromOwnRows: [operative("op", email: "a@b.com", qualifications: [fromRow])]
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.expiry)
    }

    func testDatesReachTheScriptAsMillisecondsNotSeconds() {
        // A date in seconds would read as January 1970 (hand-off v1.73.0).
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let read = PersonQualifications.expiryDate(qualificationId: "Q1", expiryDates: ["Q1": date])
        XCTAssertEqual(read?.timeIntervalSince1970 ?? 0, 1_900_000_000, accuracy: 0.001)
    }

    func testADateInTheMapIsNeverShownAsNoExpiry() throws {
        // Web read only `hasEndDate && endDate` and showed "No expiry" for a date kept in the map.
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = reference.addingTimeInterval(400 * day)
        let q = Qualification(id: "Q1", name: "CSCS", hasEndDate: false)
        let rows = try XCTUnwrap(PersonQualifications.rows(
            fromOwnRows: [operative("op", email: "a@b.com", qualifications: [q], expiry: ["Q1": expiry])],
            reference: reference
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.expiry, expiry)
        XCTAssertTrue(PersonQualifications.expiryText(rows[0]).hasPrefix("Expires "))
        XCTAssertEqual(rows.first?.tone, PersonQualificationRow.Tone.none)
    }

    func testAnExpiredQualificationIsMarkedExpiredByTheWarningsRule() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let q = Qualification(id: "Q1", name: "CSCS")
        let soonQ = Qualification(id: "Q2", name: "IPAF")
        let rows = try XCTUnwrap(PersonQualifications.rows(
            fromOwnRows: [operative(
                "op",
                email: "a@b.com",
                qualifications: [q, soonQ],
                expiry: ["Q1": reference.addingTimeInterval(-10 * day), "Q2": reference.addingTimeInterval(10 * day)]
            )],
            reference: reference
        ))
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId["Q1"]?.tone, .expired)
        XCTAssertTrue(PersonQualifications.expiryText(byId["Q1"]!).hasPrefix("Expired "))
        XCTAssertEqual(byId["Q2"]?.tone, .expiringSoon)
    }

    func testNoExpiryReadsNoExpiry() throws {
        let rows = try XCTUnwrap(PersonQualifications.rows(
            fromOwnRows: [operative("op", email: "a@b.com", qualifications: [Qualification(id: "Q1", name: "CSCS")])]
        ))
        XCTAssertEqual(PersonQualifications.expiryText(rows[0]), "No expiry")
    }

    func testSettingAnExpiryRemovesEveryOtherSpellingOfTheId() {
        // RULEBOOK 1.73.0 `withQualificationExpiry`: one spelling of the id is left; other ids are untouched.
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let later = date.addingTimeInterval(30 * day)
        let stored: [String: Date] = ["q-case": date, "Q-OTHER": date]
        let set = PersonQualifications.settingExpiry(later, qualificationId: "Q-CASE", in: stored)
        XCTAssertEqual(Set(set.keys), ["Q-CASE", "Q-OTHER"])
        XCTAssertEqual(set["Q-CASE"], OrganizationRulebookContext.calendar.startOfDay(for: later))
        XCTAssertEqual(set["Q-OTHER"], date)
        let cleared = PersonQualifications.settingExpiry(nil, qualificationId: "Q-CASE", in: stored)
        XCTAssertEqual(cleared, ["Q-OTHER": date])
        // A save after clearing removes the stored other spelling (it was loaded and is no longer held).
        let changes = OperativeQualificationPatch.changes(
            baselineExpiry: stored,
            editorExpiry: cleared,
            selectedIds: ["Q-CASE", "Q-OTHER"],
            baselineCertificates: [:],
            editorCertificates: [:]
        )
        XCTAssertEqual(changes.removeExpiry, ["q-case"])
        XCTAssertTrue(changes.setExpiry.isEmpty)
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

    func testACertificateIsOfferedOnlyAsAnHttpsLink() throws {
        let q1 = Qualification(id: "Q1", name: "CSCS")
        let q2 = Qualification(id: "Q2", name: "IPAF")
        let rows = try XCTUnwrap(PersonQualifications.rows(fromOwnRows: [operative(
            "op",
            email: "a@b.com",
            qualifications: [q1, q2],
            certificates: ["q1": "https://firebasestorage.googleapis.com/v0/b/x/o/cert.pdf", "Q2": "javascript:alert(1)"]
        )]))
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId["Q1"]?.certificateURL?.scheme, "https")
        XCTAssertNil(byId["Q2"]?.certificateURL)
    }

    func testOneQualificationOnTwoRowsIsShownOnceTheCopyWithACertificateWins() throws {
        let q = Qualification(id: "Q1", name: "CSCS")
        let withCert = operative(
            "op-b",
            email: "a@b.com",
            qualifications: [q],
            certificates: ["Q1": "https://example.com/new.pdf"]
        )
        let without = operative("op-a", email: "a@b.com", qualifications: [Qualification(id: "q1", name: "CSCS")])
        let rows = try XCTUnwrap(PersonQualifications.rows(fromOwnRows: [without, withCert]))
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
