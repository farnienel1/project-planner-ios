//
//  WeeklyReportExportBuilder.swift
//  Project Planner
//
//  Generates styled Weekly Report .xlsx and .pdf exports.
//

import UIKit

enum WeeklyReportExportBuilder {
    enum SectionStyle: Sendable {
        case standard
        /// Unactioned clashes / missed bookings — red banner at top of report.
        case critical
    }

    struct Section {
        let title: String
        let headers: [String]
        let rows: [[String]]
        let totalRow: [String]?
        let style: SectionStyle
        let bannerNote: String?

        init(
            title: String,
            headers: [String],
            rows: [[String]],
            totalRow: [String]?,
            style: SectionStyle = .standard,
            bannerNote: String? = nil
        ) {
            self.title = title
            self.headers = headers
            self.rows = rows
            self.totalRow = totalRow
            self.style = style
            self.bannerNote = bannerNote
        }
    }

    struct Context {
        let organizationName: String
        let periodStart: Date
        let periodEnd: Date
        let invoicingPeriodLabel: String?
        let logoImage: UIImage?
        let sections: [Section]
    }

    struct ExportURLs {
        let xlsx: URL
        let pdf: URL
    }

    static func makeExports(context: Context) throws -> ExportURLs {
        let stamp = Int(Date().timeIntervalSince1970)
        let base = FileManager.default.temporaryDirectory
        let xlsxURL = base.appendingPathComponent("WeeklyReport-\(stamp).xlsx")
        let pdfURL = base.appendingPathComponent("WeeklyReport-\(stamp).pdf")
        try writeXLSX(context: context, to: xlsxURL)
        guard let pdf = makePDF(context: context) else {
            throw NSError(domain: "WeeklyReportExportBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to generate PDF",
            ])
        }
        try pdf.write(to: pdfURL, options: .atomic)
        return ExportURLs(xlsx: xlsxURL, pdf: pdfURL)
    }

    // MARK: - XLSX

    private static func writeXLSX(context: Context, to url: URL) throws {
        var rows: [[String]] = []
        rows.append(["⬛ PROJECT PLANNER", "", "", "", "WEEKLY REPORT", "", "", ""])
        rows.append(["", "", "", "", "Period:  \(formatPeriod(context.periodStart, context.periodEnd))", "", "", ""])
        if let invoicing = context.invoicingPeriodLabel, !invoicing.isEmpty {
            rows.append(["", "", "", "", "Invoicing period: \(invoicing)", "", "", ""])
        }
        rows.append([""])

        for section in context.sections {
            if section.style == .critical {
                rows.append(["⚠ UNACTIONED WARNINGS — ACTION REQUIRED", "", "", "", "", "", "", ""])
                if let note = section.bannerNote, !note.isEmpty {
                    rows.append([note, "", "", "", "", "", "", ""])
                }
            }
            rows.append([section.title, "", "", "", "", "", "", ""])
            rows.append(section.headers)
            if section.rows.isEmpty {
                rows.append(Array(repeating: "", count: max(section.headers.count, 1)))
            } else {
                rows.append(contentsOf: section.rows)
            }
            if let totalRow = section.totalRow {
                rows.append(totalRow)
            }
            rows.append([""])
        }

        let sheetXML = worksheetXML(rows: rows)
        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Weekly Report" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """

        try SimpleZipWriter.writeArchive(
            entries: [
                "[Content_Types].xml": Data(contentTypes.utf8),
                "_rels/.rels": Data(rootRels.utf8),
                "xl/workbook.xml": Data(workbookXML.utf8),
                "xl/_rels/workbook.xml.rels": Data(relsXML.utf8),
                "xl/worksheets/sheet1.xml": Data(sheetXML.utf8),
            ],
            to: url
        )
    }

    private static func worksheetXML(rows: [[String]]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
        """
        for (rowIndex, row) in rows.enumerated() {
            xml += "<row r=\"\(rowIndex + 1)\">"
            for (colIndex, value) in row.enumerated() {
                let cellRef = columnName(colIndex + 1) + "\(rowIndex + 1)"
                let escaped = escapeXML(value)
                if value.isEmpty {
                    xml += "<c r=\"\(cellRef)\"/>"
                } else {
                    xml += "<c r=\"\(cellRef)\" t=\"inlineStr\"><is><t>\(escaped)</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += """
          </sheetData>
        </worksheet>
        """
        return xml
    }

    private static func columnName(_ index: Int) -> String {
        var n = index
        var name = ""
        while n > 0 {
            let rem = (n - 1) % 26
            name = String(UnicodeScalar(65 + rem)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - PDF

    static func makePDF(context: Context) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let margin: CGFloat = 28
        let contentWidth = pageRect.width - margin * 2
        let navy = UIColor(red: 0.043, green: 0.071, blue: 0.125, alpha: 1)
        let cyan = UIColor(red: 0.055, green: 0.647, blue: 0.914, alpha: 1)
        let slate = UIColor(red: 0.392, green: 0.455, blue: 0.545, alpha: 1)
        let criticalRed = UIColor(red: 0.72, green: 0.11, blue: 0.11, alpha: 1)
        let criticalFill = UIColor(red: 1.0, green: 0.92, blue: 0.92, alpha: 1)

        return renderer.pdfData { pdf in
            pdf.beginPage()
            var y = drawPDFHeader(
                context: context,
                pdf: pdf,
                originY: margin,
                margin: margin,
                contentWidth: contentWidth,
                pageRect: pageRect,
                navy: navy,
                cyan: cyan
            )

            if let invoicing = context.invoicingPeriodLabel, !invoicing.isEmpty {
                y += 8
                y = drawLabelValue(
                    label: "INVOICING PERIOD",
                    value: invoicing,
                    at: CGPoint(x: margin, y: y),
                    width: contentWidth,
                    labelColor: slate,
                    valueColor: navy
                )
                y += 8
            }

            for section in context.sections {
                if y > pageRect.height - 120 {
                    pdf.beginPage()
                    y = margin
                }
                y = drawSection(
                    section: section,
                    pdf: pdf,
                    startY: y + 10,
                    margin: margin,
                    contentWidth: contentWidth,
                    pageRect: pageRect,
                    navy: navy,
                    slate: slate,
                    criticalRed: criticalRed,
                    criticalFill: criticalFill
                )
            }
        }
    }

    private static func drawPDFHeader(
        context: Context,
        pdf: UIGraphicsPDFRendererContext,
        originY: CGFloat,
        margin: CGFloat,
        contentWidth: CGFloat,
        pageRect: CGRect,
        navy: UIColor,
        cyan: UIColor
    ) -> CGFloat {
        let headerHeight: CGFloat = 72
        let headerRect = CGRect(x: margin, y: originY, width: contentWidth, height: headerHeight)
        let path = UIBezierPath(roundedRect: headerRect, cornerRadius: 12)
        navy.setFill()
        path.fill()

        if let logo = context.logoImage {
            let logoBox = CGRect(x: headerRect.maxX - 68, y: headerRect.minY + 10, width: 56, height: 52)
            drawAspectFit(image: logo, in: logoBox)
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .black),
            .foregroundColor: UIColor.white,
        ]
        ("PROJECT" as NSString).draw(at: CGPoint(x: headerRect.minX + 14, y: headerRect.minY + 14), withAttributes: titleAttrs)
        var plannerAttrs = titleAttrs
        plannerAttrs[.foregroundColor] = cyan
        (" PLANNER" as NSString).draw(at: CGPoint(x: headerRect.minX + 14 + ("PROJECT" as NSString).size(withAttributes: titleAttrs).width - 4, y: headerRect.minY + 14), withAttributes: plannerAttrs)

        (context.organizationName as NSString).draw(
            at: CGPoint(x: headerRect.minX + 14, y: headerRect.minY + 34),
            withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.55)]
        )

        let weeklyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .heavy),
            .foregroundColor: cyan,
        ]
        ("WEEKLY REPORT" as NSString).draw(
            at: CGPoint(x: headerRect.minX + 14, y: headerRect.minY + 50),
            withAttributes: weeklyAttrs
        )

        let period = "Period: \(formatPeriod(context.periodStart, context.periodEnd))"
        (period as NSString).draw(
            at: CGPoint(x: headerRect.minX + 14, y: headerRect.maxY + 10),
            withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: navy]
        )

        return headerRect.maxY + 28
    }

    private static func drawLabelValue(
        label: String,
        value: String,
        at origin: CGPoint,
        width: CGFloat,
        labelColor: UIColor,
        valueColor: UIColor
    ) -> CGFloat {
        (label as NSString).draw(at: origin, withAttributes: [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: labelColor,
        ])
        (value as NSString).draw(
            in: CGRect(x: origin.x, y: origin.y + 14, width: width, height: 36),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: valueColor,
            ]
        )
        return origin.y + 44
    }

    private static func drawSection(
        section: Section,
        pdf: UIGraphicsPDFRendererContext,
        startY: CGFloat,
        margin: CGFloat,
        contentWidth: CGFloat,
        pageRect: CGRect,
        navy: UIColor,
        slate: UIColor,
        criticalRed: UIColor,
        criticalFill: UIColor
    ) -> CGFloat {
        var y = startY
        let isCritical = section.style == .critical
        let titleColor = isCritical ? criticalRed : navy
        let headerFill = isCritical ? criticalRed : navy

        if isCritical {
            let bannerHeight: CGFloat = section.bannerNote == nil ? 36 : 58
            let bannerRect = CGRect(x: margin, y: y, width: contentWidth, height: bannerHeight)
            let path = UIBezierPath(roundedRect: bannerRect, cornerRadius: 8)
            criticalFill.setFill()
            path.fill()
            criticalRed.setStroke()
            path.lineWidth = 1.5
            path.stroke()

            ("⚠ UNACTIONED WARNINGS — ACTION REQUIRED" as NSString).draw(
                at: CGPoint(x: margin + 10, y: y + 8),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
                    .foregroundColor: criticalRed,
                ]
            )
            if let note = section.bannerNote, !note.isEmpty {
                (note as NSString).draw(
                    in: CGRect(x: margin + 10, y: y + 26, width: contentWidth - 20, height: 28),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 8.5, weight: .medium),
                        .foregroundColor: criticalRed.withAlphaComponent(0.9),
                    ]
                )
            }
            y += bannerHeight + 10
        }

        (section.title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: titleColor,
        ])
        y += 18

        let headerRect = CGRect(x: margin, y: y, width: contentWidth, height: 20)
        headerFill.setFill()
        UIRectFill(headerRect)
        let colWidth = contentWidth / CGFloat(max(section.headers.count, 1))
        for (index, header) in section.headers.enumerated() {
            (header as NSString).draw(
                in: CGRect(x: margin + CGFloat(index) * colWidth + 4, y: y + 4, width: colWidth - 6, height: 14),
                withAttributes: [.font: UIFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: UIColor.white]
            )
        }
        y += 22

        let dataRows = section.rows.isEmpty ? [Array(repeating: "—", count: section.headers.count)] : section.rows
        for row in dataRows {
            if y > pageRect.height - 60 {
                pdf.beginPage()
                y = margin
            }
            if isCritical {
                criticalFill.setFill()
                UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 30))
            }
            UIColor(white: 0.94, alpha: 1).setFill()
            UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 0.6))
            let cellColor = isCritical ? criticalRed : slate
            for (index, cell) in row.enumerated() {
                (cell as NSString).draw(
                    in: CGRect(x: margin + CGFloat(index) * colWidth + 4, y: y + 4, width: colWidth - 6, height: 28),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 8.5, weight: isCritical ? .semibold : .regular),
                        .foregroundColor: cellColor,
                    ]
                )
            }
            y += 30
        }

        if let totalRow = section.totalRow {
            for (index, cell) in totalRow.enumerated() where !cell.isEmpty {
                (cell as NSString).draw(
                    in: CGRect(x: margin + CGFloat(index) * colWidth + 4, y: y + 2, width: colWidth - 6, height: 16),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: navy]
                )
            }
            y += 20
        }
        return y
    }

    private static func drawAspectFit(image: UIImage, in rect: CGRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
    }

    private static func formatPeriod(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}
