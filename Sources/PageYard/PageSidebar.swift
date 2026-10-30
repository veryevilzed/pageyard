import AppKit
import PDFKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted with the PDFPage as object whenever its rendered content changed.
    static let editorPageChanged = Notification.Name("EditorPageChanged")
}

/// Pages inserted together from one file. They stay contiguous and move as a
/// unit until the user breaks the group.
final class PageGroup {
    var name: String
    var pages: [PDFPage]

    init(name: String, pages: [PDFPage]) {
        self.name = name
        self.pages = pages
    }
}

/// Stable outline item wrapping a page.
final class PageItem {
    let page: PDFPage
    init(_ page: PDFPage) { self.page = page }
}

/// Creates pages that don't come from an existing PDF.
enum PageFactory {
    static let a4 = CGSize(width: 595.28, height: 841.89)

    /// Returns the page together with its owning document, which must be kept alive.
    static func page(size: CGSize, draw: (CGContext, CGRect) -> Void) -> (PDFPage, PDFDocument)? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        draw(ctx, box)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0) else { return nil }
        return (page, doc)
    }

    static func blank(size: CGSize) -> (PDFPage, PDFDocument)? {
        page(size: size) { ctx, box in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box)
        }
    }
}

private let itemPasteboardType = NSPasteboard.PasteboardType("com.zed.pageyard.sidebar-item")

final class SidebarOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Page list with groups: navigation, reordering, inserting, deleting,
/// rotating and exporting pages.
final class PageSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var pdfView: EditorPDFView?
    var onExport: (([PDFPage]) -> Void)?

    private(set) var groups: [PageGroup] = []
    private var top: [AnyObject] = []
    private var pageItems: [ObjectIdentifier: PageItem] = [:]
    private var thumbs: [ObjectIdentifier: NSImage] = [:]
    private var staleThumbs = Set<ObjectIdentifier>()
    private var collapsed = Set<ObjectIdentifier>()
    /// Documents that own inserted pages; kept alive for the pages' sake.
    private var sources: [PDFDocument] = []
    private var syncingSelection = false

    let outline = SidebarOutlineView()

    override init(frame: NSRect) {
        super.init(frame: frame)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.indentationPerLevel = 8
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.registerForDraggedTypes([itemPasteboardType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.onDelete = { [weak self] in self?.deleteSelected() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: frame.width, height: frame.height - 28))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = outline
        outline.sizeLastColumnToFit()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 28))
        bar.autoresizingMask = [.width]
        addSubview(bar)
        func button(_ symbol: String, _ tip: String, _ action: Selector, x: CGFloat) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .smallSquare
            b.isBordered = false
            b.toolTip = tip
            b.frame = NSRect(x: x, y: 2, width: 26, height: 24)
            bar.addSubview(b)
            return b
        }
        let plus = button("plus", "Добавить: страницы из файла, пустой лист, лист-макет, с iPhone…", #selector(showAddMenu(_:)), x: 6)
        plus.title = " Добавить"
        plus.imagePosition = .imageLeading
        plus.font = .systemFont(ofSize: 12)
        plus.frame.size.width = 84
        _ = button("minus", "Удалить выделенные страницы", #selector(deleteSelectedAction(_:)), x: 92)

        NotificationCenter.default.addObserver(self, selector: #selector(pageContentChanged(_:)), name: .editorPageChanged, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Model

    private var document: PDFDocument? { pdfView?.document }

    private var documentPages: [PDFPage] {
        guard let doc = document else { return [] }
        return (0..<doc.pageCount).compactMap(doc.page(at:))
    }

    private func pageItem(_ page: PDFPage) -> PageItem {
        let key = ObjectIdentifier(page)
        if let item = pageItems[key] { return item }
        let item = PageItem(page)
        pageItems[key] = item
        return item
    }

    func group(containing page: PDFPage) -> PageGroup? {
        groups.first { $0.pages.contains { $0 === page } }
    }

    private func pages(of obj: AnyObject) -> [PDFPage] {
        if let g = obj as? PageGroup { return g.pages }
        if let p = obj as? PageItem { return [p.page] }
        return []
    }

    func reload() {
        let pages = documentPages
        let index = Dictionary(uniqueKeysWithValues: pages.enumerated().map { (ObjectIdentifier($1), $0) })
        for g in groups {
            g.pages = g.pages.filter { index[ObjectIdentifier($0)] != nil }
                .sorted { index[ObjectIdentifier($0)]! < index[ObjectIdentifier($1)]! }
        }
        groups.removeAll { $0.pages.isEmpty }

        var owner: [ObjectIdentifier: PageGroup] = [:]
        for g in groups { for p in g.pages { owner[ObjectIdentifier(p)] = g } }
        var seen = Set<ObjectIdentifier>()
        top = []
        for p in pages {
            if let g = owner[ObjectIdentifier(p)] {
                if seen.insert(ObjectIdentifier(g)).inserted { top.append(g) }
            } else {
                top.append(pageItem(p))
            }
        }
        outline.reloadData()
        for g in groups where !collapsed.contains(ObjectIdentifier(g)) { outline.expandItem(g) }
        selectCurrentPage()
    }

    /// Page order plus each group's member pages; enough to undo any page operation.
    struct Layout {
        var pages: [PDFPage]
        var groups: [(PageGroup, [PDFPage])]
    }

    private func currentLayout() -> Layout {
        Layout(pages: documentPages, groups: groups.map { ($0, $0.pages) })
    }

    private func layout(fromTop items: [AnyObject]) -> Layout {
        Layout(pages: items.flatMap(pages(of:)),
               groups: items.compactMap { $0 as? PageGroup }.map { ($0, $0.pages) })
    }

    func apply(_ layout: Layout, name: String) {
        guard let view = pdfView, let doc = view.document, !layout.pages.isEmpty else { NSSound.beep(); return }
        let old = currentLayout()
        view.finishEditing()
        let current = view.currentPage

        // Put each target page in place (moving it if already present), then
        // drop the leftovers. exchangePage(at:withPageAt:) crashes on pages
        // copied from other documents, so pages are removed and re-inserted.
        for (i, p) in layout.pages.enumerated() {
            if i < doc.pageCount, doc.page(at: i) === p { continue }
            if let j = (i..<doc.pageCount).first(where: { doc.page(at: $0) === p }) {
                doc.removePage(at: j)
            }
            doc.insert(p, at: i)
        }
        while doc.pageCount > layout.pages.count { doc.removePage(at: doc.pageCount - 1) }

        groups = layout.groups.map { g, pages in g.pages = pages; return g }
        view.layoutDocumentView()
        if let current, layout.pages.contains(where: { $0 === current }) { view.go(to: current) }
        view.documentPagesChanged()
        reload()
        view.undoManager?.registerUndo(withTarget: self) { $0.apply(old, name: name) }
        view.undoManager?.setActionName(name)
    }

    // MARK: - Operations

    func moveTop(from: Int, to: Int) {
        guard top.indices.contains(from), from != to, from + 1 != to else { return }
        var items = top
        let moved = items.remove(at: from)
        items.insert(moved, at: to > from ? to - 1 : to)
        apply(layout(fromTop: items), name: "Перемещение страниц")
    }

    func breakGroup(_ g: PageGroup) {
        let items = top.flatMap { obj -> [AnyObject] in
            obj === g ? g.pages.map(pageItem) : [obj]
        }
        apply(layout(fromTop: items), name: "Разгруппировать")
    }

    func delete(_ pages: [PDFPage]) {
        let gone = Set(pages.map(ObjectIdentifier.init))
        let keep = documentPages.filter { !gone.contains(ObjectIdentifier($0)) }
        guard !keep.isEmpty else {
            NSSound.beep()
            return
        }
        apply(Layout(pages: keep, groups: groups.map { g in (g, g.pages.filter { !gone.contains(ObjectIdentifier($0)) }) }),
              name: pages.count == 1 ? "Удаление страницы" : "Удаление страниц")
    }

    func rotate(_ pages: [PDFPage], by degrees: Int) {
        for p in pages { p.rotation = ((p.rotation + degrees) % 360 + 360) % 360 }
        pdfView?.layoutDocumentView()
        pages.forEach { NotificationCenter.default.post(name: .editorPageChanged, object: $0) }
        pdfView?.undoManager?.registerUndo(withTarget: self) { $0.rotate(pages, by: -degrees) }
        pdfView?.undoManager?.setActionName("Поворот страницы")
    }

    /// Called while slow conversions (Word / Excel) run.
    var onBusy: ((String?) -> Void)?

    /// Turns PDFs / images into sidebar items: multi-page PDFs become groups,
    /// pictures follow `imageOptions`.
    func items(fromFiles files: [(url: URL, name: String)], imageOptions: ImageInsertOptions = .saved) -> [AnyObject] {
        var result: [AnyObject] = []
        var sheetImages: [NSImage] = []
        var sheetSlot: Int?
        for (url, name) in files {
            if DocumentImporter.isPDF(url) {
                guard let src = PDFDocument(url: url) else { continue }
                if src.isLocked, PageYardDocument.askPassword(for: src, name: name) == nil { continue }
                sources.append(src)
                let pages = (0..<src.pageCount).compactMap { src.page(at: $0)?.copy() as? PDFPage }
                if pages.count > 1 {
                    result.append(PageGroup(name: name, pages: pages))
                } else {
                    result += pages.map(pageItem)
                }
            } else if DocumentImporter.isImage(url), let img = NSImage(contentsOf: url) {
                switch (imageOptions.placement, imageOptions.together) {
                case (.ownPage, _):
                    if let (page, owner) = PageFactory.image(img) {
                        sources.append(owner)
                        result.append(pageItem(page))
                    }
                case (.layoutSheet, false):
                    if let item = layoutSheetItem([img], size: imageOptions.sheetSize) { result.append(item) }
                case (.layoutSheet, true):
                    // One shared sheet, placed where the first picture was.
                    if sheetSlot == nil { sheetSlot = result.count }
                    sheetImages.append(img)
                }
            }
        }
        if let slot = sheetSlot, let item = layoutSheetItem(sheetImages, size: imageOptions.sheetSize) {
            result.insert(item, at: slot)
        }
        return result
    }

    private func layoutSheetItem(_ images: [NSImage], size: CGSize) -> PageItem? {
        guard let (page, owner) = PageFactory.layoutSheet(images, size: size) else { return nil }
        sources.append(owner)
        pdfView?.markLayoutSheet(page)
        return pageItem(page)
    }

    /// Inserts any supported files; office documents are converted to PDF first.
    func importFiles(_ urls: [URL], atTop index: Int, imageOptions: ImageInsertOptions? = nil) {
        let urls = urls.filter(DocumentImporter.canImport)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let imageCount = urls.filter(DocumentImporter.isImage).count
        guard imageCount == 0 || imageOptions != nil else {
            guard let window else { importFiles(urls, atTop: index, imageOptions: .saved); return }
            ImageInsertDialog.ask(on: window, imageCount: imageCount) { [weak self] options in
                guard let options else { return }
                self?.importFiles(urls, atTop: index, imageOptions: options)
            }
            return
        }
        let options = imageOptions ?? .saved
        let named = urls.map { (url: $0, name: $0.deletingPathExtension().lastPathComponent) }
        guard urls.contains(where: DocumentImporter.needsConversion) else {
            insert(items(fromFiles: named, imageOptions: options), atTop: index, name: "Вставка страниц")
            return
        }
        onBusy?("Конвертация в PDF…")
        DispatchQueue.global(qos: .userInitiated).async {
            var ready: [(url: URL, name: String)] = []
            var errors: [String] = []
            for f in named {
                guard DocumentImporter.needsConversion(f.url) else { ready.append(f); continue }
                switch DocumentImporter.convertToPDF(f.url) {
                case .success(let pdf): ready.append((pdf, f.name))
                case .failure(let e): errors.append("\(f.url.lastPathComponent): \(e.message)")
                }
            }
            let failures = errors
            let converted = ready
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onBusy?(nil)
                self.insert(self.items(fromFiles: converted, imageOptions: options), atTop: index, name: "Вставка страниц")
                if !failures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Не все файлы удалось вставить"
                    alert.informativeText = failures.joined(separator: "\n\n")
                    if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                }
            }
        }
    }

    func insert(_ items: [AnyObject], atTop index: Int, name: String) {
        guard !items.isEmpty else { return }
        var all = top
        all.insert(contentsOf: items, at: min(max(0, index), all.count))
        apply(layout(fromTop: all), name: name)
        if let first = pages(of: items[0]).first { pdfView?.go(to: first) }
    }

    /// Top-level slot right after the current / selected page (after its whole group).
    func insertionIndexAfterCurrent() -> Int {
        let page = selectedPages().last ?? pdfView?.currentPage
        guard let page else { return top.count }
        let owner: AnyObject = group(containing: page) ?? pageItem(page)
        return (top.firstIndex { $0 === owner } ?? top.count - 1) + 1
    }

    func insertBlankPage(size: CGSize? = nil) {
        let ref = size ?? pdfView?.currentPage?.bounds(for: .cropBox).size ?? PageFactory.a4
        guard let (page, owner) = PageFactory.blank(size: ref) else { return }
        sources.append(owner)
        insert([pageItem(page)], atTop: insertionIndexAfterCurrent(), name: "Пустая страница")
    }

    @objc func insertFromPanel(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentImporter.contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "PDF, картинки, Word, Excel, Pages, Numbers. Многостраничный файл вставится группой."
        panel.prompt = "Вставить"
        let at = insertionIndexAfterCurrent()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self else { return }
            self.importFiles(panel.urls, atTop: at)
        }
    }

    @objc private func deleteSelectedAction(_ sender: Any?) { deleteSelected() }

    func deleteSelected() {
        let pages = selectedPages()
        if !pages.isEmpty { delete(pages) }
    }

    /// Pages of the selected rows; a selected group contributes all its pages.
    func selectedPages() -> [PDFPage] {
        var seen = Set<ObjectIdentifier>()
        var result: [PDFPage] = []
        for row in outline.selectedRowIndexes {
            for p in pages(of: outline.item(atRow: row) as AnyObject) where seen.insert(ObjectIdentifier(p)).inserted {
                result.append(p)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: documentPages.enumerated().map { (ObjectIdentifier($1), $0) })
        return result.sorted { (order[ObjectIdentifier($0)] ?? 0) < (order[ObjectIdentifier($1)] ?? 0) }
    }

    // MARK: - Thumbnails

    @objc private func pageContentChanged(_ note: Notification) {
        guard let page = note.object as? PDFPage, page.document === document else { return }
        staleThumbs.insert(ObjectIdentifier(page))
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(flushThumbs), object: nil)
        perform(#selector(flushThumbs), with: nil, afterDelay: 0.4)
    }

    @objc private func flushThumbs() {
        for key in staleThumbs {
            thumbs[key] = nil
            if let item = pageItems[key] { outline.reloadItem(item) }
        }
        staleThumbs = []
    }

    private func thumbnail(_ page: PDFPage) -> NSImage {
        let key = ObjectIdentifier(page)
        if let t = thumbs[key] { return t }
        let t = page.thumbnail(of: CGSize(width: 240, height: 300), for: .cropBox)
        thumbs[key] = t
        return t
    }

    // MARK: - Selection sync

    func selectCurrentPage() {
        guard let page = pdfView?.currentPage else { return }
        var row = outline.row(forItem: pageItem(page))
        if row < 0, let g = group(containing: page) { row = outline.row(forItem: g) }
        guard row >= 0, !outline.selectedRowIndexes.contains(row) else { return }
        syncingSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        syncingSelection = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, outline.selectedRowIndexes.count == 1 else { return }
        if let page = pages(of: outline.item(atRow: outline.selectedRow) as AnyObject).first {
            pdfView?.go(to: page)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let g = notification.userInfo?["NSObject"] as? PageGroup { collapsed.insert(ObjectIdentifier(g)) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let g = notification.userInfo?["NSObject"] as? PageGroup { collapsed.remove(ObjectIdentifier(g)) }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return top.count }
        return (item as? PageGroup)?.pages.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let g = item as? PageGroup { return pageItem(g.pages[index]) }
        return top[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is PageGroup
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is PageGroup ? 28 : 168
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = GroupTintRowView()
        if let g = item as? PageGroup {
            row.tint = .header
            row.groupName = g.name
        } else if let p = item as? PageItem, group(containing: p.page) != nil {
            row.tint = .member
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let g = item as? PageGroup {
            let cell = GroupCell()
            cell.title.stringValue = g.name
            let n = g.pages.count
            cell.count.stringValue = "\(n) стр."
            cell.toolTip = "\(g.name): \(n) стр. Перетаскивается целиком. Правый клик → Разгруппировать"
            return cell
        }
        guard let p = item as? PageItem else { return nil }
        let cell = PageCell()
        cell.thumb.image = thumbnail(p.page)
        cell.isLayoutSheet = pdfView?.isLayoutSheet(p.page) ?? false
        if let doc = document { cell.number.stringValue = "\(doc.index(for: p.page) + 1)" }
        return cell
    }

    // MARK: - Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Only top-level rows move; pages inside a group travel with it.
        guard outlineView.parent(forItem: item) == nil,
              let i = top.firstIndex(where: { $0 === item as AnyObject }) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(String(i), forType: itemPasteboardType)
        return pb
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(DocumentImporter.canImport)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let isInternal = info.draggingPasteboard.availableType(from: [itemPasteboardType]) != nil
        guard isInternal || !droppedFiles(info).isEmpty else { return [] }
        // Drops always land between top-level rows, never inside a group.
        if let item {
            let owner: AnyObject = (item as? PageItem).flatMap { group(containing: $0.page) } ?? item as AnyObject
            guard let ti = top.firstIndex(where: { $0 === owner }) else { return [] }
            outlineView.setDropItem(nil, dropChildIndex: (item is PageGroup && index == 0) ? ti : ti + 1)
        } else if index == NSOutlineViewDropOnItemIndex {
            outlineView.setDropItem(nil, dropChildIndex: top.count)
        }
        return isInternal ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let to = index < 0 ? top.count : index
        if let s = info.draggingPasteboard.string(forType: itemPasteboardType), let from = Int(s) {
            moveTop(from: from, to: to)
            return true
        }
        let files = droppedFiles(info)
        guard !files.isEmpty else { return false }
        importFiles(files, atTop: to)
        return true
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else {
            add(menu, "Вставить страницы из файла…", #selector(insertFromPanel(_:)), nil)
            return
        }
        // Right-click on an unselected row acts on that row only.
        if !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        let pages = selectedPages()
        let many = pages.count > 1

        add(menu, many ? "Экспортировать \(pages.count) стр. как изображения…" : "Экспортировать как изображение…",
            #selector(exportClicked(_:)), pages)
        menu.addItem(.separator())
        add(menu, "Повернуть вправо", #selector(rotateRight(_:)), pages)
        add(menu, "Повернуть влево", #selector(rotateLeft(_:)), pages)
        menu.addItem(.separator())
        add(menu, "Вставить страницы из файла…", #selector(insertFromPanel(_:)), nil)
        add(menu, "Вставить пустую страницу", #selector(insertBlank(_:)), nil)
        add(menu, "Вставить пустой лист-макет для картинок", #selector(insertBlankSheet(_:)), nil)
        if let p = (item as? PageItem)?.page, pdfView?.isLayoutSheet(p) == true, pages.count == 1 {
            add(menu, "Добавить картинки на этот лист…", #selector(addImagesToSheet(_:)), p)
        }

        let g = (item as? PageGroup) ?? (item as? PageItem).flatMap { group(containing: $0.page) }
        if let g {
            menu.addItem(.separator())
            add(menu, "Разгруппировать «\(g.name)»", #selector(breakClicked(_:)), g)
        }
        menu.addItem(.separator())
        add(menu, many ? "Удалить \(pages.count) стр." : "Удалить страницу", #selector(deleteClicked(_:)), pages)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ object: Any?) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = object
        menu.addItem(mi)
    }

    @objc private func exportClicked(_ sender: NSMenuItem) {
        if let pages = sender.representedObject as? [PDFPage] { onExport?(pages) }
    }

    @objc private func rotateRight(_ sender: NSMenuItem) {
        if let pages = sender.representedObject as? [PDFPage] { rotate(pages, by: 90) }
    }

    @objc private func rotateLeft(_ sender: NSMenuItem) {
        if let pages = sender.representedObject as? [PDFPage] { rotate(pages, by: -90) }
    }

    @objc private func insertBlank(_ sender: Any?) { insertBlankPage() }

    @objc private func insertBlankSheet(_ sender: Any?) {
        insertLayoutSheet(size: ImageInsertOptions.saved.sheetSize)
    }

    func insertLayoutSheet(size: CGSize) {
        guard let item = layoutSheetItem([], size: size) else { return }
        insert([item], atTop: insertionIndexAfterCurrent(), name: "Лист-макет")
    }

    // MARK: - "Add" menu

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        add(menu, "Страницы из файла (PDF, картинки, Word, Excel)…", #selector(insertFromPanel(_:)), nil)
        menu.addItem(.separator())
        menu.addItem(sizeSubmenu("Пустая страница", action: #selector(addBlankSized(_:)), includeCurrent: true))
        menu.addItem(sizeSubmenu("Лист-макет для картинок", action: #selector(addSheetSized(_:)), includeCurrent: false))
        menu.addItem(.separator())
        for item in ContinuityImport.menu().items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func sizeSubmenu(_ title: String, action: Selector, includeCurrent: Bool) -> NSMenuItem {
        let sub = NSMenu()
        if includeCurrent, let size = pdfView?.currentPage?.bounds(for: .cropBox).size {
            add(sub, "Как текущая страница", action, NSValue(size: size))
            sub.addItem(.separator())
        }
        for paper in ImageInsertOptions.Paper.allCases {
            let p = paper.portrait
            add(sub, "\(paper.title) книжная", action, NSValue(size: p))
            add(sub, "\(paper.title) альбомная", action, NSValue(size: CGSize(width: p.height, height: p.width)))
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = sub
        return holder
    }

    @objc private func addBlankSized(_ sender: NSMenuItem) {
        insertBlankPage(size: (sender.representedObject as? NSValue)?.sizeValue)
    }

    @objc private func addSheetSized(_ sender: NSMenuItem) {
        insertLayoutSheet(size: (sender.representedObject as? NSValue)?.sizeValue ?? PageFactory.a4)
    }

    @objc private func addImagesToSheet(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? PDFPage, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Картинки разместятся на листе; потом их можно двигать и менять размер"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            let images = panel.urls.compactMap(NSImage.init(contentsOf:))
            self?.pdfView?.go(to: page)
            self?.pdfView?.placeImages(images, on: page, at: nil)
        }
    }

    @objc private func breakClicked(_ sender: NSMenuItem) {
        if let g = sender.representedObject as? PageGroup { breakGroup(g) }
    }

    @objc private func deleteClicked(_ sender: NSMenuItem) {
        if let pages = sender.representedObject as? [PDFPage] { delete(pages) }
    }
}

// MARK: - Cells

private final class PageCell: NSTableCellView {
    let thumb = NSImageView()
    let number = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "Макет")
    var isLayoutSheet = false {
        didSet {
            badge.isHidden = !isLayoutSheet
            toolTip = isLayoutSheet ? "Лист-макет: картинки на нём можно двигать и менять размер; перетащите сюда ещё картинки" : nil
        }
    }

    init() {
        super.init(frame: .zero)
        thumb.imageScaling = .scaleProportionallyDown
        thumb.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 3
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            return s
        }()
        addSubview(thumb)
        number.alignment = .center
        number.font = .systemFont(ofSize: 11)
        number.textColor = .secondaryLabelColor
        addSubview(number)
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemPurple.cgColor
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
        addSubview(badge)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        number.frame = NSRect(x: 0, y: 2, width: bounds.width, height: 15)
        thumb.frame = NSRect(x: 8, y: 20, width: bounds.width - 16, height: bounds.height - 26)
        badge.frame = NSRect(x: 12, y: bounds.height - 22, width: 42, height: 14)
    }
}

private final class GroupCell: NSTableCellView {
    let icon = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "Группа")!)
    let title = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .controlAccentColor
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        [icon, title, count].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let h = bounds.height
        count.sizeToFit()
        let cw = ceil(count.frame.width)
        icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 18, height: 16)
        count.frame = NSRect(x: bounds.width - cw - 2, y: (h - 15) / 2, width: cw, height: 15)
        title.frame = NSRect(x: 21, y: (h - 16) / 2, width: max(10, bounds.width - cw - 27), height: 16)
    }
}

/// Paints a coloured bracket along grouped rows so a group reads as one block.
private final class GroupTintRowView: NSTableRowView {
    enum Tint { case none, header, member }
    var tint: Tint = .none
    var groupName = ""

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard tint != .none else { return }
        NSColor.controlAccentColor.withAlphaComponent(tint == .header ? 0.16 : 0.07).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }
}
