import AppKit
import ImageCaptureCore
import PDFKit

/// Scanning through ImageCaptureCore: USB and network scanners, flatbed or
/// document feeder (all sheets in one go, optionally both sides). Pages
/// collect in the sheet; «Вставить» adds them as one group after the current page.
final class ScanWindowController: NSWindowController, NSWindowDelegate, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    /// One sheet per editor window at a time.
    private static var open: [ObjectIdentifier: ScanWindowController] = [:]

    static func present(on parent: NSWindow, insert: @escaping (URL) -> Void) {
        if let existing = open[ObjectIdentifier(parent)] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = ScanWindowController(insert: insert)
        open[ObjectIdentifier(parent)] = c
        c.parentWindow = parent
        parent.beginSheet(c.window!) { _ in
            c.shutDown()
            open[ObjectIdentifier(parent)] = nil
        }
    }

    private enum Color: Int, CaseIterable {
        case color, gray, bw
        var title: String { ["Цветной", "Оттенки серого", "Чёрно-белый"][rawValue] }
    }

    private struct Format {
        let type: ICScannerDocumentType
        let title: String
    }

    private static let formats: [Format] = [
        Format(type: .typeA4, title: "A4"),
        Format(type: .typeUSLetter, title: "Letter"),
        Format(type: .typeUSLegal, title: "Legal"),
        Format(type: .typeA5, title: "A5"),
        Format(type: .typeA3, title: "A3"),
    ]

    private let insert: (URL) -> Void
    private weak var parentWindow: NSWindow?
    private let browser = ICDeviceBrowser()
    private var scanners: [ICScannerDevice] = []
    private var scanner: ICScannerDevice?
    private var ready = false
    private var scanning = false
    private var stopRequested = false
    /// Overview (preview) scan of the glass in progress.
    private var previewing = false
    /// After a failure the session is reopened once and the action repeated.
    private enum Action { case scan, preview }
    private var retryAfterReconnect: Action?
    private var retried = false
    private var busy: Bool { scanning || previewing }
    /// Pages of the current scan (a feeder may report them in reverse order).
    private var batch: [ScannedPage] = []
    private var pages: [ScannedPage] = []
    private var skippedBlank = 0
    private let downloads = FileManager.default.temporaryDirectory
        .appendingPathComponent("PageYard-scan-\(UUID().uuidString)", isDirectory: true)

    private let scannerPopup = NSPopUpButton()
    private let source = NSSegmentedControl(labels: ["Планшет", "Автоподатчик"], trackingMode: .selectOne, target: nil, action: nil)
    private let duplex = NSButton(checkboxWithTitle: "С двух сторон", target: nil, action: nil)
    private let formatPopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let skipBlank = NSButton(checkboxWithTitle: "Пропускать пустые страницы", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let thumbs = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let scanButton = NSButton(title: "Сканировать", target: nil, action: nil)
    private let insertButton = NSButton(title: "Вставить", target: nil, action: nil)
    private let clearButton = NSButton(title: "Очистить", target: nil, action: nil)
    private let preview = ScanPreviewView()
    private let previewButton = NSButton(title: "Просмотр стекла", target: nil, action: nil)
    private let previewCaption = NSTextField(wrappingLabelWithString: "")

    private init(insert: @escaping (URL) -> Void) {
        self.insert = insert
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Сканирование"
        super.init(window: window)
        window.delegate = self
        build()
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue)!
        browser.start()
        setStatus("Ищу сканеры…", busy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.scanners.isEmpty else { return }
            self.setStatus("Сканер не найден. Включите его и проверьте, что он есть в Системных настройках → Принтеры и сканеры (сетевой — в той же сети, что и Mac).", busy: false)
        }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - UI

    private func build() {
        let d = UserDefaults.standard
        scannerPopup.target = self
        scannerPopup.action = #selector(scannerChanged)
        source.target = self
        source.action = #selector(sourceChanged)
        source.selectedSegment = d.integer(forKey: "scanSource")
        duplex.state = d.bool(forKey: "scanDuplex") ? .on : .off
        duplex.target = self
        duplex.action = #selector(saveSettings)
        for c in Color.allCases { colorPopup.addItem(withTitle: c.title); colorPopup.lastItem?.tag = c.rawValue }
        colorPopup.selectItem(withTag: d.object(forKey: "scanColor") as? Int ?? Color.gray.rawValue)
        skipBlank.state = (d.object(forKey: "scanSkipBlank") as? Bool ?? true) ? .on : .off
        skipBlank.toolTip = "Пустые обороты при двусторонней подаче и чистые листы не попадут в документ"
        for p in [colorPopup, formatPopup, resolutionPopup] { p.target = self; p.action = #selector(saveSettings) }
        skipBlank.target = self
        skipBlank.action = #selector(saveSettings)

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.preferredMaxLayoutWidth = 500
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label("Сканер:"), scannerPopup],
            [label("Подача:"), NSStackView(views: [source, duplex])],
            [label("Формат:"), formatPopup],
            [label("Цвет:"), colorPopup],
            [label("Разрешение:"), resolutionPopup],
            [NSGridCell.emptyContentView, skipBlank],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        scannerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        thumbs.orientation = .horizontal
        thumbs.spacing = 8
        thumbs.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        let scroll = NSScrollView()
        scroll.documentView = thumbs
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 130),
            scroll.widthAnchor.constraint(equalToConstant: 520),
            thumbs.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            thumbs.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        countLabel.textColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearPages)
        clearButton.controlSize = .small
        clearButton.bezelStyle = .rounded
        let countRow = NSStackView(views: [countLabel, clearButton])

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        scanButton.target = self
        scanButton.action = #selector(scanOrStop)
        insertButton.target = self
        insertButton.action = #selector(insertPages)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [cancel, spacer, scanButton, insertButton])
        buttons.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.alignment = .firstBaseline

        let left = NSStackView(views: [grid, statusRow, scroll, countRow, buttons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 12

        previewButton.target = self
        previewButton.action = #selector(previewGlass)
        previewButton.bezelStyle = .rounded
        previewButton.toolTip = "Быстрый снимок стекла: видно, ровно ли лежит лист и попадает ли он в рамку формата"
        previewCaption.textColor = .secondaryLabelColor
        previewCaption.font = .systemFont(ofSize: 11)
        previewCaption.alignment = .center
        previewCaption.preferredMaxLayoutWidth = 280
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 280),
            preview.heightAnchor.constraint(equalToConstant: 380),
        ])
        let right = NSStackView(views: [preview, previewCaption, previewButton])
        right.orientation = .vertical
        right.spacing = 8

        let stack = NSStackView(views: [left, right])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        updateControls()
        updatePages()
        showPreviewHint()
    }

    private func setStatus(_ text: String, busy: Bool) {
        status.stringValue = text
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private var unit: ICScannerFunctionalUnit? { ready ? scanner?.selectedFunctionalUnit : nil }

    private func available(_ type: ICScannerFunctionalUnitType) -> Bool {
        scanner?.availableFunctionalUnitTypes.contains { $0.uintValue == type.rawValue } ?? false
    }

    /// Fills the format / colour / resolution choices from what the selected unit supports.
    private func updateControls() {
        let fu = unit
        let enabled = fu != nil && !busy
        source.setEnabled(available(.flatbed), forSegment: 0)
        source.setEnabled(available(.documentFeeder), forSegment: 1)
        source.isEnabled = enabled
        if let fu { source.selectedSegment = fu.type == .documentFeeder ? 1 : 0 }
        let feeder = fu as? ICScannerFunctionalUnitDocumentFeeder
        duplex.isHidden = !(feeder?.supportsDuplexScanning ?? false)
        duplex.isEnabled = enabled

        let d = UserDefaults.standard
        let types = Self.documentTypes(of: fu)
        formatPopup.removeAllItems()
        if fu is ICScannerFunctionalUnitFlatbed {
            formatPopup.addItem(withTitle: "Вся область стекла")
            formatPopup.lastItem?.tag = Int(ICScannerDocumentType.typeDefault.rawValue)
        }
        for f in Self.formats where types.contains(Int(f.type.rawValue)) {
            formatPopup.addItem(withTitle: f.title)
            formatPopup.lastItem?.tag = Int(f.type.rawValue)
        }
        if formatPopup.numberOfItems == 0 { formatPopup.addItem(withTitle: "Как задано в сканере"); formatPopup.lastItem?.tag = -1 }
        let savedFormat = d.object(forKey: "scanFormat") as? Int ?? Int(ICScannerDocumentType.typeA4.rawValue)
        if formatPopup.indexOfItem(withTag: savedFormat) >= 0 { formatPopup.selectItem(withTag: savedFormat) }
        formatPopup.isEnabled = enabled

        colorPopup.item(at: Color.bw.rawValue)?.isHidden = !(fu?.supportedBitDepths.contains(1) ?? false)
        colorPopup.isEnabled = enabled

        resolutionPopup.removeAllItems()
        var dpis = Array(fu?.preferredResolutions ?? IndexSet())
        if dpis.isEmpty { dpis = Array(fu?.supportedResolutions ?? IndexSet()).filter { [150, 200, 300, 400, 600].contains($0) } }
        for r in dpis { resolutionPopup.addItem(withTitle: "\(r) dpi"); resolutionPopup.lastItem?.tag = r }
        let savedDPI = d.object(forKey: "scanDPI") as? Int ?? 300
        let best = dpis.min { abs($0 - savedDPI) < abs($1 - savedDPI) }
        if let best { resolutionPopup.selectItem(withTag: best) }
        resolutionPopup.isEnabled = enabled && !dpis.isEmpty

        skipBlank.isEnabled = !busy
        scanButton.title = scanning ? "Остановить" : "Сканировать"
        scanButton.isEnabled = scanning || (fu != nil && !previewing)
        scannerPopup.isEnabled = !busy
        previewButton.isEnabled = fu?.canPerformOverviewScan == true && !busy
        previewButton.isHidden = fu != nil && fu?.canPerformOverviewScan != true
        preview.area = previewArea()
        updateDefaultButton()
    }

    /// Return scans while there is nothing to insert, then inserts.
    private func updateDefaultButton() {
        let scanFirst = pages.isEmpty || scanning
        scanButton.keyEquivalent = scanFirst ? "\r" : ""
        insertButton.keyEquivalent = scanFirst ? "" : "\r"
    }

    private static func documentTypes(of fu: ICScannerFunctionalUnit?) -> IndexSet {
        switch fu {
        case let f as ICScannerFunctionalUnitFlatbed: f.supportedDocumentTypes
        case let f as ICScannerFunctionalUnitDocumentFeeder: f.supportedDocumentTypes
        default: IndexSet()
        }
    }

    private func updatePages() {
        countLabel.stringValue = pages.isEmpty
            ? "Отсканированные страницы появятся здесь"
            : "Отсканировано: \(pages.count) стр." + (skippedBlank > 0 ? ", пустых пропущено: \(skippedBlank)" : "")
        clearButton.isHidden = pages.isEmpty || scanning
        insertButton.title = pages.isEmpty ? "Вставить" : "Вставить \(pages.count) стр."
        insertButton.isEnabled = !pages.isEmpty && !scanning
        updateDefaultButton()
    }

    private func addThumbnail(_ page: ScannedPage) {
        let v = NSImageView(image: NSImage(cgImage: page.image, size: .zero))
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.separatorColor.cgColor
        let h: CGFloat = 112
        let w = h * CGFloat(page.image.width) / CGFloat(max(1, page.image.height))
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        thumbs.addArrangedSubview(v)
        thumbs.layoutSubtreeIfNeeded()
        if let scroll = thumbs.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: max(0, thumbs.frame.width - scroll.contentSize.width), y: 0))
        }
    }

    // MARK: - Actions

    @objc private func saveSettings() {
        let d = UserDefaults.standard
        d.set(source.selectedSegment, forKey: "scanSource")
        d.set(duplex.state == .on, forKey: "scanDuplex")
        d.set(colorPopup.selectedTag(), forKey: "scanColor")
        if formatPopup.selectedTag() >= 0 { d.set(formatPopup.selectedTag(), forKey: "scanFormat") }
        if resolutionPopup.selectedTag() > 0 { d.set(resolutionPopup.selectedTag(), forKey: "scanDPI") }
        d.set(skipBlank.state == .on, forKey: "scanSkipBlank")
        preview.area = previewArea()
    }

    @objc private func scannerChanged() {
        let i = scannerPopup.indexOfSelectedItem
        guard scanners.indices.contains(i), scanners[i] !== scanner else { return }
        select(scanners[i])
    }

    @objc private func sourceChanged() {
        saveSettings()
        let type: ICScannerFunctionalUnitType = source.selectedSegment == 1 ? .documentFeeder : .flatbed
        guard let scanner, ready, scanner.selectedFunctionalUnit.type != type, available(type) else { return }
        ready = false
        updateControls()
        setStatus("Переключаю подачу…", busy: true)
        scanner.requestSelect(type)
    }

    @objc private func clearPages() {
        pages = []
        skippedBlank = 0
        thumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updatePages()
    }

    @objc private func cancel(_ sender: Any?) {
        if scanning { scanner?.cancelScan() }
        close(sheet: window)
    }

    @objc private func insertPages() {
        guard !pages.isEmpty else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ":", with: ".")
        // Outside `downloads` (removed when the sheet closes); PDFKit may read the file lazily.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Скан \(stamp).pdf")
        guard ScannedPage.writePDF(pages, to: url) else {
            setStatus("Не удалось собрать PDF из отсканированных страниц", busy: false)
            return
        }
        let insert = self.insert
        close(sheet: window)
        insert(url)
    }

    private func close(sheet: NSWindow?) {
        guard let sheet else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
    }

    @objc private func scanOrStop() {
        retried = false
        startScan()
    }

    private func startScan() {
        if scanning {
            stopRequested = true
            scanner?.cancelScan()
            setStatus("Останавливаю…", busy: true)
            return
        }
        guard let scanner, let fu = unit else { return }
        saveSettings()
        configure(fu)
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = downloads
        scanner.documentName = "page-\(UUID().uuidString.prefix(8))"
        scanner.documentUTI = Color(rawValue: colorPopup.selectedTag()) == .bw ? "public.png" : "public.jpeg"
        if let feeder = fu as? ICScannerFunctionalUnitDocumentFeeder, !feeder.documentLoaded {
            setStatus("Податчик сообщает, что бумаги нет — всё равно пробую…", busy: true)
        } else {
            setStatus(fu.type == .documentFeeder ? "Сканирую все листы из податчика…" : "Сканирую…", busy: true)
        }
        batch = []
        stopRequested = false
        scanning = true
        updateControls()
        updatePages()
        log("scan: \(fu.type == .documentFeeder ? "feeder" : "flatbed"), \(fu.resolution) dpi, pixel \(fu.pixelDataType.rawValue), area \(fu.scanArea)")
        scanner.requestScan()
    }

    private func configure(_ fu: ICScannerFunctionalUnit) {
        let dpi = resolutionPopup.selectedTag()
        if dpi > 0 { fu.resolution = dpi }
        switch Color(rawValue: colorPopup.selectedTag()) ?? .gray {
        case .color: fu.pixelDataType = .RGB; fu.bitDepth = .depth8Bits
        case .gray: fu.pixelDataType = .gray; fu.bitDepth = .depth8Bits
        case .bw: fu.pixelDataType = .BW; fu.bitDepth = .depth1Bit
        }
        let tag = formatPopup.selectedTag()
        if let feeder = fu as? ICScannerFunctionalUnitDocumentFeeder {
            if tag > 0, let t = ICScannerDocumentType(rawValue: UInt(tag)) { feeder.documentType = t }
            if feeder.supportsDuplexScanning { feeder.duplexScanningEnabled = duplex.state == .on }
        } else if let flatbed = fu as? ICScannerFunctionalUnitFlatbed {
            if tag > 0, let t = ICScannerDocumentType(rawValue: UInt(tag)) {
                flatbed.documentType = t
                flatbed.scanArea = CGRect(origin: .zero, size: flatbed.documentSize)
            } else if tag == 0 {
                flatbed.scanArea = CGRect(origin: .zero, size: flatbed.physicalSize)
            }
        }
    }

    // MARK: - Device browser

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let s = device as? ICScannerDevice, !scanners.contains(where: { $0 === s }) else { return }
        scanners.append(s)
        scannerPopup.addItem(withTitle: s.name ?? "Сканер")
        if scanner == nil {
            let preferred = UserDefaults.standard.string(forKey: "scanDevice")
            if preferred == nil || s.name == preferred || !moreComing { select(s) }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let i = scanners.firstIndex(where: { $0 === device }) else { return }
        scanners.remove(at: i)
        scannerPopup.removeItem(at: i)
        if device === scanner {
            scanner = nil
            ready = false
            scanning = false
            setStatus("Сканер отключился", busy: false)
            updateControls()
        }
    }

    private func select(_ s: ICScannerDevice) {
        if let old = scanner, old !== s { old.delegate = nil; old.requestCloseSession() }
        scanner = s
        ready = false
        UserDefaults.standard.set(s.name, forKey: "scanDevice")
        if let i = scanners.firstIndex(where: { $0 === s }) { scannerPopup.selectItem(at: i) }
        updateControls()
        setStatus("Подключаюсь к «\(s.name ?? "сканер")»…", busy: true)
        s.delegate = self
        s.requestOpenSession()
    }

    // MARK: - Scanner device

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        log("session opened, error \(error.map(Self.describe) ?? "none")")
        if let error { setStatus("Не удалось подключиться: \(Self.describe(error))", busy: false) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        log("session closed, error \(error.map(Self.describe) ?? "none")")
    }

    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        log("device error \(error.map(Self.describe) ?? "none")")
        // Mid-scan errors end in didCompleteScan…, which retries; don't stop the spinner here.
        if let error, !busy { setStatus("Ошибка сканера: \(Self.describe(error))", busy: false) }
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {
        let key = status.first { $0.key.rawValue == "ICStatusNotificationKey" }?.value as? String ?? ""
        if key.contains("WarmingUp") { setStatus("Сканер прогревается…", busy: true) }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let s = scanner, device === s else { return }
        let want: ICScannerFunctionalUnitType = source.selectedSegment == 1 && available(.documentFeeder) ? .documentFeeder
            : available(.flatbed) ? .flatbed : .documentFeeder
        if s.selectedFunctionalUnit.type == want {
            unitReady()
        } else {
            setStatus("Выбираю подачу…", busy: true)
            s.requestSelect(want)
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        guard scanner === self.scanner else { return }
        if let error {
            setStatus("Не удалось выбрать подачу: \(error.localizedDescription)", busy: false)
        }
        unitReady()
    }

    private func unitReady() {
        ready = true
        updateControls()
        if let action = retryAfterReconnect {
            retryAfterReconnect = nil
            log("reconnected, repeating \(action)")
            action == .scan ? startScan() : startPreview()
            return
        }
        showPreviewHint()
        let fu = unit
        var text = "Готов. "
        if fu?.type == .documentFeeder {
            text += "Положите стопку в податчик — отсканируются все листы за раз."
        } else {
            text += "Положите лист на стекло. Можно сканировать несколько раз подряд — страницы копятся."
        }
        if available(.documentFeeder), fu?.type != .documentFeeder { text += " Есть автоподатчик — переключите «Подача»." }
        setStatus(text, busy: false)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        let dpi = CGFloat(unit?.resolution ?? 300)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let page = ScannedPage(url: url, dpi: dpi) else { return }
        if skipBlank.state == .on, page.isBlank {
            skippedBlank += 1
        } else {
            batch.append(page)
            addThumbnail(page)
            preview.show(page.image)
            previewCaption.stringValue = "Страница \(pages.count + batch.count)"
        }
        setStatus("Сканирую… страниц: \(pages.count + batch.count)", busy: true)
        countLabel.stringValue = "Отсканировано: \(pages.count + batch.count) стр."
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder
        if feeder?.reverseFeederPageOrder == true {
            batch.reverse()
            thumbs.arrangedSubviews.suffix(batch.count).forEach { $0.removeFromSuperview() }
            batch.forEach(addThumbnail)
        }
        pages += batch
        let got = batch.count
        batch = []
        scanning = false
        log("scan done: \(got) pages, error \(error.map(Self.describe) ?? "none")")
        if error != nil, !stopRequested, got == 0, reconnect(then: .scan) { return }
        updateControls()
        updatePages()
        if let error, !stopRequested, got == 0 {
            let empty = feeder != nil ? " Проверьте, что листы лежат в податчике." : ""
            setStatus("Сканирование не удалось: \(Self.describe(error)).\(empty) Подробности — в ~/Library/Logs/PageYard/scan.log", busy: false)
        } else {
            setStatus(got == 0 ? "Ничего не отсканировано" : "Готово: +\(got) стр. Можно отсканировать ещё или нажать «Вставить».", busy: false)
        }
    }

    // MARK: - Preview of the glass

    @objc private func previewGlass() {
        retried = false
        startPreview()
    }

    private func startPreview() {
        guard let scanner, let fu = unit, fu.canPerformOverviewScan, !busy else { return }
        saveSettings()
        configure(fu)
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = downloads
        previewing = true
        updateControls()
        preview.show(nil)
        previewCaption.stringValue = "Снимаю стекло…"
        setStatus("Просмотр стекла…", busy: true)
        log("overview scan")
        scanner.requestOverviewScan()
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
        previewing = false
        let image = unit?.overviewImage
        log("overview done: \(image.map { "\($0.width)x\($0.height)" } ?? "no image"), error \(error.map(Self.describe) ?? "none")")
        if image == nil, error != nil, reconnect(then: .preview) { return }
        updateControls()
        if let image {
            preview.show(image)
            preview.area = previewArea()
            previewCaption.stringValue = "Синяя рамка — то, что попадёт в скан (\(formatPopup.titleOfSelectedItem ?? ""))"
            setStatus("Если лист лежит криво или выходит за рамку — поправьте и нажмите «Просмотр стекла» ещё раз.", busy: false)
        } else {
            previewCaption.stringValue = ""
            setStatus("Просмотр не получился: \(error.map(Self.describe) ?? "сканер не прислал картинку")", busy: false)
        }
    }

    private func showPreviewHint() {
        guard preview.image == nil else { return }
        if let fu = unit {
            previewCaption.stringValue = fu.canPerformOverviewScan
                ? "Нажмите «Просмотр стекла», чтобы увидеть, как лежит лист"
                : "Здесь будет видна последняя отсканированная страница"
        } else {
            previewCaption.stringValue = ""
        }
    }

    /// The selected format as a fraction of the glass (top-left origin), for the frame on the preview.
    private func previewArea() -> CGRect? {
        guard let fu = unit as? ICScannerFunctionalUnitFlatbed, preview.image != nil, !scanning else { return nil }
        let glass = fu.physicalSize
        guard glass.width > 0, glass.height > 0 else { return nil }
        let toCM: CGFloat = switch fu.measurementUnit {
        case .inches: 2.54
        case .centimeters: 1
        case .points: 2.54 / 72
        case .picas: 2.54 / 6
        case .twips: 2.54 / 1440
        default: 0
        }
        guard toCM > 0 else { return nil }
        let sizes: [Int: CGSize] = [
            Int(ICScannerDocumentType.typeA4.rawValue): CGSize(width: 21, height: 29.7),
            Int(ICScannerDocumentType.typeUSLetter.rawValue): CGSize(width: 21.59, height: 27.94),
            Int(ICScannerDocumentType.typeUSLegal.rawValue): CGSize(width: 21.59, height: 35.56),
            Int(ICScannerDocumentType.typeA5.rawValue): CGSize(width: 14.8, height: 21),
            Int(ICScannerDocumentType.typeA3.rawValue): CGSize(width: 29.7, height: 42),
        ]
        guard let cm = sizes[formatPopup.selectedTag()] else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: 0, y: 0, width: min(1, cm.width / (glass.width * toCM)), height: min(1, cm.height / (glass.height * toCM)))
    }

    // MARK: - Recovery and log

    /// Network scanners drop idle sessions (sleep, another app): reopen it once and repeat.
    private func reconnect(then action: Action) -> Bool {
        guard !retried, let s = scanner else { return false }
        retried = true
        retryAfterReconnect = action
        ready = false
        updateControls()
        setStatus("Сканер не ответил — переподключаюсь и пробую ещё раз…", busy: true)
        log("reconnecting")
        s.requestCloseSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak s] in
            guard let self, let s, s === self.scanner else { return }
            s.requestOpenSession()
        }
        return true
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.localizedDescription) (\(e.domain) \(e.code))"
    }

    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PageYard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan.log")
    }()

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(scanner?.name ?? "-")] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    // MARK: - Diagnostics

    /// What the sheet shows now (for PAGEYARD_SCANTEST).
    var debugState: String {
        "scanner «\(scanner?.name ?? "-")», ready \(ready), source \(source.selectedSegment) (flatbed \(available(.flatbed)), feeder \(available(.documentFeeder))), "
            + "formats \(formatPopup.itemTitles), colors \(colorPopup.itemArray.filter { !$0.isHidden }.map(\.title)), dpi \(resolutionPopup.itemTitles), "
            + "status «\(status.stringValue)»"
    }

    var isReady: Bool { ready }

    /// Pretends the scanner delivered `files` (one scan pass).
    func debugDeliver(_ files: [URL]) {
        if let fu = unit { configure(fu) }
        batch = []
        scanning = true
        for f in files { scannerDevice(scanner ?? ICScannerDevice(), didScanTo: f) }
        scannerDevice(scanner ?? ICScannerDevice(), didCompleteScanWithError: nil)
    }

    func debugInsert() { insertPages() }

    func debugScan() { scanOrStop() }
    func debugPreview() { previewGlass() }
    var isBusy: Bool { busy || retryAfterReconnect != nil }
    /// A scan that "failed" with nothing delivered: must reconnect and scan again.
    func debugFail() {
        retried = false
        scanning = true
        scannerDevice(scanner ?? ICScannerDevice(), didCompleteScanWithError: NSError(domain: "com.apple.ImageCaptureCore", code: -9923, userInfo: [NSLocalizedDescriptionKey: "Failed"]))
    }
    var isScanning: Bool { scanning }

    static func controller(for parent: NSWindow) -> ScanWindowController? { open[ObjectIdentifier(parent)] }

    // MARK: - Teardown

    private func shutDown() {
        browser.stop()
        browser.delegate = nil
        scanner?.delegate = nil
        scanner?.requestCloseSession()
        scanner = nil
        try? FileManager.default.removeItem(at: downloads)
    }
}

/// A scanned sheet: the image and its physical size.
struct ScannedPage {
    let image: CGImage
    /// Page size in points (from the scan resolution).
    let size: CGSize
    /// The file as delivered: JPEG is embedded into the PDF without re-encoding.
    let data: Data

    init?(url: URL, dpi: CGFloat) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(image: image, data: data, dpi: dpi)
    }

    init(image: CGImage, data: Data, dpi: CGFloat) {
        self.image = image
        self.data = data
        let scale = 72 / max(dpi, 1)
        size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    /// Almost no ink away from the edges (scanner shadows at the borders don't count).
    var isBlank: Bool {
        let w = 120, h = max(1, Int(120 * CGFloat(image.height) / CGFloat(max(1, image.width))))
        var px = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let mx = w / 12, my = h / 12
        var paper = [Int](repeating: 0, count: 256)
        for y in my..<(h - my) { for x in mx..<(w - mx) { paper[Int(px[y * w + x])] += 1 } }
        // Paper level: the brightest common value; ink is clearly darker than it.
        let total = paper.reduce(0, +)
        var acc = 0, level = 255
        for v in stride(from: 255, through: 0, by: -1) {
            acc += paper[v]
            if acc > total / 2 { level = v; break }
        }
        let ink = paper[0..<max(0, level - 60)].reduce(0, +)
        return Double(ink) / Double(max(1, total)) < 0.002
    }

    static func writePDF(_ pages: [ScannedPage], to url: URL) -> Bool {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator as String: "PageYard"] as CFDictionary) else { return false }
        for p in pages {
            var box = CGRect(origin: .zero, size: p.size)
            ctx.beginPage(mediaBox: &box)
            // Re-read from the original bytes so JPEG data passes through untouched.
            let image = CGImageSourceCreateWithData(p.data as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } ?? p.image
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return true
    }
}

/// The glass overview or the last scanned page, with the scan-area frame.
final class ScanPreviewView: NSView {
    private(set) var image: CGImage?
    /// Fraction of the image, top-left origin.
    var area: CGRect? { didSet { needsDisplay = true } }

    func show(_ image: CGImage?) {
        self.image = image
        if image == nil { area = nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else {
            let text = "Предпросмотр" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            return
        }
        let inner = bounds.insetBy(dx: 8, dy: 8)
        let scale = min(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let r = CGRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: r).stroke()
        if let a = area {
            let f = CGRect(x: r.minX + a.minX * w, y: r.maxY - (a.minY + a.height) * h, width: a.width * w, height: a.height * h)
            let path = NSBezierPath(rect: f.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([6, 3], count: 2, phase: 0)
            NSColor.systemBlue.setStroke()
            path.stroke()
        }
    }
}
