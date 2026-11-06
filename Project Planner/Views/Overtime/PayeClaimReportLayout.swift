//
//  PayeClaimReportLayout.swift
//  Project Planner
//
//  Presentation only (RULEBOOK 1.30.0 §26). What the price work / expenses report PDF and the Add sheet show, read
//  from the rulebook's own answers: the saved report copy (`PayeClaimReportRecord`), `payeClaimReportRows`,
//  `payeClaimEvidencePages`, `formatPaymentRunDay`, `priceWorkJobNumberText`, `formatMoney` (`OrgMoney`) and the
//  `payeClaims.ts` text constants. Nothing is decided or counted here: every figure, total, count, message and
//  evidence page comes from the script; this file only places them in table columns and page headers.
//

import Foundation

/// The report PDF's content, laid out as a table and one header per evidence page. Built only from the saved copy.
nonisolated struct PayeClaimReportLayout: Equatable {
    /// One summary table row: a report item.
    nonisolated struct Row: Equatable {
        var itemId: String
        /// `formatPaymentRunDay` of the item's day, or "from – to" for price work over several days.
        var date: String
        /// Price work: `priceWorkJobNumberText` ("—" for an item stored before 1.30.1). Expense: as stored.
        var jobNumber: String
        var name: String
        /// Price work only (the snapshot's `approvedByName`).
        var approvedBy: String
        /// `payeClaimReportRows` row figure (`formatMoney` in the report's currency).
        var amount: String
        /// The item's description, under the row.
        var description: String
        /// The rulebook's evidence line for the row ("Evidence: 2 (a.jpg, b.pdf)"), or empty.
        var evidenceNote: String
    }

    /// The header of one evidence page (`payeClaimEvidencePages`, one page per piece of evidence).
    nonisolated struct EvidenceHeading: Equatable {
        var itemId: String
        var itemName: String
        var date: String
        var jobNumber: String
        var approvedBy: String
        var amount: String
        /// The rulebook's own title for this piece ("Evidence 2 of 3: receipt.jpg").
        var evidenceTitle: String
        /// The rest of the rulebook's page details (the item's description).
        var notes: [String]
        var path: String
        /// `image` | `pdf` | `listed` (`payeClaimEvidenceDrawAs`).
        var drawAs: String
    }

    var isPriceWork: Bool
    /// `PRICE_WORK_REPORT_TITLE` / `EXPENSES_REPORT_TITLE`.
    var documentTitle: String
    var personName: String
    var companyName: String
    /// `payeClaimReportRows` subtitle (the report range).
    var rangeText: String
    var generatedText: String
    var rows: [Row]
    /// `PRICE_WORK_EMPTY_MESSAGE` / `EXPENSES_EMPTY_MESSAGE` from `payeClaimReportRows`.
    var emptyMessage: String
    /// The saved copy's `totals.itemCount` / `totals.evidenceCount`.
    var itemCount: Int
    var evidenceCount: Int
    /// `PRICE_WORK_TOTAL_LABEL` / `EXPENSES_TOTAL_LABEL`, and the saved total through `formatMoney`.
    var totalLabel: String
    var totalAmount: String
    var evidencePages: [EvidenceHeading]

    /// Table column titles, in drawing order.
    var columnTitles: [String] {
        isPriceWork
            ? ["From – To", "Job number", "Name", "Approved by", "Amount"]
            : ["Date", "Job number", "Name", "Amount"]
    }

    /// The line under the page footer: company, report and person.
    var footerText: String {
        [companyName, documentTitle, personName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Nil when the rulebook could not read the saved copy (`payeClaimReportRows` returned nothing).
    static func make(report: PayeClaimReportRecord, generatedText: String) -> PayeClaimReportLayout? {
        guard let summary = CanonicalBusinessEngine.payeClaimReportRows(report) else { return nil }
        let pages = CanonicalBusinessEngine.payeClaimEvidencePages(report)
        let priceWork = report.kind == PayeClaimKind.priceWork.rawValue
        let rows: [Row] = report.items.enumerated().map { index, item in
            let ruled = index < summary.rows.count ? summary.rows[index] : nil
            return Row(
                itemId: item.id,
                date: dateText(start: item.startDate, end: item.endDate),
                jobNumber: jobNumberText(item.jobNumber, priceWork: priceWork),
                name: item.title,
                approvedBy: priceWork ? item.approvedByName : "",
                amount: ruled?.figure ?? OrgMoney.format(item.amount, currencyCode: report.currency),
                description: item.details,
                // `payeClaimReportRows` puts the evidence line last, and only when the item has evidence.
                evidenceNote: item.evidence.isEmpty ? "" : (ruled?.lines.last ?? "")
            )
        }
        let headings: [EvidenceHeading] = pages.map { page in
            let item = report.items.first { $0.id == page.itemId }
            return EvidenceHeading(
                itemId: page.itemId,
                itemName: item.map { $0.title.isEmpty ? page.heading : $0.title } ?? page.heading,
                date: item.map { dateText(start: $0.startDate, end: $0.endDate) } ?? "",
                jobNumber: item.map { jobNumberText($0.jobNumber, priceWork: priceWork) } ?? "",
                approvedBy: priceWork ? (item?.approvedByName ?? "") : "",
                amount: item.map { OrgMoney.format($0.amount, currencyCode: report.currency) } ?? "",
                evidenceTitle: page.details.first ?? page.name,
                notes: Array(page.details.dropFirst()),
                path: page.path,
                drawAs: page.drawAs
            )
        }
        return PayeClaimReportLayout(
            isPriceWork: priceWork,
            documentTitle: priceWork
                ? CanonicalBusinessEngine.payeClaimText("PRICE_WORK_REPORT_TITLE", fallback: "Price work report")
                : CanonicalBusinessEngine.payeClaimText("EXPENSES_REPORT_TITLE", fallback: "Expenses report"),
            personName: report.userName,
            companyName: report.companyName,
            rangeText: summary.subtitle,
            generatedText: generatedText,
            rows: rows,
            emptyMessage: summary.empty,
            itemCount: report.totals.itemCount,
            evidenceCount: report.totals.evidenceCount,
            totalLabel: priceWork
                ? CanonicalBusinessEngine.payeClaimText("PRICE_WORK_TOTAL_LABEL", fallback: "Total price work")
                : CanonicalBusinessEngine.payeClaimText("EXPENSES_TOTAL_LABEL", fallback: "Total expenses"),
            totalAmount: OrgMoney.format(report.totals.amount, currencyCode: report.currency),
            evidencePages: headings
        )
    }

    /// The day as the report rows show it (`formatPaymentRunDay`), "from – to" when the item spans several days.
    static func dateText(start: String, end: String) -> String {
        guard !start.isEmpty else { return "" }
        let first = CanonicalBusinessEngine.formatPaymentRunDay(start)
        guard !end.isEmpty, end != start else { return first }
        return "\(first) – \(CanonicalBusinessEngine.formatPaymentRunDay(end))"
    }

    private static func jobNumberText(_ value: String, priceWork: Bool) -> String {
        priceWork ? CanonicalBusinessEngine.priceWorkJobNumberText(value) : value
    }
}

// MARK: - Add sheet: which card a validation message belongs to

/// The card on the Add Price Work / Add Expense sheet that a rulebook validation message is shown next to. The
/// message itself is always the rulebook's (`priceWorkValidationError` / `expenseValidationError`); this only
/// matches it against the rulebook's own message constants to choose where it appears.
nonisolated enum PayeClaimFormSection: String, CaseIterable, Equatable {
    case details
    case dates
    case approver
    case amount
    case evidence
    /// Anything not matched (an older or newer script's message): shown above the add button.
    case other

    private static let messageNames: [(PayeClaimFormSection, [String])] = [
        (.details, ["PAYE_CLAIM_TITLE_MESSAGE", "PRICE_WORK_JOB_NUMBER_REQUIRED_MESSAGE", "PRICE_WORK_JOB_NUMBER_TOO_LONG_MESSAGE"]),
        (.dates, ["PAYE_CLAIM_DATE_MESSAGE", "PRICE_WORK_DATES_MESSAGE"]),
        (.approver, ["PRICE_WORK_APPROVER_REQUIRED_MESSAGE", "PRICE_WORK_APPROVER_INVALID_MESSAGE"]),
        (.amount, ["PAYE_CLAIM_AMOUNT_MESSAGE"]),
        (.evidence, ["EXPENSE_EVIDENCE_REQUIRED_MESSAGE", "PAYE_CLAIM_EVIDENCE_LIMIT_MESSAGE", "PAYE_CLAIM_EVIDENCE_INVALID_MESSAGE"]),
    ]

    static func section(for message: String) -> PayeClaimFormSection {
        for (section, names) in messageNames {
            for name in names {
                let text = CanonicalBusinessEngine.payeClaimText(name, fallback: "")
                if !text.isEmpty && text == message { return section }
            }
        }
        return .other
    }
}
