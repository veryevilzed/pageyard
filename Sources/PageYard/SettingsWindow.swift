import AppKit

/// Settings (⌘,): translation provider, API keys (Keychain) and models.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let provider = NSSegmentedControl(labels: TranslationProvider.allCases.map(\.title), trackingMode: .selectOne,
                                              target: nil, action: nil)
    private let claudeKey = NSSecureTextField()
    private let openAIKey = NSSecureTextField()
    private let claudeModel = NSComboBox()
    private let openAIModel = NSComboBox()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Настройки PageYard — перевод"
        super.init(window: window)
        window.delegate = self
        build()
        load()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        load()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func build() {
        provider.target = self
        provider.action = #selector(providerChanged)
        for f in [claudeKey, openAIKey] {
            f.placeholderString = "вставьте ключ API"
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        claudeKey.placeholderString = "sk-ant-…"
        openAIKey.placeholderString = "sk-…"
        claudeModel.addItem(withObjectValue: TranslationSettings.defaultClaudeModel)
        for c in [claudeModel, openAIModel] {
            c.widthAnchor.constraint(equalToConstant: 300).isActive = true
            c.isAutomaticTextCompletionEnabled = false
        }
        openAIModel.placeholderString = "нажмите «Загрузить модели»"
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 500
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let grid = NSGridView(views: [
            [label("Сервис перевода:"), provider, NSGridCell.emptyContentView],
            [label("Ключ Claude:"), claudeKey, NSGridCell.emptyContentView],
            [label("Модель Claude:"), claudeModel, button("Загрузить модели", #selector(loadClaudeModels))],
            [label("Ключ OpenAI:"), openAIKey, NSGridCell.emptyContentView],
            [label("Модель OpenAI:"), openAIModel, button("Загрузить модели", #selector(loadOpenAIModels))],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let note = NSTextField(wrappingLabelWithString:
            "Ключи хранятся в связке ключей macOS. Текст страницы отправляется выбранному сервису только при переводе; оплата — по вашему ключу.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 500

        let howToTitle = NSTextField(labelWithString: "Где взять ключ")
        howToTitle.font = .boldSystemFont(ofSize: 13)
        let guide = NSStackView(views: [
            Self.instructions("Claude (Anthropic)", [
                "Откройте консоль Anthropic и войдите (или зарегистрируйтесь).",
                "Пополните баланс: Settings → Billing → Add credits (без баланса запросы не проходят).",
                "Settings → API keys → Create Key, дайте ключу любое имя и скопируйте его — он показывается один раз.",
                "Вставьте ключ в поле «Ключ Claude» выше.",
            ], links: [("Страница ключей", "https://platform.claude.com/settings/keys"),
                       ("Баланс", "https://platform.claude.com/settings/billing")], target: self),
            Self.instructions("OpenAI", [
                "Откройте платформу OpenAI и войдите (аккаунт ChatGPT подходит, но баланс у API отдельный).",
                "Пополните баланс: Settings → Billing → Add payment details / Add to credit balance.",
                "API keys → Create new secret key, скопируйте ключ — он показывается один раз.",
                "Вставьте ключ в поле «Ключ OpenAI», затем нажмите «Загрузить модели» и выберите модель.",
            ], links: [("Страница ключей", "https://platform.openai.com/api-keys"),
                       ("Баланс", "https://platform.openai.com/settings/organization/billing/overview")], target: self),
        ])
        guide.orientation = .vertical
        guide.alignment = .leading
        guide.spacing = 12
        let howTo = NSStackView(views: [howToTitle, guide])
        howTo.orientation = .vertical
        howTo.alignment = .leading
        howTo.spacing = 8

        let test = button("Проверить перевод", #selector(testTranslation))
        let bottom = NSStackView(views: [test, spinner, status])
        bottom.spacing = 10
        bottom.alignment = .centerY

        let stack = NSStackView(views: [grid, note, howTo, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = NSView()
        window?.contentView?.addSubview(stack)
        if let root = window?.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                stack.topAnchor.constraint(equalTo: root.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            ])
        }
    }

    private func load() {
        provider.selectedSegment = TranslationProvider.allCases.firstIndex(of: TranslationSettings.provider) ?? 0
        claudeKey.stringValue = TranslationSettings.apiKey(.claude) ?? ""
        openAIKey.stringValue = TranslationSettings.apiKey(.openai) ?? ""
        claudeModel.stringValue = TranslationSettings.claudeModel
        openAIModel.stringValue = TranslationSettings.openAIModel
        status.stringValue = ""
    }

    private func save() {
        TranslationSettings.provider = TranslationProvider.allCases[max(0, provider.selectedSegment)]
        TranslationSettings.setAPIKey(claudeKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .claude)
        TranslationSettings.setAPIKey(openAIKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .openai)
        TranslationSettings.claudeModel = claudeModel.stringValue.trimmingCharacters(in: .whitespaces)
        TranslationSettings.openAIModel = openAIModel.stringValue.trimmingCharacters(in: .whitespaces)
    }

    func windowWillClose(_ notification: Notification) { save() }

    @objc private func providerChanged() { save() }

    /// Numbered steps with buttons that open the provider's pages.
    private static func instructions(_ title: String, _ steps: [String], links: [(String, String)], target: AnyObject) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .boldSystemFont(ofSize: 12)
        var views: [NSView] = [header]
        for (i, step) in steps.enumerated() {
            let l = NSTextField(wrappingLabelWithString: "\(i + 1). \(step)")
            l.font = .systemFont(ofSize: 11.5)
            l.preferredMaxLayoutWidth = 520
            views.append(l)
        }
        let buttons = links.map { title, url -> NSButton in
            let b = NSButton(title: title + " ↗", target: target, action: #selector(openLink(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.toolTip = url
            b.identifier = NSUserInterfaceItemIdentifier(url)
            return b
        }
        views.append(NSStackView(views: buttons))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    @objc private func openLink(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue, let url = URL(string: id) { NSWorkspace.shared.open(url) }
    }

    @objc private func loadClaudeModels() { loadModels(.claude, into: claudeModel) }
    @objc private func loadOpenAIModels() { loadModels(.openai, into: openAIModel) }

    private func loadModels(_ p: TranslationProvider, into box: NSComboBox) {
        save()
        guard let key = TranslationSettings.apiKey(p) else { status.stringValue = "Сначала вставьте ключ"; return }
        spinner.startAnimation(nil)
        status.stringValue = "Загружаю список моделей…"
        Task { @MainActor in
            defer { self.spinner.stopAnimation(nil) }
            do {
                let ids = try await TranslationService.availableModels(p, key: key)
                box.removeAllItems()
                box.addItems(withObjectValues: ids)
                if box.stringValue.isEmpty || !ids.contains(box.stringValue), let first = ids.first {
                    box.stringValue = p == .claude && ids.contains(TranslationSettings.defaultClaudeModel)
                        ? TranslationSettings.defaultClaudeModel : first
                }
                self.save()
                self.status.stringValue = "Моделей: \(ids.count). Выбрана: \(box.stringValue)"
            } catch {
                self.status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func testTranslation() {
        save()
        spinner.startAnimation(nil)
        status.stringValue = "Перевожу «Hello, world!»…"
        Task { @MainActor in
            defer { self.spinner.stopAnimation(nil) }
            do {
                let out = try await TranslationService.translate(["Hello, world!"], from: "auto", to: TranslationSettings.targetLanguage)
                self.status.stringValue = "Работает: «\(out.first ?? "")»"
            } catch {
                self.status.stringValue = error.localizedDescription
            }
        }
    }
}
