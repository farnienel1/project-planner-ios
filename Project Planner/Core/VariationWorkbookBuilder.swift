//
//  VariationWorkbookBuilder.swift
//  Project Planner
//
//  RULEBOOK 1.52.0 §22 (owner decision 15 Nov: Excel replaces the CSV): the variations workbook. The rows come from
//  the rulebook (`CanonicalBusinessEngine.variationExportRows`, file name `variationExportFileName`); this file only
//  draws them as a plain .xlsx (Office Open XML, `SimpleZipWriter`), the same parts as web
//  `lib/variations/variationWorkbook.ts`: sheet 1 "Variations" (header block, one row per variation, a totals row,
//  the company logo as a drawing part), sheet 2 "Line items". Money cells use the currency number format; every text
//  cell is an inline string (a value that starts with = + - @ is never read as a formula).
//

import Foundation
import UIKit

enum VariationWorkbookBuilder {
    struct Input {
        /// `Variation.rulebookInput` of every stored variation (the rule leaves deleted ones out).
        var variations: [[String: Any]]
        var companyName: String
        var jobNumber: String
        var jobName: String
        var generatedBy: String
        var timeZone: String
        var currency: String
        var includeCost: Bool
        var logoURL: String?
    }

    struct Logo {
        let bytes: Data
        let type: String
        let width: Int
        let height: Int
    }

    enum BuildError: LocalizedError {
        case noRows
        var errorDescription: String? { "The variations could not be prepared. Please try again." }
    }

    /// Writes the workbook to a temporary file and returns its URL.
    static func writeFile(_ input: Input) async throws -> URL {
        guard let rows = CanonicalBusinessEngine.variationExportRows(
            input.variations,
            timeZone: input.timeZone,
            currency: input.currency,
            includeCost: input.includeCost
        ) else {
            throw BuildError.noRows
        }
        let logo = await loadLogo(input.logoURL)
        let entries = workbookEntries(rows: rows, input: input, generatedAt: generatedAtText(timeZone: input.timeZone), logo: logo)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(CanonicalBusinessEngine.variationExportFileName(jobNumber: input.jobNumber))
        try? FileManager.default.removeItem(at: url)
        try SimpleZipWriter.writeArchive(entries: entries, to: url)
        return url
    }

    /// "15 Nov 2026, 14:05" in the organisation zone (display only).
    static func generatedAtText(timeZone: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: timeZone) ?? OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: now)
    }

    // MARK: - Parts

    private enum Style {
        static let text = 0, bold = 1, header = 2, title = 3, money = 4, number = 5, moneyBold = 6, numberBold = 7, wrap = 8, muted = 9
    }

    private struct Cell {
        var value: RulebookVariationExportCell
        var style: Int = 0

        static func text(_ value: String, _ style: Int = 0) -> Cell {
            Cell(value: value.isEmpty ? .empty : .text(value), style: style)
        }
    }

    private static let numberKeys: Set<String> = ["labourHours", "materialLines", "evidenceCount", "quantity", "hours"]
    private static let wrapKeys: Set<String> = ["description", "heading", "previousNumbers"]

    private static func style(for key: String, value: RulebookVariationExportCell, costKeys: Set<String>) -> Int {
        if case .number = value {
            if costKeys.contains(key) { return Style.money }
            return numberKeys.contains(key) ? Style.number : Style.text
        }
        return wrapKeys.contains(key) ? Style.wrap : Style.text
    }

    /// The zip entries of the .xlsx (internal for tests).
    static func workbookEntries(rows: RulebookVariationExport, input: Input, generatedAt: String, logo: Logo?) -> [String: Data] {
        let costKeys = rows.costKeys
        let summaryColumns = rows.summaryColumns.filter { rows.includeCost || !costKeys.contains($0.key) }
        let lineColumns = rows.lineColumns.filter { rows.includeCost || !costKeys.contains($0.key) }
        let job = [input.jobNumber, input.jobName].filter { !$0.isEmpty }.joined(separator: " · ")
        let generated = [generatedAt, input.generatedBy.isEmpty ? "" : "by \(input.generatedBy)"].filter { !$0.isEmpty }.joined(separator: " ")
        let header: [[Cell]] = [
            [.text("Variations", Style.title)],
            [.text("Company", Style.bold), .text(input.companyName)],
            [.text("Job", Style.bold), .text(job)],
            [.text("Generated", Style.bold), .text(generated)],
            [],
        ]
        let summaryHead = summaryColumns.map { Cell.text($0.label, Style.header) }
        let summaryBody: [[Cell]] = rows.summaryRows.map { row in
            summaryColumns.map { column in
                let value = row[column.key] ?? .empty
                return Cell(value: value, style: style(for: column.key, value: value, costKeys: costKeys))
            }
        }
        let count: Int = {
            if case .number(let value) = rows.summaryTotals["count"] ?? .empty { return Int(value) }
            return 0
        }()
        var totalsRow: [Cell] = []
        for (index, column) in summaryColumns.enumerated() {
            if index == 0 {
                totalsRow.append(.text("Totals (\(count))", Style.bold))
                continue
            }
            let value = rows.summaryTotals[column.key] ?? .empty
            if case .number = value {
                totalsRow.append(Cell(value: value, style: costKeys.contains(column.key) ? Style.moneyBold : Style.numberBold))
            } else {
                totalsRow.append(Cell(value: .empty, style: Style.numberBold))
            }
        }
        let firstTableRow = header.count + 1
        let sheet1 = sheetXML(
            rows: header + [summaryHead] + summaryBody + [totalsRow],
            widths: summaryColumns.map { key -> Int in
                switch key.key {
                case "description": return 48
                case "heading": return 32
                case "previousNumbers": return 22
                case "raisedBy": return 20
                default: return 14
                }
            },
            freezeRow: firstTableRow,
            drawing: logo != nil,
            autoFilter: summaryBody.isEmpty ? nil : "A\(firstTableRow):\(columnName(summaryColumns.count - 1))\(firstTableRow + summaryBody.count)"
        )
        let lineHead = lineColumns.map { Cell.text($0.label, Style.header) }
        let lineBody: [[Cell]] = rows.lineRows.map { row in
            lineColumns.map { column in
                let value = row[column.key] ?? .empty
                return Cell(value: value, style: style(for: column.key, value: value, costKeys: costKeys))
            }
        }
        let sheet2 = sheetXML(
            rows: [[.text("Line items", Style.title)], [.text(job, Style.muted)], [], lineHead] + lineBody,
            widths: lineColumns.map { key -> Int in
                switch key.key {
                case "description": return 44
                case "subcontractor": return 24
                case "type": return 15
                default: return 12
                }
            },
            freezeRow: 4,
            drawing: false,
            autoFilter: lineBody.isEmpty ? nil : "A4:\(columnName(lineColumns.count - 1))\(4 + lineBody.count)"
        )
        var definedNames = ""
        if !summaryBody.isEmpty || !lineBody.isEmpty {
            definedNames += "<definedNames>"
            if !summaryBody.isEmpty {
                definedNames += "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">Variations!$A$\(firstTableRow):$\(columnName(summaryColumns.count - 1))$\(firstTableRow + summaryBody.count)</definedName>"
            }
            if !lineBody.isEmpty {
                definedNames += "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"1\" hidden=\"1\">'Line items'!$A$4:$\(columnName(lineColumns.count - 1))$\(4 + lineBody.count)</definedName>"
            }
            definedNames += "</definedNames>"
        }
        let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var contentTypes = xmlHead
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            + "<Override PartName=\"/xl/worksheets/sheet2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        if logo != nil {
            contentTypes += "<Override PartName=\"/xl/drawings/drawing1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
        }
        contentTypes += "</Types>"
        var entries: [String: Data] = [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data((xmlHead + "<Relationships xmlns=\"\(relNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(officeRel)/officeDocument\" Target=\"xl/workbook.xml\"/>"
                + "</Relationships>").utf8),
            "xl/workbook.xml": Data((xmlHead
                + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(officeRel)\">"
                + "<sheets><sheet name=\"Variations\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Line items\" sheetId=\"2\" r:id=\"rId2\"/></sheets>"
                + definedNames
                + "</workbook>").utf8),
            "xl/_rels/workbook.xml.rels": Data((xmlHead + "<Relationships xmlns=\"\(relNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(officeRel)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(officeRel)/worksheet\" Target=\"worksheets/sheet2.xml\"/>"
                + "<Relationship Id=\"rId3\" Type=\"\(officeRel)/styles\" Target=\"styles.xml\"/>"
                + "</Relationships>").utf8),
            "xl/styles.xml": Data(stylesXML(currency: rows.currency).utf8),
            "xl/worksheets/sheet1.xml": Data(sheet1.utf8),
            "xl/worksheets/sheet2.xml": Data(sheet2.utf8),
        ]
        if let logo {
            let media = "image1.\(logo.type)"
            entries["xl/worksheets/_rels/sheet1.xml.rels"] = Data((xmlHead + "<Relationships xmlns=\"\(relNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(officeRel)/drawing\" Target=\"../drawings/drawing1.xml\"/>"
                + "</Relationships>").utf8)
            entries["xl/drawings/drawing1.xml"] = Data(drawingXML(logo: logo, columnIndex: max(3, summaryColumns.count - 3)).utf8)
            entries["xl/drawings/_rels/drawing1.xml.rels"] = Data((xmlHead + "<Relationships xmlns=\"\(relNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(officeRel)/image\" Target=\"../media/\(media)\"/>"
                + "</Relationships>").utf8)
            entries["xl/media/\(media)"] = logo.bytes
        }
        return entries
    }

    private static func escapeXML(_ value: String) -> String {
        // Characters XML 1.0 cannot hold are dropped.
        let kept = value.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF)
        }
        return String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let rem = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + rem))) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func cellXML(_ ref: String, _ cell: Cell) -> String {
        let s = cell.style != 0 ? " s=\"\(cell.style)\"" : ""
        switch cell.value {
        case .empty:
            return cell.style != 0 ? "<c r=\"\(ref)\"\(s)/>" : ""
        case .number(let value):
            guard value.isFinite else { return "" }
            return "<c r=\"\(ref)\"\(s)><v>\(numberText(value))</v></c>"
        case .text(let text):
            return "<c r=\"\(ref)\"\(s) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXML(text))</t></is></c>"
        }
    }

    private static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    private static func sheetXML(rows: [[Cell]], widths: [Int], freezeRow: Int, drawing: Bool, autoFilter: String?) -> String {
        let cols = widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>" }.joined()
        var body = ""
        for (r, row) in rows.enumerated() {
            body += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() {
                body += cellXML("\(columnName(c))\(r + 1)", cell)
            }
            body += "</row>"
        }
        let pane = "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"\(freezeRow)\" topLeftCell=\"A\(freezeRow + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + pane
            + "<cols>\(cols)</cols><sheetData>\(body)</sheetData>"
            + (autoFilter.map { "<autoFilter ref=\"\($0)\"/>" } ?? "")
            + (drawing ? "<drawing r:id=\"rId1\"/>" : "")
            + "</worksheet>"
    }

    private static func stylesXML(currency: String) -> String {
        let symbol = OrgMoney.symbol(currencyCode: currency).replacingOccurrences(of: "\"", with: "")
        let moneyFormat = escapeXML("\"\(symbol)\"#,##0.00")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"\(moneyFormat)\"/><numFmt numFmtId=\"165\" formatCode=\"#,##0.##\"/></numFmts>"
            + "<fonts count=\"5\">"
            + "<font><sz val=\"11\"/><name val=\"Calibri\"/></font>"
            + "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font>"
            + "<font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font>"
            + "<font><b/><sz val=\"16\"/><color rgb=\"FF0C2350\"/><name val=\"Calibri\"/></font>"
            + "<font><sz val=\"10\"/><color rgb=\"FF5B6475\"/><name val=\"Calibri\"/></font>"
            + "</fonts>"
            + "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
            + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF0C2350\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>"
            + "<borders count=\"2\"><border><left/><right/><top/><bottom/><diagonal/></border>"
            + "<border><left/><right/><top style=\"thin\"><color rgb=\"FF0C2350\"/></top><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"10\">"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"><alignment vertical=\"top\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"><alignment vertical=\"top\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"><alignment vertical=\"center\" wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"3\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
            + "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"><alignment vertical=\"top\"/></xf>"
            + "<xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"><alignment vertical=\"top\"/></xf>"
            + "<xf numFmtId=\"164\" fontId=\"1\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyBorder=\"1\"/>"
            + "<xf numFmtId=\"165\" fontId=\"1\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyBorder=\"1\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"4\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
            + "</cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            + "</styleSheet>"
    }

    /// Pixel size → EMU (Excel drawings: 9525 EMU per pixel).
    private static func drawingXML(logo: Logo, columnIndex: Int) -> String {
        let scale = min(180 / Double(logo.width), 60 / Double(logo.height), 1)
        let cx = Int((Double(logo.width) * scale * 9525).rounded())
        let cy = Int((Double(logo.height) * scale * 9525).rounded())
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<xdr:oneCellAnchor><xdr:from><xdr:col>\(columnIndex)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"
            + "<xdr:ext cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"2\" name=\"Company logo\" descr=\"Company logo\"/><xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr>"
            + "<xdr:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>"
            + "<xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>"
            + "<xdr:clientData/></xdr:oneCellAnchor></xdr:wsDr>"
    }

    // MARK: - Logo

    /// The company logo as PNG or JPEG bytes with its size; nil when there is none or it cannot be read (the file is
    /// then made without a logo). Any other image type is redrawn as PNG.
    static func loadLogo(_ urlText: String?) async -> Logo? {
        guard let urlText, let url = CanonicalBusinessEngine.safeExternalURL(urlText),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return logo(from: data)
    }

    static func logo(from data: Data) -> Logo? {
        if let size = CanonicalBusinessEngine.imageDimensionsFromHeader(data) {
            let bytes = [UInt8](data.prefix(4))
            if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
                return Logo(bytes: data, type: "png", width: size.width, height: size.height)
            }
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 {
                return Logo(bytes: data, type: "jpeg", width: size.width, height: size.height)
            }
        }
        guard let image = UIImage(data: data), let png = image.pngData(),
              image.size.width > 0, image.size.height > 0 else { return nil }
        return Logo(bytes: png, type: "png", width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
    }
}
