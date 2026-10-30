import AppKit
import PDFKit

/// How pictures become pages.
struct ImageInsertOptions {
    enum Placement: Int { case ownPage, layoutSheet }

    enum Paper: Int, CaseIterable {
        case a4, a5, a3, letter

        var title: String { ["A4", "A5", "A3", "Letter"][rawValue] }

        var portrait: CGSize {
            switch self {
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .a5: CGSize(width: 419.53, height: 595.28)
            case .a3: CGSize(width: 841.89, height: 1190.55)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }

    var placement: Placement = .layoutSheet
    var paper: Paper = .a4
    var landscape = false
    /// All pictures share one sheet (otherwise one sheet per picture).
    var together = true

    var sheetSize: CGSize {
        let p = paper.portrait
        return landscape ? CGSize(width: p.height, height: p.width) : p
    }

    static var saved: ImageInsertOptions {
        let d = UserDefaults.standard
        var o = ImageInsertOptions()
        if d.object(forKey: "imgPlacement") != nil {
            o.placement = Placement(rawValue: d.integer(forKey: "imgPlacement")) ?? .layoutSheet
            o.paper = Paper(rawValue: d.integer(forKey: "imgPaper")) ?? .a4
            o.landscape = d.bool(forKey: "imgLandscape")
            o.together = d.bool(forKey: "imgTogether")
        }
        return o
    }

    func save() {
        let d = UserDefaults.standard
        d.set(placement.rawValue, forKey: "imgPlacement")
        d.set(paper.rawValue, forKey: "imgPaper")
        d.set(landscape, forKey: "imgLandscape")
        d.set(together, forKey: "imgTogether")
    }
}

extension PageFactory {
    /// A page exactly the shape of the picture, filled by it.
    static func image(_ image: NSImage) -> (PDFPage, PDFDocument)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var size = image.size.width > 1 && image.size.height > 1
            ? image.size : CGSize(width: cg.width, height: cg.height)
        // Keep pages in a sane physical range (A6…A3 on the long side).
        let longest = max(size.width, size.height)
        let k = longest > 1190 ? 1190 / longest : longest < 420 ? 420 / longest : 1
        size = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        return page(size: size) { ctx, box in
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: box)
        }
    }

    /// Grid placement of pictures on a sheet, maximising the area they get.
    static func arrange(_ sizes: [CGSize], in sheet: CGSize, margin: CGFloat = 28, gap: CGFloat = 14) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let area = CGRect(origin: .zero, size: sheet).insetBy(dx: margin, dy: margin)
        var best: (score: CGFloat, rects: [CGRect]) = (-1, [])
        for cols in 1...sizes.count {
            let rows = Int(ceil(Double(sizes.count) / Double(cols)))
            let cw = (area.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
            let ch = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            guard cw > 10, ch > 10 else { continue }
            var rects: [CGRect] = []
            var score: CGFloat = 0
            for (i, s) in sizes.enumerated() {
                let col = i % cols, row = i / cols
                let cell = CGRect(x: area.minX + CGFloat(col) * (cw + gap),
                                  y: area.maxY - CGFloat(row + 1) * ch - CGFloat(row) * gap,
                                  width: cw, height: ch)
                let k = min(cell.width / max(s.width, 1), cell.height / max(s.height, 1))
                let w = s.width * k, h = s.height * k
                rects.append(CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h))
                score += w * h
            }
            if score > best.score { best = (score, rects) }
        }
        return best.rects
    }

    /// A blank sheet with the pictures laid out as movable, resizable objects.
    static func layoutSheet(_ images: [NSImage], size: CGSize) -> (PDFPage, PDFDocument)? {
        guard let (page, owner) = blank(size: size) else { return nil }
        let origin = page.bounds(for: .mediaBox).origin
        for (img, r) in zip(images, arrange(images.map(\.size), in: size)) {
            page.addAnnotation(ImageAnnotation(image: img, rect: r.offsetBy(dx: origin.x, dy: origin.y)))
        }
        return (page, owner)
    }
}

/// Asks how pictures should be inserted.
enum ImageInsertDialog {
    static func ask(on window: NSWindow, imageCount: Int, completion: @escaping (ImageInsertOptions?) -> Void) {
        var o = ImageInsertOptions.saved

        let own = NSButton(radioButtonWithTitle: "Каждая картинка — отдельный лист своего размера", target: nil, action: nil)
        let sheet = NSButton(radioButtonWithTitle: "На лист-макет, где картинки можно двигать и менять размер:", target: nil, action: nil)
        let paper = NSPopUpButton(frame: .zero, pullsDown: false)
        paper.addItems(withTitles: ImageInsertOptions.Paper.allCases.map(\.title))
        paper.selectItem(at: o.paper.rawValue)
        let orientation = NSSegmentedControl(labels: ["Книжная", "Альбомная"], trackingMode: .selectOne, target: nil, action: nil)
        orientation.selectedSegment = o.landscape ? 1 : 0
        let together = NSButton(checkboxWithTitle: imageCount > 1 ? "Все \(imageCount) на один лист" : "Все на один лист",
                                target: nil, action: nil)
        together.state = o.together ? .on : .off
        together.isEnabled = imageCount > 1

        let handler = RadioHandler { isSheet in
            [paper, orientation, together].forEach { $0.isEnabled = isSheet }
            together.isEnabled = isSheet && imageCount > 1
        }
        for b in [own, sheet] {
            b.target = handler
            b.action = #selector(RadioHandler.changed(_:))
        }
        own.state = o.placement == .ownPage ? .on : .off
        sheet.state = o.placement == .layoutSheet ? .on : .off
        handler.update(sheet.state == .on)

        let sheetRow = NSStackView(views: [paper, orientation])
        sheetRow.spacing = 8
        let stack = NSStackView(views: [own, sheet, sheetRow, together])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: own)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        sheetRow.setContentHuggingPriority(.required, for: .vertical)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        stack.frame = container.bounds
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        // Indent the sheet options under their radio button.
        sheetRow.edgeInsets.left = 20
        together.frame.origin.x += 20

        let alert = NSAlert()
        alert.messageText = imageCount == 1 ? "Как вставить картинку?" : "Как вставить \(imageCount) картинки?"
        alert.accessoryView = container
        alert.addButton(withTitle: "Вставить")
        alert.addButton(withTitle: "Отмена")
        objc_setAssociatedObject(alert, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        alert.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { completion(nil); return }
            o.placement = sheet.state == .on ? .layoutSheet : .ownPage
            o.paper = ImageInsertOptions.Paper(rawValue: paper.indexOfSelectedItem) ?? .a4
            o.landscape = orientation.selectedSegment == 1
            o.together = together.state == .on
            o.save()
            completion(o)
        }
    }

    private final class RadioHandler: NSObject {
        let onChange: (Bool) -> Void
        init(_ onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
        func update(_ isSheet: Bool) { onChange(isSheet) }
        @objc func changed(_ sender: NSButton) {
            onChange(sender.title.hasPrefix("На лист"))
        }
    }
}
