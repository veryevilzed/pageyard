import AppKit
import UniformTypeIdentifiers

/// Turns files that aren't PDFs or images (Word, Excel, Pages, Numbers…) into
/// temporary PDFs, using whatever converter is installed.
enum DocumentImporter {
    static let textExtensions: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "pages", "txt", "html", "htm"]
    static let sheetExtensions: Set<String> = ["xls", "xlsx", "csv", "numbers", "ods"]
    static let slideExtensions: Set<String> = ["ppt", "pptx", "key", "odp"]

    struct ImportError: Error { let message: String }

    static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func needsConversion(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext) || sheetExtensions.contains(ext) || slideExtensions.contains(ext)
    }

    static func canImport(_ url: URL) -> Bool {
        isPDF(url) || isImage(url) || needsConversion(url)
    }

    /// File types for open panels.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.pdf, .image]
        for ext in textExtensions.union(sheetExtensions).union(slideExtensions) {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    /// Blocking; call off the main thread.
    static func convertToPDF(_ url: URL) -> Result<URL, ImportError> {
        let ext = url.pathExtension.lowercased()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PageYard-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")

        if let soffice = libreOffice() {
            let r = run(soffice, ["--headless", "--convert-to", "pdf", "--outdir", dir.path, url.path], timeout: 180)
            if r.status == 0, FileManager.default.fileExists(atPath: out.path) { return .success(out) }
        }

        let iWork: (id: String, name: String)?
        if textExtensions.contains(ext) {
            iWork = ("com.apple.Pages", "Pages")
        } else if sheetExtensions.contains(ext) {
            iWork = ("com.apple.Numbers", "Numbers")
        } else {
            iWork = ("com.apple.Keynote", "Keynote")
        }
        var iWorkError: String?
        let skipIWork = ProcessInfo.processInfo.environment["PAGEYARD_NO_IWORK"] != nil
        if let iWork, !skipIWork, NSWorkspace.shared.urlForApplication(withBundleIdentifier: iWork.id) != nil {
            let script = """
            on run argv
                tell application id "\(iWork.id)"
                    set d to open (POSIX file (item 1 of argv))
                    export d to (POSIX file (item 2 of argv)) as PDF
                    close d saving no
                end tell
            end run
            """
            let r = run("/usr/bin/osascript", ["-e", script, url.path, out.path], timeout: 180)
            if r.status == 0, FileManager.default.fileExists(atPath: out.path) { return .success(out) }
            iWorkError = "\(iWork.name): \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        if textExtensions.contains(ext) {
            var result: Result<URL, ImportError> = .failure(ImportError(message: "не удалось прочитать документ"))
            DispatchQueue.main.sync { result = renderText(url, to: out) }
            if case .success = result { return result }
        }

        let hint = sheetExtensions.contains(ext)
            ? "Для таблиц нужен Numbers или LibreOffice (brew install --cask libreoffice)."
            : "Нужен Pages, Keynote или LibreOffice (brew install --cask libreoffice)."
        return .failure(ImportError(message: [iWorkError, hint].compactMap { $0 }.joined(separator: "\n")))
    }

    private static func libreOffice() -> String? {
        let candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            return (-1, "время ожидания истекло")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Fallback without office apps: lays the text out on A4 pages with AppKit.
    /// Keeps fonts and paragraphs; complex Word layout (tables, columns) is simplified.
    private static func renderText(_ url: URL, to out: URL) -> Result<URL, ImportError> {
        guard let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
            return .failure(ImportError(message: "не удалось прочитать документ"))
        }
        let info = NSPrintInfo()
        info.paperSize = PageFactory.a4
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 56
        info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let width = PageFactory.a4.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.textStorage?.setAttributedString(attr)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            return .failure(ImportError(message: "не удалось сверстать документ"))
        }
        return .success(out)
    }
}
