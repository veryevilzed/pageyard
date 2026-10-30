import AppKit
import PDFKit

/// Debug aid: with PAGEYARD_SNAPSHOT=<dir> the app drives a few tools through
/// real mouse events on the first window and saves window snapshots.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["PAGEYARD_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(URL(fileURLWithPath: dir)) }
    }

    private static func save(_ window: NSWindow, _ url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func click(_ view: EditorPDFView, page: PDFPage, at p: CGPoint, drag to: CGPoint? = nil) {
        guard let window = view.window else { return }
        let start = view.convert(view.convert(p, from: page), to: nil)
        let end = to.map { view.convert(view.convert($0, from: page), to: nil) } ?? start
        func ev(_ type: NSEvent.EventType, _ loc: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: ev(.leftMouseDown, start))
        if to != nil { view.mouseDragged(with: ev(.leftMouseDragged, end)) }
        view.mouseUp(with: ev(.leftMouseUp, end))
    }

    private static func type(_ view: EditorPDFView, _ text: String) {
        guard let tv = view.window?.firstResponder as? NSTextView else { print("no editor"); return }
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    private static func run(_ dir: URL) {
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? EditorWindowController }).first,
              let window = wc.window else { print("no window"); exit(1) }
        let view = wc.pdfView
        guard let page = view.document?.page(at: 0) else { exit(1) }
        save(window, dir.appendingPathComponent("gui-0.png"))

        view.activate(.text)
        click(view, page: page, at: CGPoint(x: 180, y: 704))
        type(view, "Петров Пётр")
        save(window, dir.appendingPathComponent("gui-1-editing.png"))
        view.finishEditing()

        view.activate(.cross)
        click(view, page: page, at: CGPoint(x: 55, y: 652))

        view.activate(.editText)
        click(view, page: page, at: CGPoint(x: 80, y: 785))
        if let tv = view.window?.firstResponder as? NSTextView {
            tv.string = "Договор № 789 от 03.03.2026"
            view.textDidChange(Notification(name: NSText.didChangeNotification))
        }
        save(window, dir.appendingPathComponent("gui-2-replace.png"))
        view.finishEditing()

        view.activate(.whiteout)
        click(view, page: page, at: CGPoint(x: 260, y: 600), drag: CGPoint(x: 330, y: 590))

        view.activate(.select)
        click(view, page: page, at: CGPoint(x: 58, y: 652))   // select the cross
        view.activate(.highlight)
        click(view, page: page, at: CGPoint(x: 45, y: 640), drag: CGPoint(x: 250, y: 662))
        if let tv = NSApp.windows.compactMap({ $0.firstResponder as? NSTextView }).first {
            tv.string = "Проверить галочку"
        }
        save(window, dir.appendingPathComponent("gui-2b-note.png"))
        NSApp.windows.forEach { w in if w.className.contains("Popover") { w.close() } }
        if let source = ProcessInfo.processInfo.environment["PAGEYARD_SNAPSHOT_INSERT"].map(URL.init(fileURLWithPath:)) {
            wc.sidebar.insert(wc.sidebar.items(fromFiles: [(source, "Вставленный файл")]), atTop: 1, name: "i")
        }
        view.showsFieldHints = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            save(window, dir.appendingPathComponent("gui-3-final.png"))
            view.mode = .view
            save(window, dir.appendingPathComponent("gui-4-view.png"))
            if let pics = ProcessInfo.processInfo.environment["PAGEYARD_SNAPSHOT_IMAGES"] {
                wc.sidebar.importFiles(pics.split(separator: ":").map { URL(fileURLWithPath: String($0)) }, atTop: 1)
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                if let sheet = window.attachedSheet { save(sheet, dir.appendingPathComponent("gui-6-images.png")) }
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            }
            // Continuity: who answers in the main window, and does a "scan" become pages?
            window.makeFirstResponder(view)
            let mainRequestor = window.firstResponder?.validRequestor(forSendType: nil, returnType: .pdf)
            print("main window requestor: \(mainRequestor.map { String(describing: Swift.type(of: $0)) } ?? "none")")
            if let source = view.document?.dataRepresentation(), let requestor = mainRequestor as? NSServicesMenuRequestor {
                let pb = NSPasteboard(name: NSPasteboard.Name("pageyard-continuity-test"))
                pb.clearContents()
                pb.setData(source, forType: .pdf)
                let before = view.document?.pageCount ?? 0
                _ = requestor.readSelection?(from: pb)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                print("scan import: pages \(before) → \(view.document?.pageCount ?? 0), groups \(wc.sidebar.groups.map(\.name))")
            }
            wc.newSignature(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            if let sheet = window.attachedSheet, let pad = sheet.windowController as? SignaturePadController {
                pad.showImported(fakeSignaturePhoto())
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                save(sheet, dir.appendingPathComponent("gui-8-cleanup.png"))
            }
            if let sheet = window.attachedSheet {
                let padRequestor = sheet.firstResponder?.validRequestor(forSendType: nil, returnType: .png)
                print("signature pad requestor: \(padRequestor.map { String(describing: Swift.type(of: $0)) } ?? "none")")
                save(sheet, dir.appendingPathComponent("gui-7-signature.png"))
                window.endSheet(sheet)
            }
            NSDocumentController.shared.newDocument(nil)
            if let w = NSApp.windows.first(where: { ($0.windowController as? EditorWindowController)?.pdfView.document?.pageCount == 0 }) {
                save(w, dir.appendingPathComponent("gui-5-new.png"))
            } else {
                print("no new document window")
            }
            window.undoManager?.undo()
            print("undo: \(window.undoManager?.redoActionName ?? "-")")
            exit(0)
        }
    }

    /// A phone-like photo of a signature: grey paper, uneven light, noise, a shadow.
    static func fakeSignaturePhoto() -> NSImage {
        NSImage(size: CGSize(width: 900, height: 500), flipped: false) { r in
            NSGradient(starting: NSColor(white: 0.93, alpha: 1), ending: NSColor(white: 0.62, alpha: 1))!.draw(in: r, angle: -35)
            NSColor(white: 0, alpha: 0.12).setFill()
            NSBezierPath(ovalIn: CGRect(x: 600, y: -150, width: 500, height: 400)).fill()
            for _ in 0..<5000 {
                NSColor(white: CGFloat.random(in: 0.5...1), alpha: 0.12).setFill()
                CGRect(x: .random(in: 0...900), y: .random(in: 0...500), width: 2, height: 2).fill()
            }
            let ink = NSBezierPath()
            ink.lineWidth = 7
            ink.lineCapStyle = .round
            ink.move(to: CGPoint(x: 120, y: 220))
            ink.curve(to: CGPoint(x: 380, y: 260), controlPoint1: CGPoint(x: 180, y: 420), controlPoint2: CGPoint(x: 300, y: 80))
            ink.curve(to: CGPoint(x: 760, y: 240), controlPoint1: CGPoint(x: 460, y: 420), controlPoint2: CGPoint(x: 620, y: 100))
            NSColor(srgbRed: 0.1, green: 0.15, blue: 0.45, alpha: 0.9).setStroke()
            ink.stroke()
            return true
        }
    }
}
