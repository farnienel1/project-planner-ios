import XCTest
@testable import Project_Planner

/// Owner reports 24 Nov (iPhone): company details abbreviation and offline copy, logo preview, warnings on a weak
/// signal, "Last active", and the site map job summary.
@MainActor
final class IOSFixes24NovTests: XCTestCase {

    // MARK: 1. Abbreviation: the form starts from the stored value, never derived initials

    func testCompanyDetailsFormStartsFromStoredAbbreviation() {
        XCTAssertEqual(CompanyDetailsFormSeed.abbreviation(stored: "RAC"), "RAC")
        XCTAssertEqual(CompanyDetailsFormSeed.abbreviation(stored: " rac "), "RAC")
    }

    func testCompanyDetailsFormStartsBlankWithNoStoredAbbreviation() {
        // Before 24 Nov the form was pre-filled with initials from the name ("Raccord MEP" → "RM") and a save wrote them.
        XCTAssertEqual(CompanyDetailsFormSeed.abbreviation(stored: nil), "")
        XCTAssertEqual(CompanyDetailsFormSeed.abbreviation(stored: "  "), "")
        // The hub badge still shows initials when nothing is stored.
        XCTAssertEqual(OrganizationDocumentAbbreviation.display(abbreviation: nil, organizationName: "Raccord MEP"), "RM")
        XCTAssertEqual(OrganizationDocumentAbbreviation.display(abbreviation: "RAC", organizationName: "Raccord MEP"), "RAC")
    }

    // MARK: 2. Offline copy keeps every company-details field

    private func loadedOrganization() -> Organization {
        var org = Organization(
            firestoreDocumentId: "org-1",
            name: "Raccord MEP",
            officeAddressLine1: "1 High Street",
            officeAddressLine2: "Unit 4",
            officeCity: "London",
            officeCounty: "Greater London",
            officePostcode: "SW1A 1AA",
            countryCode: "GB",
            defaultLatitude: 51.5,
            defaultLongitude: -0.12,
            companyLogoURL: "https://firebasestorage.googleapis.com/v0/b/x/o/logo.png?alt=media",
            documentAbbreviation: "RAC"
        )
        org.companyDetailsLoaded = true
        return org
    }

    func testCompanyDetailsCacheRoundTripKeepsEveryField() throws {
        let source = loadedOrganization()
        let document = try XCTUnwrap(source.companyDetailsCacheDocument)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(document))

        var stub = Organization(firestoreDocumentId: "org-1", name: "Raccord MEP")
        XCTAssertFalse(stub.companyDetailsLoaded)
        stub.applyCompanyDetailsCache(document)

        XCTAssertTrue(stub.companyDetailsLoaded)
        XCTAssertEqual(stub.documentAbbreviation, "RAC")
        XCTAssertEqual(stub.companyLogoURL, source.companyLogoURL)
        XCTAssertEqual(stub.officeAddressLine1, "1 High Street")
        XCTAssertEqual(stub.officeAddressLine2, "Unit 4")
        XCTAssertEqual(stub.officeCity, "London")
        XCTAssertEqual(stub.officeCounty, "Greater London")
        XCTAssertEqual(stub.officePostcode, "SW1A 1AA")
        XCTAssertEqual(stub.countryCode, "GB")
        XCTAssertEqual(stub.defaultLatitude ?? 0, 51.5, accuracy: 0.0001)
        XCTAssertEqual(stub.defaultLongitude ?? 0, -0.12, accuracy: 0.0001)
    }

    func testStubNeverProducesACacheDocument() {
        // A copy built from the cached name alone must never overwrite a good saved copy with blanks.
        let stub = Organization(firestoreDocumentId: "org-1", name: "Raccord MEP")
        XCTAssertNil(stub.companyDetailsCacheDocument)
    }

    func testServerDocumentMarksCompanyDetailsLoaded() {
        let org = Organization.make(
            fromFirestoreId: "org-1",
            data: ["name": "Raccord MEP", "documentAbbreviation": "RAC", "countryCode": "GB"],
            settings: OrganizationSettings()
        )
        XCTAssertTrue(org.companyDetailsLoaded)
        XCTAssertEqual(org.documentAbbreviation, "RAC")
    }

    // MARK: 3. Logo preview

    func testPDFLogoIsRecognisedFromItsPath() throws {
        let pdf = try XCTUnwrap(URL(string: "https://firebasestorage.googleapis.com/v0/b/x/o/organizations%2Fo%2Fbranding%2Fcompany_logo%2Fu_1.pdf?alt=media&token=t"))
        let png = try XCTUnwrap(URL(string: "https://firebasestorage.googleapis.com/v0/b/x/o/organizations%2Fo%2Fbranding%2Fcompany_logo%2Fu_1.png?alt=media"))
        XCTAssertTrue(CompanyLogoPreviewKind.isPDF(pdf))
        XCTAssertFalse(CompanyLogoPreviewKind.isPDF(png))
    }

    // MARK: 4. Warnings on a weak signal

    func testSavedResultsShowAfterTheWait() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(WarningsWeakSignal.shouldShowSaved(waitingSince: start, now: start.addingTimeInterval(9), hasCompletedLiveDetection: false))
        XCTAssertTrue(WarningsWeakSignal.shouldShowSaved(waitingSince: start, now: start.addingTimeInterval(10), hasCompletedLiveDetection: false))
        XCTAssertFalse(WarningsWeakSignal.shouldShowSaved(waitingSince: start, now: start.addingTimeInterval(60), hasCompletedLiveDetection: true))
    }

    func testSavedPhaseUntilTheLiveScanPublishes() {
        let savedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: false, incompleteDataMessage: nil, activeCount: 3, showingSavedResultsFrom: savedAt),
            .saved(activeCount: 3, savedAt: savedAt)
        )
        // The live scan wins.
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: true, incompleteDataMessage: nil, activeCount: 2, showingSavedResultsFrom: savedAt),
            .ready(activeCount: 2)
        )
        // Nothing saved: still loading.
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: false, incompleteDataMessage: nil, activeCount: 0),
            .loading
        )
    }

    func testWeakSignalNoteText() {
        XCTAssertEqual(
            WarningsWeakSignal.savedNote(lastUpdated: "Last updated 24 Nov 2026, 14:05"),
            "Weak signal — showing saved warnings. Last updated 24 Nov 2026, 14:05"
        )
        XCTAssertEqual(WarningsWeakSignal.savedNote(lastUpdated: nil), "Weak signal — showing saved warnings.")
    }

    /// Review of #284: saved rows are never shown as they were. With no window to rebuild against, rows dated
    /// before today go; undated rows (qualifications) and tomorrow's materials row stay.
    func testSavedRowsDropDaysBeforeTodayWithoutAWindow() {
        let cal = CanonicalBusinessEngine.businessCalendar
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        func row(_ key: String, _ type: Warning.WarningType, _ date: Date?) -> Warning {
            Warning(resolutionKey: key, type: type, title: "TEST", message: "TEST", severity: .high, occurrenceDate: date)
        }
        let rows = [
            row("old", .unbookedLabour, yesterday),
            row("today", .unbookedLabour, today),
            row("qual", .qualificationExpiry, yesterday),
            row("mat", .materialsCutoff, yesterday),
        ]
        let kept = WarningsService.savedRowsForCurrentWindow(rows, detection: nil, invoicing: nil, now: Date())
        XCTAssertEqual(kept.map(\.resolutionKey), ["today", "qual", "mat"])
    }

    /// A cache written before 24 Nov has no account on it and is never shown again.
    func testSavedCacheWithoutAnAccountDecodesWithNoUser() throws {
        let data = try JSONEncoder().encode(WarningsDiskCache.empty)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "userId")
        let decoded = try JSONDecoder().decode(
            WarningsDiskCache.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.userId)
    }

    // MARK: 5. Last active: newest heartbeat across the person's users documents

    func testNewestLastSeenAcrossThePersonsDocuments() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 5_000)
        let main = AppUser(id: "uid-main", email: "jo@example.test", organizationId: "org-1", role: .operative, lastSeenAt: older)
        let invite = AppUser(id: "6A9632BA-0000", email: "jo@example.test", organizationId: "org-1", role: .operative, lastSeenAt: newer)
        let other = AppUser(id: "uid-other", email: "sam@example.test", organizationId: "org-1", role: .operative,
                            lastSeenAt: Date(timeIntervalSince1970: 9_000))
        let newest = UserStore.newestLastSeenAt(
            personIds: ["uid-main", "6a9632ba-0000"],
            documents: [main, invite, other],
            fallback: main.lastSeenAt
        )
        XCTAssertEqual(newest, newer)
        XCTAssertNil(UserStore.newestLastSeenAt(personIds: ["nobody"], documents: [main], fallback: nil))
    }

    func testLastActiveIsShownInTheOrganisationZone() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-01T23:30:00Z"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(LastActiveText.format(instant, timeZone: london), "2 Jul 2026 at 00:30")
    }

    func testForegroundHeartbeatInterval() {
        XCTAssertEqual(LastSeenHeartbeat.intervalSeconds, 900)
    }

    // MARK: 7. Site map job summary only adds up the rulebook's per-booking answers

    func testSiteMapJobSummaryAddsUpPerBookingFigures() {
        let summary = SiteMapJobDaySummary.make(
            peopleOnSite: 3,
            results: [
                .init(totalPaidHours: 8, outsideHours: 0, outsideMultiplier: 1.5, multipliedClockHours: nil, multipliedBreakHours: nil),
                .init(totalPaidHours: 11, outsideHours: 3, outsideMultiplier: 1.5, multipliedClockHours: 2, multipliedBreakHours: 0),
            ],
            onLeaveNames: ["Jo Bloggs"]
        )
        XCTAssertEqual(summary.peopleOnSite, 3)
        XCTAssertEqual(summary.hours, 19, accuracy: 0.0001)
        XCTAssertEqual(summary.overtimeClockHours, 2, accuracy: 0.0001)
        XCTAssertEqual(summary.onLeaveCount, 1)
        XCTAssertTrue(summary.overtimeText.contains("2h"), summary.overtimeText)
    }

    func testSiteMapJobSummaryWithNoOvertime() {
        let summary = SiteMapJobDaySummary.make(
            peopleOnSite: 0,
            results: [],
            onLeaveNames: []
        )
        XCTAssertEqual(summary.overtimeText, "0h")
        XCTAssertEqual(summary.hours, 0)
    }
}
