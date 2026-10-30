import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Prepares photos for upload: ≤ 2,048 px on the long edge and ≤ 1 MiB JPEG (PROTOCOL §2).
/// Transparency is flattened onto white; orientation is baked in.
enum ImageProcessor {
    struct Prepared: Sendable {
        var data: Data
        var width: Int
        var height: Int
    }

    static func prepareJPEG(from data: Data, maxPixels: CGFloat = Validation.maxImagePixels,
                            maxBytes: Int = Validation.maxImageBytes) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var limit = maxPixels
        for _ in 0..<6 {
            guard let image = downsample(source, maxPixels: limit) else { return nil }
            let flattened = flatten(image)
            for quality in [0.85, 0.75, 0.65, 0.55, 0.45] as [CGFloat] {
                if let jpeg = flattened.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                    return Prepared(data: jpeg, width: Int(flattened.size.width * flattened.scale),
                                    height: Int(flattened.size.height * flattened.scale))
                }
            }
            limit *= 0.75
        }
        return nil
    }

    static func prepareJPEG(from image: UIImage) -> Prepared? {
        guard let data = image.jpegData(compressionQuality: 0.95) ?? image.pngData() else { return nil }
        return prepareJPEG(from: data)
    }

    private static func downsample(_ source: CGImageSource, maxPixels: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func flatten(_ image: CGImage) -> UIImage {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// File attachments accepted by the server (PROTOCOL §2): PDF, TXT, ZIP or LOG up to 10 MiB.
enum FileAttachmentPolicy {
    static var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .zip]
        if let log = UTType(filenameExtension: "log") { types.append(log) }
        return types
    }

    static func contentType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "log": return "text/plain"
        case "zip": return "application/zip"
        default:
            guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
            if type.conforms(to: .pdf) { return "application/pdf" }
            if type.conforms(to: .zip) { return "application/zip" }
            if type.conforms(to: .plainText) { return "text/plain" }
            return nil
        }
    }
}
