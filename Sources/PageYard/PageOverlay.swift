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
