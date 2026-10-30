import AppKit
import PDFKit

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("sidebar")
    static let mode = Self("mode")
    static let marks = Self("marks")
    static let zoom = Self("zoom")
}

/// Document window: a fixed top toolbar (pages, mode, markers, zoom) and a
/// second row with the tools of the current mode.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    EditorPDFViewDelegate, NSMenuItemValidation, NSComboBoxDelegate, NSServicesMenuRequestor {
    let pdfView = EditorPDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
    let sidebar = PageSidebar(frame: NSRect(x: 0, y: 0, width: 170, height: 800))
    private let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1150, height: 800))
    private let pdfArea = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
    private let placeholder = NSStackView()
    private let strip = NSVisualEffectView()
    private static let stripHeight: CGFloat = 40

    private var modeControl: NSSegmentedControl!
    private var marksButton: NSButton!
    private var zoomPopup: NSPopUpButton!
    private let toolControl = NSSegmentedControl()
    private let sizeBox = NSComboBox()
    private let colorWell = NSColorWell(style: .minimal)
    private let signatureButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hintsButton = NSButton()
    private let eraseCheck = NSButton(checkboxWithTitle: "Стирать под текстом", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")

    init(pdf: PDFDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 450)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        pdfView.editorDelegate = self
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.document = pdf
        pdfView.onDropFiles = { [weak self] urls in
            guard let self else { return }
            self.sidebar.importFiles(urls, atTop: self.sidebar.insertionIndexAfterCurrent())
        }

        sidebar.pdfView = pdfView
        sidebar.onExport = { [weak self] pages in self?.exportImages(of: pages) }
        sidebar.onBusy = { [weak self] status in self?.window?.subtitle = status ?? "" }

        buildContent(in: window)
        buildStrip()

        let toolbar = NSToolbar(identifier: "EditorToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.mode]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
        // Keyboard focus starts on the page (tool shortcuts), not the font size box.
        window.initialFirstResponder = pdfView

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(signaturesChanged), name: SignatureStore.changed, object: nil)
        nc.addObserver(self, selector: #selector(formFieldHit(_:)), name: .PDFViewAnnotationHit, object: pdfView)
        nc.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)

        signaturesChanged()
        sidebar.reload()
        updatePlaceholder()
        let saved = UserDefaults.standard.object(forKey: "editorMode") as? Int
        pdfView.mode = saved.flatMap(EditorMode.init(rawValue:)) ?? .fill
        editorModeChanged(pdfView.mode)
    }

    required init?(coder: NSCoder) { nil }

    private var editorDocument: PageYardDocument? { document as? PageYardDocument }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1150, height: 840))
        strip.frame = NSRect(x: 0, y: root.bounds.height - Self.stripHeight, width: root.bounds.width, height: Self.stripHeight)
        strip.autoresizingMask = [.width, .minYMargin]
        strip.material = .headerView
        strip.blendingMode = .withinWindow
        root.addSubview(strip)
        let line = NSBox(frame: NSRect(x: 0, y: 0, width: strip.bounds.width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width, .maxYMargin]
        strip.addSubview(line)

        pdfView.frame = pdfArea.bounds
        pdfView.autoresizingMask = [.width, .height]
        pdfArea.addSubview(pdfView)

        let title = NSTextField(labelWithString: "Пустой документ")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString:
            "Перетащите сюда PDF, картинки, документы Word / Pages или таблицы Excel / Numbers — они станут страницами. Порядок меняется перетаскиванием в панели слева.")
        text.alignment = .center
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 420
        let button = NSButton(title: "Добавить файлы…", target: sidebar, action: #selector(PageSidebar.insertFromPanel(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 48, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        [icon, title, text, button].forEach(placeholder.addArrangedSubview)
        placeholder.orientation = .vertical
        placeholder.spacing = 12
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        pdfArea.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: pdfArea.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: pdfArea.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])

        split.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height - Self.stripHeight)
        split.autoresizingMask = [.width, .height]
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pdfArea)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        root.addSubview(split)
        window.contentView = root
        split.setPosition(200, ofDividerAt: 0)
    }

    private func setStripVisible(_ visible: Bool) {
        guard let root = window?.contentView else { return }
        strip.isHidden = !visible
        let h = visible ? root.bounds.height - Self.stripHeight : root.bounds.height
        split.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: h)
    }

    private func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: label)!
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    private func buildStrip() {
        toolControl.trackingMode = .selectOne
        toolControl.target = self
        toolControl.action = #selector(toolSegmentChanged(_:))
        toolControl.segmentStyle = .rounded

        sizeBox.addItems(withObjectValues: ["6", "7", "8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "32", "36", "48"])
        sizeBox.stringValue = "12"
        sizeBox.target = self
        sizeBox.action = #selector(sizeChanged(_:))
        sizeBox.delegate = self
        sizeBox.toolTip = "Размер шрифта"
        // No inline predictions / completions in a number field.
        sizeBox.isAutomaticTextCompletionEnabled = false
        sizeBox.widthAnchor.constraint(equalToConstant: 64).isActive = true

        colorWell.color = .black
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Цвет текста и отметок"
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true

        eraseCheck.target = self
        eraseCheck.action = #selector(eraseChanged(_:))
        eraseCheck.toolTip = "Текст закрывает то, что под ним, а при сохранении старый текст под ним удаляется из файла. Действует на новые области и на выделенный текст"

        signatureButton.toolTip = "Сохранённые подписи"
        signatureButton.widthAnchor.constraint(equalToConstant: 92).isActive = true

        hintsButton.image = symbol("rectangle.dashed", "Поля")
        hintsButton.title = "Поля"
        hintsButton.imagePosition = .imageLeading
        hintsButton.setButtonType(.pushOnPushOff)
        hintsButton.bezelStyle = .rounded
        hintsButton.target = self
        hintsButton.action = #selector(toggleHints(_:))
        hintsButton.toolTip = "Подсветить найденные места для заполнения: линии, ячейки, квадратики (⌘⇧F)"

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sizeLabel = NSTextField(labelWithString: "Шрифт")
        sizeLabel.textColor = .secondaryLabelColor
        let styleSep = separator()

        let stack = NSStackView(views: [toolControl, styleSep, sizeLabel, sizeBox, colorWell, eraseCheck, signatureButton, hintsButton, hintLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(14, after: toolControl)
        stack.setCustomSpacing(14, after: colorWell)
        stack.setCustomSpacing(14, after: eraseCheck)
        stack.setCustomSpacing(16, after: hintsButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: strip.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
    }

    private func rebuildToolControl() {
        let tools = pdfView.mode.tools
        toolControl.segmentCount = tools.count
        for (i, t) in tools.enumerated() {
            toolControl.setImage(symbol(t.symbol, t.title), forSegment: i)
            toolControl.setLabel(t.title, forSegment: i)
            toolControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
            toolControl.setToolTip("\(t.title) (\(t.keyLabel))", forSegment: i)
            toolControl.setWidth(0, forSegment: i)
        }
        toolControl.selectedSegment = tools.firstIndex(of: pdfView.tool) ?? -1
    }

    private func updatePlaceholder() {
        let empty = (pdfView.document?.pageCount ?? 0) == 0
        placeholder.isHidden = !empty
        pdfView.isHidden = empty
    }

    // MARK: - Top toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .flexibleSpace, .mode, .flexibleSpace, .marks, .zoom]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .mode:
            let c = NSSegmentedControl(labels: EditorMode.allCases.map(\.title), trackingMode: .selectOne,
                                       target: self, action: #selector(modeSegmentChanged(_:)))
            for m in EditorMode.allCases { c.setToolTip("\(m.title) (⌘\(m.rawValue + 1))", forSegment: m.rawValue) }
            c.selectedSegment = pdfView.mode.rawValue
            modeControl = c
            item.view = c
            item.label = "Режим"
        case .marks:
            let b = NSButton(image: symbol("eye", "Пометки"), target: self, action: #selector(toggleMarks(_:)))
            b.bezelStyle = .texturedRounded
            marksButton = b
            editorMarksVisibilityChanged(pdfView.marksVisible)
            item.view = b
            item.label = "Пометки"
        case .zoom:
            let minus = NSButton(image: symbol("minus.magnifyingglass", "Уменьшить"), target: self, action: #selector(zoomOutAction(_:)))
            let plus = NSButton(image: symbol("plus.magnifyingglass", "Увеличить"), target: self, action: #selector(zoomInAction(_:)))
            [minus, plus].forEach { $0.bezelStyle = .texturedRounded }
            minus.toolTip = "Уменьшить (⌘−)"
            plus.toolTip = "Увеличить (⌘+)"
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.addItem(withTitle: "100%")
            let fit = NSMenuItem(title: "По размеру окна", action: #selector(zoomPreset(_:)), keyEquivalent: "")
            fit.tag = -1
            fit.target = self
            popup.menu?.addItem(fit)
            popup.menu?.addItem(.separator())
            for pct in [50, 75, 100, 125, 150, 200, 300, 400] {
                let mi = NSMenuItem(title: "\(pct)%", action: #selector(zoomPreset(_:)), keyEquivalent: "")
                mi.tag = pct
                mi.target = self
                popup.menu?.addItem(mi)
            }
            popup.toolTip = "Масштаб"
            popup.widthAnchor.constraint(equalToConstant: 84).isActive = true
            zoomPopup = popup
            scaleChanged()
            let stack = NSStackView(views: [minus, popup, plus])
            stack.spacing = 4
            item.view = stack
            item.label = "Масштаб"
        case .sidebar:
            let b = NSButton(image: symbol("sidebar.left", "Страницы"), target: self, action: #selector(toggleThumbnails(_:)))
            b.bezelStyle = .texturedRounded
            b.toolTip = "Панель страниц (⌘⌥S)"
            item.view = b
            item.label = "Страницы"
        default:
            return nil
        }
        return item
    }

    // MARK: - Notifications

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editorDocument?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        RenderState.viewScale = pdfView.scaleFactor
    }

    @objc private func formFieldHit(_ note: Notification) {
        // Native form widgets are edited by PDFKit itself; just mark dirty.
        if let a = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation, a.type == "Widget" {
            editorDocument?.updateChangeCount(.changeDone)
        }
    }

    @objc private func pageChanged() {
        sidebar.selectCurrentPage()
    }

    @objc private func scaleChanged() {
        let pct = Int((pdfView.scaleFactor * 100).rounded())
        zoomPopup?.item(at: 0)?.title = pdfView.autoScales ? "\(pct)% ↔" : "\(pct)%"
    }

    // MARK: - Actions

    @objc private func toolSegmentChanged(_ sender: NSSegmentedControl) {
        let tools = pdfView.mode.tools
        guard tools.indices.contains(sender.selectedSegment) else { return }
        selectTool(tools[sender.selectedSegment])
    }

    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        if let m = EditorMode(rawValue: sender.selectedSegment) { setMode(m) }
    }

    @objc func selectModeFromMenu(_ sender: NSMenuItem) {
        if let m = EditorMode(rawValue: sender.tag) { setMode(m) }
    }

    private func setMode(_ m: EditorMode) {
        pdfView.mode = m
        window?.makeFirstResponder(pdfView)
    }

    @objc func selectToolFromMenu(_ sender: NSMenuItem) {
        if let t = Tool(rawValue: sender.tag) { selectTool(t) }
    }

    private func selectTool(_ t: Tool) {
        if t == .signature, SignatureStore.shared.current == nil {
            newSignature(nil)
            return
        }
        pdfView.activate(t)
        window?.makeFirstResponder(pdfView)
    }

    @objc private func sizeChanged(_ sender: NSComboBox) {
        applySize(sender.stringValue)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let v = sizeBox.objectValueOfSelectedItem as? String { applySize(v) }
    }

    private func applySize(_ s: String) {
        guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v >= 2, v <= 400 else { return }
        pdfView.fontSize = CGFloat(v)
        pdfView.applyStyle()
    }

    @objc private func eraseChanged(_ sender: NSButton) {
        pdfView.eraseUnderText = sender.state == .on
        pdfView.applyEraseToSelection()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        pdfView.textColor = sender.color
        pdfView.applyStyle()
    }

    @objc func toggleHints(_ sender: Any?) {
        if pdfView.mode == .view { pdfView.mode = .fill }
        pdfView.showsFieldHints.toggle()
        hintsButton.state = pdfView.showsFieldHints ? .on : .off
    }

    @objc func toggleMarks(_ sender: Any?) {
        pdfView.marksVisible.toggle()
    }

    @objc func toggleThumbnails(_ sender: Any?) {
        // The divider may also have been dragged to zero, so judge by width too.
        let visible = !sidebar.isHidden && sidebar.frame.width > 20
        if visible {
            sidebar.isHidden = true
        } else {
            sidebar.isHidden = false
            split.adjustSubviews()
            split.setPosition(200, ofDividerAt: 0)
        }
    }

    @objc private func zoomPreset(_ sender: NSMenuItem) {
        if sender.tag < 0 {
            pdfView.autoScales = true
        } else {
            pdfView.autoScales = false
            pdfView.scaleFactor = CGFloat(sender.tag) / 100
        }
        scaleChanged()
    }

    @objc func zoomInAction(_ sender: Any?) { pdfView.zoomIn(nil) }
    @objc func zoomOutAction(_ sender: Any?) { pdfView.zoomOut(nil) }
    @objc func actualSizeAction(_ sender: Any?) { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    @objc func fitAction(_ sender: Any?) { pdfView.autoScales = true; scaleChanged() }

    @objc func deleteSelection(_ sender: Any?) { pdfView.deleteSelected() }

    @objc func insertPagesFromFile(_ sender: Any?) { sidebar.insertFromPanel(sender) }
    @objc func insertBlankPage(_ sender: Any?) { sidebar.insertBlankPage() }

    @objc func exportPageImages(_ sender: Any?) {
        exportImages(of: nil)
    }

    @objc func exportCurrentPageImage(_ sender: Any?) {
        guard let page = pdfView.currentPage else { NSSound.beep(); return }
        exportImages(of: [page])
    }

    // MARK: - Export

    /// `pages == nil`: all pages, or the sidebar selection if the user ticks it.
    private func exportImages(of pages: [PDFPage]?) {
        guard let window, let pdf = pdfView.document, pdf.pageCount > 0 else { NSSound.beep(); return }
        let defaults = UserDefaults.standard

        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ["PNG", "JPEG"])
        format.selectItem(at: defaults.integer(forKey: "exportFormat"))
        let dpiValues = [72, 150, 200, 300, 600]
        let dpi = NSPopUpButton(frame: .zero, pullsDown: false)
        dpi.addItems(withTitles: dpiValues.map { "\($0) DPI" })
        dpi.selectItem(at: dpiValues.firstIndex(of: defaults.object(forKey: "exportDPI") as? Int ?? 150) ?? 1)
        // Which pages: all / selected in the sidebar / a range.
        let selected = sidebar.selectedPages()
        let scopeAll = NSButton(radioButtonWithTitle: "Все (\(pdf.pageCount))", target: self, action: #selector(exportScopeChanged(_:)))
        let scopeSelected = NSButton(radioButtonWithTitle: "Выделенные в панели (\(selected.count))", target: self, action: #selector(exportScopeChanged(_:)))
        let scopeRange = NSButton(radioButtonWithTitle: "Страницы с", target: self, action: #selector(exportScopeChanged(_:)))
        let from = NSTextField(string: "1")
        let to = NSTextField(string: "\(pdf.pageCount)")
        for f in [from, to] { f.widthAnchor.constraint(equalToConstant: 48).isActive = true }
        scopeSelected.isEnabled = !selected.isEmpty
        scopeAll.state = .on
        exportScopeButtons = [scopeAll, scopeSelected, scopeRange]
        let rangeRow = NSStackView(views: [scopeRange, from, NSTextField(labelWithString: "по"), to])
        rangeRow.spacing = 6
        let scopeStack = NSStackView(views: [scopeAll, scopeSelected, rangeRow])
        scopeStack.orientation = .vertical
        scopeStack.alignment = .leading
        scopeStack.spacing = 4
        let single = NSTextField(labelWithString: pages.map { $0.count == 1 ? "Страница \(pdf.index(for: $0[0]) + 1)" : "Страниц: \($0.count)" } ?? "")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Формат:"), format],
            [NSTextField(labelWithString: "Разрешение:"), dpi],
            [NSTextField(labelWithString: "Страницы:"), pages == nil ? scopeStack : single],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 2).yPlacement = .top
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: pages == nil ? 150 : 96))
        grid.frame = accessory.bounds.insetBy(dx: 10, dy: 8)
        accessory.addSubview(grid)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Экспортировать"
        panel.message = "Выберите папку для изображений страниц (со всеми правками)"
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self, let dir = panel.url else { return }
            defaults.set(format.indexOfSelectedItem, forKey: "exportFormat")
            defaults.set(dpiValues[dpi.indexOfSelectedItem], forKey: "exportDPI")
            let all = (0..<pdf.pageCount).compactMap(pdf.page(at:))
            let chosen: [PDFPage]
            if let pages {
                chosen = pages
            } else if scopeSelected.state == .on {
                chosen = selected
            } else if scopeRange.state == .on {
                let a = max(1, min(pdf.pageCount, from.integerValue)), b = max(1, min(pdf.pageCount, to.integerValue))
                chosen = Array(all[(min(a, b) - 1)...(max(a, b) - 1)])
            } else {
                chosen = all
            }
            self.commitPendingEdits()
            let baked = PDFDocument(data: DocumentWriter.bake(pdf, password: self.editorDocument?.password).data)
            let list = chosen.compactMap { p -> (page: PDFPage, number: Int)? in
                let i = pdf.index(for: p)
                guard let bp = baked?.page(at: i) else { return nil }
                return (bp, i + 1)
            }
            let base = (self.editorDocument?.displayName as NSString?)?.deletingPathExtension ?? "Страница"
            do {
                let urls = try PageImageExporter.export(list, to: dir, baseName: base,
                                                        format: PageImageExporter.Format(rawValue: format.indexOfSelectedItem) ?? .png,
                                                        dpi: CGFloat(dpiValues[dpi.indexOfSelectedItem]))
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private var exportScopeButtons: [NSButton] = []

    /// The scope radios sit in different stacks, so they are grouped by hand.
    @objc private func exportScopeChanged(_ sender: NSButton) {
        for b in exportScopeButtons where b !== sender { b.state = .off }
        sender.state = .on
    }

    // MARK: - Import from iPhone / iPad (Continuity Camera)

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, ContinuityImport.accepts(returnType), window?.attachedSheet == nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    /// Scanned documents arrive as PDF and become pages; photos go through
    /// the usual picture dialog, or straight onto the current layout sheet.
    func readSelection(from pboard: NSPasteboard) -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PageYard-continuity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM HH-mm-ss"
        let stamp = fmt.string(from: Date())
        let at = sidebar.insertionIndexAfterCurrent()
        if let data = pboard.data(forType: .pdf) {
            let url = dir.appendingPathComponent("Скан \(stamp).pdf")
            guard (try? data.write(to: url)) != nil else { return false }
            sidebar.importFiles([url], atTop: at)
            return true
        }
        guard let image = NSImage(pasteboard: pboard) else { return false }
        if let page = pdfView.currentPage, pdfView.isLayoutSheet(page) {
            pdfView.placeImages([image], on: page, at: nil)
            return true
        }
        let url = dir.appendingPathComponent("Фото \(stamp).png")
        guard let png = SignatureStore.pngData(image), (try? png.write(to: url)) != nil else { return false }
        sidebar.importFiles([url], atTop: at)
        return true
    }

    // MARK: - Signatures

    @objc func newSignature(_ sender: Any?) {
        guard let window else { return }
        SignaturePadController.run(on: window) { [weak self] image in
            guard let self, let image, let item = SignatureStore.shared.add(image) else { return }
            self.pdfView.signatureImage = item.image
            self.pdfView.activate(.signature)
        }
    }

    @objc private func chooseSignature(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SignatureStore.shared.currentID = id
        pdfView.activate(.signature)
        window?.makeFirstResponder(pdfView)
    }

    @objc private func deleteCurrentSignature(_ sender: Any?) {
        guard let cur = SignatureStore.shared.current, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить сохранённую подпись?"
        alert.informativeText = "Уже поставленные в документ подписи останутся."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn { SignatureStore.shared.remove(cur.id) }
        }
    }

    @objc private func signaturesChanged() {
        let store = SignatureStore.shared
        pdfView.signatureImage = store.current?.image
        let menu = NSMenu()
        let face = NSMenuItem(title: store.current == nil ? "Подпись" : "", action: nil, keyEquivalent: "")
        face.image = store.current.map { SignatureStore.thumbnail($0.image, height: 18) } ?? symbol("signature", "Подпись")
        menu.addItem(face)
        for item in store.items {
            let mi = NSMenuItem(title: "", action: #selector(chooseSignature(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.id
            mi.image = SignatureStore.thumbnail(item.image, height: 30)
            mi.state = item.id == store.current?.id ? .on : .off
            menu.addItem(mi)
        }
        if !store.items.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Новая подпись…", action: #selector(newSignature(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        if store.current != nil {
            let del = NSMenuItem(title: "Удалить выбранную подпись", action: #selector(deleteCurrentSignature(_:)), keyEquivalent: "")
            del.target = self
            menu.addItem(del)
        }
        signatureButton.menu = menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(deleteSelection(_:)):
            return pdfView.hasSelection
        case #selector(selectToolFromMenu(_:)):
            item.state = pdfView.mode != .view && item.tag == pdfView.tool.rawValue ? .on : .off
            return true
        case #selector(selectModeFromMenu(_:)):
            item.state = item.tag == pdfView.mode.rawValue ? .on : .off
            return true
        case #selector(toggleHints(_:)):
            item.state = pdfView.showsFieldHints ? .on : .off
            return true
        case #selector(toggleMarks(_:)):
            item.state = pdfView.marksVisible ? .on : .off
            return true
        case #selector(exportPageImages(_:)), #selector(exportCurrentPageImage(_:)):
            return (pdfView.document?.pageCount ?? 0) > 0
        default:
            return true
        }
    }

    /// Called before saving / printing.
    func commitPendingEdits() {
        pdfView.finishEditing()
    }

    // MARK: - EditorPDFViewDelegate

    func editorToolChanged(_ tool: Tool) {
        toolControl.selectedSegment = pdfView.mode.tools.firstIndex(of: tool) ?? -1
        hintLabel.stringValue = tool.hint
        hintLabel.toolTip = tool.hint
    }

    func editorModeChanged(_ mode: EditorMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "editorMode")
        modeControl?.selectedSegment = mode.rawValue
        rebuildToolControl()
        hintsButton.state = pdfView.showsFieldHints ? .on : .off
        signatureButton.isHidden = mode != .fill
        hintsButton.isHidden = mode != .fill
        setStripVisible(mode != .view)
        editorToolChanged(pdfView.tool)
    }

    func editorSelectionChanged(_ a: EditableAnnotation?) {
        // Mirror the object's style so toolbar edits start from it.
        if let tb = a as? TextBoxAnnotation {
            let size = (tb.textFont.pointSize * 10).rounded() / 10
            sizeBox.stringValue = String(format: "%g", size)
            colorWell.color = tb.ink
            pdfView.fontSize = size
            pdfView.textColor = tb.ink
            if tb.redactionRect == nil {
                eraseCheck.state = tb.erasesBelow ? .on : .off
                pdfView.eraseUnderText = tb.erasesBelow
            }
        } else if let m = a as? MarkAnnotation {
            colorWell.color = m.ink
            pdfView.textColor = m.ink
        }
    }

    func editorNeedsSignature() {
        newSignature(nil)
    }

    func editorPagesChanged() {
        updatePlaceholder()
    }

    func editorMarksVisibilityChanged(_ visible: Bool) {
        marksButton?.image = symbol(visible ? "eye" : "eye.slash", "Пометки")
        marksButton?.toolTip = visible ? "Скрыть пометки маркером и заметки (⌘⇧M)" : "Показать пометки маркером и заметки (⌘⇧M)"
    }
}
