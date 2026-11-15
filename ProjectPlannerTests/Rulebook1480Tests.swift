import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.48.0 §28 (owner decisions 15 Nov 1–5): one materials quantity model (order unit + what is in one), one
/// wording (`materialLineText`), one catalogue CSV rule and its upload checks — all through `CanonicalBusinessEngine`.
/// Expected values were checked in node against the packed `canonical-business.js` this branch mirrors (web
/// `lib/canonical/materialQuantity.test.ts`).
@MainActor
final class Rulebook1480Tests: XCTestCase {
    private let org = "TEST-org-148"
    private let projectId = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 148"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func line(_ quantity: Double, _ orderUnit: String, _ amount: Double? = nil, _ measure: String? = nil) -> MaterialItem {
        MaterialItem(
            quantity: quantity,
            unit: .number,
            orderUnit: orderUnit,
            contentAmount: amount,
            contentMeasure: measure,
            material: "TEST-Cable",
            addedBy: "TEST-User",
            projectId: projectId,
            date: Date(timeIntervalSince1970: 1_794_960_000)
        )
    }

    // MARK: One wording

    func testTheOwnersLinesReadInTradeStyle() {
        XCTAssertEqual(line(2, "Drum", 50, "m").quantityText, "2no 50m drums")
        XCTAssertEqual(line(1, "Drum", 50, "m").quantityText, "1no 50m drum")
        XCTAssertEqual(line(10, "Length", 3, "m").quantityText, "10no 3m lengths")
        XCTAssertEqual(line(100, "Metre").quantityText, "100m")
        XCTAssertEqual(line(12.5, "Metre").quantityText, "12.5m")
        XCTAssertEqual(line(4, "Each").quantityText, "4no")
        XCTAssertEqual(line(2, "Box", 100, "m").quantityText, "2no 100m boxes")
        XCTAssertEqual(line(6, "Length", 2.4, "m").quantityText, "6no 2.4m lengths")
    }

    func testTheCatalogueRowSaysWhatIsInOne() {
        let item = MaterialCatalogItem(
            name: "TEST-Flex", brand: "TEST-Brand", defaultUnit: .drum,
            orderUnit: "Drum", contentAmount: 50, contentMeasure: "m",
            size: "1.0", createdByUserId: "u", createdByName: "TEST-Admin"
        )
        XCTAssertEqual(item.orderUnitSummary, "Drum · 50m in one")
        XCTAssertEqual(item.sizeDisplay, "", "the 1.0 placeholder is hidden (materialSizeText)")
    }

    // MARK: Readers

    func testAStoredLengthOfOneMetreReadsMetreAndSavesBackUnchanged() throws {
        let stored: [String: Any] = [
            "projectId": projectId.uuidString, "quantity": 100, "unit": "Length", "length": "1", "sizeOrLength": "1",
            "lengthUnit": "M", "material": "TEST-Flex", "addedBy": "TEST-User", "dayKey": "2026-11-18",
        ]
        let item = try XCTUnwrap(FirebaseBackend.materialItem(documentId: "TEST-line-1", data: stored))
        XCTAssertEqual(item.orderUnit, "Metre")
        XCTAssertEqual(item.quantityText, "100m")
        let payload = try XCTUnwrap(FirebaseBackend.materialLinePayload(item, addedByUserId: nil))
        XCTAssertEqual(payload["orderUnit"] as? String, "Metre")
        XCTAssertEqual(payload["unit"] as? String, "Length")
        XCTAssertEqual(payload["length"] as? String, "1")
        XCTAssertEqual(payload["lengthUnit"] as? String, "M")
        // Saving the same meaning back keeps the older document's stored quantity fields (no rewrite).
        let write = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite("materialLineWriteFields", before: stored, next: payload))
        for key in ["orderUnit", "contentAmount", "contentMeasure", "unit", "length", "lengthUnit"] {
            XCTAssertFalse(write.setKeys.contains(key), key)
        }
    }

    func testAMetreQuantityOf12Point5RoundTripsWithoutRounding() throws {
        let item = try XCTUnwrap(FirebaseBackend.materialItem(documentId: "TEST-line-2", data: [
            "projectId": projectId.uuidString, "quantity": 12.5, "orderUnit": "Metre", "unit": "Length", "length": "1",
            "lengthUnit": "M", "material": "TEST-Flex", "addedBy": "TEST-User", "dayKey": "2026-11-18",
        ]))
        XCTAssertEqual(item.quantity, 12.5)
        XCTAssertEqual(item.quantityText, "12.5m")
        let payload = try XCTUnwrap(FirebaseBackend.materialLinePayload(item, addedByUserId: nil))
        XCTAssertEqual((payload["quantity"] as? NSNumber)?.doubleValue, 12.5)
    }

    func testAReelLineSavesDrumForOlderBuildsAndReelAsTheOrderUnit() throws {
        let payload = try XCTUnwrap(FirebaseBackend.materialLinePayload(line(3, "Reel", 100, "m"), addedByUserId: nil))
        XCTAssertEqual(payload["orderUnit"] as? String, "Reel")
        XCTAssertEqual(payload["unit"] as? String, "Drum")
        XCTAssertEqual((payload["contentAmount"] as? NSNumber)?.doubleValue, 100)
        XCTAssertEqual(payload["contentMeasure"] as? String, "m")
        XCTAssertEqual(payload["length"] as? String, "100")
        XCTAssertEqual(payload["lengthUnit"] as? String, "M")
    }

    func testAStaleOrderUnitAfterAnOldStyleEditReadsTheOldFields() throws {
        // An older build changed the unit to Box and left orderUnit Drum behind: the old fields win.
        let item = try XCTUnwrap(FirebaseBackend.materialItem(documentId: "TEST-line-3", data: [
            "projectId": projectId.uuidString, "quantity": 2, "orderUnit": "Drum", "contentAmount": 50, "contentMeasure": "m",
            "unit": "Box", "length": "50", "lengthUnit": "M", "material": "TEST-Cable", "addedBy": "TEST-User",
            "dayKey": "2026-11-18",
        ]))
        XCTAssertEqual(item.orderUnit, "Box")
        XCTAssertEqual(item.quantityText, "2no 50m boxes")
    }

    func testAMaterialLineCachedBefore148StillDecodes() throws {
        let cached = """
        {"id":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1","quantity":4,"unit":"Length","material":"TEST-Trunking",
         "addedBy":"TEST-User","addedAt":0,"projectId":"99999999-8888-4777-8666-555555555555","date":0,
         "status":"draft","length":"3","lengthUnit":"M"}
        """
        let item = try JSONDecoder().decode(MaterialItem.self, from: Data(cached.utf8))
        XCTAssertEqual(item.quantity, 4)
        XCTAssertNil(item.orderUnit)
        XCTAssertEqual(item.effectiveQuantityModel.orderUnit, "Length")
        XCTAssertEqual(item.quantityText, "4no 3m lengths")
    }

    // MARK: Quantity checks

    func testOnlyMetreTakesDecimalsAndOnlyAChangedQuantityIsChecked() {
        var draft = MaterialQuantityDraft(quantity: 2, model: MaterialQuantityModel(orderUnit: "Each", contentAmount: nil, contentMeasure: nil))
        draft.quantityText = "2.5"
        XCTAssertEqual(draft.validationError(comparedWith: nil), CanonicalBusinessEngine.constant("MATERIAL_QUANTITY_WHOLE_MESSAGE", as: String.self))
        draft.orderUnit = "Metre"
        draft.fitMeasureToUnit()
        XCTAssertNil(draft.validationError(comparedWith: nil))
        // An older line of 2.5 boxes still saves a notes change: nothing about the quantity changed.
        let older = MaterialQuantityDraft(quantity: 2.5, model: MaterialQuantityModel(orderUnit: "Box", contentAmount: nil, contentMeasure: nil))
        XCTAssertNil(older.validationError(comparedWith: older))
    }

    // MARK: Send records

    func testASendRecordStoresTheTextItWasSentWith() throws {
        let record = MaterialSendRecord(
            projectId: projectId,
            requestType: .order,
            sentBy: "TEST-User",
            recipients: [],
            lines: [line(2, "Drum", 50, "m").sendLineSnapshot]
        )
        let payload = try XCTUnwrap(FirebaseBackend.materialSendRecordPayload(record))
        let lines = try XCTUnwrap(payload["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.first?["quantityText"] as? String, "2no 50m drums")
    }

    func testAnOldSendRecordShowsTheOldWording() {
        let old = MaterialSendLineSnapshot(
            materialId: UUID(), name: "TEST-Cable", quantity: 2, unit: .drum, brand: nil, productCode: nil, lengthDisplay: "50 m"
        )
        XCTAssertEqual(old.historyText, "2 Drums · Length: 50 m")
        var new = old
        new.quantityText = "2no 50m drums"
        XCTAssertEqual(new.historyText, "2no 50m drums")
    }

    /// A payload that carries the new fields and old ones sends old fields that agree with the order unit
    /// (`materialQuantityWriteFields`): otherwise the reader takes it for an older build's edit and the old fields win.
    func testEmailLinesSendTheOldUnitThatGoesWithTheOrderUnit() throws {
        var reel = line(3, "Reel", 100, "m")
        reel.unit = .number // a new line's in-app old unit before it is read back
        let sent = try XCTUnwrap(MaterialRequestEmailPayload.materialLines([reel]).first)
        XCTAssertEqual(sent["orderUnit"] as? String, "Reel")
        XCTAssertEqual(sent["unit"] as? String, "Drum")
        XCTAssertEqual(CanonicalBusinessEngine.materialLineText(sent), "3no 100m reels")
        // Applying the picker writes the old fields the rulebook writes, so the in-app copy agrees too.
        var item = line(1, "Each")
        MaterialQuantityDraft(quantity: 3, model: MaterialQuantityModel(orderUnit: "Reel", contentAmount: 100, contentMeasure: "m")).apply(to: &item)
        XCTAssertEqual(item.unit, .drum)
        XCTAssertEqual(item.length, "100")
        XCTAssertEqual(item.lengthUnit, .metres)
    }

    // MARK: Catalogue CSV

    func testAnOldLayoutCsvStillImports() throws {
        let csv = """
        Catalogue ID,Name,Category,Manufacturer/Brand,Product Code,Default Type (Length Drum Box Pallet or Number),Size,Length,Length Unit (M or MM)
        ,TEST-Flex,Cable,TEST-Brand,P1,Length,,1,M
        ,TEST-Trunking,Containment,TEST-Brand,T1,Length,,3,M

        """
        let parsed = try MaterialCatalogCSV.parse(data: Data(csv.utf8), fileName: "catalogue.csv")
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.rows.map(\.orderUnit), ["Metre", "Length"])
        XCTAssertEqual(parsed.rows.last?.contentAmount, 3)
        XCTAssertEqual(parsed.rows.last?.contentMeasure, "m")
        XCTAssertEqual(parsed.rows.first?.defaultUnit, .length)
    }

    func testAnXlsxRenamedOrTooBigOrNotUtf8FileIsRefused() {
        func message(_ data: Data, _ name: String) -> String? {
            do {
                _ = try MaterialCatalogCSV.parse(data: data, fileName: name)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        // An Excel file (zip bytes) under an .xlsx name.
        XCTAssertEqual(
            message(Data([0x50, 0x4B, 0x03, 0x04]), "catalogue.xlsx"),
            CanonicalBusinessEngine.constant("MATERIAL_CATALOGUE_CSV_NOT_CSV_MESSAGE", as: String.self)
        )
        // An Excel file renamed .csv holds NUL bytes.
        XCTAssertEqual(
            message(Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00]), "catalogue.csv"),
            CanonicalBusinessEngine.materialCatalogueCsvBinaryMessage
        )
        // UTF-16 holds NUL bytes too (web checks NUL before UTF-8): refused, never read through a UTF-16 fallback.
        XCTAssertEqual(
            message(Data("Name,Category\nTEST-Flex,Cable\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), "catalogue.csv"),
            CanonicalBusinessEngine.materialCatalogueCsvBinaryMessage
        )
        // Latin-1 bytes are not UTF-8.
        XCTAssertEqual(
            message(Data([0x4E, 0x61, 0x6D, 0x65, 0x2C, 0x43, 0x61, 0x74, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x2C, 0x58, 0x0A]), "catalogue.csv"),
            CanonicalBusinessEngine.materialCatalogueCsvEncodingMessage
        )
        // 3 MB is over the 2 MB limit.
        XCTAssertEqual(
            message(Data(repeating: 0x41, count: 3 * 1024 * 1024), "catalogue.csv"),
            CanonicalBusinessEngine.constant("MATERIAL_CATALOGUE_CSV_TOO_BIG_MESSAGE", as: String.self)
        )
        // An empty file.
        XCTAssertEqual(
            message(Data(), "catalogue.csv"),
            CanonicalBusinessEngine.constant("MATERIAL_CATALOGUE_CSV_EMPTY_MESSAGE", as: String.self)
        )
    }

    func testTheExportHasNewAndOldColumnsAndGuardsFormulas() throws {
        let items = [
            MaterialCatalogItem(
                name: "=HYPERLINK(\"x\")", brand: "TEST-Brand", defaultUnit: .drum,
                orderUnit: "Reel", contentAmount: 100, contentMeasure: "m",
                category: "Cable", createdByUserId: "u", createdByName: "TEST-Admin"
            ),
        ]
        let csv = try XCTUnwrap(MaterialCatalogCSV.csvString(for: items))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, CanonicalBusinessEngine.constant("MATERIAL_CATALOGUE_CSV_HEADER", as: String.self))
        XCTAssertTrue(lines[0].contains("Order unit,Contents amount,Contents measure"))
        XCTAssertTrue(lines[0].hasSuffix("Default Type (Length Drum Box Pallet or Number),Length,Length Unit (M or MM)"))
        XCTAssertTrue(lines[1].contains(",Reel,100,m,"), lines[1])
        XCTAssertTrue(lines[1].contains(",Drum,100,M"), "the nearest old meaning for older tools: \(lines[1])")
        XCTAssertTrue(lines[1].contains("'=HYPERLINK"), "formula guard on export: \(lines[1])")
        // And it reads back as the same model.
        let back = try MaterialCatalogCSV.parse(text: csv)
        XCTAssertEqual(back.rows.first?.orderUnit, "Reel")
        XCTAssertEqual(back.rows.first?.contentAmount, 100)
    }
}
