import AppKit
import PDFKit

/// Transparent view PDFKit lays over each visible page. It draws the user's
/// objects with AppKit, so they stay sharp at any zoom (the scroll view
/// magnifies views by redrawing them, unlike PDFKit's rasterised annotations).
final class PageOverlayView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?

    override var isOpaque: Bool { false }

    /// Clicks go through to the PDF view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Maps page space to this view's coordinates (handles zoom and rotation).
    private func pageTransform() -> CGAffineTransform? {
        guard let pdfView, let page else { return nil }
        func map(_ p: CGPoint) -> CGPoint { convert(pdfView.convert(p, from: page), from: pdfView) }
        let o = map(.zero), x = map(CGPoint(x: 1, y: 0)), y = map(CGPoint(x: 0, y: 1))
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let ctx = NSGraphicsContext.current?.cgContext, let t = pageTransform() else { return }
        ctx.saveGState()
        ctx.concatenate(t)
        if let editor = pdfView as? EditorPDFView {
            // A translated page is dimmed and the translated blocks stand out
            // as white cards (like Live Text translation), below the user's objects.
            let blocks = editor.translationBlocks(on: page)
            if !blocks.isEmpty {
                NSColor.black.withAlphaComponent(0.45).setFill()
                page.bounds(for: .cropBox).fill(using: .sourceOver)
                for block in blocks { block.draw() }
            }
            // Waiting for the translation: pulsing highlight over the source text.
            let waiting = editor.pendingRects(on: page)
            if !waiting.isEmpty {
                let phase = editor.pulsePhase
                let accent = NSColor.controlAccentColor
                for r in waiting {
                    let area = r.insetBy(dx: -3, dy: -2)
                    accent.withAlphaComponent(0.12 + 0.22 * phase).setFill()
                    let shape = NSBezierPath(roundedRect: area, xRadius: 2.5, yRadius: 2.5)
                    shape.fill()
                    shape.lineWidth = 1.2 / max(editor.scaleFactor, 0.05)
                    accent.withAlphaComponent(0.5 + 0.5 * phase).setStroke()
                    shape.stroke()
                }
                if let first = waiting.max(by: { $0.maxY < $1.maxY }) {
                    let font = NSFont.systemFont(ofSize: 9 / max(editor.scaleFactor, 0.4) * 1.6, weight: .semibold)
                    let label = "Перевожу…" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                    let size = label.size(withAttributes: attrs)
                    let tag = CGRect(x: first.minX - 3, y: first.maxY + 3, width: size.width + 8, height: size.height + 3)
                    accent.setFill()
                    NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2).fill()
                    label.draw(at: CGPoint(x: tag.minX + 4, y: tag.minY + 1.5), withAttributes: attrs)
                }
            }
            if let r = editor.marquee(on: page) {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                r.fill()
                let frame = NSBezierPath(rect: r)
                frame.lineWidth = 1 / max(editor.scaleFactor, 0.05)
                frame.setLineDash([4 / max(editor.scaleFactor, 0.05), 3 / max(editor.scaleFactor, 0.05)], count: 2, phase: 0)
                NSColor.controlAccentColor.setStroke()
                frame.stroke()
            }
        }
        for case let a as EditableAnnotation in page.annotations {
            a.render(in: ctx)
        }
        ctx.restoreGState()
    }
}
