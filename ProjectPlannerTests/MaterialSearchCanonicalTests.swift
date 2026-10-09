import XCTest
@testable import Project_Planner

@MainActor
final class MaterialSearchCanonicalTests: XCTestCase {
    func testScriptExportsMaterialSearch() {
        let names = [
            "tokenizeMaterialSearch",
            "materialSearchScore",
            "rankMaterialRecords",
            "materialRecordMatches",
            "normalizeMaterialSearchText",
            "catalogueRecordFromItem",
        ]
        for name in names {
            let kind = CanonicalBusinessEngine.exportKind(name)
            XCTAssertEqual(kind, "function", name)
        }
    }

    func testTwoPointFiveMillimetreLSFindsTheTwinAndEarthDrum() {
        let thinner = CanonicalBusinessEngine.CanonicalMaterialRecord(
            name: "1.5mm2 Twin & Earth Cable"
        )
        let screw = CanonicalBusinessEngine.CanonicalMaterialRecord(name: "Coach screw")
        let drum = CanonicalBusinessEngine.CanonicalMaterialRecord(
            name: "2.5mm2 Twin & Earth Cable 6242B LSZH (100m Drum)",
            productCode: "6242B",
            size: "2.5mm2",
            length: "100m"
        )
        let records = [thinner, screw, drum]
        let hits = CanonicalBusinessEngine.rankMaterialRecords(query: "2.5mm LS", records: records)
        XCTAssertEqual(hits?.map(\.index), [2])
        XCTAssertGreaterThan(hits?.first?.score ?? 0, 0)
        XCTAssertTrue(CanonicalBusinessEngine.materialRecordMatches(query: "2.5mm LS", record: drum))
        XCTAssertFalse(CanonicalBusinessEngine.materialRecordMatches(query: "2.5mm LS", record: thinner))
        XCTAssertFalse(CanonicalBusinessEngine.materialRecordMatches(query: "2.5mm LS", record: screw))
    }

    func testDrumRanksAboveAMatchingSmallerCable() {
        let smaller = CanonicalBusinessEngine.CanonicalMaterialRecord(
            name: "1.5mm2 LSZH flex"
        )
        let drum = CanonicalBusinessEngine.CanonicalMaterialRecord(
            name: "2.5mm2 Twin & Earth Cable 6242B LSZH (100m Drum)"
        )
        let hits = CanonicalBusinessEngine.rankMaterialRecords(
            query: "2.5mm LS",
            records: [smaller, drum]
        )
        XCTAssertEqual(hits?.first?.index, 1)
    }

    func testSpacedMeasureIsOneToken() {
        XCTAssertEqual(CanonicalBusinessEngine.tokenizeMaterialSearch("2.5 mm"), ["2.5mm"])
    }

    func testEmptyQueryKeepsOriginalOrder() {
        let records = [
            CanonicalBusinessEngine.CanonicalMaterialRecord(name: "B"),
            CanonicalBusinessEngine.CanonicalMaterialRecord(name: "A"),
        ]
        let hits = CanonicalBusinessEngine.rankMaterialRecords(query: "", records: records)
        XCTAssertEqual(hits?.map(\.index), [0, 1])
    }
}
