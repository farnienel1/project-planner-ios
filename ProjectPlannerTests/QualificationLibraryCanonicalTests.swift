import XCTest
@testable import Project_Planner

@MainActor
final class QualificationLibraryCanonicalTests: XCTestCase {
    func testSearchRanksByCodeAndKeepsSectionChips() {
        XCTAssertEqual(CanonicalBusinessEngine.tokenizeQualificationSearch("ECS Gold"), ["ecs", "gold"])
        let gold = CanonicalBusinessEngine.CanonicalQualificationSearchRecord(
            name: "ECS Installation Electrician (Gold Card)",
            code: "EL-ECS-IE",
            awardingBody: "ECS / JIB",
            section: "Electrical",
            subsection: "ECS Cards & JIB Grades"
        )
        let ccn1 = CanonicalBusinessEngine.CanonicalQualificationSearchRecord(
            name: "CCN1 Core Domestic Gas Safety (includes CPA1)",
            code: "GAS-CCN1",
            awardingBody: "ACS",
            section: "Gas"
        )
        let custom = CanonicalBusinessEngine.CanonicalQualificationSearchRecord(name: "Site induction")
        XCTAssertGreaterThan(CanonicalBusinessEngine.qualificationSearchScore(query: "ecs gold", record: gold), 0)
        XCTAssertEqual(CanonicalBusinessEngine.qualificationSearchScore(query: "ecs gold", record: ccn1), 0)
        XCTAssertGreaterThan(CanonicalBusinessEngine.qualificationSearchScore(query: "GAS-CCN1", record: ccn1), 0)

        let ranked = CanonicalBusinessEngine.rankQualificationRecords(query: "ccn1", records: [gold, ccn1, custom])
        XCTAssertEqual(ranked?.map(\.index), [1])
        let electrical = CanonicalBusinessEngine.rankQualificationRecords(
            query: "ecs",
            records: [gold, ccn1],
            section: "Electrical"
        )
        XCTAssertEqual(electrical?.map(\.index), [0])
        let allHits = CanonicalBusinessEngine.rankQualificationRecords(
            query: "",
            records: [gold, ccn1, custom],
            section: CanonicalBusinessEngine.qualificationFilterAll
        )
        XCTAssertEqual(allHits?.map(\.index), [0, 1, 2])
        XCTAssertTrue(CanonicalBusinessEngine.qualificationMatchesSection(section: "", wanted: "Other"))
        XCTAssertFalse(CanonicalBusinessEngine.qualificationMatchesSection(section: "Electrical", wanted: "Gas"))

        let chips = CanonicalBusinessEngine.qualificationLibraryFilterChips([gold, ccn1, custom])
        XCTAssertEqual(chips?.first?.key, CanonicalBusinessEngine.qualificationFilterAll)
        XCTAssertEqual(chips?.first?.count, 3)
        XCTAssertEqual(chips?.dropFirst().map(\.key), ["Electrical", "Gas", "Other"])
        XCTAssertEqual(
            CanonicalBusinessEngine.qualificationSectionChipLabel("Air Conditioning, Refrigeration & F-Gas"),
            "Air Con & F-Gas"
        )
    }

    func testStarterLibraryHas272CodedRows() throws {
        let rows = StarterQualificationLibrary.rows()
        XCTAssertEqual(rows.count, 272)
        XCTAssertEqual(rows.first?.code, "EL-ECS-IE")
        XCTAssertEqual(Set(rows.map(\.code)).count, 272)
        let items = StarterQualificationLibrary.qualifications(createdAt: Date(timeIntervalSince1970: 0))
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.id, "EL-ECS-IE")
        XCTAssertEqual(first.hasEndDate, false)
        let fields = FirebaseBackend.qualificationTemplateFirestoreFields(first)
        XCTAssertEqual(fields["name"] as? String, first.name)
        XCTAssertEqual(fields["hasEndDate"] as? Bool, false)
        XCTAssertEqual(fields["code"] as? String, "EL-ECS-IE")
        XCTAssertEqual(fields["section"] as? String, "Electrical")
        XCTAssertNotNil(fields["createdAt"])
        XCTAssertNotNil(fields["updatedAt"])
    }

    func testPackedScriptExportsQualificationSearch() {
        XCTAssertEqual(
            CanonicalBusinessEngine.exportKind("rankQualificationRecords"),
            "function"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.exportKind("qualificationLibraryFilterChips"),
            "function"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.exportKind("missingStarterQualificationCodes"),
            "function"
        )
    }

    func testACustomRowDoesNotBlockMissingLibraryCodes() {
        let library = ["EL-ECS-IE", "GAS-GSR", "PRO-IOSH"]
        XCTAssertEqual(CanonicalBusinessEngine.starterCollectionShouldSeed(existingDocumentCount: 0), true as Bool?)
        XCTAssertEqual(CanonicalBusinessEngine.starterCollectionShouldSeed(existingDocumentCount: 1), false as Bool?)
        XCTAssertEqual(
            CanonicalBusinessEngine.missingStarterQualificationCodes(existingDocumentIds: [], libraryCodes: library),
            library as [String]?
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.missingStarterQualificationCodes(
                existingDocumentIds: ["custom-uuid"],
                libraryCodes: library
            ),
            library as [String]?
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.missingStarterQualificationCodes(
                existingDocumentIds: ["EL-ECS-IE", "custom-uuid"],
                libraryCodes: library
            ),
            ["GAS-GSR", "PRO-IOSH"] as [String]?
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.missingStarterQualificationCodes(
                existingDocumentIds: library,
                libraryCodes: library
            ),
            [] as [String]?
        )
    }
}
