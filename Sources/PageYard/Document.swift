import AppKit
import PDFKit

@objc(PageYardDocument)
final class PageYardDocument: NSDocument {
    private(set) var pdf: PDFDocument?
    private(set) var password: String?

    override class var autosavesInPlace: Bool { false }

    private var editor: EditorWindowController? {
        windowControllers.compactMap { $0 as? EditorWindowController }.first
    }

    /// File → New: an empty PDF to drag pages, pictures and documents into.
    convenience init(type typeName: String) throws {
        self.init()
        fileType = typeName
        pdf = PDFDocument()
    }

    override func makeWindowControllers() {
        guard let pdf else { return }
        addWindowController(EditorWindowController(pdf: pdf))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let doc = PDFDocument(data: data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        if doc.isLocked {
            guard let pw = Self.askPassword(for: doc, name: nil) else { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
            password = pw
        }
        pdf = doc
    }

    static func askPassword(for doc: PDFDocument, name: String?) -> String? {
        var message = name.map { "«\($0)» защищён паролем" } ?? "Документ защищён паролем"
        for _ in 0..<5 {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "Введите пароль, чтобы открыть PDF."
            alert.addButton(withTitle: "Открыть")
            alert.addButton(withTitle: "Отмена")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if doc.unlock(withPassword: field.stringValue) { return field.stringValue }
            message = "Неверный пароль"
        }
        return nil
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let pdf else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError) }
        guard pdf.pageCount > 0 else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "В документе нет ни одной страницы",
                                     NSLocalizedRecoverySuggestionErrorKey: "Перетащите в окно PDF, картинки или документы, чтобы добавить страницы."])
        }
        editor?.commitPendingEdits()
        let report = DocumentWriter.bake(pdf, password: password)
        if let err = report.redactionError {
            DispatchQueue.main.async { [weak self] in self?.warnRedaction(err) }
        }
        return report.data
    }

    private func warnRedaction(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Исходный текст не удалось вырезать"
        alert.informativeText = "Правки сохранены поверх старого текста (он закрашен, но остаётся в файле).\n\n\(message)"
        if let w = windowForSheet { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let pdf else { return try super.printOperation(withSettings: printSettings) }
        editor?.commitPendingEdits()
        let baked = PDFDocument(data: DocumentWriter.bake(pdf, password: password).data) ?? pdf
        guard let op = baked.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            return try super.printOperation(withSettings: printSettings)
        }
        return op
    }
}
