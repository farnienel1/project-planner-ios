import XCTest
import CoreLocation
@testable import Project_Planner

/// Owner 24 Nov: the iPhone site map places and shows jobs exactly as web PR #440 (`lib/maps/siteMapPlacement.ts`).
final class SiteMapPlacementTests: XCTestCase {
    private func place(
        latitude: Double? = nil,
        longitude: Double? = nil,
        line1: String = "",
        postcode: String = "",
        address: String = "",
        lookups: [String: PostcodeLookupAnswer] = [:]
    ) -> SiteMapPlacement? {
        SiteMapPlacementRules.placement(
            latitude: latitude, longitude: longitude, addressLine1: line1,
            postcodeField: postcode, formattedAddress: address, lookups: lookups
        )
    }

    func testSavedPinWinsOverEverything() {
        let result = place(latitude: 51.5, longitude: -0.12, line1: "52.1, -1.2", postcode: "SW1X 9HR",
                           lookups: ["SW1X 9HR": .found(latitude: 1, longitude: 1)])
        XCTAssertEqual(result, .stored(CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)))
    }

    func testLatLngAddressTextIsSecond() {
        XCTAssertEqual(place(line1: "51.51278, -0.13805", postcode: "SW1X 9HR"),
                       .addressCoordinates(CLLocationCoordinate2D(latitude: 51.51278, longitude: -0.13805)))
        // No decimal point: not a coordinate pair (web).
        XCTAssertNil(SiteMapPlacementRules.coordinatesFromText("12, 14"))
    }

    func testPostcodeIsThirdAndReadInAnyForm() {
        let lookups: [String: PostcodeLookupAnswer] = ["SW1X 9HR": .found(latitude: 51.49, longitude: -0.15)]
        XCTAssertEqual(place(postcode: "Sw1\u{00D7} 9Hr", address: "1 High St, Sw1× 9Hr", lookups: lookups),
                       .postcode(CLLocationCoordinate2D(latitude: 51.49, longitude: -0.15), postcode: "SW1X 9HR"))
        XCTAssertEqual(place(postcode: "SW1 X9HR", lookups: lookups),
                       .postcode(CLLocationCoordinate2D(latitude: 51.49, longitude: -0.15), postcode: "SW1X 9HR"))
        XCTAssertEqual(SiteMapPlacementRules.postcode(field: "", addressTexts: ["1 High St, London ec4m 7ju"]), "EC4M 7JU")
    }

    func testPendingNotFoundFailedAndNoAddress() {
        XCTAssertNil(place(postcode: "SW1X 9HR"))
        XCTAssertEqual(place(postcode: "SW1X 9HR", lookups: ["SW1X 9HR": .notFound]), .postcodeNotFound(postcode: "SW1X 9HR"))
        XCTAssertEqual(place(postcode: "SW1X 9HR", lookups: ["SW1X 9HR": .failed]), .lookupFailed(postcode: "SW1X 9HR"))
        XCTAssertEqual(place(address: "Unit 4, Somewhere"), .noPostcode)
        XCTAssertEqual(place(), .noAddress)
        XCTAssertEqual(SiteMapPlacement.noAddress.unplacedReason, "No address")
        XCTAssertEqual(SiteMapPlacement.postcodeNotFound(postcode: "SW1X 9HR").unplacedReason, "Postcode SW1X 9HR not found")
    }

    func testWhichJobsShow() {
        XCTAssertTrue(SiteMapPlacementRules.jobShown(isLive: true, tab: "active", includeCompleted: false, bookedThatDay: false))
        XCTAssertTrue(SiteMapPlacementRules.jobShown(isLive: true, tab: "upcoming", includeCompleted: false, bookedThatDay: false))
        XCTAssertFalse(SiteMapPlacementRules.jobShown(isLive: true, tab: "completed", includeCompleted: false, bookedThatDay: false))
        XCTAssertTrue(SiteMapPlacementRules.jobShown(isLive: true, tab: "completed", includeCompleted: true, bookedThatDay: false))
        XCTAssertTrue(SiteMapPlacementRules.jobShown(isLive: true, tab: "completed", includeCompleted: false, bookedThatDay: true))
        XCTAssertFalse(SiteMapPlacementRules.jobShown(isLive: false, tab: "active", includeCompleted: true, bookedThatDay: true))
    }

    func testUnplacedTextMatchesWeb() {
        XCTAssertNil(SiteMapPlacementRules.unplacedText(count: 0, lookupFailedCount: 0))
        XCTAssertEqual(SiteMapPlacementRules.unplacedText(count: 1, lookupFailedCount: 0), "1 job could not be placed on the map.")
        XCTAssertEqual(SiteMapPlacementRules.unplacedText(count: 2, lookupFailedCount: 1),
                       "2 jobs could not be placed on the map. 1 job is waiting for the postcode lookup — retry.")
    }

    func testParsesPostcodesIoBulk() throws {
        let json = #"{"status":200,"result":[{"query":"sw1x9hr","result":{"latitude":51.49,"longitude":-0.15}},{"query":"ZZ1 1ZZ","result":null}]}"#
        let parsed = try XCTUnwrap(SiteMapPlacementRules.parsePostcodesIoBulk(Data(json.utf8)))
        XCTAssertEqual(parsed["SW1X 9HR"], .found(latitude: 51.49, longitude: -0.15))
        XCTAssertEqual(parsed["ZZ1 1ZZ"], .notFound)
    }
}
