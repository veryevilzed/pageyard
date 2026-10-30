import AppKit
import UniformTypeIdentifiers

/// Saved signatures, kept as transparent PNGs in Application Support.
final class SignatureStore {
    static let shared = SignatureStore()
    static let changed = Notification.Name("SignatureStoreChanged")

    struct Item {
        let id: String
        let url: URL
        let image: NSImage
    }

    private(set) var items: [Item] = []
    let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("PageYard/Signatures", isDirectory: true)
        // Signatures saved before the app was renamed from PDFEdit.
        let legacy = base.appendingPathComponent("PDFEdit/Signatures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: legacy, to: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    var currentID: String? {
        get { UserDefaults.standard.string(forKey: "currentSignature") }
        set {
            UserDefaults.standard.set(newValue, forKey: "currentSignature")
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    var current: Item? {
        items.first { $0.id == currentID } ?? items.last
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        items = urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
            .compactMap { url in
                NSImage(contentsOf: url).map { Item(id: url.deletingPathExtension().lastPathComponent, url: url, image: $0) }
            }
    }

    @discardableResult
    func add(_ image: NSImage) -> Item? {
        guard let png = Self.pngData(image) else { return nil }
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("\(id).png")
        do { try png.write(to: url) } catch { return nil }
        reload()
        currentID = id
        return items.first { $0.id == id }
    }

    func remove(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: item.url)
        reload()
        currentID = items.last?.id
    }

    static func pngData(_ image: NSImage) -> Data? {
        if let rep = image.representations.first as? NSBitmapImageRep, let d = rep.representation(using: .png, properties: [:]) {
            return d
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    struct Cleanup {
        var removeBackground = true
        /// 0…1: higher removes more (shadows, faint strokes, paper texture).
        var strength: CGFloat = 0.5
        /// Recolour the ink; nil keeps the photo's colours.
        var ink: NSColor?
    }

    /// Turns a photo / scan / pasted signature into ink on a transparent
    /// background, cropped to the ink. The paper level is estimated locally,
    /// so grey paper and uneven phone-camera lighting are handled too.
    static func cleanedSignature(from image: NSImage, cleanup: Cleanup = Cleanup()) -> NSImage? {
        // Rasterise first: pasted Preview signatures arrive as vector PDF.
        let pts = image.size
        guard pts.width > 0, pts.height > 0 else { return nil }
        let scale = min(8, 1600 / max(pts.width, pts.height))
        let w = max(1, Int(pts.width * scale)), h = max(1, Int(pts.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }

        // Luminance of the un-premultiplied colour.
        var lum = [Float](repeating: 1, count: w * h)
        for i in 0..<(w * h) {
            let a = Float(p[i * 4 + 3])
            guard a > 0 else { continue }
            lum[i] = (0.299 * Float(p[i * 4]) + 0.587 * Float(p[i * 4 + 1]) + 0.114 * Float(p[i * 4 + 2])) / a
        }

        // Paper brightness per block (a high percentile, so ink doesn't count),
        // interpolated per pixel.
        let block = max(16, max(w, h) / 24)
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        var paper = [Float](repeating: 1, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var hist = [Int](repeating: 0, count: 64)
                var n = 0
                for y in (by * block)..<min(h, (by + 1) * block) {
                    for x in (bx * block)..<min(w, (bx + 1) * block) {
                        hist[min(63, Int(lum[y * w + x] * 63))] += 1
                        n += 1
                    }
                }
                var acc = 0, bin = 63
                while bin > 0 { acc += hist[bin]; if acc * 10 >= n { break }; bin -= 1 }
                paper[by * bw + bx] = max(0.15, Float(bin) / 63)
            }
        }
        func paperAt(_ x: Int, _ y: Int) -> Float {
            let fx = max(0, min(Float(bw - 1), (Float(x) + 0.5) / Float(block) - 0.5))
            let fy = max(0, min(Float(bh - 1), (Float(y) + 0.5) / Float(block) - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(bw - 1, x0 + 1), y1 = min(bh - 1, y0 + 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let top = paper[y0 * bw + x0] * (1 - tx) + paper[y0 * bw + x1] * tx
            let bottom = paper[y1 * bw + x0] * (1 - tx) + paper[y1 * bw + x1] * tx
            return top * (1 - ty) + bottom * ty
        }

        let low = Float(0.04 + 0.32 * cleanup.strength)
        let high = low + 0.18
        var inkRGB: (Float, Float, Float)?
        if let c = cleanup.ink?.usingColorSpace(.sRGB) {
            inkRGB = (Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
        }

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, o = i * 4
                let a = Float(p[o + 3]) / 255
                if a == 0 { continue }
                var keep: Float = 1
                if cleanup.removeBackground {
                    // How much darker than the paper around it this pixel is.
                    let darkness = max(0, 1 - lum[i] / paperAt(x, y))
                    keep = darkness <= low ? 0 : darkness >= high ? 1 : (darkness - low) / (high - low)
                }
                let na = a * keep
                var r = Float(p[o]) / 255 / a, g = Float(p[o + 1]) / 255 / a, b = Float(p[o + 2]) / 255 / a
                if let ink = inkRGB { (r, g, b) = ink }
                p[o] = UInt8(min(255, r * na * 255))
                p[o + 1] = UInt8(min(255, g * na * 255))
                p[o + 2] = UInt8(min(255, b * na * 255))
                p[o + 3] = UInt8(na * 255)
                if na > 0.1 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY, let full = ctx.makeImage() else { return nil }
        let pad = max(2, Int(4 * scale))
        // Bitmap memory rows and CGImage rows both run top-down.
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let crop = CGRect(x: x0, y: y0, width: min(w, maxX + pad + 1) - x0, height: min(h, maxY + pad + 1) - y0)
        guard let cropped = full.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: crop.width / scale, height: crop.height / scale))
    }

    static func thumbnail(_ image: NSImage, height: CGFloat) -> NSImage {
        let aspect = image.size.width / max(image.size.height, 1)
        let size = CGSize(width: min(height * aspect, height * 5), height: height)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: - Drawing canvas

final class SignatureCanvas: NSView, NSServicesMenuRequestor {
    var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    var inkColor: NSColor = .black { didSet { needsDisplay = true } }
    /// Called with a picture coming from Continuity Sketch (iPhone / iPad).
    var onImportedImage: ((NSImage) -> Void)?
    let lineWidth: CGFloat = 2.6

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let guide = NSBezierPath()
        guide.move(to: CGPoint(x: 24, y: 56))
        guide.line(to: CGPoint(x: bounds.width - 24, y: 56))
        guide.setLineDash([5, 4], count: 2, phase: 0)
        guide.lineWidth = 1
        NSColor.gray.withAlphaComponent(0.5).setStroke()
        guide.stroke()

        if strokes.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.gray]
            let s = "Распишитесь здесь мышью или трекпадом" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.midY + 10), withAttributes: attrs)
        }
        inkColor.setStroke()
        for s in strokes { Self.path(for: s, width: lineWidth).stroke() }
    }

    static func path(for pts: [CGPoint], width: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        guard let first = pts.first else { return p }
        p.move(to: first)
        guard pts.count > 1 else {
            p.line(to: CGPoint(x: first.x + 0.1, y: first.y))
            return p
        }
        // Quadratic smoothing through midpoints, expressed as cubic curves.
        var current = first
        for i in 1..<pts.count {
            let c = pts[i - 1]
            let mid = CGPoint(x: (c.x + pts[i].x) / 2, y: (c.y + pts[i].y) / 2)
            let cp1 = CGPoint(x: current.x + 2 / 3 * (c.x - current.x), y: current.y + 2 / 3 * (c.y - current.y))
            let cp2 = CGPoint(x: mid.x + 2 / 3 * (c.x - mid.x), y: mid.y + 2 / 3 * (c.y - mid.y))
            p.curve(to: mid, controlPoint1: cp1, controlPoint2: cp2)
            current = mid
        }
        p.line(to: pts[pts.count - 1])
        return p
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
    }

    func renderedImage() -> NSImage? {
        let all = strokes.flatMap { $0 }
        guard let first = all.first else { return nil }
        var bb = CGRect(origin: first, size: .zero)
        for p in all { bb = bb.union(CGRect(origin: p, size: .zero)) }
        bb = bb.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bb.width * scale), pixelsHigh: Int(bb.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let t = NSAffineTransform()
        t.scale(by: scale)
        t.translateX(by: -bb.minX, yBy: -bb.minY)
        t.concat()
        inkColor.setStroke()
        for s in strokes { Self.path(for: s, width: lineWidth).stroke() }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: bb.size)
        img.addRepresentation(rep)
        return img
    }

    // Continuity Sketch: lets "Import from iPhone or iPad" deliver an image here.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, ContinuityImport.accepts(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        ContinuityImport.menu()
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let img = NSImage(pasteboard: pboard) else { return false }
        onImportedImage?(img)
        return true
    }
}

// MARK: - Signature sheet

/// Shows an imported signature on a checkerboard so transparency is visible.
final class SignaturePreview: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        clip.addClip()
        NSColor.white.setFill()
        bounds.fill()
        NSColor(white: 0.9, alpha: 1).setFill()
        let cell: CGFloat = 10
        for row in 0..<Int(bounds.height / cell) + 1 {
            for col in 0..<Int(bounds.width / cell) + 1 where (row + col) % 2 == 0 {
                NSRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
            }
        }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.gray]
            let msg = "На фото не найдено подписи — уменьшите силу очистки" as NSString
            let size = msg.size(withAttributes: attrs)
            msg.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            return
        }
        let area = bounds.insetBy(dx: 20, dy: 16)
        let k = min(area.width / image.size.width, area.height / image.size.height)
        let w = image.size.width * k, h = image.size.height * k
        image.draw(in: CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}

final class SignaturePadController: NSWindowController {
    private let canvas = SignatureCanvas()
    private let preview = SignaturePreview()
    private var completion: ((NSImage?) -> Void)?
    private static var active: SignaturePadController?

    private let titleLabel = NSTextField(labelWithString: "Новая подпись")
    private let drawInk = NSSegmentedControl()
    private let clearButton = NSButton()
    private let drawHint = NSTextField(labelWithString: "Или загрузите фото/скан подписи — фон можно сделать прозрачным")
    private let cleanupRow = NSStackView()
    private let removeBackground = NSButton(checkboxWithTitle: "Убрать фон", target: nil, action: nil)
    private let strength = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let photoInk = NSSegmentedControl()

    /// The picture being cleaned up; nil while drawing.
    private var imported: NSImage?
    private var processed: NSImage?

    static func run(on parent: NSWindow, completion: @escaping (NSImage?) -> Void) {
        let c = SignaturePadController()
        c.completion = completion
        active = c
        parent.beginSheet(c.window!)
        c.window?.makeFirstResponder(c.canvas)
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 372),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        super.init(window: panel)
        build(in: panel.contentView!)
        canvas.onImportedImage = { [weak self] img in self?.showImported(img) }
        setImportMode(false)
    }

    required init?(coder: NSCoder) { nil }

    private func build(in root: NSView) {
        for v in [canvas, preview] as [NSView] {
            v.frame = NSRect(x: 20, y: 106, width: 560, height: 210)
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.separatorColor.cgColor
            root.addSubview(v)
        }

        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: 332, width: 230, height: 22)
        root.addSubview(titleLabel)

        drawInk.segmentCount = 2
        drawInk.setLabel("Чёрные", forSegment: 0)
        drawInk.setLabel("Синие", forSegment: 1)
        drawInk.trackingMode = .selectOne
        drawInk.selectedSegment = 0
        drawInk.target = self
        drawInk.action = #selector(inkChanged(_:))
        drawInk.frame = NSRect(x: 420, y: 330, width: 160, height: 24)
        root.addSubview(drawInk)

        // "Import from iPhone or iPad" (Continuity): AppKit fills the menu
        // with the user's devices; a context menu is where it does so reliably.
        let device = NSButton(title: "С iPhone / iPad", target: self, action: #selector(showDeviceMenu(_:)))
        device.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        device.imagePosition = .imageLeading
        device.bezelStyle = .rounded
        device.frame = NSRect(x: 262, y: 328, width: 150, height: 28)
        device.toolTip = "Нарисовать подпись или сфотографировать её на iPhone / iPad (Continuity)"
        root.addSubview(device)

        // Clean-up controls for imported pictures; a hint while drawing.
        drawHint.textColor = .secondaryLabelColor
        drawHint.font = .systemFont(ofSize: 12)
        drawHint.frame = NSRect(x: 20, y: 70, width: 560, height: 18)
        root.addSubview(drawHint)

        removeBackground.state = .on
        removeBackground.target = self
        removeBackground.action = #selector(cleanupChanged(_:))
        removeBackground.toolTip = "Сделать бумагу прозрачной, оставить только чернила"
        strength.target = self
        strength.action = #selector(cleanupChanged(_:))
        strength.isContinuous = true
        strength.widthAnchor.constraint(equalToConstant: 120).isActive = true
        removeBackground.setContentCompressionResistancePriority(.required, for: .horizontal)
        strength.toolTip = "Сильнее — убирает тени и пятна, но может съесть бледные штрихи"
        photoInk.segmentCount = 3
        ["Как на фото", "Чёрные", "Синие"].enumerated().forEach { photoInk.setLabel($1, forSegment: $0) }
        photoInk.trackingMode = .selectOne
        photoInk.selectedSegment = 0
        photoInk.target = self
        photoInk.action = #selector(cleanupChanged(_:))
        let strengthLabel = NSTextField(labelWithString: "Сила очистки")
        strengthLabel.textColor = .secondaryLabelColor
        [removeBackground, strengthLabel, strength, photoInk].forEach(cleanupRow.addArrangedSubview)
        cleanupRow.spacing = 8
        cleanupRow.setCustomSpacing(18, after: removeBackground)
        cleanupRow.setCustomSpacing(18, after: strength)
        cleanupRow.frame = NSRect(x: 20, y: 64, width: 560, height: 30)
        root.addSubview(cleanupRow)

        var x: CGFloat = 20
        func button(_ title: String, _ action: Selector, width: CGFloat) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 18, width: width, height: 30)
            root.addSubview(b)
            x += width + 6
            return b
        }
        clearButton.title = "Очистить"
        clearButton.target = self
        clearButton.action = #selector(clearOrDraw)
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: x, y: 18, width: 92, height: 30)
        root.addSubview(clearButton)
        x += 98
        _ = button("Из файла…", #selector(importFile), width: 100)
            .then { $0.toolTip = "Фото или скан подписи; фон можно сделать прозрачным" }
        _ = button("Вставить", #selector(pasteImage), width: 86)
            .then { $0.toolTip = "Вставить подпись из буфера, например скопированную в Просмотре (⌘C)" }

        let save = NSButton(title: "Сохранить", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 486, y: 18, width: 94, height: 30)
        root.addSubview(save)
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 396, y: 18, width: 86, height: 30)
        root.addSubview(cancel)
    }

    private func setImportMode(_ on: Bool) {
        canvas.isHidden = on
        preview.isHidden = !on
        drawInk.isHidden = on
        drawHint.isHidden = on
        cleanupRow.isHidden = !on
        titleLabel.stringValue = on ? "Подпись из изображения" : "Новая подпись"
        clearButton.title = on ? "Рисовать" : "Очистить"
        clearButton.toolTip = on ? "Вернуться к рисованию подписи" : "Стереть нарисованное"
    }

    @objc private func showDeviceMenu(_ sender: NSButton) {
        window?.makeFirstResponder(canvas)
        ContinuityImport.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // The sheet's controller is in its responder chain too, so imports land
    // here even when the canvas isn't first responder.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, ContinuityImport.accepts(returnType) { return canvas }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc private func inkChanged(_ sender: NSSegmentedControl) {
        canvas.inkColor = sender.selectedSegment == 0 ? .black : NSColor(srgbRed: 0.05, green: 0.2, blue: 0.65, alpha: 1)
    }

    @objc private func clearOrDraw() {
        if imported != nil {
            imported = nil
            processed = nil
            setImportMode(false)
            window?.makeFirstResponder(canvas)
        } else {
            canvas.strokes = []
        }
    }

    @objc private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Выберите фото или скан подписи — дальше можно убрать фон"
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        showImported(img)
    }

    @objc private func pasteImage() {
        guard let img = NSImage(pasteboard: .general) else {
            NSSound.beep()
            return
        }
        showImported(img)
    }

    func showImported(_ img: NSImage) {
        imported = img
        setImportMode(true)
        reprocess()
    }

    @objc private func cleanupChanged(_ sender: Any?) {
        strength.isEnabled = removeBackground.state == .on
        reprocess()
    }

    private func reprocess() {
        guard let imported else { return }
        var c = SignatureStore.Cleanup()
        c.removeBackground = removeBackground.state == .on
        c.strength = CGFloat(strength.doubleValue)
        switch photoInk.selectedSegment {
        case 1: c.ink = .black
        case 2: c.ink = NSColor(srgbRed: 0.05, green: 0.2, blue: 0.65, alpha: 1)
        default: c.ink = nil
        }
        processed = SignatureStore.cleanedSignature(from: imported, cleanup: c)
        preview.image = processed
    }

    @objc private func save() {
        let img = imported != nil ? processed : canvas.renderedImage()
        guard let img else { NSSound.beep(); return }
        close(with: img)
    }

    @objc private func cancel() { close(with: nil) }

    private func close(with image: NSImage?) {
        if let w = window { w.sheetParent?.endSheet(w) }
        completion?(image)
        completion = nil
        Self.active = nil
    }
}

extension NSObjectProtocol {
    @discardableResult
    func then(_ body: (Self) -> Void) -> Self {
        body(self)
        return self
    }
}

/// Continuity Camera / Sketch ("Import from iPhone or iPad").
enum ContinuityImport {
    static func accepts(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .pdf || NSImage.imageTypes.contains(type.rawValue)
    }

    /// A menu holding the placeholder AppKit replaces with device items
    /// (take photo, scan documents, add sketch).
    static func menu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Импорт с iPhone или iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        return menu
    }
}
