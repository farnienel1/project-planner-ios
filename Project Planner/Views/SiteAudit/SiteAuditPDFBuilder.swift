//
//  SiteAuditPDFBuilder.swift
//  Project Planner
//
//  Professional site audit PDF matching site_audit_full_flow.html
//

import UIKit

enum SiteAuditPDFBuilder {
    struct Context {
        let audit: SiteAudit
        let localItems: [SiteAuditDraftItem]
        let organizationName: String?
        let logoImage: UIImage?
        let clientName: String?
        let siteAddress: String?
    }

    static func makePDF(
        audit: SiteAudit,
        localItems: [SiteAuditDraftItem],
        organizationName: String?,
        logoImage: UIImage?,
        clientName: String? = nil,
        siteAddress: String? = nil
    ) -> URL? {
        let ctx = Context(
            audit: audit,
            localItems: localItems,
            organizationName: organizationName,
            logoImage: logoImage,
            clientName: clientName,
            siteAddress: siteAddress
        )
        let ref = referenceCode(for: audit)
        let fileName = "SiteAudit_\(audit.projectJobNumber)_\(audit.type.rawValue.replacingOccurrences(of: " ", with: ""))_\(pdfDateStamp(audit.date)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let margin: CGFloat = 32
        let contentWidth = pageRect.width - margin * 2

        do {
            try renderer.writePDF(to: url) { context in
                var y: CGFloat = 0
                context.beginPage()
                y = drawHeader(ctx: context, pageWidth: pageRect.width, y: 0, audit: audit, orgName: organizationName, logo: logoImage, siteAddress: siteAddress)
                y = drawMetaGrid(ctx: context, x: margin, y: y, width: contentWidth, audit: audit, clientName: clientName, reference: ref)
                y = drawSectionHeading(ctx: context, x: margin, y: y + 8, width: contentWidth, itemCount: audit.items.count)

                for (index, item) in audit.items.enumerated() {
                    let image = localItems[safe: index]?.image ?? localItems.first(where: { $0.id == item.id })?.image
                    let needed: CGFloat = 200
                    if y + needed > pageRect.height - 80 {
                        drawFooter(ctx: context, pageRect: pageRect, margin: margin, orgName: organizationName, reference: ref, page: 1, total: 1)
                        context.beginPage()
                        y = 28
                    }
                    y = drawItemCard(
                        ctx: context,
                        x: margin,
                        y: y,
                        width: contentWidth,
                        index: index + 1,
                        item: item,
                        image: image
                    )
                }

                if y + 120 > pageRect.height - 50 {
                    drawFooter(ctx: context, pageRect: pageRect, margin: margin, orgName: organizationName, reference: ref, page: 1, total: 1)
                    context.beginPage()
                    y = 28
                }
                y = drawSignatureBlock(ctx: context, x: margin, y: y + 14, width: contentWidth, author: audit.authorName, date: audit.date)
                drawFooter(ctx: context, pageRect: pageRect, margin: margin, orgName: organizationName, reference: ref, page: 1, total: 1)
            }
            return url
        } catch {
            print("PDF generation error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Drawing

    private static func drawHeader(
        ctx: UIGraphicsPDFRendererContext,
        pageWidth: CGFloat,
        y: CGFloat,
        audit: SiteAudit,
        orgName: String?,
        logo: UIImage?,
        siteAddress: String?
    ) -> CGFloat {
        let headerHeight: CGFloat = 118
        let rect = CGRect(x: 0, y: y, width: pageWidth, height: headerHeight)
        let cg = ctx.cgContext

        // Solid fallback + diagonal gradient (HTML: #0B1020 → #1A2447)
        cg.saveGState()
        UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1).setFill()
        cg.fill(rect)
        let startColor = UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1).cgColor
        let endColor = UIColor(red: 0.102, green: 0.141, blue: 0.278, alpha: 1).cgColor
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [startColor, endColor] as CFArray,
            locations: [0, 1]
        ) {
            cg.addRect(rect)
            cg.clip()
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        }
        cg.restoreGState()

        cg.saveGState()
        cg.setFillColor(UIColor(red: 0.094, green: 0.373, blue: 0.647, alpha: 0.35).cgColor)
        cg.fillEllipse(in: CGRect(x: pageWidth - 110, y: y - 20, width: 140, height: 140))
        cg.restoreGState()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            .kern: 0.8
        ]
        "SITE AUDIT REPORT".draw(at: CGPoint(x: 32, y: y + 28), withAttributes: labelAttrs)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        audit.type.rawValue.draw(at: CGPoint(x: 32, y: y + 44), withAttributes: titleAttrs)

        var subtitle = "\(audit.projectJobNumber) · \(audit.projectName)"
        if let siteAddress, !siteAddress.isEmpty {
            subtitle = "\(audit.projectJobNumber) · \(siteAddress)"
        }
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85)
        ]
        let subtitleRect = CGRect(x: 32, y: y + 72, width: pageWidth - 160, height: 36)
        (subtitle as NSString).draw(in: subtitleRect, withAttributes: subAttrs)

        if !audit.customTitle.isEmpty {
            let customAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.75)
            ]
            let customRect = CGRect(x: 32, y: y + 90, width: pageWidth - 160, height: 20)
            (audit.customTitle as NSString).draw(in: customRect, withAttributes: customAttrs)
        }

        let logoBox = CGRect(x: pageWidth - 96, y: y + 24, width: 64, height: 64)
        if let logo, let prepared = compressedImage(logo, maxWidth: 200) {
            prepared.draw(in: aspectFitRect(for: prepared.size, in: logoBox))
        } else {
            drawLogoPlaceholder(in: logoBox, orgName: orgName)
        }
        if let orgName, !orgName.isEmpty {
            let orgAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let orgRect = CGRect(x: pageWidth - 130, y: y + 92, width: 98, height: 16)
            (orgName as NSString).draw(in: orgRect, withAttributes: orgAttrs)
        }

        return y + headerHeight
    }

    private static func drawMetaGrid(
        ctx: UIGraphicsPDFRendererContext,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        audit: SiteAudit,
        clientName: String?,
        reference: String
    ) -> CGFloat {
        let pairs: [(String, String)] = [
            ("Project", "\(audit.projectJobNumber) \(audit.projectName)"),
            ("Client", clientName?.isEmpty == false ? clientName! : "—"),
            ("Author", audit.authorName),
            ("Date", mediumDate(audit.date)),
            ("Type", "\(audit.type.rawValue) audit"),
            ("Reference", reference)
        ]
        let colWidth = (width - 18) / 2
        let columnGap: CGFloat = 18
        let rowGap: CGFloat = 18
        let topPadding: CGFloat = 24
        let bottomPadding: CGFloat = 24

        var rowHeights: [CGFloat] = []
        for row in 0..<3 {
            var maxH: CGFloat = 0
            for col in 0..<2 {
                let idx = row * 2 + col
                guard idx < pairs.count else { continue }
                maxH = max(maxH, metaCellHeight(width: colWidth, key: pairs[idx].0, value: pairs[idx].1))
            }
            rowHeights.append(max(maxH, 34))
        }
        let gridHeight = topPadding + rowHeights.reduce(0, +) + rowGap * CGFloat(max(0, rowHeights.count - 1)) + bottomPadding

        let bgRect = CGRect(x: 0, y: y, width: x + width + x, height: gridHeight)
        UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1).setFill()
        ctx.cgContext.fill(bgRect)
        UIColor(red: 0.933, green: 0.941, blue: 0.953, alpha: 1).setFill()
        ctx.cgContext.fill(CGRect(x: 0, y: bgRect.maxY - 1, width: bgRect.width, height: 1))

        var rowY = y + topPadding
        for (rowIndex, rowHeight) in rowHeights.enumerated() {
            for col in 0..<2 {
                let idx = rowIndex * 2 + col
                guard idx < pairs.count else { continue }
                let cx = x + CGFloat(col) * (colWidth + columnGap)
                drawMetaCell(x: cx, y: rowY, width: colWidth, key: pairs[idx].0, value: pairs[idx].1)
            }
            rowY += rowHeight + rowGap
        }
        return y + gridHeight
    }

    private static func metaCellHeight(width: CGFloat, key: String, value: String) -> CGFloat {
        let keyH: CGFloat = 12
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var attrs = valAttrs
        attrs[.paragraphStyle] = paragraph
        let valH = (value as NSString).boundingRect(
            with: CGSize(width: width, height: 120),
            options: [.usesLineFragmentOrigin],
            attributes: attrs,
            context: nil
        ).height
        return keyH + 4 + ceil(valH)
    }

    private static func drawMetaCell(x: CGFloat, y: CGFloat, width: CGFloat, key: String, value: String) {
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1),
            .kern: 0.6
        ]
        (key.uppercased() as NSString).draw(
            at: CGPoint(x: x, y: y),
            withAttributes: keyAttrs
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1),
            .paragraphStyle: paragraph
        ]
        if key == "Reference" {
            valAttrs[.font] = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        }
        let valRect = CGRect(x: x, y: y + 14, width: width, height: 80)
        (value as NSString).draw(in: valRect, withAttributes: valAttrs)
    }

    private static func drawSectionHeading(ctx: UIGraphicsPDFRendererContext, x: CGFloat, y: CGFloat, width: CGFloat, itemCount: Int) -> CGFloat {
        UIColor(red: 0.094, green: 0.373, blue: 0.647, alpha: 1).setFill()
        ctx.cgContext.fill(CGRect(x: x, y: y, width: 24, height: 3))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1),
            .kern: 0.2
        ]
        "SITE OBSERVATIONS · \(itemCount) ITEM\(itemCount == 1 ? "" : "S")".draw(at: CGPoint(x: x, y: y + 12), withAttributes: attrs)
        return y + 36
    }

    private static func drawItemCard(
        ctx: UIGraphicsPDFRendererContext,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        index: Int,
        item: SiteAuditItem,
        image: UIImage?
    ) -> CGFloat {
        let cardHeight: CGFloat = image != nil ? 168 : 90
        let cardRect = CGRect(x: x, y: y, width: width, height: cardHeight)
        UIColor.white.setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()
        UIColor(red: 0.933, green: 0.941, blue: 0.953, alpha: 1).setStroke()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).stroke()

        let headerH: CGFloat = 36
        let headerRect = CGRect(x: x, y: y, width: width, height: headerH)
        UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1).setFill()
        ctx.cgContext.fill(headerRect)
        UIColor(red: 0.933, green: 0.941, blue: 0.953, alpha: 1).setFill()
        ctx.cgContext.fill(CGRect(x: x, y: y + headerH - 1, width: width, height: 1))

        let numRect = CGRect(x: x + 14, y: y + 7, width: 22, height: 22)
        UIColor(red: 0.094, green: 0.373, blue: 0.647, alpha: 1).setFill()
        UIBezierPath(ovalIn: numRect).fill()
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        "\(index)".draw(
            at: CGPoint(x: numRect.midX - 4, y: numRect.midY - 7),
            withAttributes: numAttrs
        )

        let title = item.title.isEmpty ? "Untitled item" : item.title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1)
        ]
        title.draw(at: CGPoint(x: x + 44, y: y + 10), withAttributes: titleAttrs)

        let bodyY = y + headerH + 14
        let photoW: CGFloat = 200
        if let image, let prepared = compressedImage(image, maxWidth: 900) {
            let photoRect = CGRect(x: x + 14, y: bodyY, width: photoW, height: 118)
            UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1).setFill()
            UIBezierPath(roundedRect: photoRect, cornerRadius: 4).fill()
            // Photo already carries capture-time watermark from upload; do not stamp again.
            prepared.draw(in: aspectFitRect(for: prepared.size, in: photoRect))
            drawDetailColumn(ctx: ctx, x: x + 14 + photoW + 14, y: bodyY, width: width - photoW - 42, item: item)
        } else {
            drawDetailColumn(ctx: ctx, x: x + 14, y: bodyY, width: width - 28, item: item)
        }

        return y + cardHeight + 22
    }

    private static func drawDetailColumn(ctx: UIGraphicsPDFRendererContext, x: CGFloat, y: CGFloat, width: CGFloat, item: SiteAuditItem) {
        var dy = y
        let rows: [(String, String, Bool)] = [
            ("Location", item.location.isEmpty ? "—" : item.location, false),
            ("Assignee", item.assignee.isEmpty ? "—" : item.assignee, false),
            ("Comments", item.comments.isEmpty ? "—" : item.comments, false),
            ("Annotations", item.annotations.isEmpty ? "None" : item.annotations, item.annotations.isEmpty)
        ]
        for (idx, row) in rows.enumerated() {
            if idx > 0 {
                UIColor(red: 0.933, green: 0.941, blue: 0.953, alpha: 1).setStroke()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: x, y: dy))
                path.addLine(to: CGPoint(x: x + width, y: dy))
                path.setLineDash([2, 2], count: 2, phase: 0)
                path.stroke()
                dy += 6
            }
            dy = drawDetailRow(x: x, y: dy, width: width, key: row.0, value: row.1, muted: row.2)
        }
    }

    private static func drawDetailRow(x: CGFloat, y: CGFloat, width: CGFloat, key: String, value: String, muted: Bool) -> CGFloat {
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1),
            .kern: 0.3
        ]
        key.uppercased().draw(at: CGPoint(x: x, y: y), withAttributes: keyAttrs)
        var valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1)
        ]
        if muted {
            valAttrs[.foregroundColor] = UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1)
            valAttrs[.obliqueness] = 0.15
        }
        let bounding = CGRect(x: x, y: y + 12, width: width, height: 200)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        valAttrs[.paragraphStyle] = paragraph
        let h = (value as NSString).boundingRect(
            with: CGSize(width: width, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: valAttrs,
            context: nil
        ).height
        (value as NSString).draw(in: bounding, withAttributes: valAttrs)
        return y + 12 + max(h, 14) + 4
    }

    private static func drawSignatureBlock(ctx: UIGraphicsPDFRendererContext, x: CGFloat, y: CGFloat, width: CGFloat, author: String, date: Date) -> CGFloat {
        UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1).setFill()
        ctx.cgContext.fill(CGRect(x: x, y: y, width: width, height: 2))

        let colW = (width - 24) / 2
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1),
            .kern: 0.6
        ]
        "AUTHOR SIGNATURE".draw(at: CGPoint(x: x, y: y + 14), withAttributes: keyAttrs)
        "CLIENT ACKNOWLEDGEMENT".draw(at: CGPoint(x: x + colW + 24, y: y + 14), withAttributes: keyAttrs)

        let scriptAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.italicSystemFont(ofSize: 18),
            .foregroundColor: UIColor(red: 0.102, green: 0.141, blue: 0.278, alpha: 1)
        ]
        let initials = authorSignatureShort(author)
        initials.draw(at: CGPoint(x: x, y: y + 38), withAttributes: scriptAttrs)

        UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1).setStroke()
        let line1 = UIBezierPath()
        line1.move(to: CGPoint(x: x, y: y + 62))
        line1.addLine(to: CGPoint(x: x + colW * 0.7, y: y + 62))
        line1.stroke()

        let line2 = UIBezierPath()
        line2.move(to: CGPoint(x: x + colW + 24, y: y + 62))
        line2.addLine(to: CGPoint(x: x + width, y: y + 62))
        line2.stroke()

        let footAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1)
        ]
        "\(author) · \(mediumDate(date))".draw(at: CGPoint(x: x, y: y + 68), withAttributes: footAttrs)
        "Signed & dated".draw(at: CGPoint(x: x + colW + 24, y: y + 68), withAttributes: footAttrs)

        return y + 88
    }

    private static func drawFooter(
        ctx: UIGraphicsPDFRendererContext,
        pageRect: CGRect,
        margin: CGFloat,
        orgName: String?,
        reference: String,
        page: Int,
        total: Int
    ) {
        let y = pageRect.height - 44
        UIColor(red: 0.933, green: 0.941, blue: 0.953, alpha: 1).setFill()
        ctx.cgContext.fill(CGRect(x: 0, y: y - 12, width: pageRect.width, height: 1))

        let leftAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1)
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1)
        ]
        (orgName ?? "Site Audit").draw(at: CGPoint(x: margin, y: y), withAttributes: leftAttrs)
        "Mechanical & Electrical Contractors".draw(at: CGPoint(x: margin, y: y + 12), withAttributes: subAttrs)

        let right = "Page \(page) of \(total)"
        let refAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: UIColor(red: 0.420, green: 0.447, blue: 0.502, alpha: 1)
        ]
        let rightSize = right.size(withAttributes: subAttrs)
        right.draw(at: CGPoint(x: pageRect.width - margin - rightSize.width, y: y), withAttributes: subAttrs)
        let refSize = reference.size(withAttributes: refAttrs)
        reference.draw(at: CGPoint(x: pageRect.width - margin - refSize.width, y: y + 12), withAttributes: refAttrs)
    }

    // MARK: - Helpers

    private static func drawLogoPlaceholder(in rect: CGRect, orgName: String?) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
        let colors = [UIColor(red: 0.094, green: 0.373, blue: 0.647, alpha: 1).cgColor,
                      UIColor(red: 0.216, green: 0.541, blue: 0.867, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            UIGraphicsGetCurrentContext()?.saveGState()
            path.addClip()
            UIGraphicsGetCurrentContext()?.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
            UIGraphicsGetCurrentContext()?.restoreGState()
        }
        let initials = organizationInitials(orgName)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let size = initials.size(withAttributes: attrs)
        initials.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private static func referenceCode(for audit: SiteAudit) -> String {
        let job = audit.projectJobNumber.replacingOccurrences(of: " ", with: "")
        let ts = Int(audit.createdAt.timeIntervalSince1970)
        return "SA-\(job)-\(ts)"
    }

    private static func organizationInitials(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "PP" }
        let parts = name.split(separator: " ").prefix(2)
        if parts.isEmpty { return String(name.prefix(2)).uppercased() }
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    private static func authorSignatureShort(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1)). \(parts[1])"
        }
        return name
    }

    private static func pdfDateStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dMMMyy"
        return f.string(from: date)
    }

    private static func mediumDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }

    private static func compressedImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage? {
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
        guard let data = resized.jpegData(compressionQuality: 0.62) else { return resized }
        return UIImage(data: data) ?? resized
    }

    private static func aspectFitRect(for imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: box.minX + (box.width - fitted.width) / 2,
            y: box.minY + (box.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
