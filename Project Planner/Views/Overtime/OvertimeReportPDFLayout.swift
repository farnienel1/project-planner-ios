//
//  OvertimeReportPDFLayout.swift
//  Project Planner
//
//  The overtime report PDF in the invoice / timesheet PDF family (`InvoicePDFBuilder` in InvoicingView.swift): the
//  same title block (big navy title, "Project Planner", rule, COMPANY / NAME / GENERATED / PERIOD), a navy table header,
//  hairline rows, the navy total box, plus the company logo, a repeated table header after each page break and page
//  numbers. Look only: every text comes from the saved copy (`parseOvertimeReportDocument`) and `overtimeReportRows`
//  — no figure is worked out here.
//

import UIKit

/// One table row of the report: the fields `overtimeReportRows` joins into its text row, kept apart for the columns.
/// `fullText` is set only when the saved lines could not be read field by field: the rulebook's row text then spans
/// the table.
struct OvertimeReportTableRow: Hashable {
    var day: String
    var job: String
    var time: String
    var overtime: String
    var fullText: String? = nil
}

/// Which rows go on which page (pure, so it can be tested).
struct OvertimeReportPagination: Equatable {
    /// Row indices per page; a page may hold none (the total alone on the last page).
    var pages: [[Int]]
    /// The page the total box is drawn on.
    var totalsPage: Int

    var pageCount: Int { pages.count }
}

enum OvertimeReportPDFLayout {
    static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let margin: CGFloat = 28
    static var contentWidth: CGFloat { pageRect.width - margin * 2 }
    /// Lowest y a row or the total may reach; the footer (page number) sits under it.
    static var contentBottom: CGFloat { pageRect.height - margin - 26 }
    static let tableHeaderHeight: CGFloat = 24
    static let totalsGap: CGFloat = 12
    static let totalsHeight: CGFloat = 46
    static let emptyStateHeight: CGFloat = 30
    /// Top of the table on a continuation page (under the one-line running heading).
    static var continuationTableTop: CGFloat { margin + 24 }

    /// Column widths: Day, Job, Start–Finish, Overtime (the last right-aligned). They fill `contentWidth`.
    static let columnWidths: [CGFloat] = [112, 205, 92, 130]
    static let columnTitles = ["Day", "Job", "Start–Finish", "Overtime"]
    static let cellPadding: CGFloat = 8

    /// The table rows of a saved report. The fields are read from the saved lines (the same fields `overtimeReportRows`
    /// joins); when they cannot be read one-for-one with the rulebook's rows, each rulebook row spans the table.
    static func tableRows(savedLines: [[String: Any]]?, rulebookRows: [String]) -> [OvertimeReportTableRow] {
        guard let savedLines, savedLines.count == rulebookRows.count else {
            return rulebookRows.map { OvertimeReportTableRow(day: "", job: "", time: "", overtime: "", fullText: $0) }
        }
        return savedLines.map { line in
            func text(_ key: String) -> String {
                (line[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let start = text("start")
            let end = text("end")
            return OvertimeReportTableRow(
                day: text("dayLabel"),
                job: [text("jobNumber"), text("jobName")].filter { !$0.isEmpty }.joined(separator: " "),
                time: start.isEmpty || end.isEmpty ? "" : "\(start)–\(end)",
                overtime: text("text")
            )
        }
    }

    /// `overtimeReportRows.total` ("Total overtime: 12.5h") as the box's label and figure; the whole text as the label
    /// when it has no ": ".
    static func splitTotal(_ total: String) -> (label: String, value: String) {
        guard let range = total.range(of: ": ", options: .backwards) else { return (total, "") }
        return (String(total[..<range.lowerBound]), String(total[range.upperBound...]))
    }

    /// The report title: `overtimeReportRows.title` up to its " · " (the name goes in the NAME box).
    static func documentTitle(_ rulebookTitle: String) -> String {
        let head = rulebookTitle.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return head.isEmpty ? "Overtime report" : head
    }

    /// Splits rows over pages. Page 1's table starts at `firstTableTop`, later pages at `nextTableTop`; each page with
    /// rows repeats the table header. The total goes under the last row, or alone on a new page when it does not fit.
    static func paginate(
        rowHeights: [CGFloat],
        firstTableTop: CGFloat,
        nextTableTop: CGFloat,
        bottom: CGFloat,
        tableHeader: CGFloat = OvertimeReportPDFLayout.tableHeaderHeight,
        emptyHeight: CGFloat = OvertimeReportPDFLayout.emptyStateHeight,
        gap: CGFloat = OvertimeReportPDFLayout.totalsGap,
        totals: CGFloat = OvertimeReportPDFLayout.totalsHeight
    ) -> OvertimeReportPagination {
        var pages: [[Int]] = [[]]
        var y = firstTableTop + tableHeader
        if rowHeights.isEmpty { y += emptyHeight }
        for (index, height) in rowHeights.enumerated() {
            if y + height > bottom && !(pages[pages.count - 1].isEmpty) {
                pages.append([])
                y = nextTableTop + tableHeader
            }
            pages[pages.count - 1].append(index)
            y += height
        }
        if y + gap + totals > bottom {
            // The total does not fit under the last row: it goes alone on a new page.
            pages.append([])
        }
        return OvertimeReportPagination(pages: pages, totalsPage: pages.count - 1)
    }

    /// "Page 2 of 3".
    static func pageLabel(_ page: Int, of count: Int) -> String { "Page \(page + 1) of \(max(count, 1))" }

    /// The generated time in the organisation's zone ("6 Nov 2026, 14:05"); now when the saved time is not back yet.
    static func generatedText(ms: Double?, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: ms.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now)
    }
}

/// Draws the report. Colours and type follow `InvoicePDFBuilder` so the PDFs read as one family.
enum OvertimeReportPDFBuilder {
    struct Content {
        var title: String
        var companyName: String
        var personName: String
        var period: String
        var generated: String
        var rows: [OvertimeReportTableRow]
        var totalLabel: String
        var totalValue: String
        var emptyMessage: String
        var logo: UIImage?
    }

    // The invoice PDF's palette (same values as `InvoicePDFBuilder`).
    private static let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
    private static let cyan = UIColor(red: 0.169, green: 0.733, blue: 0.937, alpha: 1)
    private static let slate = UIColor(red: 0.36, green: 0.42, blue: 0.5, alpha: 1)
    private static let hairline = UIColor(white: 0.93, alpha: 1)
    private static let totalLabelColor = UIColor(red: 0.62, green: 0.72, blue: 0.82, alpha: 1)

    private static let dayFont = UIFont.systemFont(ofSize: 10.5, weight: .bold)
    private static let jobFont = UIFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let timeFont = UIFont.systemFont(ofSize: 10, weight: .regular)
    private static let overtimeFont = UIFont.systemFont(ofSize: 10.5, weight: .bold)
    private static let rowVerticalPadding: CGFloat = 9

    static func makeData(_ content: Content) -> Data {
        let layout = OvertimeReportPDFLayout.self
        let margin = layout.margin
        let width = layout.contentWidth
        let headerBottom = titleBlockHeight() + margin + 14
        let heights = content.rows.map(rowHeight)
        let pagination = layout.paginate(
            rowHeights: heights,
            firstTableTop: headerBottom,
            nextTableTop: layout.continuationTableTop,
            bottom: layout.contentBottom
        )
        let renderer = UIGraphicsPDFRenderer(bounds: layout.pageRect)
        return renderer.pdfData { pdf in
            for (pageIndex, rowIndices) in pagination.pages.enumerated() {
                pdf.beginPage()
                var y: CGFloat
                if pageIndex == 0 {
                    drawTitleBlock(content, origin: CGPoint(x: margin, y: margin), width: width)
                    y = headerBottom
                } else {
                    drawRunningHeading(content, y: margin, width: width)
                    y = layout.continuationTableTop
                }
                if pageIndex == 0 || !rowIndices.isEmpty {
                    drawTableHeader(y: y, x: margin, width: width)
                    y += layout.tableHeaderHeight
                }
                if pageIndex == 0 && content.rows.isEmpty {
                    draw(content.emptyMessage, in: CGRect(x: margin + 10, y: y + 8, width: width - 20, height: layout.emptyStateHeight),
                         font: .systemFont(ofSize: 11), color: .darkGray)
                    y += layout.emptyStateHeight
                }
                for index in rowIndices {
                    drawRow(content.rows[index], y: y, x: margin, height: heights[index])
                    y += heights[index]
                }
                if pageIndex == pagination.totalsPage {
                    if !rowIndices.isEmpty || pageIndex == 0 {
                        hairline.setFill()
                        UIRectFill(CGRect(x: margin, y: y, width: width, height: 0.8))
                    }
                    let top = rowIndices.isEmpty && pageIndex > 0 ? y : y + layout.totalsGap
                    drawTotal(content, rect: CGRect(x: margin, y: top, width: width, height: layout.totalsHeight))
                }
                drawFooter(content, page: pageIndex, of: pagination.pageCount, width: width)
            }
        }
    }

    // MARK: Header

    private static func titleBlockHeight() -> CGFloat {
        // Title 56 + rule + two meta rows (40 each) + spacing, as `InvoicePDFBuilder.drawTitleBlock`.
        56 + 12 + 80
    }

    private static func drawTitleBlock(_ content: Content, origin: CGPoint, width: CGFloat) {
        if let logo = content.logo, logo.size.height > 0, logo.size.width > 0 {
            let maxHeight: CGFloat = 44
            let maxWidth: CGFloat = 150
            let scale = min(maxHeight / logo.size.height, maxWidth / logo.size.width)
            let size = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
            logo.draw(in: CGRect(x: origin.x + width - size.width, y: origin.y + (48 - size.height) / 2, width: size.width, height: size.height))
        }
        let titleWidth = width - (content.logo == nil ? 0 : 160)
        draw(content.title, in: CGRect(x: origin.x, y: origin.y, width: titleWidth, height: 38),
             font: .systemFont(ofSize: 31, weight: .bold), color: navy, lines: 1)
        ("Project Planner" as NSString).draw(at: CGPoint(x: origin.x, y: origin.y + 36), withAttributes: [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: cyan,
        ])

        let lineY = origin.y + 56
        navy.setFill()
        UIRectFill(CGRect(x: origin.x, y: lineY, width: width, height: 1.6))

        let metaTop = lineY + 12
        let columnWidth = (width - 14) / 2
        let leftX = origin.x
        let rightX = origin.x + columnWidth + 14
        func meta(_ label: String, _ value: String, x: CGFloat, y: CGFloat) {
            (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: UIColor.gray,
            ])
            draw(value.isEmpty ? "—" : value, in: CGRect(x: x, y: y + 12, width: columnWidth, height: 26),
                 font: .systemFont(ofSize: 12.5, weight: .semibold), color: navy, lines: 1)
        }
        meta("COMPANY", content.companyName, x: leftX, y: metaTop)
        meta("NAME", content.personName, x: rightX, y: metaTop)
        meta("GENERATED", content.generated, x: leftX, y: metaTop + 40)
        meta("PERIOD", content.period, x: rightX, y: metaTop + 40)
    }

    /// The one-line heading on a continuation page: "Overtime report · Sam Smith · 26 Oct – 25 Nov".
    private static func drawRunningHeading(_ content: Content, y: CGFloat, width: CGFloat) {
        let text = [content.title, content.personName, content.period].filter { !$0.isEmpty }.joined(separator: " · ")
        draw(text, in: CGRect(x: OvertimeReportPDFLayout.margin, y: y, width: width, height: 16),
             font: .systemFont(ofSize: 10, weight: .semibold), color: slate, lines: 1)
    }

    // MARK: Table

    private static func columnRects(x: CGFloat, y: CGFloat, height: CGFloat) -> [CGRect] {
        var left = x
        return OvertimeReportPDFLayout.columnWidths.map { columnWidth in
            defer { left += columnWidth }
            return CGRect(x: left, y: y, width: columnWidth, height: height)
        }
    }

    private static func drawTableHeader(y: CGFloat, x: CGFloat, width: CGFloat) {
        let height = OvertimeReportPDFLayout.tableHeaderHeight
        navy.setFill()
        UIRectFill(CGRect(x: x, y: y, width: width, height: height))
        let pad = OvertimeReportPDFLayout.cellPadding
        for (index, rect) in columnRects(x: x, y: y, height: height).enumerated() {
            let isLast = index == OvertimeReportPDFLayout.columnTitles.count - 1
            draw(OvertimeReportPDFLayout.columnTitles[index],
                 in: rect.insetBy(dx: pad, dy: 0).offsetBy(dx: 0, dy: 7),
                 font: .systemFont(ofSize: 9.5, weight: .bold), color: .white, alignment: isLast ? .right : .left, lines: 1)
        }
    }

    private static func cellWidth(_ column: Int) -> CGFloat {
        OvertimeReportPDFLayout.columnWidths[column] - OvertimeReportPDFLayout.cellPadding * 2
    }

    private static func rowHeight(_ row: OvertimeReportTableRow) -> CGFloat {
        let content: CGFloat
        if let full = row.fullText {
            content = textHeight(full, font: jobFont, width: OvertimeReportPDFLayout.contentWidth - OvertimeReportPDFLayout.cellPadding * 2)
        } else {
            content = max(
                textHeight(row.day, font: dayFont, width: cellWidth(0)),
                textHeight(row.job, font: jobFont, width: cellWidth(1)),
                textHeight(row.time, font: timeFont, width: cellWidth(2)),
                textHeight(row.overtime, font: overtimeFont, width: cellWidth(3))
            )
        }
        return max(30, content + rowVerticalPadding * 2)
    }

    private static func drawRow(_ row: OvertimeReportTableRow, y: CGFloat, x: CGFloat, height: CGFloat) {
        let width = OvertimeReportPDFLayout.contentWidth
        hairline.setFill()
        UIRectFill(CGRect(x: x, y: y, width: width, height: 0.8))
        let pad = OvertimeReportPDFLayout.cellPadding
        let top = y + rowVerticalPadding
        let inner = height - rowVerticalPadding * 2
        if let full = row.fullText {
            draw(full, in: CGRect(x: x + pad, y: top, width: width - pad * 2, height: inner), font: jobFont, color: navy)
            return
        }
        let rects = columnRects(x: x, y: top, height: inner).map { $0.insetBy(dx: pad, dy: 0) }
        draw(row.day, in: rects[0], font: dayFont, color: navy)
        draw(row.job.isEmpty ? "—" : row.job, in: rects[1], font: jobFont, color: navy)
        draw(row.time.isEmpty ? "—" : row.time, in: rects[2], font: timeFont, color: slate)
        draw(row.overtime, in: rects[3], font: overtimeFont, color: navy, alignment: .right)
    }

    // MARK: Total and footer

    private static func drawTotal(_ content: Content, rect: CGRect) {
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(red: 0.071, green: 0.149, blue: 0.243, alpha: 1).cgColor,
                UIColor(red: 0.039, green: 0.083, blue: 0.153, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )
        if let context = UIGraphicsGetCurrentContext(), let gradient {
            context.saveGState()
            UIBezierPath(roundedRect: rect, cornerRadius: 12).addClip()
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.midY), end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
            context.restoreGState()
        }
        draw(content.totalLabel, in: CGRect(x: rect.minX + 14, y: rect.minY + 16, width: rect.width * 0.6, height: 16),
             font: .systemFont(ofSize: 11, weight: .medium), color: totalLabelColor, lines: 1)
        draw(content.totalValue, in: CGRect(x: rect.minX + rect.width * 0.4, y: rect.minY + 11, width: rect.width * 0.6 - 14, height: 26),
             font: .systemFont(ofSize: 20, weight: .bold), color: .white, alignment: .right, lines: 1)
    }

    private static func drawFooter(_ content: Content, page: Int, of count: Int, width: CGFloat) {
        let layout = OvertimeReportPDFLayout.self
        let y = layout.pageRect.height - layout.margin - 12
        hairline.setFill()
        UIRectFill(CGRect(x: layout.margin, y: y - 6, width: width, height: 0.8))
        let left = [content.companyName, content.title].filter { !$0.isEmpty }.joined(separator: " · ")
        draw(left, in: CGRect(x: layout.margin, y: y, width: width * 0.7, height: 12),
             font: .systemFont(ofSize: 8.5), color: .gray, lines: 1)
        draw(layout.pageLabel(page, of: count), in: CGRect(x: layout.margin + width * 0.7, y: y, width: width * 0.3, height: 12),
             font: .systemFont(ofSize: 8.5, weight: .semibold), color: .gray, alignment: .right, lines: 1)
    }

    // MARK: Text

    private static func attributes(font: UIFont, color: UIColor, alignment: NSTextAlignment, lines: Int) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return ceil(font.lineHeight) }
        let size = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font: font, color: .black, alignment: .left, lines: 0),
            context: nil
        ).size
        return ceil(size.height)
    }

    private static func draw(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        lines: Int = 0
    ) {
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font: font, color: color, alignment: alignment, lines: lines),
            context: nil
        )
    }
}
