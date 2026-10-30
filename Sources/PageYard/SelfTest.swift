import AppKit
import PDFKit

/// `PageYard --selftest <dir>`: builds a form-like PDF without form fields,
/// runs every tool headlessly, saves, and renders the result to PNG.
enum SelfTest {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let source = makeSourcePDF()
        try? source.write(to: dir.appendingPathComponent("source.pdf"))
        guard let doc = PDFDocument(data: source), let page = doc.page(at: 0), let page2 = doc.page(at: 1) else {
            print("FAIL: cannot load source"); return
        }
        page2.rotation = 90

        // A native form field, to check its value survives baking.
        let widget = PDFAnnotation(bounds: CGRect(x: 360, y: 700, width: 160, height: 20), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "native"
        widget.widgetStringValue = "Поле формы"
        page.addAnnotation(widget)

        let view = EditorPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = doc

        let fields = view.detector.fields(on: page)
        for f in fields { print("field \(f.kind) \(f.rect.integral)") }

        // Text snapped onto the underline after "Фамилия:".
        let t1 = view.makeTextBox(on: page, at: CGPoint(x: 200, y: 706), snap: true)
        t1.text = "Иванов Иван"; t1.fit()
        view.add(t1, to: page, name: "t")
        print("text on line → \(t1.bounds.integral)")

        // Cross into the checkbox, clicked off-centre.
        let m = view.makeMark(.cross, on: page, at: CGPoint(x: 54, y: 653), snap: true)
        view.add(m, to: page, name: "m")
        print("cross → \(m.bounds)")

        // Text into a table cell.
        let t2 = view.makeTextBox(on: page, at: CGPoint(x: 330, y: 575), snap: true)
        t2.text = "Ячейка 2"; t2.fit()
        view.add(t2, to: page, name: "t")
        print("text in cell → \(t2.bounds.integral)")

        // Signature on the signature line.
        let canvas = SignatureCanvas(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        canvas.inkColor = NSColor(srgbRed: 0.05, green: 0.2, blue: 0.65, alpha: 1)
        canvas.strokes = [(0..<60).map { i in CGPoint(x: 40 + Double(i) * 6, y: 100 + sin(Double(i) / 4) * 30) }]
        if let img = canvas.renderedImage() {
            let s = view.makeSignature(img, on: page, at: CGPoint(x: 200, y: 505), snap: true)
            view.add(s, to: page, name: "s")
            print("signature → \(s.bounds.integral)")
        }

        // Real text edit of the contract number line.
        if let sel = page.selectionForLine(at: CGPoint(x: 80, y: 785)), let r = view.makeReplacement(for: sel, on: page) {
            print("replace '\(r.text)' font=\(r.textFont.fontName) \(r.textFont.pointSize) bounds=\(r.bounds.integral)")
            r.text = "Договор № 456 от 02.02.2026"
            r.fit()
            view.add(r, to: page, name: "r")
        } else {
            print("FAIL: no selection for line")
        }

        let t3 = view.makeTextBox(on: page2, at: CGPoint(x: 100, y: 120), snap: false)
        t3.text = "Текст на повёрнутой странице"; t3.fit()
        view.add(t3, to: page2, name: "t")

        // Wrapping text area that erases what's under it.
        let area = TextBoxAnnotation(text: "Новый абзац, который переносится по ширине области", font: .defaultFill(10), color: .black,
                                     topLeft: CGPoint(x: 48, y: 776))
        area.wrapWidth = 160
        area.minHeight = 24
        area.erasesBelow = true
        area.cover = CGSize(width: 160, height: 24)
        area.fit()
        view.add(area, to: page, name: "a")
        print("text area → \(area.bounds.integral) (wraps: \(area.bounds.height > 20))")

        // Yellow marker with a note.
        let mark = HighlightAnnotation(rect: CGRect(x: 45, y: 755, width: 260, height: 22), note: "Проверить номер договора")
        view.add(mark, to: page, name: "h")

        // Page management: insert a 2-page PDF as a group, move it, break it.
        let sidebar = PageSidebar(frame: CGRect(x: 0, y: 0, width: 170, height: 800))
        sidebar.pdfView = view
        sidebar.reload()
        let extra = dir.appendingPathComponent("source.pdf")
        sidebar.insert(sidebar.items(fromFiles: [(extra, "Вставка")]), atTop: 1, name: "i")
        print("after insert: pages \(doc.pageCount), groups \(sidebar.groups.map { "\($0.name):\($0.pages.count)" })")
        sidebar.moveTop(from: 1, to: 3)
        print("group moved to end: first page of group index \(doc.index(for: sidebar.groups[0].pages[0]))")
        sidebar.breakGroup(sidebar.groups[0])
        print("after break: groups \(sidebar.groups.count), pages \(doc.pageCount)")
        if let blankPage = doc.page(at: doc.pageCount - 1) { sidebar.delete([blankPage]) }
        print("after delete: pages \(doc.pageCount)")

        // Two pictures on one A4 layout sheet, then one resized.
        let pics: [URL] = [("red", NSColor.systemRed, CGSize(width: 400, height: 300)), ("blue", NSColor.systemBlue, CGSize(width: 300, height: 500))].map { name, color, size in
            let img = NSImage(size: size, flipped: false) { r in color.setFill(); r.fill(); return true }
            let url = dir.appendingPathComponent("\(name).png")
            try? SignatureStore.pngData(img)?.write(to: url)
            return url
        }
        var opts = ImageInsertOptions()
        opts.placement = .layoutSheet
        opts.together = true
        sidebar.insert(sidebar.items(fromFiles: pics.map { ($0, $0.lastPathComponent) }, imageOptions: opts), atTop: 1, name: "i")
        if let sheet = doc.page(at: 1) {
            let imgs = sheet.annotations.compactMap { $0 as? ImageAnnotation }
            print("layout sheet: \(view.isLayoutSheet(sheet)), size \(sheet.bounds(for: .cropBox).size), images \(imgs.map { $0.bounds.integral })")
            imgs.first?.bounds = CGRect(x: 60, y: 420, width: 200, height: 150)
        }
        opts.placement = .ownPage
        sidebar.insert(sidebar.items(fromFiles: [(pics[1], "blue")], imageOptions: opts), atTop: 2, name: "i")
        print("own-size page: \(doc.page(at: 2)?.bounds(for: .cropBox).size ?? .zero)")

        // Office fallback converter (iWork skipped in tests via PAGEYARD_NO_IWORK).
        let rtf = dir.appendingPathComponent("note.rtf")
        try? NSAttributedString(string: "Документ Word\n\nВторой абзац").rtf(from: NSRange(location: 0, length: 26), documentAttributes: [:])?.write(to: rtf)
        setenv("PAGEYARD_NO_IWORK", "1", 1)
        let sem = DispatchSemaphore(value: 0)
        var converted: Result<URL, DocumentImporter.ImportError>?
        DispatchQueue.global().async { converted = DocumentImporter.convertToPDF(rtf); sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        switch converted {
        case .success(let u): print("rtf → pdf: \(PDFDocument(url: u)?.string?.contains("Второй") == true)")
        case .failure(let e): print("rtf → pdf FAILED: \(e.message)")
        case nil: print("rtf → pdf: no result")
        }

        // Copies of every object kind keep their look.
        let kinds: [EditableAnnotation] = [t1, m, mark, area]
        let copies = kinds.map { $0.duplicate() }
        var sameLook = true
        for (a, c) in zip(kinds, copies) {
            let sameClass = String(describing: Swift.type(of: a)) == String(describing: Swift.type(of: c))
            let width: CGFloat = abs(a.bounds.width - c.bounds.width)
            if !sameClass || width > 0.5 || c.page != nil { sameLook = false }
        }
        print("duplicates keep look: \(sameLook), copied text: \((copies[0] as? TextBoxAnnotation)?.text ?? "-")")

        // Clean export: original content only, no objects or markup.
        if let clean = DocumentWriter.withoutAnnotations(doc).flatMap(PDFDocument.init(data:)) {
            let text = clean.page(at: 0)?.string ?? ""
            let markup = (0..<clean.pageCount).flatMap { clean.page(at: $0)?.annotations ?? [] }
                .filter { DocumentWriter.markupTypes.contains($0.type ?? "") }
            print("clean export: pages \(clean.pageCount)/\(doc.pageCount), original text kept \(text.contains("123")), added text absent \(!text.contains("Иванов")), markup \(markup.count)")
            print("objects restored after clean export: \(page.annotations.contains { $0 === t1 })")
        }

        let report = DocumentWriter.bake(doc, password: nil)
        if let e = report.redactionError { print("REDACTION ERROR: \(e)") }
        let outURL = dir.appendingPathComponent("out.pdf")
        try? report.data.write(to: outURL)

        guard let out = PDFDocument(url: outURL) else { print("FAIL: output unreadable"); return }
        let text = out.page(at: 0)?.string ?? ""
        print("output pages: \(out.pageCount), annotations on p1: \(out.page(at: 0)?.annotations.count ?? -1)")
        print("old number still present: \(text.contains("123"))")
        print("erased line still present: \(text.contains("нетронутой"))")
        print("new number present: \(text.contains("456"))")
        print("filled text present: \(text.contains("Иванов"))")
        print("form value present: \(text.contains("Поле формы"))")
        let natives = out.page(at: 0)?.annotations.filter { $0.type == "Highlight" } ?? []
        print("native highlights: \(natives.count), note: \(natives.first?.contents ?? "-")")
        let pngs = (try? PageImageExporter.export([(out.page(at: 0)!, 1)], to: dir, baseName: "export", format: .png, dpi: 150)) ?? []
        print("exported: \(pngs.map(\.lastPathComponent))")
        for i in 0..<out.pageCount {
            guard let p = out.page(at: i) else { continue }
            let img = p.thumbnail(of: CGSize(width: 1300, height: 1300), for: .cropBox)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("out-\(i + 1).png"))
            }
        }
        print("OK")
    }

    private static func makeSourcePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!

        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, font: String = "Times New Roman") {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let f = NSFont(name: font, size: size) ?? .systemFont(ofSize: size)
            (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: f])
            NSGraphicsContext.restoreGraphicsState()
        }

        ctx.beginPDFPage(nil)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(0.8)
        text("Договор № 123 от 01.01.2025", 50, 780, size: 14)
        text("Строка ниже должна остаться нетронутой.", 50, 762, size: 12)
        text("Фамилия:", 50, 700)
        ctx.stroke(CGRect(x: 0, y: 0, width: 0, height: 0))
        ctx.move(to: CGPoint(x: 110, y: 699)); ctx.addLine(to: CGPoint(x: 330, y: 699)); ctx.strokePath()
        ctx.stroke(CGRect(x: 50, y: 647, width: 11, height: 11))
        text("Согласен с условиями", 68, 647)
        ctx.stroke(CGRect(x: 50, y: 560, width: 200, height: 26))
        ctx.stroke(CGRect(x: 250, y: 560, width: 200, height: 26))
        text("Ячейка 1", 56, 567)
        text("Подпись:", 50, 500)
        ctx.move(to: CGPoint(x: 110, y: 499)); ctx.addLine(to: CGPoint(x: 300, y: 499)); ctx.strokePath()
        ctx.endPDFPage()

        ctx.beginPDFPage(nil)
        text("Вторая страница (будет повёрнута)", 50, 780, size: 16)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
