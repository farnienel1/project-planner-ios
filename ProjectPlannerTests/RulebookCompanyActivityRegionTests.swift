import XCTest
@testable import Project_Planner

/// Rulebook 1.4.0 (§4.1, §4.4, §13): bank-holiday regions, the Company details region prompt, company activity
/// recipients and the push test, all read through `CanonicalBusinessEngine`.
@MainActor
final class RulebookCompanyActivityRegionTests: XCTestCase {
    // MARK: - Bank-holiday regions

    func testRegionListKeepsEveryStoredIosIdAndDecodesSubdivisions() throws {
        let all = CanonicalBusinessEngine.bankHolidayRegions()
        let ids = Set(all.map(\.id))
        // Every id the old iOS directory stored, except `AE` (United Arab Emirates), which the 1.4.0 list does not
        // carry (reported to web).
        for stored in ["GB-ENG-WLS", "GB-SCT", "GB-NIR", "GB", "IE", "US", "CA", "AU", "NZ", "FR", "DE", "ES", "IT", "NL", "SE", "NO", "DK", "PL"] {
            XCTAssertTrue(ids.contains(stored), stored)
        }
        let englandWales = try XCTUnwrap(all.first { $0.id == "GB-ENG-WLS" })
        XCTAssertEqual(englandWales.countryCode, "GB")
        XCTAssertEqual(englandWales.countyCodes, ["GB-ENG", "GB-WLS"])
        XCTAssertNil(try XCTUnwrap(all.first { $0.id == "IE" }).countyCodes)
    }

    func testRegionsForCountryAndDefaults() {
        XCTAssertEqual(
            CanonicalBusinessEngine.bankHolidayRegionsForCountry("GB").map(\.id),
            ["GB-ENG-WLS", "GB-SCT", "GB-NIR", "GB"]
        )
        XCTAssertEqual(CanonicalBusinessEngine.bankHolidayRegionsForCountry("FR").map(\.id), ["FR"])
        XCTAssertEqual(CanonicalBusinessEngine.defaultBankHolidayRegionForCountry("GB"), "GB-ENG-WLS")
        XCTAssertEqual(CanonicalBusinessEngine.defaultBankHolidayRegionForCountry("FR"), "FR")
        XCTAssertNil(CanonicalBusinessEngine.defaultBankHolidayRegionForCountry("XK"))
        XCTAssertEqual(CanonicalBusinessEngine.normalizeBankHolidayRegionId("gb-eng"), "GB-ENG-WLS")
        XCTAssertNil(CanonicalBusinessEngine.normalizeBankHolidayRegionId("ZZ"))
        XCTAssertEqual(CanonicalBusinessEngine.bankHolidayRegionLabel("GB-SCT"), "Scotland")
        XCTAssertEqual(CanonicalBusinessEngine.bankHolidayCountryTitle("GB"), "United Kingdom")
        XCTAssertTrue(CanonicalBusinessEngine.bankHolidayCountries().contains(BankHolidayCountry(code: "IE", title: "Ireland")))
    }

    // MARK: - Company details region prompt

    func testCountryChangeRequiresARegionFromTheNewCountry() {
        let prompt = CanonicalBusinessEngine.companyDetailsRegionPrompt(
            previousCountryCode: "GB",
            previousBankHolidayRegionId: "GB-SCT",
            countryCode: "FR"
        )
        XCTAssertTrue(prompt.required)
        XCTAssertEqual(prompt.choices.map(\.id), ["FR"])
        XCTAssertEqual(prompt.defaultRegionId, "FR")
        XCTAssertEqual(prompt.message, "Choose the bank holidays for France.")
        XCTAssertTrue(prompt.blocksSave(regionId: ""))
        XCTAssertTrue(prompt.blocksSave(regionId: "GB-SCT"))
        XCTAssertFalse(prompt.blocksSave(regionId: "FR"))

        let sameCountry = CanonicalBusinessEngine.companyDetailsRegionPrompt(
            previousCountryCode: "GB",
            previousBankHolidayRegionId: "GB-SCT",
            countryCode: "GB"
        )
        XCTAssertFalse(sameCountry.required)
        XCTAssertFalse(sameCountry.blocksSave(regionId: ""))

        // A country with no listed regions has nothing to choose.
        XCTAssertFalse(
            CanonicalBusinessEngine.companyDetailsRegionPrompt(
                previousCountryCode: "GB",
                previousBankHolidayRegionId: "GB-SCT",
                countryCode: "XK"
            ).required
        )
    }

    func testCompanyDetailsValidationAndWriteCarryTheRegion() throws {
        func input(country: String, region: String?) -> [String: Any] {
            CanonicalBusinessEngine.companyDetailsInput(
                name: "TEST-Company",
                hasOfficeAddress: false,
                officeAddressLine1: nil,
                officeAddressLine2: nil,
                officeCity: nil,
                officeCounty: nil,
                officePostcode: nil,
                countryCode: country,
                documentAbbreviation: nil,
                defaultLatitude: nil,
                defaultLongitude: nil,
                bankHolidayRegionId: region,
                previousCountryCode: "GB",
                previousBankHolidayRegionId: "GB-SCT"
            )
        }
        XCTAssertEqual(
            CanonicalBusinessEngine.companyDetailsValidationError(input(country: "FR", region: "GB-SCT")),
            "Choose the bank holidays for France."
        )
        XCTAssertNil(CanonicalBusinessEngine.companyDetailsValidationError(input(country: "FR", region: "FR")))

        let write = try XCTUnwrap(CanonicalBusinessEngine.companyDetailsWriteFields(input(country: "FR", region: "FR")))
        XCTAssertEqual(write.set["countryCode"] as? String, "FR")
        XCTAssertEqual(write.set["bankHolidayRegionId"] as? String, "FR")
        XCTAssertEqual(write.set["settings.bankHolidayRegionId"] as? String, "FR")

        // A new country with no listed region removes the old country's region.
        let unlisted = try XCTUnwrap(CanonicalBusinessEngine.companyDetailsWriteFields(input(country: "XK", region: nil)))
        XCTAssertTrue(unlisted.remove.contains("bankHolidayRegionId"))
        XCTAssertTrue(unlisted.remove.contains("settings.bankHolidayRegionId"))
    }

    // MARK: - Company activity and push test (§13)

    private func member(_ id: String, admin: Bool, superAdmin: Bool = false, manager: Bool = false,
                        operativeMode: Bool = false, active: Bool = true) -> [String: Any] {
        [
            "id": id,
            "email": "\(id.lowercased())@test.example",
            "isActive": active,
            "role": [
                "isSuperAdmin": superAdmin,
                "isAdmin": admin,
                "isManager": manager,
                "isOperativeMode": operativeMode,
            ],
            "isSuperAdmin": superAdmin,
            "adminAccess": admin,
            "manager": manager,
            "operativeMode": operativeMode,
            "formerUserIds": [String](),
            "sameEmailUserIds": [String](),
        ]
    }

    func testCompanyActivityGoesToActiveAdminsOnlyAndNeverTheActor() throws {
        let actor = member("ADMIN-A", admin: true)
        let roster = [
            actor,
            member("SUPER-B", admin: true, superAdmin: true),
            member("MANAGER-C", admin: false, manager: true),
            member("ADMIN-INACTIVE-D", admin: true, active: false),
            member("ADMIN-OPMODE-E", admin: true, operativeMode: true),
            member("OPERATIVE-F", admin: false, operativeMode: true),
        ]
        let recipients = try XCTUnwrap(CanonicalBusinessEngine.companyActivityRecipients(actor: actor, roster: roster))
        // RULEBOOK 1.11.0 §8 "Admin and operative mode": a stray operative-mode flag on an admin is ignored, so
        // ADMIN-OPMODE-E is an admin recipient (web canonical.test.ts "company activity" expects A2, A4).
        XCTAssertEqual(recipients, ["SUPER-B", "ADMIN-OPMODE-E"])
        XCTAssertFalse(recipients.contains("ADMIN-A"))

        // The actor by bare id is removed too.
        let byId = try XCTUnwrap(CanonicalBusinessEngine.companyActivityRecipients(actor: "SUPER-B", roster: roster))
        XCTAssertEqual(byId, ["ADMIN-A", "ADMIN-OPMODE-E"])

        XCTAssertEqual(
            CanonicalBusinessEngine.companyActivityNoticeTypes,
            ["operative_created", "manager_created", "client_created", "project_created", "small_works_created", "warning_removed"]
        )
        // Every company activity type is one the app decodes.
        for type in CanonicalBusinessEngine.companyActivityNoticeTypes {
            XCTAssertNotNil(AppNotification.NotificationType(rawValue: type), type)
        }
    }

    func testPushTestReachesItsSender() throws {
        XCTAssertEqual(CanonicalBusinessEngine.pushTestNoticeType, "push_test")
        XCTAssertEqual(AppNotification.NotificationType(rawValue: "push_test"), .pushTest)
        XCTAssertEqual(CanonicalBusinessEngine.pushTestRecipients(actor: "USER-1"), ["USER-1"])
        XCTAssertEqual(CanonicalBusinessEngine.pushTestRecipients(actor: member("USER-2", admin: false)), ["USER-2"])
        XCTAssertEqual(CanonicalBusinessEngine.notificationPushesToActor("push_test"), true)
        XCTAssertEqual(CanonicalBusinessEngine.notificationPushesToActor("task_created"), false)
    }

    func testRetiredCompanyTogglesStillParseAndCompanyActivityPatchIsDotted() throws {
        let parsed = try XCTUnwrap(
            CanonicalBusinessEngine.parseUserNotificationPreferences([
                "projectCreated": false,
                "companyActivity": false,
            ])
        )
        XCTAssertEqual(parsed["projectCreated"], false)
        XCTAssertEqual(parsed["companyActivity"], false)
        XCTAssertEqual(
            CanonicalBusinessEngine.userNotificationPreferenceFieldPatch(["companyActivity": false]),
            ["notificationPreferences.companyActivity": false]
        )
    }
}
