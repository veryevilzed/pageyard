import AppKit
import PDFKit

/// Renders pages to PNG / JPEG files.
enum PageImageExporter {
    enum Format: Int {
        case png, jpeg

        var ext: String { self == .png ? "png" : "jpg" }
    }

    static func render(_ page: PDFPage, dpi: CGFloat) -> NSBitmapImageRep? {
        let crop = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 1 ? CGSize(width: crop.height, height: crop.width) : crop.size
        let scale = dpi / 72
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        // Keep DPI metadata so other apps show the real page size.
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        page.draw(with: .cropBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Writes `<base>-NN.<ext>` (or `<base>.<ext>` for a single page) and returns the files.
    static func export(_ pages: [(page: PDFPage, number: Int)], to dir: URL, baseName: String,
                       format: Format, dpi: CGFloat) throws -> [URL] {
        let digits = String(pages.map(\.number).max() ?? 1).count
        var urls: [URL] = []
        for (page, number) in pages {
            guard let rep = render(page, dpi: dpi) else { continue }
            let data: Data?
            switch format {
            case .png: data = rep.representation(using: .png, properties: [:])
            case .jpeg: data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            guard let data else { continue }
            let suffix = pages.count == 1 && number == 1 ? "" : "-" + String(format: "%0\(digits)d", number)
            let url = dir.appendingPathComponent("\(baseName)\(suffix).\(format.ext)")
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }
}
