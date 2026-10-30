import AppKit
import PDFKit

/// Global render switches read by annotation drawing code.
enum RenderState {
    /// True while the document is being baked into a new PDF: selection chrome
    /// and editor-only visuals must not end up in the file.
    static var isFlattening = false
    /// While flattening, text covers whose original glyphs were physically
    /// removed don't need the background fill anymore.
    static var coversRemovedByRedaction = false
    /// Current zoom of the active view, used to keep selection chrome constant on screen.
    static var viewScale: CGFloat = 1
}

extension NSFont {
    func sized(_ size: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func defaultFill(_ size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }
}

/// Base class for everything the user places on a page. Drawn by us (not by
/// PDFKit appearance streams) and baked into page content on save.
class EditableAnnotation: PDFAnnotation {
    enum ResizeMode { case free, aspect, fontScale }

    var isSelected = false
    var isEditing = false

    init(rect: CGRect) {
        super.init(bounds: rect, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    var resizeMode: ResizeMode { .free }

    /// Snapshot of everything user-editable; used for undo.
    var state: [String: Any] {
        get { ["bounds": bounds] }
        set { if let b = newValue["bounds"] as? CGRect { bounds = b } }
    }

    func drawContent(in rect: CGRect) {}

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if !isEditing { drawContent(in: bounds) }
        if isSelected && !RenderState.isFlattening { drawSelectionChrome() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelectionChrome() {
        let s = 1 / max(RenderState.viewScale, 0.05)
        let frame = NSBezierPath(rect: bounds)
        frame.lineWidth = s
        frame.setLineDash([4 * s, 3 * s], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        frame.stroke()

        let h = 8 * s
        let handle = NSBezierPath(ovalIn: CGRect(x: bounds.maxX - h / 2, y: bounds.minY - h / 2, width: h, height: h))
        NSColor.white.setFill()
        handle.fill()
        handle.lineWidth = 1.5 * s
        handle.stroke()
    }
}

/// Free text typed by the user. With `cover` set it is a replacement for
/// original page text: the covered area is painted with the page background
/// in the editor, and the original glyphs are removed from the file on save.
final class TextBoxAnnotation: EditableAnnotation {
    static let padding: CGFloat = 2

    var text: String
    var textFont: NSFont
    var ink: NSColor
    var cover: CGSize?
    var coverColor: NSColor = .white
    /// Original text region (page space) whose glyphs get removed on save.
    var redactionRect: CGRect?
    /// Text area drawn by dragging: fixed width with line wrapping.
    var wrapWidth: CGFloat?
    var minHeight: CGFloat = 0
    /// The area hides what's under it (painted, and its text removed on save).
    var erasesBelow = false

    init(text: String, font: NSFont, color: NSColor, topLeft: CGPoint) {
        self.text = text
        self.textFont = font
        self.ink = color
        super.init(rect: CGRect(origin: topLeft, size: .zero))
        fit()
    }

    required init?(coder: NSCoder) { nil }

    override var resizeMode: ResizeMode { cover == nil && wrapWidth == nil ? .fontScale : .free }

    /// Region whose original text is removed from the file on save.
    var regionToRemove: CGRect? {
        redactionRect ?? (erasesBelow ? bounds : nil)
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: textFont, .foregroundColor: ink]
    }

    func textSize() -> CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        let width = wrapWidth.map { max(4, $0 - 2 * Self.padding) } ?? 100_000
        let r = s.boundingRect(with: CGSize(width: width, height: 100_000),
                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                               attributes: attributes)
        return CGSize(width: ceil(r.width) + 2 * Self.padding, height: ceil(r.height) + 2 * Self.padding)
    }

    /// Resizes bounds to the text, keeping the top-left corner in place.
    func fit() {
        let t = textSize()
        let w = wrapWidth ?? max(t.width, cover?.width ?? 0)
        let h = max(t.height, cover?.height ?? 0, minHeight)
        bounds = CGRect(x: bounds.minX, y: bounds.maxY - h, width: w, height: h)
    }

    /// Distance from the top of the bounds to the top of the text block.
    var textTopInset: CGFloat {
        guard let c = cover, wrapWidth == nil else { return 0 }
        return max(0, (c.height - textSize().height) / 2)
    }

    override var state: [String: Any] {
        get {
            var s = super.state
            s["text"] = text
            s["font"] = textFont
            s["color"] = ink
            s["cover"] = cover.map { NSValue(size: $0) } ?? NSNull()
            s["wrap"] = wrapWidth.map { NSNumber(value: Double($0)) } ?? NSNull()
            s["minHeight"] = minHeight
            s["erase"] = erasesBelow
            return s
        }
        set {
            super.state = newValue
            if let t = newValue["text"] as? String { text = t }
            if let f = newValue["font"] as? NSFont { textFont = f }
            if let c = newValue["color"] as? NSColor { ink = c }
            if let c = newValue["cover"] { cover = (c as? NSValue)?.sizeValue }
            if let w = newValue["wrap"] { wrapWidth = (w as? NSNumber).map { CGFloat($0.doubleValue) } }
            if let h = newValue["minHeight"] as? CGFloat { minHeight = h }
            if let e = newValue["erase"] as? Bool { erasesBelow = e }
        }
    }

    override func drawContent(in rect: CGRect) {
        // Replaced text only needs the paint until its glyphs are removed;
        // an erasing area always hides everything under it (images, lines too).
        if erasesBelow || (cover != nil && !(RenderState.isFlattening && RenderState.coversRemovedByRedaction && redactionRect != nil)) {
            coverColor.setFill()
            rect.fill()
        } else if wrapWidth != nil && !RenderState.isFlattening && !isSelected {
            // Faint outline so an empty text area stays visible while editing.
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            let p = NSBezierPath(rect: rect)
            p.lineWidth = 0.5 / max(RenderState.viewScale, 0.05)
            p.setLineDash([3 / max(RenderState.viewScale, 0.05), 2 / max(RenderState.viewScale, 0.05)], count: 2, phase: 0)
            p.stroke()
        }
        let t = textSize()
        let top = rect.maxY - textTopInset
        let textWidth = (wrapWidth ?? t.width) - 2 * Self.padding
        let r = CGRect(x: rect.minX + Self.padding, y: top - t.height + Self.padding,
                       width: textWidth, height: t.height - 2 * Self.padding)
        (text as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }
}

enum MarkKind: String {
    case cross, check, dot
}

/// ✕ / ✓ / ● drawn with vector paths.
final class MarkAnnotation: EditableAnnotation {
    var kind: MarkKind
    var ink: NSColor

    init(kind: MarkKind, color: NSColor, rect: CGRect) {
        self.kind = kind
        self.ink = color
        super.init(rect: rect)
    }

    required init?(coder: NSCoder) { nil }

    override var resizeMode: ResizeMode { .aspect }

    override var state: [String: Any] {
        get { var s = super.state; s["color"] = ink; return s }
        set { super.state = newValue; if let c = newValue["color"] as? NSColor { ink = c } }
    }

    override func drawContent(in rect: CGRect) {
        let r = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
        let path = NSBezierPath()
        path.lineWidth = max(0.8, rect.width * 0.12)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        ink.set()
        switch kind {
        case .cross:
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.maxY))
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.line(to: CGPoint(x: r.maxX, y: r.minY))
            path.stroke()
        case .check:
            path.move(to: CGPoint(x: r.minX, y: r.midY))
            path.line(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.maxY))
            path.stroke()
        case .dot:
            NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.15, dy: r.height * 0.15)).fill()
        }
    }
}

/// Signature or any other picture.
final class ImageAnnotation: EditableAnnotation {
    let image: NSImage

    init(image: NSImage, rect: CGRect) {
        self.image = image
        super.init(rect: rect)
    }

    required init?(coder: NSCoder) { nil }

    override var resizeMode: ResizeMode { .aspect }

    override func drawContent(in rect: CGRect) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Opaque rectangle painted over page content.
final class WhiteoutAnnotation: EditableAnnotation {
    var ink: NSColor = .white

    override var state: [String: Any] {
        get { var s = super.state; s["color"] = ink; return s }
        set { super.state = newValue; if let c = newValue["color"] as? NSColor { ink = c } }
    }

    override func drawContent(in rect: CGRect) {
        ink.setFill()
        rect.fill()
        if !RenderState.isFlattening {
            // Hairline so an empty whiteout on a white page stays findable.
            NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
            let p = NSBezierPath(rect: rect)
            p.lineWidth = 0.5 / max(RenderState.viewScale, 0.05)
            p.stroke()
        }
    }
}

/// Highlight of an auto-detected fill-in spot. Never saved.
final class HintAnnotation: PDFAnnotation {
    let field: DetectedField

    init(field: DetectedField) {
        self.field = field
        let r = field.kind == .line
            ? CGRect(x: field.rect.minX, y: field.rect.minY, width: field.rect.width, height: 14)
            : field.rect
        super.init(bounds: r, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !RenderState.isFlattening else { return }
        context.saveGState()
        let color: CGColor = field.kind == .checkbox
            ? NSColor.systemOrange.withAlphaComponent(0.25).cgColor
            : NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        context.setFillColor(color)
        context.fill(bounds)
        context.restoreGState()
    }
}

/// Yellow marker over a block, optionally with a note. Saved as a native PDF
/// highlight annotation (not baked), so it can be hidden in any viewer.
///
/// The note label sits above the block *inside* the annotation bounds:
/// PDFKit clips annotation drawing to its bounds.
final class HighlightAnnotation: EditableAnnotation {
    static let defaultColor = NSColor(srgbRed: 1, green: 0.86, blue: 0.1, alpha: 1)
    private static let noteAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 7.5), .foregroundColor: NSColor.black,
    ]

    var note: String
    var ink: NSColor = HighlightAnnotation.defaultColor
    var isMarkHidden = false

    init(rect block: CGRect, note: String = "") {
        self.note = note
        super.init(rect: block)
        bounds = Self.bounds(forBlock: block, note: note)
    }

    required init?(coder: NSCoder) { nil }

    /// Height of the note label for a block of the given width (0 without a note).
    static func noteHeight(_ note: String, width: CGFloat) -> CGFloat {
        guard !note.isEmpty else { return 0 }
        let r = (note as NSString).boundingRect(with: CGSize(width: max(20, width - 8), height: 200),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: noteAttributes)
        return min(ceil(r.height), 60) + 6
    }

    static func bounds(forBlock block: CGRect, note: String) -> CGRect {
        CGRect(x: block.minX, y: block.minY, width: block.width, height: block.height + noteHeight(note, width: block.width))
    }

    /// The highlighted area itself (bounds minus the note label).
    var blockRect: CGRect {
        let h = Self.noteHeight(note, width: bounds.width)
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(1, bounds.height - h))
    }

    override var state: [String: Any] {
        get { var s = super.state; s["note"] = note; return s }
        set { super.state = newValue; if let n = newValue["note"] as? String { note = n } }
    }

    override func drawContent(in rect: CGRect) {
        guard !isMarkHidden, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let block = blockRect
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(ink.withAlphaComponent(0.45).cgColor)
        ctx.fill(block)
        ctx.restoreGState()
        guard !note.isEmpty else { return }

        let text = note as NSString
        let used = text.boundingRect(with: CGSize(width: max(20, rect.width - 8), height: 200),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: Self.noteAttributes)
        let box = CGRect(x: rect.minX, y: block.maxY + 1,
                         width: min(rect.width, ceil(used.width) + 8), height: rect.maxY - block.maxY - 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        NSColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 0.97).setFill()
        path.fill()
        NSColor(srgbRed: 0.8, green: 0.62, blue: 0, alpha: 1).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        text.draw(with: box.insetBy(dx: 4, dy: 2.5), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                  attributes: Self.noteAttributes)
    }
}
