//
//  SiteAuditMediaProcessor.swift
//  Project Planner
//
//  Downscales and watermarks site-audit photos off the main thread so lists,
//  uploads, and PDF generation stay responsive with many images.
//

import UIKit

enum SiteAuditMediaProcessor {
    /// Thumbnails and on-screen lists.
    nonisolated static let displayMaxPixelDimension: CGFloat = 1200
    /// Firebase Storage uploads.
    nonisolated static let uploadMaxPixelDimension: CGFloat = 1280
    /// Embedded PDF photos (200pt wide box).
    nonisolated static let pdfMaxPixelDimension: CGFloat = 720

    nonisolated static func normalizedForDisplay(_ image: UIImage, maxPixelDimension: CGFloat = displayMaxPixelDimension) -> UIImage {
        resized(image, maxPixelDimension: maxPixelDimension)
    }

    nonisolated static func preparedForUpload(_ image: UIImage) -> UIImage {
        resized(image, maxPixelDimension: uploadMaxPixelDimension)
    }

    nonisolated static func preparedForPDF(_ image: UIImage) -> UIImage {
        jpegBackedImage(resized(image, maxPixelDimension: pdfMaxPixelDimension), quality: 0.62) ?? resized(image, maxPixelDimension: pdfMaxPixelDimension)
    }

    nonisolated static func draftImage(from data: Data, capturedAt: Date = Date()) -> UIImage? {
        guard let source = UIImage(data: data) else { return nil }
        let normalized = normalizedForDisplay(source)
        return addTimestampWatermark(to: normalized, at: capturedAt)
    }

    nonisolated static func addTimestampWatermark(to image: UIImage, at date: Date) -> UIImage {
        let base = resized(image, maxPixelDimension: displayMaxPixelDimension)
        let renderer = UIGraphicsImageRenderer(size: base.size)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss"
        let text = formatter.string(from: date)
        let fontSize = max(16, min(28, base.size.width / 36))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        return renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            let box = CGRect(
                x: 16,
                y: base.size.height - textSize.height - 24,
                width: textSize.width + 16,
                height: textSize.height + 8
            )
            UIColor.black.withAlphaComponent(0.25).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 8).fill()
            text.draw(at: CGPoint(x: 24, y: base.size.height - textSize.height - 20), withAttributes: attributes)
        }
    }

    // MARK: - Private

    nonisolated private static func resized(_ image: UIImage, maxPixelDimension: CGFloat) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let longest = max(width, height)
        guard longest > maxPixelDimension, longest > 0 else { return image }
        let scale = maxPixelDimension / longest
        let newSize = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    nonisolated private static func jpegBackedImage(_ image: UIImage, quality: CGFloat) -> UIImage? {
        guard let data = image.jpegData(compressionQuality: quality) else { return nil }
        return UIImage(data: data)
    }
}
