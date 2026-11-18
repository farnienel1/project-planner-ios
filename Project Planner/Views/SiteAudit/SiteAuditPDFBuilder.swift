//
//  SiteAuditPDFBuilder.swift
//  Project Planner
//
//  RULEBOOK 1.68.0 §29 (owner decision 17 Nov): the site audit PDF is laid out by the rulebook
//  (`siteAuditReportLayout`) and this file only draws its ops, so the iPhone PDF is the same as web's:
//  the same fields, labels, order, wrapped lines, card heights, page breaks, photo boxes and "Page n of N".
//  Before 1.68.0 cards had a fixed height (annotations fell outside the border), photos were squeezed into a
//  200 × 118 box and every footer read "Page n of n".
//

import UIKit

enum SiteAuditPDFBuilder {
    struct Context {
        let audit: SiteAudit
        let localItems: [SiteAuditDraftItem]
        let organizationName: String?
        var organizationAbbreviation: String? = nil
        let logoImage: UIImage?
        let clientName: String?
        let siteAddress: String?
    }

    /// The job as the report reads it (`siteAuditReportInput`): its client and address lines. Built on the caller's
    /// actor, so the off-main PDF work only gets plain text.
    static func job(for project: Project?) -> [String: String]? {
        guard let project else { return nil }
        return [
            "clientName": project.client.name,
            "addressLine1": project.addressLine1,
            "addressLine2": project.addressLine2 ?? "",
            "townCity": project.townCity,
            "postcode": project.postcode,
        ]
    }

    /// Generates the PDF off the main thread so submit does not freeze with many photos.
    static func makePDFAsync(
        audit: SiteAudit,
        localItems: [SiteAuditDraftItem],
        organizationName: String?,
        organizationAbbreviation: String? = nil,
        logoImage: UIImage?,
        job: [String: String]? = nil
    ) async -> URL? {
        let auditCopy = audit
        let itemsCopy = localItems
        let orgName = organizationName
        let logo = logoImage
        let jobCopy = job
        // Read on the caller's actor; the detached task must not touch main-actor state.
        let timeZone = OrganizationRulebookContext.timeZoneIdentifier
        let typeText = audit.storedTypeText
        return await Task.detached(priority: .userInitiated) {
            makePDF(
                audit: auditCopy,
                localItems: itemsCopy,
                organizationName: orgName,
                logoImage: logo,
                job: jobCopy,
                timeZone: timeZone,
                typeText: typeText
            )
        }.value
    }

    /// `organizationAbbreviation` is kept for callers but no longer used: the badge text is the rulebook's
    /// (`siteAuditReportLayout`, initials of the organisation name), the same as web.
    nonisolated static func makePDF(
        audit: SiteAudit,
        localItems: [SiteAuditDraftItem],
        organizationName: String?,
        organizationAbbreviation: String? = nil,
        logoImage: UIImage?,
        job: [String: String]? = nil,
        timeZone: String,
        typeText: String? = nil
    ) -> URL? {
        var images: [String: UIImage] = [:]
        var photos: [String: Any] = [:]
        var itemInputs: [[String: Any]] = []
        for item in audit.items {
            let ref = item.id.uuidString
            var row: [String: Any] = [
                "id": ref,
                "title": item.title,
                "location": item.location,
                "assignee": item.assignee,
                "comments": item.comments,
                "annotations": item.annotations,
                "imageURL": item.imageURL ?? "",
                "createdAtMs": milliseconds(item.createdAt)
            ]
            if let captured = item.imageCapturedAt { row["imageCapturedAtMs"] = milliseconds(captured) }
            if let raw = localItems.first(where: { $0.id == item.id })?.image {
                let prepared = autoreleasepool { SiteAuditMediaProcessor.preparedForPDF(raw) }
                images[ref] = prepared
                photos[ref] = ["width": Double(prepared.size.width), "height": Double(prepared.size.height)]
            }
            itemInputs.append(row)
        }
        var args: [String: Any] = [
            "timeZone": timeZone,
            "photos": photos,
            "audit": [
                "id": audit.id.uuidString,
                "projectJobNumber": audit.projectJobNumber,
                "projectName": audit.projectName,
                "type": typeText ?? audit.type.rawValue,
                "customTitle": audit.customTitle,
                "authorName": audit.authorName,
                "dateMs": milliseconds(audit.date),
                "createdAtMs": milliseconds(audit.createdAt),
                "items": itemInputs
            ] as [String: Any]
        ]
        if let organizationName { args["organizationName"] = organizationName }
        if let job { args["job"] = job }
        if let logoImage {
            let prepared = autoreleasepool { compressedImage(logoImage, maxWidth: 400) } ?? logoImage
            images["logo"] = prepared
            args["logo"] = ["width": Double(prepared.size.width), "height": Double(prepared.size.height)]
        }
        // RULEBOOK 1.68.0 §29: the input is composed by the rulebook (`siteAuditReportInput`), as on web.
        guard let input = CanonicalBusinessEngine.siteAuditReportInput(args) else {
            print("PDF generation error: the rulebook did not compose the site audit report")
            return nil
        }

        guard let layout = CanonicalBusinessEngine.siteAuditReportLayout(input) else {
            print("PDF generation error: the rulebook did not lay out the site audit report")
            return nil
        }
        let fileName = (layout["fileName"] as? String) ?? "SiteAudit.pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try render(layout: layout, images: images, to: url)
            return url
        } catch {
            print("PDF generation error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Drawing the rulebook's ops

    /// One drawn op, for tests: the page number, the kind and (for text) the text.
    nonisolated struct DrawnOp: Equatable {
        let page: Int
        let kind: String
        let text: String?
    }

    /// Draws every op of `layout` exactly where the rulebook puts it (top-left origin, text by its baseline,
    /// Helvetica / Helvetica-Bold). Decides nothing: no wrapping, sizing or page breaks happen here.
    @discardableResult
    nonisolated static func render(
        layout: [String: Any],
        images: [String: UIImage],
        to url: URL
    ) throws -> [DrawnOp] {
        let page = layout["page"] as? [String: Any]
        let width = number(page?["width"]) ?? 595.28
        let height = number(page?["height"]) ?? 841.89
        let pages = (layout["pages"] as? [[String: Any]]) ?? []
        var drawn: [DrawnOp] = []
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height))
        try renderer.writePDF(to: url) { context in
            for pageLayout in pages {
                context.beginPage()
                let pageNumber = (pageLayout["number"] as? Int) ?? 0
                for op in (pageLayout["ops"] as? [[String: Any]]) ?? [] {
                    let kind = (op["kind"] as? String) ?? ""
                    draw(op: op, kind: kind, images: images, in: context.cgContext)
                    drawn.append(DrawnOp(page: pageNumber, kind: kind, text: kind == "text" ? op["text"] as? String : nil))
                }
            }
        }
        return drawn
    }

    nonisolated private static func draw(op: [String: Any], kind: String, images: [String: UIImage], in cg: CGContext) {
        switch kind {
        case "rect":
            let rect = CGRect(x: number(op["x"]) ?? 0, y: number(op["y"]) ?? 0, width: number(op["w"]) ?? 0, height: number(op["h"]) ?? 0)
            let radius = number(op["radius"]) ?? 0
            let path = radius > 0 ? UIBezierPath(roundedRect: rect, cornerRadius: radius) : UIBezierPath(rect: rect)
            if let fill = color(op["fill"]) {
                fill.setFill()
                path.fill()
            }
            if let stroke = color(op["stroke"]) {
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        case "line":
            let path = UIBezierPath()
            path.move(to: CGPoint(x: number(op["x1"]) ?? 0, y: number(op["y1"]) ?? 0))
            path.addLine(to: CGPoint(x: number(op["x2"]) ?? 0, y: number(op["y2"]) ?? 0))
            path.lineWidth = number(op["width"]) ?? 1
            if let dash = op["dash"] as? [Any], dash.count == 2 {
                let pattern = dash.compactMap { number($0) }
                path.setLineDash(pattern, count: pattern.count, phase: 0)
            }
            (color(op["color"]) ?? .black).setStroke()
            path.stroke()
        case "circle":
            let r = number(op["r"]) ?? 0
            let rect = CGRect(x: (number(op["cx"]) ?? 0) - r, y: (number(op["cy"]) ?? 0) - r, width: r * 2, height: r * 2)
            (color(op["fill"]) ?? .black).setFill()
            UIBezierPath(ovalIn: rect).fill()
        case "text":
            let text = (op["text"] as? String) ?? ""
            let size = number(op["size"]) ?? 10
            let bold = (op["bold"] as? Bool) ?? false
            let font = UIFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
                ?? (bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color(op["color"]) ?? .black
            ]
            // The layout gives the baseline; UIKit draws from the top of the line box.
            let top = (number(op["baseline"]) ?? 0) - font.ascender
            (text as NSString).draw(at: CGPoint(x: number(op["x"]) ?? 0, y: top), withAttributes: attributes)
        case "image":
            let rect = CGRect(x: number(op["x"]) ?? 0, y: number(op["y"]) ?? 0, width: number(op["w"]) ?? 0, height: number(op["h"]) ?? 0)
            if let ref = op["ref"] as? String, let image = images[ref] {
                // The box already has the picture's aspect ratio: the whole photo is drawn, never cropped.
                image.draw(in: rect)
            } else {
                // The picture could not be read: a grey box of the same size, so the layout is unchanged.
                UIColor(red: 0xEE / 255, green: 0xF0 / 255, blue: 0xF3 / 255, alpha: 1).setFill()
                cg.fill(rect)
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    nonisolated private static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }

    nonisolated private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        return nil
    }

    nonisolated private static func color(_ value: Any?) -> UIColor? {
        guard var hex = value as? String, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    nonisolated private static func compressedImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage? {
        let source = image
        let resized: UIImage
        if source.size.width > maxWidth {
            let scale = maxWidth / source.size.width
            let newSize = CGSize(width: maxWidth, height: source.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            resized = renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            resized = source
        }
        // PNG keeps a transparent logo transparent (the header is dark).
        guard let data = resized.pngData() else { return resized }
        return UIImage(data: data) ?? resized
    }
}
