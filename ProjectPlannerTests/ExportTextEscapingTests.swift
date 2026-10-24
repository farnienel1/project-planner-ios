import XCTest
@testable import Project_Planner

final class ExportTextEscapingTests: XCTestCase {
    func testHTMLEscapesScriptAndApostrophe() {
        let html = ExportTextEscaping.escapeHTML("<script>Ada</script>")
        XCTAssertEqual(html, "&lt;script&gt;Ada&lt;/script&gt;")
        XCTAssertFalse(html.contains("<script"))
        XCTAssertEqual(ExportTextEscaping.escapeHTML("Ada's list"), "Ada&#39;s list")
    }

    func testAlreadyEncodedAmpersandIsLeftAlone() {
        let html = ExportTextEscaping.escapeHTML("Fish &amp; chips")
        XCTAssertEqual(html, "Fish &amp; chips")
        XCTAssertFalse(html.contains("&amp;amp;"))
        XCTAssertEqual(ExportTextEscaping.escapeHTML("&#39;"), "&#39;")
        XCTAssertEqual(ExportTextEscaping.escapeHTML("&lt;script&gt;"), "&lt;script&gt;")
    }

    func testSubjectAndFromNameDropHeaderBreaksAndCapLength() {
        let company = "Acme\r\nBcc: evil@example.com\u{0007}"
        let subject = ExportTextEscaping.sanitizeEmailSubject(company)
        XCTAssertFalse(subject.contains("\r"))
        XCTAssertFalse(subject.contains("\n"))
        XCTAssertFalse(subject.contains("\u{0007}"))
        XCTAssertTrue(subject.contains("Bcc:"))

        let long = String(repeating: "A", count: 200)
        XCTAssertEqual(ExportTextEscaping.sanitizeEmailSubject(long).count, 180)
        XCTAssertEqual(ExportTextEscaping.sanitizeFromDisplayName(long).count, 80)

        let replyTo = ExportTextEscaping.sanitizeReplyToAddress(" ada@example.com\r\n")
        XCTAssertEqual(replyTo, "ada@example.com")
        XCTAssertFalse(replyTo.contains("\r"))
        XCTAssertFalse(replyTo.contains("\n"))
    }

    func testCSVPrefixesFormulasAndQuotesCommas() {
        XCTAssertEqual(ExportTextEscaping.csvField("=1+1"), "'=1+1")
        XCTAssertEqual(ExportTextEscaping.csvField("Tray"), "Tray")
        XCTAssertEqual(ExportTextEscaping.csvField("Smith, Ada"), "\"Smith, Ada\"")
        XCTAssertEqual(ExportTextEscaping.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testCatalogueHeaderIsUnchangedAndFormulaNamesArePrefixed() {
        XCTAssertEqual(
            MaterialCatalogCSV.headerLine,
            "Catalogue ID,Name,Category,Manufacturer/Brand,Product Code,Default Type (Length Drum Box Pallet or Number),Size,Length,Length Unit (M or MM)"
        )
        let csv = MaterialCatalogCSV.csvString(for: [
            catalogueItem(name: "=1+1"),
            catalogueItem(name: "Tray"),
            catalogueItem(name: "Smith, Ada")
        ])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, MaterialCatalogCSV.headerLine)
        XCTAssertTrue(csv.contains(",'=1+1,"))
        XCTAssertTrue(csv.contains(",Tray,"))
        XCTAssertTrue(csv.contains("\"Smith, Ada\""))
        XCTAssertFalse(lines[0].hasPrefix("'"))
    }

    func testFormulaPrefixSurvivesXMLEscape() {
        let encoded = ExportTextEscaping.escapeHTML(ExportTextEscaping.spreadsheetFormulaPrefix("=1+1"))
        XCTAssertEqual(encoded, "&#39;=1+1")
        XCTAssertTrue(decodeXMLText(encoded).hasPrefix("'"))
        XCTAssertEqual(decodeXMLText(encoded), "'=1+1")

        let xml = WeeklyReportExportBuilder.worksheetXML(rows: [["=1+1"], ["Tray"], ["12"]])
        XCTAssertTrue(xml.contains("<t>&#39;=1+1</t>"))
        XCTAssertTrue(xml.contains("<t>Tray</t>"))
        XCTAssertTrue(xml.contains("<t>12</t>"))
        XCTAssertFalse(xml.contains("<t>=1+1</t>"))
        let cell = xml.split(separator: "<t>")[1].split(separator: "</t>")[0]
        XCTAssertTrue(decodeXMLText(String(cell)).hasPrefix("'"))
    }

    func testMaterialRequestHTMLEscapesNamesAndSubjectDropsNewlines() {
        let item = MaterialItem(
            quantity: 1,
            unit: .number,
            material: "<script>Ada</script>",
            addedBy: "Ada",
            projectId: UUID(),
            date: Date(timeIntervalSince1970: 0)
        )
        let context = MaterialRequestEmailBuilder.Context(
            supplierName: "Supplier",
            userName: "Ada",
            userEmail: "ada@example.com",
            userPhone: nil,
            userCompany: "Acme\nBcc: evil@example.com",
            jobNumber: "J-1",
            siteName: nil,
            deliveryAddress: nil,
            requestedDate: nil,
            quoteNeededBy: nil,
            companyLogoURL: nil,
            materials: [item],
            sentAt: Date(timeIntervalSince1970: 0)
        )
        let html = MaterialRequestEmailBuilder.buildOrderEmail(context: context)
        XCTAssertTrue(html.contains("&lt;script&gt;Ada&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script"))

        let plain = MaterialRequestEmailBuilder.buildPlainTextEmail(context: context, isQuote: false)
        XCTAssertTrue(plain.contains("<script>Ada</script>"))
        XCTAssertFalse(plain.contains("&lt;"))

        let subject = MaterialRequestEmailBuilder.orderSubject(
            jobNumber: "J-1",
            company: "Acme\nBcc: evil@example.com"
        )
        XCTAssertFalse(subject.contains("\n"))
        XCTAssertFalse(subject.contains("\r"))

        let wrapped = MaterialRequestEmailBuilder.plainTextAsSimpleHTML("Fish & chips")
        XCTAssertTrue(wrapped.contains("Fish &amp; chips"))
        XCTAssertFalse(wrapped.contains("&amp;amp;"))
        XCTAssertTrue(wrapped.contains("<pre"))
    }

    private func catalogueItem(name: String) -> MaterialCatalogItem {
        MaterialCatalogItem(
            name: name,
            brand: "Brand",
            defaultUnit: .number,
            createdByUserId: "user",
            createdByName: "Ada"
        )
    }

    private func decodeXMLText(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text
    }
}
