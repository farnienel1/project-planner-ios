import XCTest
@testable import Project_Planner

/// The price work / expenses report PDF layout (`PayeClaimReportLayout`) and the Add sheet's message placement
/// (`PayeClaimFormSection`). Presentation only: every figure, count, title and message is the packed rulebook's
/// (`payeClaimReportRows`, `payeClaimEvidencePages`, `formatPaymentRunDay`, `priceWorkJobNumberText`, `formatMoney`);
/// these tests lock that the layout reads them, one evidence heading per piece of evidence, and nothing is invented.
@MainActor
final class PayeClaimReportLayoutTests: XCTestCase {
    private let org = "TEST-ORG-LAYOUT"

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company Layout"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func evidencePath(_ ms: Int64, _ ext: String = "jpg") throws -> String {
        try XCTUnwrap(CanonicalBusinessEngine.payeClaimEvidencePath(organizationId: org, userId: "sam", unixMs: ms, fileExtension: ext))
    }

    private func report(kind: PayeClaimKind, items: [PayeClaimItem]) throws -> PayeClaimReportRecord {
        var snapshot = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReportSnapshot(
            kind: kind, userId: "sam", userName: "Sam Test", companyName: "TEST-Company Layout", currency: "GBP",
            rangeStart: "2026-10-26", rangeEnd: "2026-11-25", items: items, generatedBy: "sam"
        ))
        snapshot["generatedAt"] = 1_762_250_100_000.0
        return try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReportDocument(docId: "R-LAYOUT", data: snapshot))
    }

    func testTheExpensesReportLayoutReadsTheRulebookRowsCountsAndOneHeadingPerPieceOfEvidence() throws {
        let photo = try evidencePath(1_762_250_000_000)
        let pdf = try evidencePath(1_762_250_000_001, "pdf")
        let fuel = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: "E1",
            data: [
                "userId": "sam", "title": "TEST-Fuel", "details": "Van to site", "date": "2026-11-04", "amount": 12.5, "jobNumber": "J-1",
                "evidence": [
                    ["path": photo, "name": "receipt.jpg", "kind": "photo", "contentType": "image/jpeg"],
                    ["path": pdf, "name": "invoice.pdf", "kind": "file", "contentType": "application/pdf"],
                ],
            ],
            organizationId: org
        ))
        let parking = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: "E2",
            data: [
                "userId": "sam", "title": "TEST-Parking", "date": "2026-11-05", "amount": 4,
                "evidence": [["path": try evidencePath(1_762_250_000_002), "name": "ticket.jpg", "kind": "photo", "contentType": "image/jpeg"]],
            ],
            organizationId: org
        ))
        let saved = try report(kind: .expense, items: [fuel, parking])
        let rulebook = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReportRows(saved))
        let pages = CanonicalBusinessEngine.payeClaimEvidencePages(saved)
        let layout = try XCTUnwrap(PayeClaimReportLayout.make(report: saved, generatedText: "4 Nov 2026, 09:55"))

        XCTAssertFalse(layout.isPriceWork)
        XCTAssertEqual(layout.documentTitle, "Expenses report")
        XCTAssertEqual(layout.personName, "Sam Test")
        XCTAssertEqual(layout.companyName, "TEST-Company Layout")
        XCTAssertEqual(layout.rangeText, rulebook.subtitle, "the range is the rulebook's subtitle")
        XCTAssertEqual(layout.columnTitles, ["Date", "Job number", "Name", "Amount"])

        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows.map(\.amount), rulebook.rows.map(\.figure), "amounts are the rulebook's figures")
        XCTAssertEqual(layout.rows[0].name, "TEST-Fuel")
        XCTAssertEqual(layout.rows[0].jobNumber, "J-1")
        XCTAssertEqual(layout.rows[0].date, CanonicalBusinessEngine.formatPaymentRunDay("2026-11-04"))
        XCTAssertTrue(rulebook.rows[0].heading.hasPrefix(layout.rows[0].date), "the same day text as the rulebook heading")
        XCTAssertEqual(layout.rows[0].description, "Van to site")
        XCTAssertEqual(layout.rows[0].evidenceNote, rulebook.rows[0].lines.last)
        XCTAssertTrue(layout.rows[0].evidenceNote.hasPrefix("Evidence: 2"))
        XCTAssertEqual(layout.rows[1].jobNumber, "", "an expense without a job number shows none")
        XCTAssertEqual(layout.rows[1].approvedBy, "", "expenses have no Approved by column")

        XCTAssertEqual(layout.itemCount, 2)
        XCTAssertEqual(layout.evidenceCount, 3)
        XCTAssertEqual(layout.totalLabel, "Total expenses")
        XCTAssertEqual(layout.totalAmount, "£16.50")
        XCTAssertEqual("\(layout.totalLabel): \(layout.totalAmount)", rulebook.total, "label and figure make the rulebook total")

        XCTAssertEqual(layout.evidencePages.count, pages.count, "one evidence page per piece of evidence")
        XCTAssertEqual(layout.evidencePages.count, 3)
        XCTAssertEqual(layout.evidencePages.map(\.evidenceTitle), pages.map { $0.details.first ?? "" })
        XCTAssertEqual(layout.evidencePages[1].evidenceTitle, "Evidence 2 of 2: invoice.pdf")
        XCTAssertEqual(layout.evidencePages.map(\.drawAs), ["image", "pdf", "image"])
        XCTAssertEqual(layout.evidencePages.map(\.itemName), ["TEST-Fuel", "TEST-Fuel", "TEST-Parking"], "each page is headed by its own item")
        XCTAssertEqual(layout.evidencePages[0].amount, "£12.50")
        XCTAssertEqual(layout.evidencePages[0].jobNumber, "J-1")
        XCTAssertEqual(layout.evidencePages[0].notes, ["Van to site"])
        XCTAssertEqual(layout.evidencePages[2].amount, "£4.00")
        XCTAssertEqual(layout.footerText, "TEST-Company Layout · Expenses report · Sam Test")
    }

    func testThePriceWorkLayoutShowsFromToTheJobNumberDashAndWhoApproved() throws {
        let older = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .priceWork, docId: "P0",
            data: ["userId": "sam", "title": "TEST-Old", "startDate": "2026-11-02", "endDate": "2026-11-04", "amount": 40,
                   "approvedByUserId": "mia", "approvedByName": "Mia Test"],
            organizationId: org
        ))
        let saved = try report(kind: .priceWork, items: [older])
        let layout = try XCTUnwrap(PayeClaimReportLayout.make(report: saved, generatedText: "now"))
        XCTAssertTrue(layout.isPriceWork)
        XCTAssertEqual(layout.documentTitle, "Price work report")
        XCTAssertEqual(layout.columnTitles, ["From – To", "Job number", "Name", "Approved by", "Amount"])
        XCTAssertEqual(layout.rows.first?.jobNumber, "—", "priceWorkJobNumberText for an item stored before 1.30.1")
        XCTAssertEqual(layout.rows.first?.approvedBy, "Mia Test")
        XCTAssertEqual(
            layout.rows.first?.date,
            "\(CanonicalBusinessEngine.formatPaymentRunDay("2026-11-02")) – \(CanonicalBusinessEngine.formatPaymentRunDay("2026-11-04"))"
        )
        XCTAssertEqual(layout.totalLabel, "Total price work")
        XCTAssertEqual(layout.evidenceCount, 0)
        XCTAssertTrue(layout.evidencePages.isEmpty, "no evidence, no evidence pages")
    }

    func testEachRulebookValidationMessageIsShownNextToItsCard() {
        XCTAssertEqual(PayeClaimFormSection.section(for: "Enter a name."), .details)
        XCTAssertEqual(PayeClaimFormSection.section(for: "Add the job number for this price work."), .details)
        XCTAssertEqual(PayeClaimFormSection.section(for: "Choose a date."), .dates)
        XCTAssertEqual(PayeClaimFormSection.section(for: "Choose the dates from and to (the same day is allowed)."), .dates)
        XCTAssertEqual(PayeClaimFormSection.section(for: "Choose who approved this price work."), .approver)
        XCTAssertEqual(PayeClaimFormSection.section(for: "Enter an amount greater than zero."), .amount)
        XCTAssertEqual(
            PayeClaimFormSection.section(for: "Add at least one piece of evidence (a file, photo or personal site audit)."),
            .evidence
        )
        XCTAssertEqual(PayeClaimFormSection.section(for: "Something else."), .other)

        // The messages the sheet actually gets from the validators land on the expected cards.
        let emptyExpense = CanonicalBusinessEngine.expenseValidationError(
            draft: ["title": "", "details": "", "jobNumber": "", "date": "2026-11-04", "amount": "", "evidence": [[String: Any]]()],
            organizationId: nil, userId: nil
        )
        XCTAssertEqual(emptyExpense.map { PayeClaimFormSection.section(for: $0) }, .details)
        let noEvidence = CanonicalBusinessEngine.expenseValidationError(
            draft: ["title": "TEST-Fuel", "details": "", "jobNumber": "", "date": "2026-11-04", "amount": "12", "evidence": [[String: Any]]()],
            organizationId: nil, userId: nil
        )
        XCTAssertEqual(noEvidence.map { PayeClaimFormSection.section(for: $0) }, .evidence)
    }
}
