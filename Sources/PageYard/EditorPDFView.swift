import AppKit
import PDFKit

enum Tool: Int, CaseIterable {
    case select, text, cross, check, signature, whiteout, editText, highlight

    var title: String {
        switch self {
        case .select: "Выбор"
        case .text: "Текст"
        case .cross: "Крестик"
        case .check: "Галочка"
        case .signature: "Подпись"
        case .whiteout: "Замазка"
        case .editText: "Правка текста"
        case .highlight: "Маркер"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .cross: "xmark"
        case .check: "checkmark"
        case .signature: "signature"
        case .whiteout: "rectangle.fill"
        case .editText: "character.cursor.ibeam"
        case .highlight: "highlighter"
        }
    }

    var hint: String {
        switch self {
        case .select: "Выделяйте текст, заполняйте поля формы, перетаскивайте добавленные объекты"
        case .text: "Клик — текст на линию, в ячейку или куда угодно (⌥ без прилипания). Протяжка — область с переносом строк"
        case .cross: "Кликните в квадратик, чтобы поставить ✕. С ⇧ инструмент остаётся для следующих"
        case .check: "Кликните в квадратик, чтобы поставить ✓. С ⇧ инструмент остаётся для следующих"
        case .signature: "Кликните, где поставить подпись. Потяните за угол, чтобы изменить размер"
        case .whiteout: "Протяните прямоугольник, чтобы закрасить область"
        case .editText: "Кликните по строке или выделите фрагмент протяжкой, чтобы изменить текст"
        case .highlight: "Протяните прямоугольник, чтобы выделить блок жёлтым и добавить заметку. Двойной клик — изменить заметку"
        }
    }

    /// Physical key codes, so shortcuts work in any keyboard layout.
    var keyCode: UInt16 {
        switch self {
        case .select: 9      // V
        case .text: 17       // T
        case .cross: 7       // X
        case .check: 8       // C
        case .signature: 1   // S
        case .whiteout: 13   // W
        case .editText: 14   // E
        case .highlight: 4   // H
        }
    }

    var keyLabel: String {
        ["V", "T", "X", "C", "S", "W", "E", "H"][rawValue]
    }

    /// Mode to switch to when the tool's shortcut is pressed in a mode lacking it.
    var preferredMode: EditorMode {
        switch self {
        case .select, .text, .cross, .check, .signature: .fill
        case .whiteout, .editText, .highlight: .edit
        }
    }
}

enum EditorMode: Int, CaseIterable {
    case view, fill, edit

    var title: String {
        switch self {
        case .view: "Просмотр"
        case .fill: "Заполнение"
        case .edit: "Редактирование"
        }
    }

    var tools: [Tool] {
        switch self {
        case .view: []
        case .fill: [.select, .text, .cross, .check, .signature, .highlight]
        case .edit: [.select, .editText, .text, .whiteout, .highlight]
        }
    }
}

protocol EditorPDFViewDelegate: AnyObject {
    func editorSelectionChanged(_ annotation: EditableAnnotation?)
    func editorToolChanged(_ tool: Tool)
    func editorModeChanged(_ mode: EditorMode)
    func editorNeedsSignature()
    func editorPagesChanged()
    func editorMarksVisibilityChanged(_ visible: Bool)
}

final class EditorPDFView: PDFView, NSTextViewDelegate, PDFPageOverlayViewProvider, NSMenuItemValidation {
    weak var editorDelegate: EditorPDFViewDelegate?
    let detector = FieldDetector()

    var tool: Tool = .select {
        didSet {
            guard oldValue != tool else { return }
            finishEditing()
            if tool != .select { selected = nil }
            editorDelegate?.editorToolChanged(tool)
        }
    }

    var mode: EditorMode = .fill {
        didSet {
            guard oldValue != mode else { return }
            finishEditing()
            selected = nil
            tool = .select
            if mode == .view { showsFieldHints = false }
            updateFormLock()
            editorDelegate?.editorModeChanged(mode)
        }
    }

    /// Widgets we made read-only for view mode (original read-only ones are left alone).
    private var lockedWidgets: [PDFAnnotation] = []

    private func updateFormLock() {
        lockedWidgets.forEach { $0.isReadOnly = false }
        lockedWidgets = []
        guard mode == .view, let doc = document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" && !a.isReadOnly {
                a.isReadOnly = true
                lockedWidgets.append(a)
            }
        }
    }

    var fontSize: CGFloat = 12
    var textColor: NSColor = .black
    var signatureImage: NSImage?
    /// New text areas hide (and on save remove) what's under them.
    var eraseUnderText = false

    var showsFieldHints = false {
        didSet { if oldValue != showsFieldHints { updateHints() } }
    }

    private(set) var selected: EditableAnnotation? {
        didSet {
            guard oldValue !== selected else { return }
            oldValue?.isSelected = false
            refresh(oldValue)
            selected?.isSelected = true
            refresh(selected)
            editorDelegate?.editorSelectionChanged(selected)
        }
    }

    private enum Drag {
        case none
        case move(EditableAnnotation, CGPoint, [String: Any], Bool)
        case resize(EditableAnnotation, CGPoint, [String: Any])
        case rect(EditableAnnotation, PDFPage, CGPoint)
        case textSelect(PDFPage, CGPoint)
        case textArea(TextBoxAnnotation?, PDFPage, CGPoint, Bool)
        case translateArea(PDFPage, CGPoint)
    }

    private var drag: Drag = .none

    private var editor: NSTextView?
    private var editing: TextBoxAnnotation?
    private var editingIsNew = false
    private var editingOriginal: [String: Any] = [:]
    private let editorUndo = UndoManager()
    private var hints: [HintAnnotation] = []
    private var hintGeneration = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange(_:)), name: .PDFViewPageChanged, object: self)
        pageOverlayViewProvider = self
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: self)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func scaleChanged(_ note: Notification) {
        RenderState.viewScale = scaleFactor
        if editing != nil { finishEditing() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        RenderState.viewScale = scaleFactor
    }

    // MARK: - Model operations (undoable)

    func add(_ a: EditableAnnotation, to page: PDFPage, name: String) {
        page.addAnnotation(a)
        refresh(a)
        undoManager?.registerUndo(withTarget: self) { $0.remove(a, name: name) }
        undoManager?.setActionName(name)
    }

    func remove(_ a: EditableAnnotation, name: String) {
        guard let page = a.page else { return }
        if selected === a { selected = nil }
        page.removeAnnotation(a)
        refresh(page: page)
        undoManager?.registerUndo(withTarget: self) { $0.add(a, to: page, name: name) }
        undoManager?.setActionName(name)
    }

    func apply(_ state: [String: Any], to a: EditableAnnotation, name: String) {
        let old = a.state
        a.state = state
        refresh(a)
        undoManager?.registerUndo(withTarget: self) { $0.apply(old, to: a, name: name) }
        undoManager?.setActionName(name)
    }

    /// Registers undo for changes already made to `a` since `original`.
    private func commit(_ a: EditableAnnotation, from original: [String: Any], name: String) {
        let final = a.state
        a.state = original
        apply(final, to: a, name: name)
    }

    func refresh(_ a: PDFAnnotation?) {
        guard let page = a?.page else { return }
        refresh(page: page)
    }

    private func refresh(page: PDFPage) {
        annotationsChanged(on: page)
        overlays.object(forKey: page)?.needsDisplay = true
        needsDisplay = true
        NotificationCenter.default.post(name: .editorPageChanged, object: page)
    }

    // MARK: - Translation

    enum TranslationScope: Int { case page, selection }

    /// Translations drawn over the original; nothing is written into the file
    /// unless the user moves them into the document.
    var translationOn = false {
        didSet {
            guard oldValue != translationOn else { return }
            redrawAllOverlays()
            if translationOn { translateCurrentPageIfNeeded() }
        }
    }

    var translationScope: TranslationScope = .page {
        didSet { if translationScope == .page { translateCurrentPageIfNeeded() } }
    }

    /// Progress text (nil when idle); errors come with `isError`.
    var onTranslationStatus: ((String?) -> Void)?
    var onTranslationError: ((String) -> Void)?
    private var translations: [ObjectIdentifier: [TranslatedBlock]] = [:]
    private var translating = Set<ObjectIdentifier>()
    private var translateMarquee: (PDFPage, CGRect)?

    func translationBlocks(on page: PDFPage) -> [TranslatedBlock] {
        translationOn ? translations[ObjectIdentifier(page)] ?? [] : []
    }

    func marquee(on page: PDFPage) -> CGRect? {
        translateMarquee.flatMap { $0.0 === page ? $0.1 : nil }
    }

    func hasTranslation(on page: PDFPage) -> Bool {
        !(translations[ObjectIdentifier(page)] ?? []).isEmpty
    }

    /// Languages changed: everything translated so far is outdated.
    func resetTranslations() {
        translations = [:]
        redrawAllOverlays()
        translateCurrentPageIfNeeded()
    }

    private func redrawAllOverlays() {
        guard let doc = document else { return }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { overlays.object(forKey: page)?.needsDisplay = true }
        }
    }

    @objc private func pageDidChange(_ note: Notification) {
        translateCurrentPageIfNeeded()
    }

    func translateCurrentPageIfNeeded() {
        guard translationOn, translationScope == .page, let page = currentPage, !hasTranslation(on: page) else { return }
        translate(page: page, area: nil)
    }

    func translate(page: PDFPage, area: CGRect?) {
        let key = ObjectIdentifier(page)
        guard !translating.contains(key) else { return }
        let blocks = PageTextBlocks.blocks(on: page, in: area)
        guard !blocks.isEmpty else {
            onTranslationStatus?(area == nil ? "На странице нет текста для перевода (скан? — нужен текстовый слой)" : "В рамке нет текста")
            return
        }
        translating.insert(key)
        onTranslationStatus?("Перевод: \(blocks.count) блоков…")
        let from = TranslationSettings.sourceLanguage, to = TranslationSettings.targetLanguage
        Task { @MainActor in
            defer { self.translating.remove(key) }
            do {
                let out = try await TranslationService.translate(blocks.map(\.source), from: from, to: to)
                for (block, text) in zip(blocks, out) {
                    block.text = text
                    block.background = BackgroundSampler.color(on: page, around: block.rect.insetBy(dx: -2, dy: -2))
                    block.fit()
                }
                var list = self.translations[key] ?? []
                if let area { list.removeAll { $0.rect.intersects(area) } } else { list = [] }
                self.translations[key] = list + blocks
                self.overlays.object(forKey: page)?.needsDisplay = true
                self.onTranslationStatus?(nil)
            } catch {
                self.onTranslationStatus?(nil)
                self.onTranslationError?(error.localizedDescription)
            }
        }
    }

    /// Diagnostics: show `blocks` as the page's translation without a network call.
    func injectTranslation(_ blocks: [TranslatedBlock], on page: PDFPage) {
        for b in blocks {
            b.background = BackgroundSampler.color(on: page, around: b.rect.insetBy(dx: -2, dy: -2))
            b.fit()
        }
        translations[ObjectIdentifier(page)] = blocks
        overlays.object(forKey: page)?.needsDisplay = true
    }

    /// Turns the overlay translation of a page into regular text blocks that
    /// hide (and on save remove) the original under them.
    func moveTranslationIntoDocument(page: PDFPage) {
        let blocks = translations[ObjectIdentifier(page)] ?? []
        guard !blocks.isEmpty else { NSSound.beep(); return }
        let pad = TextBoxAnnotation.padding
        undoManager?.beginUndoGrouping()
        for b in blocks {
            guard let text = b.text else { continue }
            let tb = TextBoxAnnotation(text: text, font: TranslatedBlock.font(b.fittedSize), color: .black,
                                       topLeft: CGPoint(x: b.rect.minX - pad, y: b.rect.maxY + pad))
            tb.wrapWidth = b.rect.width + 2 * pad
            tb.minHeight = b.rect.height + 2 * pad
            tb.erasesBelow = true
            tb.cover = CGSize(width: tb.wrapWidth!, height: tb.minHeight)
            tb.coverColor = b.background
            tb.fit()
            add(tb, to: page, name: "Перевод в документ")
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Перевод в документ")
        translations[ObjectIdentifier(page)] = nil
        refresh(page: page)
    }

    // MARK: - Page overlays

    private let overlays = NSMapTable<PDFPage, PageOverlayView>.weakToWeakObjects()

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageOverlayView()
        overlay.pdfView = self
        overlay.page = page
        overlays.setObject(overlay, forKey: page)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays.removeObject(forKey: page)
    }

    /// Document-view units per page point. The scroll view magnifies the
    /// document view, so this is usually 1 regardless of zoom.
    private func documentScale(for page: PDFPage) -> CGFloat {
        guard let doc = documentView else { return scaleFactor }
        let r = doc.convert(convert(CGRect(x: 0, y: 0, width: 100, height: 100), from: page), from: self)
        return max(0.01, r.width / 100)
    }

    // MARK: - Placement (shared by UI and self-test)

    func makeTextBox(on page: PDFPage, at p: CGPoint, snap: Bool) -> TextBoxAnnotation {
        let fields = snap ? detector.fields(on: page) : []
        var size = fontSize
        var x = p.x
        let baseline: CGFloat
        if let box = FieldDetector.box(containing: p, in: fields, kinds: [.box]) {
            size = min(size, box.height * 0.7)
            let f = NSFont.defaultFill(size)
            x = box.minX + 3
            baseline = box.midY - (f.ascender + f.descender) / 2
        } else if let line = FieldDetector.line(near: p, in: fields) {
            x = max(p.x, line.minX + 1)
            baseline = line.maxY + 3
        } else {
            let f = NSFont.defaultFill(size)
            baseline = p.y - (f.ascender + f.descender) / 2
        }
        let font = NSFont.defaultFill(size)
        let top = baseline + TextBoxAnnotation.padding + font.ascender
        return TextBoxAnnotation(text: "", font: font, color: textColor,
                                 topLeft: CGPoint(x: x - TextBoxAnnotation.padding, y: top))
    }

    func makeMark(_ kind: MarkKind, on page: PDFPage, at p: CGPoint, snap: Bool) -> MarkAnnotation {
        let fields = snap ? detector.fields(on: page) : []
        let rect: CGRect
        if let cb = FieldDetector.box(containing: p, in: fields, kinds: [.checkbox], tolerance: 3) {
            let side = min(cb.width, cb.height) * 0.85
            rect = CGRect(x: cb.midX - side / 2, y: cb.midY - side / 2, width: side, height: side)
        } else {
            let side = max(6, fontSize * 0.9)
            rect = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        }
        return MarkAnnotation(kind: kind, color: textColor, rect: rect)
    }

    func makeSignature(_ image: NSImage, on page: PDFPage, at p: CGPoint, snap: Bool) -> ImageAnnotation {
        let fields = snap ? detector.fields(on: page) : []
        let aspect = image.size.height / max(image.size.width, 1)
        var w: CGFloat = 130
        var h = w * aspect
        if h > 55 { h = 55; w = h / aspect }
        let rect: CGRect
        if let box = FieldDetector.box(containing: p, in: fields, kinds: [.box]) {
            let k = min(1, (box.width - 4) / w, (box.height - 4) / h)
            w *= k
            h *= k
            rect = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        } else if let line = FieldDetector.line(near: p, in: fields) {
            // Signatures sit on the line with the tail dipping below it.
            rect = CGRect(x: p.x - w / 2, y: line.maxY - h * 0.25, width: w, height: h)
        } else {
            rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        }
        return ImageAnnotation(image: image, rect: rect)
    }

    /// Replacement for existing page text: same font, size and colour,
    /// placed exactly over the original glyphs.
    func makeReplacement(for sel: PDFSelection, on page: PDFPage) -> TextBoxAnnotation? {
        guard let raw = sel.string else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = sel.bounds(for: page)
        guard !text.isEmpty, b.width > 0.5, b.height > 0.5 else { return nil }

        var font = NSFont.defaultFill(b.height * 0.75)
        var color = NSColor.black
        if let attr = sel.attributedString, attr.length > 0 {
            let ns = attr.string as NSString
            let first = ns.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
            let i = first.location == NSNotFound ? 0 : first.location
            if let f = attr.attribute(.font, at: i, effectiveRange: nil) as? NSFont {
                // Some PDFs report unit-size fonts scaled by the text matrix.
                let lines = CGFloat(max(1, text.components(separatedBy: .newlines).count))
                let lineHeight = b.height / lines
                font = (f.pointSize < lineHeight * 0.4 || f.pointSize > lineHeight * 1.6) ? f.sized(lineHeight * 0.75) : f
            }
            if let c = attr.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor { color = c }
        }

        let pad = TextBoxAnnotation.padding
        // PDFKit's line bounds can stop short of the last glyph; extend the
        // cover to the right so no original pixels peek out.
        var coverRect = b.insetBy(dx: -pad, dy: -1)
        coverRect.size.width += b.height / CGFloat(max(1, text.components(separatedBy: .newlines).count)) * 0.4
        let tb = TextBoxAnnotation(text: text, font: font, color: color,
                                   topLeft: CGPoint(x: coverRect.minX, y: coverRect.maxY))
        tb.cover = coverRect.size
        tb.coverColor = BackgroundSampler.color(on: page, around: coverRect)
        tb.redactionRect = b
        tb.fit()
        return tb
    }

    // MARK: - Mouse

    private func locate(_ event: NSEvent) -> (PDFPage, CGPoint, CGPoint)? {
        let vp = convert(event.locationInWindow, from: nil)
        guard let page = page(for: vp, nearest: true) else { return nil }
        return (page, convert(vp, to: page), vp)
    }

    private func hitAnnotation(on page: PDFPage, at p: CGPoint) -> EditableAnnotation? {
        let tol = 3 / max(scaleFactor, 0.1)
        return page.annotations.reversed()
            .compactMap { $0 as? EditableAnnotation }
            .filter { !(($0 as? HighlightAnnotation)?.isMarkHidden ?? false) }
            .first { $0.bounds.insetBy(dx: -tol, dy: -tol).contains(p) }
    }

    private func detectedFieldAt(_ p: CGPoint, on page: PDFPage) -> Bool {
        let fields = detector.fields(on: page)
        return FieldDetector.box(containing: p, in: fields, kinds: [.box]) != nil
            || FieldDetector.line(near: p, in: fields) != nil
    }

    private func isOnHandle(_ a: EditableAnnotation, viewPoint vp: CGPoint) -> Bool {
        guard let page = a.page else { return false }
        let corner = convert(CGPoint(x: a.bounds.maxX, y: a.bounds.minY), from: page)
        return hypot(corner.x - vp.x, corner.y - vp.y) <= 9
    }

    override func mouseDown(with event: NSEvent) {
        if editing != nil { finishEditing() }
        window?.makeFirstResponder(self)
        // Translation of a chosen area: drag a frame (Select tool or view mode).
        if translationOn, translationScope == .selection, mode == .view || tool == .select,
           let (page, p, _) = locate(event), hitAnnotation(on: page, at: p) == nil, page.annotation(at: p)?.type != "Widget" {
            selected = nil
            drag = .translateArea(page, p)
            return
        }
        guard mode != .view, let (page, p, vp) = locate(event) else { super.mouseDown(with: event); return }
        let snap = !event.modifierFlags.contains(.option)

        if let s = selected, s.page === page, isOnHandle(s, viewPoint: vp) {
            drag = .resize(s, p, s.state)
            return
        }
        // Native form fields are PDFKit's, whatever tool is active.
        if hitAnnotation(on: page, at: p) == nil, let w = page.annotation(at: p), w.type == "Widget" {
            selected = nil
            super.mouseDown(with: event)
            return
        }
        if let hit = hitAnnotation(on: page, at: p) {
            if event.clickCount >= 2, let tb = hit as? TextBoxAnnotation {
                beginEditing(tb, isNew: false)
                return
            }
            if event.clickCount >= 2, let h = hit as? HighlightAnnotation {
                editNote(of: h, isNew: false)
                return
            }
            selected = hit
            drag = .move(hit, p, hit.state, false)
            return
        }
        selected = nil

        switch tool {
        case .select:
            // Double-click on a detected line / cell starts typing there.
            if event.clickCount >= 2, detectedFieldAt(p, on: page) {
                clearSelection()
                let tb = makeTextBox(on: page, at: p, snap: true)
                page.addAnnotation(tb)
                beginEditing(tb, isNew: true)
                return
            }
            super.mouseDown(with: event)
        case .text:
            // Decided on mouse-up: a click places text, a drag draws an area.
            drag = .textArea(nil, page, p, snap)
        case .cross, .check:
            add(makeMark(tool == .cross ? .cross : .check, on: page, at: p, snap: snap), to: page, name: "Отметка")
            if !event.modifierFlags.contains(.shift) { tool = .select }
        case .signature:
            guard let img = signatureImage else { editorDelegate?.editorNeedsSignature(); return }
            let s = makeSignature(img, on: page, at: p, snap: snap)
            add(s, to: page, name: "Подпись")
            selected = s
        case .whiteout:
            let w = WhiteoutAnnotation(rect: CGRect(origin: p, size: .zero))
            page.addAnnotation(w)
            drag = .rect(w, page, p)
        case .highlight:
            marksVisible = true
            let h = HighlightAnnotation(rect: CGRect(origin: p, size: .zero))
            page.addAnnotation(h)
            drag = .rect(h, page, p)
        case .editText:
            drag = .textSelect(page, p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch drag {
        case .none:
            super.mouseDragged(with: event)
        case let .move(a, start, original, _):
            guard let page = a.page else { return }
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            var b = original["bounds"] as! CGRect
            b.origin.x += p.x - start.x
            b.origin.y += p.y - start.y
            a.bounds = b
            refresh(a)
            drag = .move(a, start, original, true)
        case let .resize(a, start, original):
            guard let page = a.page else { return }
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            resize(a, original: original, dx: p.x - start.x, dy: start.y - p.y)
            refresh(a)
        case let .rect(w, page, start):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            w.bounds = CGRect(x: min(p.x, start.x), y: min(p.y, start.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            refresh(w)
        case let .textSelect(page, start):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            currentSelection = page.selection(from: start, to: p)
        case let .translateArea(page, start):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            translateMarquee = (page, CGRect(x: min(p.x, start.x), y: min(p.y, start.y), width: abs(p.x - start.x), height: abs(p.y - start.y)))
            overlays.object(forKey: page)?.needsDisplay = true
        case let .textArea(area, page, start, snap):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            let r = CGRect(x: min(p.x, start.x), y: min(p.y, start.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            guard area != nil || hypot(r.width, r.height) * scaleFactor > 6 else { return }
            let tb = area ?? makeTextArea(on: page)
            if area == nil { page.addAnnotation(tb) }
            tb.bounds = r
            tb.wrapWidth = max(12, r.width)
            tb.minHeight = r.height
            if tb.erasesBelow { tb.cover = r.size }
            refresh(tb)
            drag = .textArea(tb, page, start, snap)
        }
    }

    private func makeTextArea(on page: PDFPage) -> TextBoxAnnotation {
        let tb = TextBoxAnnotation(text: "", font: .defaultFill(fontSize), color: textColor, topLeft: .zero)
        tb.wrapWidth = 12
        if eraseUnderText { tb.erasesBelow = true }
        return tb
    }

    override func mouseUp(with event: NSEvent) {
        let current = drag
        drag = .none
        switch current {
        case .none:
            super.mouseUp(with: event)
        case let .move(a, _, original, moved):
            if moved {
                commit(a, from: original, name: "Перемещение")
            } else if tool == .text || tool == .editText, let tb = a as? TextBoxAnnotation {
                beginEditing(tb, isNew: false)
            }
        case let .resize(a, _, original):
            commit(a, from: original, name: "Изменение размера")
        case let .rect(w, page, _):
            page.removeAnnotation(w)
            refresh(page: page)
            guard w.bounds.width >= 2 && w.bounds.height >= 2 else { break }
            if let h = w as? HighlightAnnotation {
                add(h, to: page, name: "Маркер")
                editNote(of: h, isNew: true)
            } else {
                add(w, to: page, name: "Замазка")
            }
        case let .translateArea(page, _):
            let area = translateMarquee?.1
            translateMarquee = nil
            overlays.object(forKey: page)?.needsDisplay = true
            if let area, area.width * scaleFactor > 8, area.height * scaleFactor > 4 {
                translate(page: page, area: area)
            }
        case let .textArea(area, page, start, snap):
            if let tb = area {
                tb.bounds.size.height = max(tb.bounds.height, 6)
                tb.minHeight = tb.bounds.height
                if tb.erasesBelow {
                    tb.cover = tb.bounds.size
                    tb.coverColor = BackgroundSampler.color(on: page, around: tb.bounds)
                }
                tb.fit()
                beginEditing(tb, isNew: true)
            } else {
                let tb = makeTextBox(on: page, at: start, snap: snap)
                page.addAnnotation(tb)
                beginEditing(tb, isNew: true)
            }
        case let .textSelect(page, start):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            let sel = hypot(p.x - start.x, p.y - start.y) < 3
                ? page.selectionForLine(at: p)
                : page.selection(from: start, to: p)
            clearSelection()
            if let sel, let tb = makeReplacement(for: sel, on: page) {
                page.addAnnotation(tb)
                beginEditing(tb, isNew: true)
            }
        }
    }

    private func resize(_ a: EditableAnnotation, original: [String: Any], dx: CGFloat, dy: CGFloat) {
        a.state = original
        let ob = original["bounds"] as! CGRect
        switch a.resizeMode {
        case .free:
            let w = max(2, ob.width + dx), h = max(2, ob.height + dy)
            if let tb = a as? TextBoxAnnotation, tb.wrapWidth != nil {
                tb.wrapWidth = w
                tb.minHeight = h
                if tb.cover != nil { tb.cover = CGSize(width: w, height: h) }
                tb.fit()
            } else if let tb = a as? TextBoxAnnotation {
                tb.cover = CGSize(width: w, height: h)
                tb.fit()
            } else {
                a.bounds = CGRect(x: ob.minX, y: ob.maxY - h, width: w, height: h)
            }
        case .aspect:
            let w = max(4, ob.width + max(dx, dy * ob.width / max(ob.height, 1)))
            let h = w * ob.height / max(ob.width, 1)
            a.bounds = CGRect(x: ob.minX, y: ob.maxY - h, width: w, height: h)
        case .fontScale:
            guard let tb = a as? TextBoxAnnotation else { return }
            let ratio = max(0.2, (ob.height + dy) / max(ob.height, 1))
            tb.textFont = tb.textFont.sized(max(3, tb.textFont.pointSize * ratio))
            tb.fit()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode != .view, let (page, p, vp) = locate(event) else { super.mouseMoved(with: event); return }
        if hitAnnotation(on: page, at: p) == nil, page.annotation(at: p)?.type == "Widget" {
            super.mouseMoved(with: event)
        } else if let s = selected, s.page === page, isOnHandle(s, viewPoint: vp) {
            NSCursor.crosshair.set()
        } else if hitAnnotation(on: page, at: p) != nil {
            NSCursor.openHand.set()
        } else {
            switch tool {
            case .select: super.mouseMoved(with: event)
            case .text, .editText: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if let a = selected, mods.isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var delta: CGPoint?
            switch event.keyCode {
            case 51, 117:
                remove(a, name: "Удаление")
                return
            case 36, 76:
                if let tb = a as? TextBoxAnnotation { beginEditing(tb, isNew: false); return }
            case 123: delta = CGPoint(x: -step, y: 0)
            case 124: delta = CGPoint(x: step, y: 0)
            case 125: delta = CGPoint(x: 0, y: -step)
            case 126: delta = CGPoint(x: 0, y: step)
            default: break
            }
            if let d = delta {
                let original = a.state
                a.bounds = a.bounds.offsetBy(dx: d.x, dy: d.y)
                commit(a, from: original, name: "Перемещение")
                return
            }
        }
        if event.keyCode == 53 {
            selected = nil
            tool = .select
            return
        }
        if mode != .view, mods.isEmpty, !event.modifierFlags.contains(.shift),
           let t = Tool.allCases.first(where: { $0.keyCode == event.keyCode }) {
            if !mode.tools.contains(t) { mode = t.preferredMode }
            tool = t
            return
        }
        super.keyDown(with: event)
    }

    func deleteSelected() {
        if let a = selected { remove(a, name: "Удаление") }
    }

    /// Picks a tool, moving to a mode that offers it if needed.
    func activate(_ t: Tool) {
        if !mode.tools.contains(t) { mode = t.preferredMode }
        tool = t
    }

    var hasSelection: Bool { selected != nil }

    // MARK: - Style

    /// Applies the toolbar font size / colour to the edited or selected object.
    func applyStyle() {
        if let tb = editing, let tv = editor {
            tb.textFont = tb.textFont.sized(fontSize)
            tb.ink = textColor
            styleEditor(tv, for: tb)
            layoutEditor()
            return
        }
        guard let a = selected else { return }
        let original = a.state
        if let tb = a as? TextBoxAnnotation {
            tb.textFont = tb.textFont.sized(fontSize)
            tb.ink = textColor
            tb.fit()
        } else if let m = a as? MarkAnnotation {
            m.ink = textColor
        } else {
            return
        }
        commit(a, from: original, name: "Стиль")
    }

    /// Toggles "erase under text" on the edited / selected text block.
    func applyEraseToSelection() {
        guard let tb = editing ?? (selected as? TextBoxAnnotation), tb.redactionRect == nil, let page = tb.page else { return }
        let original = tb.state
        tb.erasesBelow = eraseUnderText
        tb.cover = eraseUnderText ? tb.bounds.size : nil
        if eraseUnderText { tb.coverColor = BackgroundSampler.color(on: page, around: tb.bounds) }
        if let tv = editor, editing === tb {
            styleEditor(tv, for: tb)
            return
        }
        tb.fit()
        commit(tb, from: original, name: "Стирать под текстом")
    }

    // MARK: - Inline text editing

    func beginEditing(_ tb: TextBoxAnnotation, isNew: Bool) {
        finishEditing()
        guard tb.page != nil, let doc = documentView else { return }
        selected = nil
        editing = tb
        editingIsNew = isNew
        editingOriginal = tb.state
        tb.isEditing = true
        refresh(tb)

        let tv = NSTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        let k = tb.page.map(documentScale(for:)) ?? 1
        tv.textContainer?.containerSize = NSSize(width: tb.wrapWidth.map { max(4, ($0 - 2 * TextBoxAnnotation.padding) * k) } ?? 1e6,
                                                 height: 1e6)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        styleEditor(tv, for: tb)
        tv.string = tb.text
        doc.addSubview(tv)
        editor = tv
        layoutEditor()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    private func styleEditor(_ tv: NSTextView, for tb: TextBoxAnnotation) {
        let s = tb.page.map(documentScale(for:)) ?? 1
        // The border is magnified with the document; keep it one screen pixel wide.
        tv.layer?.borderWidth = s / max(scaleFactor, 0.05)
        let font = tb.textFont.sized(tb.textFont.pointSize * s)
        tv.font = font
        tv.textColor = tb.ink
        tv.insertionPointColor = tb.ink
        tv.typingAttributes = [.font: font, .foregroundColor: tb.ink]
        tv.drawsBackground = true
        tv.backgroundColor = tb.cover != nil || tb.erasesBelow ? tb.coverColor : NSColor.white.withAlphaComponent(0.9)
        let inset = TextBoxAnnotation.padding * s
        tv.textContainerInset = NSSize(width: inset, height: inset)
    }

    private func layoutEditor() {
        guard let tv = editor, let tb = editing, let page = tb.page, let doc = documentView else { return }
        let s = documentScale(for: page)
        tb.text = tv.string
        let ts = tb.textSize()
        let topLeft = CGPoint(x: tb.bounds.minX, y: tb.bounds.maxY - tb.textTopInset)
        let dp = doc.convert(convert(topLeft, from: page), from: self)
        let width = tb.wrapWidth.map { $0 * s } ?? (max(ts.width, tb.cover?.width ?? 0, 24) * s + 4)
        let height = max(ts.height, tb.minHeight) * s
        let origin = doc.isFlipped ? dp : CGPoint(x: dp.x, y: dp.y - height)
        tv.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    func textDidChange(_ notification: Notification) {
        layoutEditor()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        editorUndo
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            finishEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(cancel: true)
            return true
        default:
            return false
        }
    }

    var isEditingText: Bool { editing != nil }

    func finishEditing(cancel: Bool = false) {
        guard let tb = editing, let tv = editor else { return }
        let typed = tv.string
        editing = nil
        editor = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        editorUndo.removeAllActions()
        tb.isEditing = false
        if window?.firstResponder == nil || window?.firstResponder === tv { window?.makeFirstResponder(self) }
        guard let page = tb.page else { return }

        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = editingOriginal["text"] as? String ?? ""
        // Everything changed while editing (text, style, erase toggle).
        var final = tb.state
        final["text"] = text

        tb.state = editingOriginal
        let unchanged = text == originalText
            && (final["font"] as? NSFont) == tb.textFont
            && (final["color"] as? NSColor) == tb.ink
            && (final["erase"] as? Bool) == tb.erasesBelow

        if editingIsNew {
            if cancel || text.isEmpty || (tb.redactionRect != nil && unchanged) {
                page.removeAnnotation(tb)
                refresh(page: page)
                return
            }
            tb.state = final
            tb.fit()
            page.removeAnnotation(tb)
            add(tb, to: page, name: tb.redactionRect != nil ? "Правка текста" : "Текст")
        } else {
            if cancel || unchanged { refresh(tb); return }
            if text.isEmpty {
                remove(tb, name: "Удаление текста")
                return
            }
            let original = tb.state
            tb.state = final
            tb.fit()
            commit(tb, from: original, name: "Правка текста")
        }
    }

    // MARK: - Field hints

    private func updateHints() {
        hintGeneration += 1
        for h in hints {
            let page = h.page
            page?.removeAnnotation(h)
            if let page { refresh(page: page) }
        }
        hints = []
        guard showsFieldHints, let doc = document else { return }
        let generation = hintGeneration
        func step(_ i: Int) {
            guard generation == hintGeneration, i < doc.pageCount, let page = doc.page(at: i) else { return }
            for f in detector.fields(on: page) {
                let h = HintAnnotation(field: f)
                page.addAnnotation(h)
                hints.append(h)
            }
            refresh(page: page)
            DispatchQueue.main.async { step(i + 1) }
        }
        step(0)
    }

    /// Called after pages were inserted, removed or reordered.
    func documentPagesChanged() {
        if showsFieldHints { updateHints() }
        applyMarksVisibility()
        editorDelegate?.editorPagesChanged()
    }

    // MARK: - Marker notes

    /// Shows or hides yellow markers with their notes, and native markup
    /// annotations that came with the file.
    var marksVisible = true {
        didSet { if oldValue != marksVisible { applyMarksVisibility() } }
    }

    private static let nativeMarkupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "Popup", "FreeText", "Ink", "Square", "Circle"]

    private func applyMarksVisibility() {
        guard let doc = document else { return }
        if !marksVisible, selected is HighlightAnnotation { selected = nil }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var changed = false
            for a in page.annotations {
                if let h = a as? HighlightAnnotation {
                    if h.isMarkHidden == marksVisible { h.isMarkHidden = !marksVisible; changed = true }
                } else if !(a is EditableAnnotation), !(a is HintAnnotation), let t = a.type, Self.nativeMarkupTypes.contains(t),
                          a.shouldDisplay != marksVisible {
                    a.shouldDisplay = marksVisible
                    changed = true
                }
            }
            if changed { refresh(page: page) }
        }
        editorDelegate?.editorMarksVisibilityChanged(marksVisible)
    }

    private var notePopover: NSPopover?

    func editNote(of h: HighlightAnnotation, isNew: Bool) {
        guard let page = h.page else { return }
        notePopover?.close()
        let controller = NoteEditorController(text: h.note, isNew: isNew)
        controller.onFinish = { [weak self, weak h] text, delete in
            guard let self, let h else { return }
            self.notePopover?.close()
            self.notePopover = nil
            if delete {
                self.remove(h, name: "Удаление маркера")
            } else if text != h.note {
                var st = h.state
                st["note"] = text
                st["bounds"] = HighlightAnnotation.bounds(forBlock: h.blockRect, note: text)
                self.apply(st, to: h, name: "Заметка")
            }
            self.window?.makeFirstResponder(self)
        }
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.behavior = .transient
        pop.delegate = controller
        notePopover = pop
        let r = convert(h.bounds, from: page)
        pop.show(relativeTo: r.insetBy(dx: -2, dy: -2), of: self, preferredEdge: .maxY)
        controller.focus()
    }

    // MARK: - Dropping files onto the page

    var onDropFiles: (([URL]) -> Void)?

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(DocumentImporter.canImport)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        // Pictures dropped onto a layout sheet land on it where they were dropped.
        let vp = convert(sender.draggingLocation, from: nil)
        if files.allSatisfy(DocumentImporter.isImage), let page = page(for: vp, nearest: false), isLayoutSheet(page) {
            placeImages(files.compactMap(NSImage.init(contentsOf:)), on: page, at: convert(vp, to: page))
            return true
        }
        onDropFiles?(files)
        return true
    }

    // MARK: - Copy / paste of objects

    /// Objects copied in this app. The pasteboard change count tells whether
    /// the clipboard still holds them or something newer from another app.
    private enum ObjectClipboard {
        static var items: [EditableAnnotation] = []
        static var changeCount = -1
        static var sourcePage: PDFPage?
        static var pasteCount = 0
    }

    private static let objectPasteboardType = NSPasteboard.PasteboardType("com.zed.pageyard.objects")

    override func copy(_ sender: Any?) {
        guard let a = selected else { super.copy(sender); return }
        ObjectClipboard.items = [a.duplicate()]
        ObjectClipboard.sourcePage = a.page
        ObjectClipboard.pasteCount = 0
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("", forType: Self.objectPasteboardType)
        // Other apps get a picture of the object.
        if let png = Self.pngPreview(of: a) { pb.setData(png, forType: .png) }
        if let tb = a as? TextBoxAnnotation { pb.setString(tb.text, forType: .string) }
        ObjectClipboard.changeCount = pb.changeCount
    }

    @objc func cut(_ sender: Any?) {
        guard let a = selected else { NSSound.beep(); return }
        copy(sender)
        remove(a, name: "Вырезать")
    }

    @objc func paste(_ sender: Any?) {
        guard mode != .view, let page = currentPage else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        if pb.changeCount == ObjectClipboard.changeCount, !ObjectClipboard.items.isEmpty {
            ObjectClipboard.pasteCount += 1
            // Same page: cascade so the copy is visible; other page: same spot.
            let step = ObjectClipboard.sourcePage === page ? CGFloat(ObjectClipboard.pasteCount) * 12 : 0
            var last: EditableAnnotation?
            for item in ObjectClipboard.items {
                let c = item.duplicate()
                c.bounds = clamp(c.bounds.offsetBy(dx: step, dy: -step), to: page)
                add(c, to: page, name: "Вставка")
                last = c
            }
            tool = .select
            selected = last
            return
        }
        // Something from another app: a picture or text.
        let center = visibleCenter(on: page)
        if let image = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff, .pdf, .fileURL]) != nil {
            let box = page.bounds(for: .cropBox)
            let k = min(1, box.width * 0.5 / max(image.size.width, 1), box.height * 0.5 / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * k, height: image.size.height * k)
            let a = ImageAnnotation(image: image, rect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                                               width: size.width, height: size.height))
            add(a, to: page, name: "Вставка картинки")
            tool = .select
            selected = a
        } else if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let tb = TextBoxAnnotation(text: text, font: .defaultFill(fontSize), color: textColor, topLeft: .zero)
            tb.wrapWidth = min(tb.textSize().width, page.bounds(for: .cropBox).width * 0.6)
            tb.fit()
            tb.bounds.origin = CGPoint(x: center.x - tb.bounds.width / 2, y: center.y - tb.bounds.height / 2)
            add(tb, to: page, name: "Вставка текста")
            tool = .select
            selected = tb
        } else {
            NSSound.beep()
        }
    }

    @objc func duplicateSelection(_ sender: Any?) {
        guard let a = selected, let page = a.page else { NSSound.beep(); return }
        let c = a.duplicate()
        c.bounds = clamp(a.bounds.offsetBy(dx: 12, dy: -12), to: page)
        add(c, to: page, name: "Дублировать")
        selected = c
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return selected != nil || !(currentSelection?.string ?? "").isEmpty
        case #selector(cut(_:)), #selector(duplicateSelection(_:)):
            return selected != nil && mode != .view
        case #selector(paste(_:)):
            return canPasteObject
        default:
            return responds(to: item.action)
        }
    }

    var canPasteObject: Bool {
        guard mode != .view else { return false }
        let pb = NSPasteboard.general
        return (pb.changeCount == ObjectClipboard.changeCount && !ObjectClipboard.items.isEmpty)
            || pb.availableType(from: [.png, .tiff, .pdf, .string]) != nil
    }

    private func clamp(_ r: CGRect, to page: PDFPage) -> CGRect {
        let box = page.bounds(for: .cropBox)
        var r = r
        r.origin.x = min(max(r.minX, box.minX), max(box.minX, box.maxX - r.width))
        r.origin.y = min(max(r.minY, box.minY), max(box.minY, box.maxY - r.height))
        return r
    }

    private func visibleCenter(on page: PDFPage) -> CGPoint {
        let p = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: page)
        let box = page.bounds(for: .cropBox)
        return CGPoint(x: min(max(p.x, box.minX), box.maxX), y: min(max(p.y, box.minY), box.maxY))
    }

    private static func pngPreview(of a: EditableAnnotation) -> Data? {
        let scale: CGFloat = 3
        let r = a.bounds
        guard r.width > 0, r.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(r.width * scale), pixelsHigh: Int(r.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let wasSelected = a.isSelected
        a.isSelected = false
        defer { a.isSelected = wasSelected }
        let ctx = gc.cgContext
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        a.render(in: ctx)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Continuity import

    /// Hand "Import from iPhone or iPad" to the window controller, which
    /// knows how to turn scans and photos into pages.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, ContinuityImport.accepts(returnType),
           let controller = window?.windowController as? EditorWindowController {
            return controller.validRequestor(forSendType: sendType, returnType: returnType)
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: - Layout sheets

    /// Pages created for arranging pictures; marked in the sidebar.
    private var layoutSheets = Set<ObjectIdentifier>()

    func markLayoutSheet(_ page: PDFPage) {
        layoutSheets.insert(ObjectIdentifier(page))
    }

    func isLayoutSheet(_ page: PDFPage) -> Bool {
        layoutSheets.contains(ObjectIdentifier(page))
    }

    /// Adds pictures as movable objects: at `point` (cascading) or, without a
    /// point, laid out in a grid when the sheet is empty / centred otherwise.
    func placeImages(_ images: [NSImage], on page: PDFPage, at point: CGPoint?) {
        guard !images.isEmpty else { return }
        if mode == .view { mode = .fill }
        let box = page.bounds(for: .cropBox)
        let hasImages = page.annotations.contains { $0 is ImageAnnotation }
        var rects: [CGRect]
        if point == nil && !hasImages {
            rects = PageFactory.arrange(images.map(\.size), in: box.size).map { $0.offsetBy(dx: box.minX, dy: box.minY) }
        } else {
            let center = point ?? CGPoint(x: box.midX, y: box.midY)
            rects = images.enumerated().map { i, img in
                let k = min(box.width * 0.45 / max(img.size.width, 1), box.height * 0.45 / max(img.size.height, 1))
                let w = img.size.width * k, h = img.size.height * k
                return CGRect(x: center.x - w / 2 + CGFloat(i) * 16, y: center.y - h / 2 - CGFloat(i) * 16, width: w, height: h)
            }
        }
        var last: ImageAnnotation?
        for (img, r) in zip(images, rects) {
            let a = ImageAnnotation(image: img, rect: r)
            add(a, to: page, name: images.count == 1 ? "Картинка" : "Картинки")
            last = a
        }
        tool = .select
        selected = last
    }
}

/// Popover body for a marker note.
final class NoteEditorController: NSViewController, NSPopoverDelegate {
    var onFinish: ((String, Bool) -> Void)?
    private let textView = NSTextView()
    private let initial: String
    private let isNew: Bool
    private var finished = false

    init(text: String, isNew: Bool) {
        initial = text
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 150))
        let title = NSTextField(labelWithString: isNew ? "Заметка к выделению (можно оставить пустой)" : "Заметка")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: 124, width: 256, height: 16)
        root.addSubview(title)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 44, width: 256, height: 76))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.frame = scroll.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.string = initial
        scroll.documentView = textView
        root.addSubview(scroll)

        let delete = NSButton(title: "Удалить маркер", target: self, action: #selector(deleteMark))
        delete.bezelStyle = .rounded
        delete.frame = NSRect(x: 8, y: 8, width: 130, height: 28)
        root.addSubview(delete)
        let done = NSButton(title: "Готово", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.toolTip = "⌘↩"
        done.frame = NSRect(x: 182, y: 8, width: 90, height: 28)
        root.addSubview(done)
        view = root
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    private func finish(delete: Bool) {
        guard !finished else { return }
        finished = true
        onFinish?(textView.string.trimmingCharacters(in: .whitespacesAndNewlines), delete)
    }

    @objc private func done() { finish(delete: false) }
    @objc private func deleteMark() { finish(delete: true) }

    func popoverWillClose(_ notification: Notification) {
        finish(delete: false)
    }
}
