import XCTest
@testable import Project_Planner

/// RULEBOOK 1.52.0 §22 (variations) on iOS through `CanonicalBusinessEngine`: labour crews, numeric material
/// quantities, custom and subcontractor lines, totals, the workbook rows, the tracker plan and the evidence link.
/// Expected values checked in node against the packed script (rulebook 1.53.0, sha256 886912f4…84b38b2), the same
/// cases as web `lib/canonical/canonical.test.ts` and the 1.52.0 hand-off (item 8).
@MainActor
final class Rulebook1520Tests: XCTestCase {
    func testTotalsWithCustomAndSubcontractorLines() throws {
        let input: [String: Any] = [
            "labour": [["hours": 8, "operatives": 2, "hoursEach": 4], ["hours": 3]],
            "materials": [["quantity": "100m"], ["quantity": "1-"]],
            "customLines": [["quantity": 2, "cost": 12.5], ["quantity": 0, "cost": 10]],
            "subcontractorLines": [["quantity": 1.5, "cost": 100]],
            "evidence": [["storagePath": "p"], ["downloadURL": "u"], [:] as [String: Any]],
        ]
        let totals = try XCTUnwrap(CanonicalBusinessEngine.variationTotals(input))
        XCTAssertEqual(totals.labourHours, 11)
        XCTAssertEqual(totals.materialsCount, 2)
        XCTAssertEqual(totals.customTotal, 35)
        XCTAssertEqual(totals.subcontractorTotal, 150)
        XCTAssertEqual(totals.costTotal, 185)
        // A storage path or a URL counts (the reader's rule); the old iOS count needed a URL.
        XCTAssertEqual(totals.evidenceCount, 2)
        XCTAssertEqual(CanonicalBusinessEngine.variationLineTotal(quantity: "2,5", cost: "10"), 25)
    }

    func testLabourCrewAndMaterialQuantity() throws {
        let crew = try XCTUnwrap(CanonicalBusinessEngine.variationLabourLineFields(id: "L1", trade: "Joiner", operatives: 2, hoursEach: 4))
        XCTAssertEqual(crew["hours"] as? Double, 8)
        XCTAssertEqual(crew["operatives"] as? Int, 2)
        XCTAssertEqual(CanonicalBusinessEngine.variationLabourText(operatives: 2, hoursEach: 4, hours: 8), "2 × 4h = 8h")
        XCTAssertEqual(CanonicalBusinessEngine.variationLabourText(operatives: 1, hoursEach: 8, hours: 8), "8h")
        let material = try XCTUnwrap(CanonicalBusinessEngine.variationMaterialLineFields(id: "M1", name: "Pipe", quantity: 2.5, unit: "m"))
        XCTAssertEqual(material["quantity"] as? String, "2.5m")
        XCTAssertNotNil(CanonicalBusinessEngine.variationMaterialQuantityError("0"))
        XCTAssertNil(CanonicalBusinessEngine.variationMaterialQuantityError("2,5"))
        XCTAssertEqual(CanonicalBusinessEngine.variationMaterialUnits, ["no", "m", "box", "kg"])
    }

    /// The reader's crew and number for 1.52 lines; an untouched old line is written back exactly as stored.
    func testCodecKeepsOldLinesAndWritesNewShapes() throws {
        let data: [String: Any] = [
            "parentId": "J1",
            "voNumber": "VO-001",
            "labour": [
                ["id": "L-old", "trade": "Labourer", "hours": 8],
                ["id": "L-new", "trade": "Joiner", "hours": 8, "operatives": 2, "hoursEach": 4],
            ],
            "materials": [
                ["id": "M-old", "name": "Bracket", "quantity": "1-"],
                ["id": "M-new", "name": "Pipe", "quantity": "100m", "quantityValue": 100, "unit": "m"],
            ],
            "customLines": [["id": "C1", "name": "Skip", "description": "8yd", "quantity": 1, "cost": 250]],
            "subcontractorLines": [["id": "S1", "subcontractorId": "F1", "name": "Sparks Ltd", "quoteNumber": "Q1", "quantity": 2, "cost": 100]],
        ]
        let variation = try XCTUnwrap(VariationCodec.variation(from: data, documentId: "V1"))
        XCTAssertEqual(variation.labour.map(\.operatives), [1, 2])
        XCTAssertEqual(variation.labour.map(\.hoursEach), [8, 4])
        XCTAssertEqual(variation.labour.map(\.legacyShape), [true, false])
        XCTAssertEqual(variation.materials.map(\.quantityValue), [nil, 100])
        XCTAssertEqual(variation.materials.map(\.legacyShape), [true, false])
        XCTAssertEqual(variation.customLines.first?.cost, 250)
        XCTAssertEqual(variation.subcontractorLines.first?.quoteNumber, "Q1")
        XCTAssertEqual(variation.totals?.costTotal, 450)

        let map = try VariationCodec.firestoreMap(from: variation)
        let labour = try XCTUnwrap(map["labour"] as? [[String: Any]])
        XCTAssertEqual(Set(labour[0].keys), ["id", "trade", "hours"])
        XCTAssertEqual(labour[1]["operatives"] as? Int, 2)
        let materials = try XCTUnwrap(map["materials"] as? [[String: Any]])
        XCTAssertEqual(Set(materials[0].keys), ["id", "name", "quantity"])
        XCTAssertEqual(materials[0]["quantity"] as? String, "1-")
        XCTAssertEqual(materials[1]["unit"] as? String, "m")
        XCTAssertEqual((map["customLines"] as? [[String: Any]])?.first?["cost"] as? Double, 250)
        XCTAssertEqual((map["subcontractorLines"] as? [[String: Any]])?.first?["name"] as? String, "Sparks Ltd")
    }

    /// Hand-off item 8: a deleted VO-004 keeps its number reserved and a submitted VO-002 its place.
    func testRenumberPlanPinsSubmittedAndReservesDeleted() throws {
        let rows: [[String: Any]] = [
            ["id": "a", "voNumber": "VO-001", "status": "open", "sequence": 1],
            ["id": "b", "voNumber": "VO-002", "status": "submitted", "sequence": 2],
            ["id": "c", "voNumber": "VO-003", "status": "open", "sequence": 3],
            ["id": "d", "voNumber": "VO-004", "status": "open", "isDeleted": true, "sequence": 4],
            ["id": "e", "voNumber": "VO-005", "status": "open", "sequence": 5],
        ]
        let plan = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlan(rows: rows, order: ["e", "a", "c"], prefix: "VO-", padding: 3, orderLocked: false))
        XCTAssertEqual(plan.rows.map(\.id), ["e", "b", "a", "c"])
        XCTAssertEqual(plan.rows.map(\.to), ["VO-001", "VO-002", "VO-003", "VO-005"])
        XCTAssertEqual(plan.rows.map(\.pinned), [false, true, false, false])
        XCTAssertNil(plan.refused)
        let locked = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlan(rows: rows, prefix: "VO-", padding: 3, orderLocked: true))
        XCTAssertEqual(locked.refused, CanonicalBusinessEngine.variationOrderLockedMessage)
        XCTAssertTrue(CanonicalBusinessEngine.variationIsPinned(status: "closed", voNumberLocked: false))
        XCTAssertFalse(CanonicalBusinessEngine.variationIsPinned(status: "open", voNumberLocked: true), "rulebook 1.63.0: an Open variation is never pinned by a stale lock")
    }

    func testExportRowsAndWorkbookParts() throws {
        let variations: [[String: Any]] = [
            [
                "voNumber": "VO-002", "heading": "B", "status": "open", "createdAtMs": 1_794_736_800_000.0,
                "labour": [["trade": "Joiner", "hours": 8, "operatives": 2, "hoursEach": 4]],
                "materials": [["name": "Pipe", "quantity": "100m"]],
                "customLines": [["name": "Skip", "description": "8yd", "quantity": 1, "cost": 250]],
                "subcontractorLines": [["name": "Sparks Ltd", "quoteNumber": "Q1", "quantity": 2, "cost": 100]],
                "evidence": [["storagePath": "x"]],
            ],
            ["voNumber": "VO-001", "heading": "A", "status": "closed", "createdAtMs": 0],
            ["voNumber": "VO-003", "isDeleted": true],
        ]
        let rows = try XCTUnwrap(CanonicalBusinessEngine.variationExportRows(variations, timeZone: "Europe/London", currency: "GBP", includeCost: true))
        XCTAssertEqual(rows.summaryRows.count, 2)
        XCTAssertEqual(rows.lineRows.count, 4)
        XCTAssertEqual(rows.summaryRows.map { $0["voNumber"] ?? .empty }, [.text("VO-001"), .text("VO-002")])
        XCTAssertEqual(rows.summaryTotals["totalCost"] ?? .empty, .number(450))
        XCTAssertEqual(rows.lineRows.map { $0["type"] ?? .empty }, [.text("Labour"), .text("Material"), .text("Custom"), .text("Subcontractor")])
        XCTAssertEqual(rows.lineRows[1]["quantity"] ?? .empty, .number(100))
        XCTAssertEqual(rows.lineRows[1]["unit"] ?? .empty, .text("m"))
        XCTAssertEqual(rows.costKeys, ["customTotal", "subcontractorTotal", "totalCost", "cost", "lineTotal"])
        XCTAssertEqual(CanonicalBusinessEngine.variationExportFileName(jobNumber: "C 646/A"), "C-646-A-variations.xlsx")

        let hidden = try XCTUnwrap(CanonicalBusinessEngine.variationExportRows(
            [["voNumber": "VO-1", "customLines": [["name": "S", "quantity": 1, "cost": 5]]]],
            timeZone: "Europe/London", currency: "GBP", includeCost: false
        ))
        XCTAssertEqual(hidden.summaryTotals["totalCost"] ?? .text("missing"), .empty)

        // The workbook: two sheets, the logo as a drawing part, money columns only when costs are shown.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 120, 0, 0, 0, 40, 8, 6, 0, 0, 0])
        let logo = try XCTUnwrap(VariationWorkbookBuilder.logo(from: png))
        XCTAssertEqual([logo.type, String(logo.width), String(logo.height)], ["png", "120", "40"])
        let input = VariationWorkbookBuilder.Input(
            variations: variations, companyName: "Acme", jobNumber: "C646", jobName: "Carnaby",
            generatedBy: "Sam", timeZone: "Europe/London", currency: "GBP", includeCost: true, logoURL: nil
        )
        let entries = VariationWorkbookBuilder.workbookEntries(rows: rows, input: input, generatedAt: "15 Nov 2026, 14:05", logo: logo)
        for part in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/drawings/drawing1.xml",
                     "xl/drawings/_rels/drawing1.xml.rels", "xl/worksheets/_rels/sheet1.xml.rels", "xl/media/image1.png", "xl/styles.xml"] {
            XCTAssertNotNil(entries[part], part)
        }
        let sheet1 = String(decoding: try XCTUnwrap(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        XCTAssertTrue(sheet1.contains("<drawing r:id=\"rId1\"/>"))
        XCTAssertTrue(sheet1.contains("Total cost"))
        let workbook = String(decoding: try XCTUnwrap(entries["xl/workbook.xml"]), as: UTF8.self)
        XCTAssertTrue(workbook.contains("name=\"Variations\"") && workbook.contains("name=\"Line items\""))
        let noCost = VariationWorkbookBuilder.workbookEntries(rows: hidden, input: input, generatedAt: "", logo: nil)
        XCTAssertNil(noCost["xl/drawings/drawing1.xml"])
        XCTAssertFalse(String(decoding: try XCTUnwrap(noCost["xl/worksheets/sheet1.xml"]), as: UTF8.self).contains("Total cost"))
    }

    func testEvidenceLinkKeepsAlreadyLinkedFiles() throws {
        let result = try XCTUnwrap(CanonicalBusinessEngine.variationEvidenceAddWriteFields(
            stored: ["evidence": [["id": "E1", "storagePath": "a"]]],
            entries: [["id": "e1", "storagePath": "z"], ["id": "N", "storagePath": "b"]]
        ))
        XCTAssertEqual(result.added, ["b"])
        XCTAssertEqual(result.alreadyLinked, ["z"])
        XCTAssertEqual(result.refused, [])
        XCTAssertEqual(result.set?["evidenceCount"] as? Int, 2)
        XCTAssertEqual(CanonicalBusinessEngine.variationEvidenceKeys(stored: ["evidence": [["id": "E1", "storagePath": "a"], ["id": "E2"]]]), ["a", "E2"])
    }

    func testListTextAndCosts() {
        // 23:30 UTC on 15 Nov is 16 Nov in Auckland: the organisation zone, never the device.
        let date = Date(timeIntervalSince1970: 1_794_785_400)
        XCTAssertEqual(CanonicalBusinessEngine.variationDateText(date, timeZone: "Pacific/Auckland"), "16 Nov 2026")
        XCTAssertEqual(CanonicalBusinessEngine.variationPreviousNumbers(voNumber: "VO-006", history: ["VO-003", "vo-006", "VO-005"]), ["VO-003", "VO-005"])
        XCTAssertTrue(CanonicalBusinessEngine.canSeeVariationCosts(.init(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false)))
        XCTAssertFalse(CanonicalBusinessEngine.canSeeVariationCosts(.init(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: true)))
    }
}
