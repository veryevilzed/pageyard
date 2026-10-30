import AppKit
import CMuPDF
import PDFKit

/// Produces the final PDF: original pages (with filled form fields), the
/// original glyphs of edited text physically removed via MuPDF, and every
/// user-placed object baked into page content.
enum DocumentWriter {
    struct Report {
        var data: Data
        /// Non-nil when text removal failed and edits were only painted over.
        var redactionError: String?
    }

    static func bake(_ doc: PDFDocument, password: String?) -> Report {
        RenderState.offscreen { bakeOffscreen(doc, password: password) }
    }

    private static func bakeOffscreen(_ doc: PDFDocument, password: String?) -> Report {
        // Take our own objects off the pages so PDFKit's serialisation only
        // contains the original document plus native form values.
        var own: [[PDFAnnotation]] = []
        var regions: [pe_region] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { own.append([]); continue }
            let mine = page.annotations.filter { $0 is EditableAnnotation || $0 is HintAnnotation }
            mine.forEach(page.removeAnnotation)
            own.append(mine)
            for case let tb as TextBoxAnnotation in mine {
                guard let r = tb.regionToRemove else { continue }
                // Shrink so neighbouring glyphs/lines that merely touch survive.
                let dx = min(0.5, r.width / 4), dy = r.height * 0.3
                let rr = r.insetBy(dx: dx, dy: dy)
                regions.append(pe_region(page: Int32(i), x0: rr.minX, y0: rr.minY, x1: rr.maxX, y1: rr.maxY))
            }
        }
        defer {
            for (i, list) in own.enumerated() {
                guard let page = doc.page(at: i) else { continue }
                list.forEach(page.addAnnotation)
            }
        }

        var base = doc
        var redactionError: String?
        var redacted = false
        if let original = doc.dataRepresentation() {
            var data = original
            if !regions.isEmpty {
                switch removeText(from: original, password: password, regions: regions) {
                case .success(let d): data = d; redacted = true
                case .failure(let e): redactionError = e.message
                }
            }
            if let reloaded = PDFDocument(data: data) {
                if reloaded.isLocked, let password { reloaded.unlock(withPassword: password) }
                if !reloaded.isLocked, reloaded.pageCount == doc.pageCount { base = reloaded }
            }
        }
        if base === doc { redacted = false }

        RenderState.isFlattening = true
        RenderState.coversRemovedByRedaction = redacted
        defer {
            RenderState.isFlattening = false
            RenderState.coversRemovedByRedaction = false
        }

        let out = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "PageYard"]
        if let attrs = doc.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] { info[kCGPDFContextTitle] = t }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] { info[kCGPDFContextAuthor] = a }
            if let s = attrs[PDFDocumentAttribute.subjectAttribute] { info[kCGPDFContextSubject] = s }
        }
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary)
        else { return Report(data: doc.dataRepresentation() ?? Data(), redactionError: redactionError) }

        var markers: [(page: Int, rect: CGRect, note: String, hidden: Bool)] = []
        for i in 0..<doc.pageCount {
            guard let live = doc.page(at: i), let page = base.page(at: i) else { continue }
            let crop = live.bounds(for: .cropBox)
            let quarterTurns = ((live.rotation % 360) + 360) % 360 / 90
            var media = CGRect(x: 0, y: 0,
                               width: quarterTurns % 2 == 1 ? crop.height : crop.width,
                               height: quarterTurns % 2 == 1 ? crop.width : crop.height)
            let boxData = Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            page.draw(with: .cropBox, to: ctx)
            ctx.saveGState()
            let transform = live.transform(for: .cropBox)
            ctx.concatenate(transform)
            for case let a as EditableAnnotation in own[i] {
                if let h = a as? HighlightAnnotation {
                    markers.append((i, h.blockRect.applying(transform), h.note, h.isMarkHidden))
                    continue
                }
                a.draw(with: .cropBox, in: ctx)
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return Report(data: addMarkers(markers, to: out as Data), redactionError: redactionError)
    }

    /// Markers stay real highlight annotations so any viewer can hide them.
    private static func addMarkers(_ markers: [(page: Int, rect: CGRect, note: String, hidden: Bool)], to data: Data) -> Data {
        guard !markers.isEmpty, let doc = PDFDocument(data: data) else { return data }
        for m in markers {
            guard let page = doc.page(at: m.page) else { continue }
            let a = PDFAnnotation(bounds: m.rect, forType: .highlight, withProperties: nil)
            a.color = HighlightAnnotation.defaultColor.withAlphaComponent(0.5)
            let w = m.rect.width, h = m.rect.height
            a.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: h)), NSValue(point: CGPoint(x: w, y: h)),
                                     NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: w, y: 0))]
            if !m.note.isEmpty { a.contents = m.note }
            a.userName = NSFullUserName()
            a.shouldDisplay = !m.hidden
            a.shouldPrint = !m.hidden
            page.addAnnotation(a)
        }
        return doc.dataRepresentation() ?? data
    }

    /// Annotation types counted as markup (comments, highlights, drawings).
    /// Form fields and links are content, not annotations to strip.
    static let markupTypes: Set<String> = [
        "Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "Popup", "FreeText", "Ink",
        "Square", "Circle", "Line", "Polygon", "PolyLine", "Stamp", "Caret", "FileAttachment", "Sound", "Redact",
    ]

    /// The document as it is now (page order, inserted and rotated pages) but
    /// without any annotations: none of the user's objects or edits, and none
    /// of the comments / highlights the file came with. Form fields stay.
    static func withoutAnnotations(_ doc: PDFDocument) -> Data? {
        var removed: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a is EditableAnnotation || a is HintAnnotation || markupTypes.contains(a.type ?? "") {
                page.removeAnnotation(a)
                removed.append((page, a))
            }
        }
        defer { for (page, a) in removed { page.addAnnotation(a) } }
        return doc.dataRepresentation()
    }

    struct MuPDFError: Error { let message: String }

    static func removeText(from data: Data, password: String?, regions: [pe_region]) -> Result<Data, MuPDFError> {
        var errBuf = [CChar](repeating: 0, count: 512)
        var outLen = 0
        let result: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            regions.withUnsafeBufferPointer { rp in
                pe_remove_text(raw.bindMemory(to: UInt8.self).baseAddress, data.count, password,
                               rp.baseAddress, Int32(rp.count), &outLen, &errBuf, errBuf.count)
            }
        }
        guard let result else {
            return .failure(MuPDFError(message: String(cString: errBuf)))
        }
        defer { pe_free(result) }
        return .success(Data(bytes: result, count: outLen))
    }
}
