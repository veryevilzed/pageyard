import AppKit
import PDFKit

/// `PAGEYARD_SCREENSHOTS=<dir>`: opens a generated demo document, walks
/// through the main features and saves README screenshots, then quits.
enum ScreenshotTour {
    static func scheduleIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["PAGEYARD_SCREENSHOTS"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PageYard-tour", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let form = tmp.appendingPathComponent("Заявление.pdf")
        let extra = tmp.appendingPathComponent("Приложение к договору.pdf")
        try? demoForm().write(to: form)
        try? demoAppendix().write(to: extra)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSDocumentController.shared.openDocument(withContentsOf: form, display: true) { doc, _, _ in
            guard let wc = doc?.windowControllers.first as? EditorWindowController else { exit(1) }
            run(wc, out: out, extra: extra, tmp: tmp)
        }
    }

    // MARK: - Scenes

    private static func run(_ wc: EditorWindowController, out: URL, extra: URL, tmp: URL) {
        guard let window = wc.window, let doc = wc.pdfView.document,
              let form = doc.page(at: 0), let contract = doc.page(at: 1) else { exit(1) }
        let view = wc.pdfView
        window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 920), display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        func fitPage(_ page: PDFPage) {
            view.autoScales = false
            view.scaleFactor = (view.bounds.height - 24) / page.bounds(for: .cropBox).height
            view.go(to: page)
        }

        func shot(_ name: String, _ windows: [NSWindow] = []) {
            save(window, extra: windows, to: out.appendingPathComponent("\(name).png"))
        }

        // 1. Filling a form that has no fields.
        view.mode = .fill
        fitPage(form)
        let fields: [(CGPoint, String)] = [
            (CGPoint(x: 230, y: 703), "Иванова Мария Сергеевна"),
            (CGPoint(x: 230, y: 673), "14.03.1991"),
            (CGPoint(x: 230, y: 643), "+7 900 123-45-67"),
        ]
        for (p, text) in fields {
            let tb = view.makeTextBox(on: form, at: p, snap: true)
            tb.text = text
            tb.fit()
            view.add(tb, to: form, name: "t")
        }
        view.add(view.makeMark(.cross, on: form, at: CGPoint(x: 56, y: 470), snap: true), to: form, name: "m")
        let cell = view.makeTextBox(on: form, at: CGPoint(x: 470, y: 362), snap: true)
        cell.text = "1"
        cell.fit()
        view.add(cell, to: form, name: "t")
        view.activate(.text)
        view.showsFieldHints = true

        after(2.0) {
            shot("fill")

            // 2. Signature from a photo, background removed.
            view.showsFieldHints = false
            view.add(view.makeMark(.check, on: form, at: CGPoint(x: 56, y: 263), snap: true), to: form, name: "m")
            let date = view.makeTextBox(on: form, at: CGPoint(x: 120, y: 203), snap: true)
            date.text = "30.10.2026"
            date.fit()
            view.add(date, to: form, name: "t")
            wc.newSignature(nil)
            after(0.8) {
                guard let sheet = window.attachedSheet, let pad = sheet.windowController as? SignaturePadController else { exit(1) }
                let photo = DebugSnapshot.fakeSignaturePhoto()
                pad.showImported(photo)
                after(0.6) {
                    shot("signature", [sheet])
                    window.endSheet(sheet)
                    if let img = SignatureStore.cleanedSignature(from: photo) {
                        let s = view.makeSignature(img, on: form, at: CGPoint(x: 450, y: 205), snap: true)
                        view.add(s, to: form, name: "s")
                    }

                    // 3. Editing existing text and marking a block.
                    view.mode = .edit
                    fitPage(contract)
                    let mark = HighlightAnnotation(rect: CGRect(x: 46, y: 634, width: 504, height: 38),
                                                   note: "Уточнить сроки оплаты у бухгалтерии")
                    view.add(mark, to: contract, name: "h")
                    view.activate(.editText)
                    if let sel = contract.selectionForLine(at: CGPoint(x: 120, y: 770)),
                       let tb = view.makeReplacement(for: sel, on: contract) {
                        contract.addAnnotation(tb)
                        view.beginEditing(tb, isNew: true)
                        if let tv = window.firstResponder as? NSTextView {
                            tv.string = tb.text.replacingOccurrences(of: "17/2026", with: "18/2026")
                            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                            view.textDidChange(Notification(name: NSText.didChangeNotification))
                        }
                    }
                    after(2.0) {
                        shot("edit")
                        view.finishEditing()

                        // 4. Pages: a whole PDF as a group and a layout sheet with pictures.
                        view.mode = .fill
                        wc.sidebar.insert(wc.sidebar.items(fromFiles: [(extra, "Приложение к договору")]), atTop: 2, name: "i")
                        let pics = [landscape(hue: 0.58), landscape(hue: 0.08)].enumerated().map { i, img -> URL in
                            let url = tmp.appendingPathComponent("photo\(i).png")
                            try? SignatureStore.pngData(img)?.write(to: url)
                            return url
                        }
                        var opts = ImageInsertOptions()
                        opts.placement = .layoutSheet
                        opts.together = true
                        wc.sidebar.insert(wc.sidebar.items(fromFiles: pics.map { ($0, $0.lastPathComponent) }, imageOptions: opts),
                                          atTop: 1, name: "i")
                        if let sheet = doc.page(at: 1) {
                            fitPage(sheet)
                            if let first = sheet.annotations.compactMap({ $0 as? ImageAnnotation }).first {
                                // Show the second picture resized and the first one selected.
                                first.bounds = CGRect(x: 60, y: 470, width: 300, height: 200)
                                view.placeImages([], on: sheet, at: nil)
                            }
                        }
                        after(2.0) {
                            shot("pages")
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Window pixels as the window server composited them (annotation layers
    /// included). An app may capture its own windows without screen-recording
    /// permission; the API is deprecated, hence the lookup by name.
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: WindowImageFn.self)
        // listOptions: includingWindow (8); imageOptions: boundsIgnoreFraming (1) | bestResolution (8)
        return fn(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
    }

    /// Renders the window (and sheets over it) the way it looks on screen.
    private static func save(_ window: NSWindow, extra: [NSWindow], to url: URL) {
        if let image = windowServerImage(window), image.width > 10 {
            // Sheets are separate windows: capture and composite them on top.
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            let size = window.frame.size
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            rep.draw(in: CGRect(origin: .zero, size: size))
            for w in extra {
                guard let sheetImage = windowServerImage(w) else { continue }
                let origin = CGPoint(x: w.frame.minX - window.frame.minX, y: w.frame.minY - window.frame.minY)
                NSBitmapImageRep(cgImage: sheetImage).draw(in: CGRect(origin: origin, size: w.frame.size))
            }
            canvas.unlockFocus()
            _ = scale
            if let tiff = canvas.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
               let png = out.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                print("captured \(url.lastPathComponent) via window server")
                return
            }
        }
        print("window server capture unavailable, falling back")
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let size = frameView.bounds.size
        let image = NSImage(size: size)
        image.lockFocus()
        rep.draw(in: CGRect(origin: .zero, size: size))
        for w in extra {
            guard let v = w.contentView?.superview, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: r)
            let origin = CGPoint(x: w.frame.minX - window.frame.minX, y: w.frame.minY - window.frame.minY)
            NSColor.black.withAlphaComponent(0.25).setFill()
            CGRect(origin: .zero, size: size).fill(using: .sourceAtop)
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.set()
            r.draw(in: CGRect(origin: origin, size: v.bounds.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
              let png = out.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: - Demo content

    private static func pdf(pages: [(CGContext) -> Void]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for draw in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            draw(ctx)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 11, bold: Bool = false, color: NSColor = .black) {
        let font = NSFont(name: bold ? "Times New Roman Bold" : "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func line(_ ctx: CGContext, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) {
        ctx.setLineWidth(0.7)
        ctx.move(to: CGPoint(x: x0, y: y))
        ctx.addLine(to: CGPoint(x: x1, y: y))
        ctx.strokePath()
    }

    private static func demoForm() -> Data {
        pdf(pages: [
            { ctx in
                ctx.setStrokeColor(gray: 0, alpha: 1)
                text("Заявление на участие в программе", 50, 780, size: 18, bold: true)
                text("Заполните разборчиво. Поля, отмеченные *, обязательны.", 50, 758, size: 10, color: .darkGray)
                let rows = ["Фамилия, имя, отчество*", "Дата рождения", "Телефон*", "Электронная почта", "Адрес"]
                for (i, label) in rows.enumerated() {
                    let y = CGFloat(700 - i * 30)
                    text(label, 50, y)
                    line(ctx, 200, 545, y - 1)
                }
                line(ctx, 200, 545, 554)
                text("Формат участия", 50, 515, size: 12, bold: true)
                for (i, label) in ["Очно", "Онлайн", "Гибрид"].enumerated() {
                    let y = CGFloat(490 - i * 22)
                    ctx.setLineWidth(0.8)
                    ctx.stroke(CGRect(x: 50, y: y - 1, width: 11, height: 11))
                    text(label, 68, y - 1)
                }
                text("Документы", 50, 405, size: 12, bold: true)
                let cols: [CGFloat] = [50, 90, 400, 545]
                for r in 0...4 { line(ctx, 50, 545, CGFloat(395 - r * 22)) }
                ctx.setLineWidth(0.7)
                for x in cols {
                    ctx.move(to: CGPoint(x: x, y: 395))
                    ctx.addLine(to: CGPoint(x: x, y: 307))
                    ctx.strokePath()
                }
                text("№", 62, 380, bold: true)
                text("Документ", 98, 380, bold: true)
                text("Копий", 408, 380, bold: true)
                text("1", 66, 358)
                text("Паспорт", 98, 358)
                text("2", 66, 336)
                text("Диплом об образовании", 98, 336)
                text("3", 66, 314)
                ctx.setLineWidth(0.8)
                ctx.stroke(CGRect(x: 50, y: 258, width: 11, height: 11))
                text("Согласен(на) на обработку персональных данных", 68, 258)
                text("Дата:", 50, 200)
                line(ctx, 90, 250, 199)
                text("Подпись:", 300, 200)
                line(ctx, 355, 545, 199)
            },
            { ctx in
                text("Договор оказания услуг № 17/2026", 50, 770, size: 16, bold: true)
                text("г. Москва", 50, 745)
                text("30 октября 2026 г.", 455, 745)
                let body = """
                Исполнитель обязуется оказать Заказчику консультационные услуги, а Заказчик — принять \
                и оплатить их в порядке и сроки, предусмотренные настоящим договором.

                Стоимость услуг составляет 120 000 (сто двадцать тысяч) рублей. Оплата производится \
                в течение десяти рабочих дней с даты подписания акта оказанных услуг.

                Договор вступает в силу с момента подписания и действует до полного исполнения \
                сторонами своих обязательств. Изменения оформляются дополнительными соглашениями.
                """
                let style = NSMutableParagraphStyle()
                style.alignment = .justified
                style.lineSpacing = 3
                (body as NSString).draw(with: CGRect(x: 50, y: 470, width: 495, height: 250), options: [.usesLineFragmentOrigin],
                                        attributes: [.font: NSFont(name: "Times New Roman", size: 12) ?? .systemFont(ofSize: 12),
                                                     .paragraphStyle: style])
                text("Исполнитель", 50, 400, bold: true)
                text("Заказчик", 330, 400, bold: true)
                line(ctx, 50, 250, 360)
                line(ctx, 330, 545, 360)
            },
        ])
    }

    private static func demoAppendix() -> Data {
        pdf(pages: (1...3).map { n in
            { ctx in
                text("Приложение № \(n) к договору", 50, 770, size: 15, bold: true)
                for i in 0..<14 { line(ctx, 50, 545, CGFloat(720 - i * 26)) }
            }
        })
    }

    /// A simple illustrated "photo" for the layout sheet.
    private static func landscape(hue: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: 800, height: 520), flipped: false) { r in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                       ending: NSColor(hue: hue + 0.05, saturation: 0.25, brightness: 1, alpha: 1))!.draw(in: r, angle: 90)
            NSColor(hue: 0.12, saturation: 0.7, brightness: 1, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: CGRect(x: 560, y: 330, width: 120, height: 120)).fill()
            for (i, shade) in [0.45, 0.32].enumerated() {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: 0, y: 0))
                p.line(to: CGPoint(x: 0, y: 160 + CGFloat(i) * 40))
                p.line(to: CGPoint(x: 220 + CGFloat(i) * 120, y: 330 - CGFloat(i) * 90))
                p.line(to: CGPoint(x: 480 + CGFloat(i) * 80, y: 170))
                p.line(to: CGPoint(x: 800, y: 260 - CGFloat(i) * 60))
                p.line(to: CGPoint(x: 800, y: 0))
                p.close()
                NSColor(hue: hue + 0.25, saturation: 0.45, brightness: CGFloat(shade) + 0.2, alpha: 1).setFill()
                p.fill()
            }
            return true
        }
    }
}
