//
//  PayeClaimReportPDF.swift
//  Project Planner
//
//  RULEBOOK 1.30.0 §26: the price work / expenses report PDF, built only from the saved report copy. Drawing only —
//  the content is `PayeClaimReportLayout` (from `payeClaimReportRows` / `payeClaimEvidencePages`). Same family as the
//  invoice / timesheet PDF (`InvoicePDFBuilder` in InvoicingView.swift): navy title and brand line, a ruled meta
//  block, a navy table header with hairline rows, a navy total box, plus a page footer with page numbers.
//  A summary page (or pages), then one page per piece of evidence: an image as large as fits, a PDF's own pages
//  appended after its heading page, anything else listed with `PAYE_CLAIM_EVIDENCE_NOT_DRAWN_NOTE`, a file that
//  could not be read with `PAYE_CLAIM_EVIDENCE_UNREADABLE_NOTE`.
//

import UIKit

/// The invoice PDF's colours and type, for the claim reports (values copied from `InvoicePDFBuilder`).
enum PayeClaimPDFStyle {
    static let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
    static let cyan = UIColor(red: 0.169, green: 0.733, blue: 0.937, alpha: 1)
    static let slate = UIColor(red: 0.36, green: 0.42, blue: 0.5, alpha: 1)
    static let metaLabel = UIColor.gray
    static let hairline = UIColor(white: 0.93, alpha: 1)
    static let panel = UIColor(white: 0.965, alpha: 1)
    static let totalStart = UIColor(red: 0.071, green: 0.149, blue: 0.243, alpha: 1)
    static let totalEnd = UIColor(red: 0.039, green: 0.083, blue: 0.153, alpha: 1)
    static let totalLabel = UIColor(red: 0.62, green: 0.72, blue: 0.82, alpha: 1)
    static let warn = UIColor(red: 0.6, green: 0.3, blue: 0, alpha: 1)
    static let warnFill = UIColor(red: 1, green: 0.965, blue: 0.91, alpha: 1)

    static let margin: CGFloat = 28
    static let footerHeight: CGFloat = 28
}

/// A page cursor that either draws (with a renderer context) or only measures (nil context), so the summary can be
/// laid out once to count its pages before the real pass prints "Page N of M".
@MainActor
final class PayeClaimReportCanvas {
    /// A4, as `PayeClaimPDFWriter.page`.
    static let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

    let context: UIGraphicsPDFRendererContext?
    let totalPages: Int
    let footerText: String
    private(set) var pageNumber = 0
    var y: CGFloat = 28

    init(context: UIGraphicsPDFRendererContext?, totalPages: Int, footerText: String) {
        self.context = context
        self.totalPages = totalPages
        self.footerText = footerText
    }

    var drawing: Bool { context != nil }
    var left: CGFloat { PayeClaimPDFStyle.margin }
    var width: CGFloat { Self.page.width - PayeClaimPDFStyle.margin * 2 }
    var bottom: CGFloat { Self.page.height - PayeClaimPDFStyle.margin - PayeClaimPDFStyle.footerHeight }

    func beginPage() {
        pageNumber += 1
        y = PayeClaimPDFStyle.margin
        guard let context else { return }
        context.beginPage(withBounds: Self.page, pageInfo: [:])
        drawFooter()
    }

    /// Appends a PDF's pages full size (no footer drawn over another document's page; they are still counted).
    func append(_ document: CGPDFDocument) {
        guard document.numberOfPages > 0 else { return }
        for index in 1...document.numberOfPages {
            guard let pdfPage = document.page(at: index) else { continue }
            pageNumber += 1
            if let context { PayeClaimPDFWriter.draw(pdfPage, in: context) }
        }
        y = Self.page.height
    }

    private func drawFooter() {
        let lineY = Self.page.height - PayeClaimPDFStyle.margin - 16
        PayeClaimPDFStyle.hairline.setFill()
        UIRectFill(CGRect(x: left, y: lineY, width: width, height: 0.8))
        let font = UIFont.systemFont(ofSize: 8.5, weight: .medium)
        let pageText = totalPages > 0 ? "Page \(pageNumber) of \(totalPages)" : "Page \(pageNumber)"
        let pageWidth: CGFloat = 90
        Self.draw(pageText, font: font, color: PayeClaimPDFStyle.slate,
                  in: CGRect(x: left + width - pageWidth, y: lineY + 5, width: pageWidth, height: 12), alignment: .right)
        Self.draw(footerText, font: font, color: PayeClaimPDFStyle.slate,
                  in: CGRect(x: left, y: lineY + 5, width: width - pageWidth - 8, height: 12), lines: 1)
    }

    // MARK: Text

    static func height(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        return ceil((text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height)
    }

    static func draw(
        _ text: String,
        font: UIFont,
        color: UIColor,
        in rect: CGRect,
        alignment: NSTextAlignment = .left,
        lines: Int = 0
    ) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style],
            context: nil
        )
    }

    /// Wrapped text at the cursor across the full width; returns its height. Never runs past the footer.
    @discardableResult
    func paragraph(_ text: String, font: UIFont, color: UIColor, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let height = min(Self.height(text, font: font, width: width), maxHeight, max(0, bottom - y))
        if drawing {
            Self.draw(text, font: font, color: color, in: CGRect(x: left, y: y, width: width, height: height))
        }
        y += height
        return height
    }

    // MARK: Header block (the invoice's title block)

    /// Title (and an optional cyan line under it), the logo on the right, a navy rule, then label / value pairs in
    /// `columns` columns. Same in measuring and drawing passes.
    func headerBlock(
        eyebrow: String?,
        title: String,
        titleSize: CGFloat,
        brandLine: String?,
        logo: UIImage?,
        meta: [(label: String, value: String)],
        columns: Int
    ) {
        let top = y
        var logoWidth: CGFloat = 0
        let logoHeight: CGFloat = 44
        if let logo, logo.size.height > 0, logo.size.width > 0 {
            logoWidth = min(120, logo.size.width * logoHeight / logo.size.height)
            if drawing {
                logo.draw(in: CGRect(x: left + width - logoWidth, y: top, width: logoWidth, height: logoHeight))
            }
        }
        let textWidth = width - (logoWidth > 0 ? logoWidth + 14 : 0)
        var cursor = top
        if let eyebrow, !eyebrow.isEmpty {
            let font = UIFont.systemFont(ofSize: 10.5, weight: .bold)
            let h = min(Self.height(eyebrow, font: font, width: textWidth), 28)
            if drawing { Self.draw(eyebrow, font: font, color: PayeClaimPDFStyle.cyan, in: CGRect(x: left, y: cursor, width: textWidth, height: h)) }
            cursor += h + 3
        }
        let titleFont = UIFont.systemFont(ofSize: titleSize, weight: .bold)
        let titleHeight = min(Self.height(title, font: titleFont, width: textWidth), titleSize * 2.6)
        if drawing { Self.draw(title, font: titleFont, color: PayeClaimPDFStyle.navy, in: CGRect(x: left, y: cursor, width: textWidth, height: titleHeight)) }
        cursor += titleHeight + 2
        if let brandLine, !brandLine.isEmpty {
            let font = UIFont.systemFont(ofSize: 10, weight: .bold)
            if drawing { Self.draw(brandLine, font: font, color: PayeClaimPDFStyle.cyan, in: CGRect(x: left, y: cursor, width: textWidth, height: 14), lines: 1) }
            cursor += 14
        }
        let ruleY = max(cursor, top + logoHeight) + 8
        if drawing {
            PayeClaimPDFStyle.navy.setFill()
            UIRectFill(CGRect(x: left, y: ruleY, width: width, height: 1.6))
        }
        y = ruleY + 12
        let shown = meta.filter { !$0.value.isEmpty }
        guard !shown.isEmpty else { return }
        let count = max(1, columns)
        let gap: CGFloat = 14
        let colWidth = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        let labelFont = UIFont.systemFont(ofSize: 9, weight: .bold)
        let valueFont = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        var index = 0
        while index < shown.count {
            let rowItems = Array(shown[index..<min(index + count, shown.count)])
            let valueHeight = rowItems.map { min(Self.height($0.value, font: valueFont, width: colWidth), 34) }.max() ?? 0
            if drawing {
                for (column, item) in rowItems.enumerated() {
                    let x = left + CGFloat(column) * (colWidth + gap)
                    Self.draw(item.label, font: labelFont, color: PayeClaimPDFStyle.metaLabel, in: CGRect(x: x, y: y, width: colWidth, height: 12), lines: 1)
                    Self.draw(item.value, font: valueFont, color: PayeClaimPDFStyle.navy, in: CGRect(x: x, y: y + 12, width: colWidth, height: valueHeight))
                }
            }
            y += 12 + valueHeight + 10
            index += count
        }
    }
}

/// The report's summary table: columns, row heights and drawing (measuring when the canvas does not draw).
@MainActor
enum PayeClaimReportTable {
    struct Column {
        let width: CGFloat
        let alignment: NSTextAlignment
    }

    static let cellPadding: CGFloat = 8
    static let headerHeight: CGFloat = 24
    static let cellFont = UIFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let dateFont = UIFont.systemFont(ofSize: 10, weight: .bold)
    static let smallFont = UIFont.systemFont(ofSize: 9.5, weight: .medium)
    static let descriptionFont = UIFont.systemFont(ofSize: 9.5)
    static let noteFont = UIFont.systemFont(ofSize: 8.5, weight: .medium)
    static let amountFont = UIFont.systemFont(ofSize: 10.5, weight: .bold)

    /// Fixed widths around a flexible Name column (index 2), the amount right-aligned last.
    static func columns(priceWork: Bool, width: CGFloat) -> [Column] {
        let fixed: [CGFloat] = priceWork ? [104, 72, 0, 96, 82] : [96, 86, 0, 92]
        let name = width - fixed.reduce(0, +)
        return fixed.enumerated().map { index, value in
            Column(width: index == 2 ? name : value, alignment: index == fixed.count - 1 ? .right : .left)
        }
    }

    static func cells(_ row: PayeClaimReportLayout.Row, priceWork: Bool) -> [(String, UIFont, UIColor)] {
        let navy = PayeClaimPDFStyle.navy
        let slate = PayeClaimPDFStyle.slate
        var out: [(String, UIFont, UIColor)] = [
            (row.date, dateFont, navy),
            (row.jobNumber, smallFont, slate),
            (row.name, cellFont, navy),
        ]
        if priceWork { out.append((row.approvedBy, smallFont, slate)) }
        out.append((row.amount, amountFont, navy))
        return out
    }

    /// The description and evidence line span every column but the amount.
    static func spanWidth(_ columns: [Column]) -> CGFloat {
        columns.dropLast().reduce(0) { $0 + $1.width } - cellPadding * 2
    }

    static func rowHeight(_ row: PayeClaimReportLayout.Row, priceWork: Bool, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let cols = columns(priceWork: priceWork, width: width)
        let values = cells(row, priceWork: priceWork)
        var cellHeight: CGFloat = 0
        for (column, cell) in zip(cols, values) {
            cellHeight = max(cellHeight, min(PayeClaimReportCanvas.height(cell.0, font: cell.1, width: column.width - cellPadding * 2), 40))
        }
        var height = 8 + cellHeight
        let span = spanWidth(cols)
        if !row.description.isEmpty {
            height += 3 + PayeClaimReportCanvas.height(row.description, font: descriptionFont, width: span)
        }
        if !row.evidenceNote.isEmpty {
            height += 2 + PayeClaimReportCanvas.height(row.evidenceNote, font: noteFont, width: span)
        }
        return min(height + 8, maxHeight)
    }

    static func drawHeader(_ titles: [String], canvas: PayeClaimReportCanvas, priceWork: Bool) {
        if canvas.drawing {
            let rect = CGRect(x: canvas.left, y: canvas.y, width: canvas.width, height: headerHeight)
            PayeClaimPDFStyle.navy.setFill()
            UIRectFill(rect)
            var x = canvas.left
            let font = UIFont.systemFont(ofSize: 9.5, weight: .bold)
            for (column, title) in zip(columns(priceWork: priceWork, width: canvas.width), titles) {
                PayeClaimReportCanvas.draw(title, font: font, color: .white,
                                           in: CGRect(x: x + cellPadding, y: canvas.y + 7, width: column.width - cellPadding * 2, height: 12),
                                           alignment: column.alignment, lines: 1)
                x += column.width
            }
        }
        canvas.y += headerHeight
    }

    static func drawRow(_ row: PayeClaimReportLayout.Row, height: CGFloat, canvas: PayeClaimReportCanvas, priceWork: Bool) {
        defer { canvas.y += height }
        guard canvas.drawing else { return }
        let top = canvas.y
        PayeClaimPDFStyle.hairline.setFill()
        UIRectFill(CGRect(x: canvas.left, y: top, width: canvas.width, height: 0.8))
        let cols = columns(priceWork: priceWork, width: canvas.width)
        var x = canvas.left
        var cellHeight: CGFloat = 0
        for (column, cell) in zip(cols, cells(row, priceWork: priceWork)) {
            let h = min(PayeClaimReportCanvas.height(cell.0, font: cell.1, width: column.width - cellPadding * 2), 40)
            PayeClaimReportCanvas.draw(cell.0, font: cell.1, color: cell.2,
                                       in: CGRect(x: x + cellPadding, y: top + 8, width: column.width - cellPadding * 2, height: h),
                                       alignment: column.alignment)
            cellHeight = max(cellHeight, h)
            x += column.width
        }
        var cursor = top + 8 + cellHeight
        let span = spanWidth(cols)
        let limit = top + height - 6
        if !row.description.isEmpty {
            cursor += 3
            let h = min(PayeClaimReportCanvas.height(row.description, font: descriptionFont, width: span), max(0, limit - cursor))
            PayeClaimReportCanvas.draw(row.description, font: descriptionFont, color: PayeClaimPDFStyle.slate,
                                       in: CGRect(x: canvas.left + cellPadding, y: cursor, width: span, height: h))
            cursor += h
        }
        if !row.evidenceNote.isEmpty, cursor < limit {
            cursor += 2
            let h = min(PayeClaimReportCanvas.height(row.evidenceNote, font: noteFont, width: span), max(0, limit - cursor))
            PayeClaimReportCanvas.draw(row.evidenceNote, font: noteFont, color: PayeClaimPDFStyle.cyan,
                                       in: CGRect(x: canvas.left + cellPadding, y: cursor, width: span, height: h))
        }
    }
}

/// The price work / expenses report PDF, built from the saved copy (`PayeClaimReportLayout`).
@MainActor
enum PayeClaimReportPDF {
    struct Made {
        var url: URL?
        var notDrawn: Int
    }

    /// What one evidence page shows, decided before drawing so the page count is known.
    private enum EvidenceContent {
        case image(UIImage)
        case pdf(CGPDFDocument, pages: Int)
        case notDrawn
        case unreadable
    }

    static func notice(_ made: Made) -> String {
        guard made.url != nil else { return "The report was saved but the PDF could not be made." }
        return made.notDrawn > 0
            ? "Report ready. \(made.notDrawn) piece(s) of evidence could not be shown in the PDF and are listed instead."
            : "Report ready. Send it to payroll yourself."
    }

    static func makeFile(
        report: PayeClaimReportRecord,
        logo: UIImage?,
        generatedByName: String? = nil,
        readFile: (String) async throws -> Data
    ) async -> Made {
        guard let layout = PayeClaimReportLayout.make(report: report, generatedByName: generatedByName) else {
            return Made(url: nil, notDrawn: 0)
        }
        var files: [String: Data] = [:]
        var unreadable = Set<String>()
        for page in layout.evidencePages where page.drawAs != "listed" && files[page.path] == nil && !unreadable.contains(page.path) {
            do {
                files[page.path] = try await readFile(page.path)
            } catch {
                unreadable.insert(page.path)
            }
        }
        // Same outcomes as before: listed or an undecodable image → not-drawn note; unread or unreadable PDF → note.
        var notDrawn = 0
        let contents: [EvidenceContent] = layout.evidencePages.map { page -> EvidenceContent in
            if page.drawAs == "listed" { notDrawn += 1; return .notDrawn }
            guard let bytes = files[page.path] else { notDrawn += 1; return .unreadable }
            if page.drawAs == "image" {
                if let image = UIImage(data: bytes) { return .image(image) }
                notDrawn += 1
                return .notDrawn
            }
            if let provider = CGDataProvider(data: bytes as CFData),
               let document = CGPDFDocument(provider),
               document.numberOfPages > 0 {
                let pages = (1...document.numberOfPages).filter { document.page(at: $0) != nil }.count
                return .pdf(document, pages: pages)
            }
            notDrawn += 1
            return .unreadable
        }

        // Measuring pass: how many pages the summary takes.
        let measure = PayeClaimReportCanvas(context: nil, totalPages: 0, footerText: layout.footerText)
        drawSummary(layout, logo: logo, canvas: measure)
        let evidencePageCount = contents.reduce(0) { sum, content in
            if case .pdf(_, let pages) = content { return sum + 1 + pages }
            return sum + 1
        }
        let totalPages = measure.pageNumber + evidencePageCount

        let notDrawnNote = CanonicalBusinessEngine.payeClaimText(
            "PAYE_CLAIM_EVIDENCE_NOT_DRAWN_NOTE", fallback: "This file type cannot be shown in the PDF. Open it in the app."
        )
        let unreadableNote = CanonicalBusinessEngine.payeClaimText(
            "PAYE_CLAIM_EVIDENCE_UNREADABLE_NOTE", fallback: "This file could not be read when the report was made. Open it in the app."
        )
        let renderer = UIGraphicsPDFRenderer(bounds: PayeClaimReportCanvas.page)
        let data = renderer.pdfData { context in
            let canvas = PayeClaimReportCanvas(context: context, totalPages: totalPages, footerText: layout.footerText)
            drawSummary(layout, logo: logo, canvas: canvas)
            for (heading, content) in zip(layout.evidencePages, contents) {
                drawEvidencePage(heading, content: content, layout: layout, logo: logo, canvas: canvas,
                                 notDrawnNote: notDrawnNote, unreadableNote: unreadableNote)
            }
        }
        let label = report.kind == PayeClaimKind.priceWork.rawValue ? "price-work" : "expenses"
        let safeName = report.userName.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(safeName.isEmpty ? "report" : safeName)-\(report.rangeStart)-\(report.rangeEnd).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return Made(url: url, notDrawn: notDrawn)
        } catch {
            return Made(url: nil, notDrawn: notDrawn)
        }
    }

    // MARK: Summary

    private static func drawSummary(_ layout: PayeClaimReportLayout, logo: UIImage?, canvas: PayeClaimReportCanvas) {
        canvas.beginPage()
        canvas.headerBlock(
            eyebrow: nil,
            title: layout.documentTitle,
            titleSize: 28,
            brandLine: "Project Planner",
            logo: logo,
            meta: [
                ("COMPANY", layout.companyName),
                ("NAME", layout.personName),
                ("GENERATED", layout.generatedText),
                ("PERIOD", layout.rangeText),
            ],
            columns: 2
        )
        canvas.y += 4
        let priceWork = layout.isPriceWork
        PayeClaimReportTable.drawHeader(layout.columnTitles, canvas: canvas, priceWork: priceWork)
        if layout.rows.isEmpty {
            canvas.y += 8
            canvas.paragraph(layout.emptyMessage, font: .systemFont(ofSize: 11), color: .darkGray)
            canvas.y += 8
        }
        // A row never takes more than a continuation page (top margin plus the repeated table header).
        let fullPage = canvas.bottom - (PayeClaimPDFStyle.margin + PayeClaimReportTable.headerHeight)
        for row in layout.rows {
            let height = PayeClaimReportTable.rowHeight(row, priceWork: priceWork, width: canvas.width, maxHeight: fullPage)
            if canvas.y + height > canvas.bottom {
                canvas.beginPage()
                PayeClaimReportTable.drawHeader(layout.columnTitles, canvas: canvas, priceWork: priceWork)
            }
            PayeClaimReportTable.drawRow(row, height: height, canvas: canvas, priceWork: priceWork)
        }
        if canvas.drawing {
            PayeClaimPDFStyle.hairline.setFill()
            UIRectFill(CGRect(x: canvas.left, y: canvas.y, width: canvas.width, height: 0.8))
        }
        canvas.y += 14
        // Counts and total stay together.
        let countsHeight: CGFloat = 46
        let totalHeight: CGFloat = 46
        if canvas.y + countsHeight + 10 + totalHeight > canvas.bottom {
            canvas.beginPage()
        }
        drawCounts(layout, canvas: canvas, height: countsHeight)
        canvas.y += 10
        drawTotal(layout, canvas: canvas, height: totalHeight)
    }

    private static func drawCounts(_ layout: PayeClaimReportLayout, canvas: PayeClaimReportCanvas, height: CGFloat) {
        defer { canvas.y += height }
        guard canvas.drawing else { return }
        let cells = [("ITEMS", "\(layout.itemCount)"), ("EVIDENCE", "\(layout.evidenceCount)")]
        let gap: CGFloat = 10
        let cellWidth = (canvas.width - gap) / 2
        for (index, cell) in cells.enumerated() {
            let rect = CGRect(x: canvas.left + CGFloat(index) * (cellWidth + gap), y: canvas.y, width: cellWidth, height: height)
            PayeClaimPDFStyle.panel.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()
            PayeClaimReportCanvas.draw(cell.0, font: .systemFont(ofSize: 9, weight: .bold), color: PayeClaimPDFStyle.metaLabel,
                                       in: CGRect(x: rect.minX + 14, y: rect.minY + 8, width: rect.width - 28, height: 12), lines: 1)
            PayeClaimReportCanvas.draw(cell.1, font: .systemFont(ofSize: 15, weight: .bold), color: PayeClaimPDFStyle.navy,
                                       in: CGRect(x: rect.minX + 14, y: rect.minY + 21, width: rect.width - 28, height: 20), lines: 1)
        }
    }

    /// The invoice's gradient total box.
    private static func drawTotal(_ layout: PayeClaimReportLayout, canvas: PayeClaimReportCanvas, height: CGFloat) {
        defer { canvas.y += height }
        guard canvas.drawing else { return }
        let box = CGRect(x: canvas.left, y: canvas.y, width: canvas.width, height: height)
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [PayeClaimPDFStyle.totalStart.cgColor, PayeClaimPDFStyle.totalEnd.cgColor] as CFArray,
            locations: [0, 1]
        )
        if let cg = UIGraphicsGetCurrentContext(), let gradient {
            cg.saveGState()
            UIBezierPath(roundedRect: box, cornerRadius: 12).addClip()
            cg.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.midY), end: CGPoint(x: box.maxX, y: box.midY), options: [])
            cg.restoreGState()
        }
        let amountWidth = box.width * 0.5
        PayeClaimReportCanvas.draw(layout.totalLabel, font: .systemFont(ofSize: 11, weight: .medium), color: PayeClaimPDFStyle.totalLabel,
                                   in: CGRect(x: box.minX + 14, y: box.minY + 16, width: box.width - amountWidth - 28, height: 16), lines: 1)
        PayeClaimReportCanvas.draw(layout.totalAmount, font: .systemFont(ofSize: 20, weight: .bold), color: .white,
                                   in: CGRect(x: box.maxX - 14 - amountWidth, y: box.minY + 11, width: amountWidth, height: 26),
                                   alignment: .right, lines: 1)
    }

    // MARK: Evidence pages

    private static func drawEvidencePage(
        _ heading: PayeClaimReportLayout.EvidenceHeading,
        content: EvidenceContent,
        layout: PayeClaimReportLayout,
        logo: UIImage?,
        canvas: PayeClaimReportCanvas,
        notDrawnNote: String,
        unreadableNote: String
    ) {
        canvas.beginPage()
        var meta: [(label: String, value: String)] = [
            ("DATE", heading.date),
            ("JOB NUMBER", heading.jobNumber),
            ("AMOUNT", heading.amount),
        ]
        if layout.isPriceWork { meta.append((label: "APPROVED BY", value: heading.approvedBy)) }
        canvas.headerBlock(
            eyebrow: heading.evidenceTitle,
            title: heading.itemName,
            titleSize: 22,
            brandLine: nil,
            logo: logo,
            meta: meta,
            columns: layout.isPriceWork ? 4 : 3
        )
        for note in heading.notes {
            canvas.paragraph(note, font: .systemFont(ofSize: 10), color: PayeClaimPDFStyle.slate, maxHeight: 90)
            canvas.y += 4
        }
        canvas.y += 8
        switch content {
        case .image(let image):
            drawImage(image, canvas: canvas)
        case .pdf(let document, let pages):
            canvas.paragraph(pages == 1 ? "The file's page follows." : "The file's \(pages) pages follow.",
                             font: .systemFont(ofSize: 10, weight: .medium), color: PayeClaimPDFStyle.slate)
            canvas.append(document)
        case .notDrawn:
            drawNote(notDrawnNote, canvas: canvas)
        case .unreadable:
            drawNote(unreadableNote, canvas: canvas)
        }
    }

    /// The image as large as fits the rest of the page, centred, with a hairline frame.
    private static func drawImage(_ image: UIImage, canvas: PayeClaimReportCanvas) {
        guard canvas.drawing, image.size.width > 0, image.size.height > 0 else { return }
        let room = CGRect(x: canvas.left, y: canvas.y, width: canvas.width, height: max(0, canvas.bottom - canvas.y - 6))
        guard room.height > 20 else { return }
        let scale = min(room.width / image.size.width, room.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: room.midX - size.width / 2, y: room.minY, width: size.width, height: size.height)
        image.draw(in: rect)
        PayeClaimPDFStyle.hairline.setStroke()
        let frame = UIBezierPath(rect: rect)
        frame.lineWidth = 0.8
        frame.stroke()
        canvas.y = rect.maxY + 8
    }

    private static func drawNote(_ text: String, canvas: PayeClaimReportCanvas) {
        let font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
        let inner = canvas.width - 28
        let height = PayeClaimReportCanvas.height(text, font: font, width: inner) + 24
        if canvas.drawing {
            let rect = CGRect(x: canvas.left, y: canvas.y, width: canvas.width, height: height)
            PayeClaimPDFStyle.warnFill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()
            PayeClaimReportCanvas.draw(text, font: font, color: PayeClaimPDFStyle.warn,
                                       in: CGRect(x: rect.minX + 14, y: rect.minY + 12, width: inner, height: height - 24))
        }
        canvas.y += height
    }
}
