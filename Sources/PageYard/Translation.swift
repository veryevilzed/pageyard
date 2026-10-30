import AppKit
import PDFKit
import Security

// MARK: - Settings

enum TranslationProvider: String, CaseIterable {
    case claude, openai

    var title: String { self == .claude ? "Claude (Anthropic)" : "OpenAI" }
}

/// Provider choice, models and languages in UserDefaults; API keys in the Keychain.
enum TranslationSettings {
    static let defaultClaudeModel = "claude-opus-5-5"

    static var provider: TranslationProvider {
        get { TranslationProvider(rawValue: UserDefaults.standard.string(forKey: "trProvider") ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trProvider") }
    }

    static var claudeModel: String {
        get { UserDefaults.standard.string(forKey: "trClaudeModel").flatMap { $0.isEmpty ? nil : $0 } ?? defaultClaudeModel }
        set { UserDefaults.standard.set(newValue, forKey: "trClaudeModel") }
    }

    /// No default: OpenAI model names change often, the user picks from the
    /// list their key can see (Settings → "Load models").
    static var openAIModel: String {
        get { UserDefaults.standard.string(forKey: "trOpenAIModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "trOpenAIModel") }
    }

    static var sourceLanguage: String {
        get { UserDefaults.standard.string(forKey: "trSource") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "trSource") }
    }

    static var targetLanguage: String {
        get { UserDefaults.standard.string(forKey: "trTarget") ?? "Russian" }
        set { UserDefaults.standard.set(newValue, forKey: "trTarget") }
    }

    static func apiKey(_ p: TranslationProvider) -> String? {
        // PAGEYARD_CLAUDE_KEY / PAGEYARD_OPENAI_KEY: for test runs, never stored.
        if let k = ProcessInfo.processInfo.environment["PAGEYARD_\(p.rawValue.uppercased())_KEY"], !k.isEmpty { return k }
        return Keychain.read(account: p.rawValue)
    }
    static func setAPIKey(_ key: String, for p: TranslationProvider) {
        if key.isEmpty { Keychain.delete(account: p.rawValue) } else { Keychain.write(key, account: p.rawValue) }
    }

    /// Languages offered in the UI: English name (sent to the model) and Russian label.
    static let languages: [(id: String, title: String)] = [
        ("Russian", "Русский"), ("English", "Английский"), ("German", "Немецкий"), ("French", "Французский"),
        ("Spanish", "Испанский"), ("Italian", "Итальянский"), ("Portuguese", "Португальский"), ("Ukrainian", "Украинский"),
        ("Belarusian", "Белорусский"), ("Polish", "Польский"), ("Czech", "Чешский"), ("Dutch", "Нидерландский"),
        ("Turkish", "Турецкий"), ("Kazakh", "Казахский"), ("Georgian", "Грузинский"), ("Armenian", "Армянский"),
        ("Hebrew", "Иврит"), ("Arabic", "Арабский"), ("Chinese (Simplified)", "Китайский"), ("Japanese", "Японский"),
        ("Korean", "Корейский"),
    ]
}

enum Keychain {
    private static let service = "com.zed.pageyard.translation"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// MARK: - Service

struct TranslationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Translates a batch of text blocks, keeping order. One request per batch.
enum TranslationService {
    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "translations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["id": ["type": "integer"], "text": ["type": "string"]],
                    "required": ["id", "text"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["translations"],
        "additionalProperties": false,
    ]

    private static func instructions(from: String, to: String) -> String {
        let source = from == "auto" ? "the language it is written in (detect it)" : from
        return """
        You are a professional translator of documents. Translate the text of every item from \(source) into \(to).
        The items are paragraphs, table cells and lines taken from one PDF page, in reading order; use them as context for each other.
        Keep numbers, dates, amounts, names, codes and e-mail addresses exactly as written. Keep the meaning and tone; don't add notes.
        If an item is already in \(to) or has nothing to translate, return it unchanged.
        Return one entry per item with the same id.
        """
    }

    static func translate(_ texts: [String], from: String, to: String) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let provider = TranslationSettings.provider
        guard let key = TranslationSettings.apiKey(provider), !key.isEmpty else {
            throw TranslationError(message: "Не задан ключ \(provider.title). Укажите его в Настройках (⌘,).")
        }
        let items = texts.enumerated().map { ["id": $0.offset, "text": $0.element] as [String: Any] }
        let payload = String(data: try JSONSerialization.data(withJSONObject: ["items": items]), encoding: .utf8) ?? "{}"
        let json: String
        switch provider {
        case .claude: json = try await claude(key: key, system: instructions(from: from, to: to), user: payload)
        case .openai: json = try await openAI(key: key, system: instructions(from: from, to: to), user: payload)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let list = obj["translations"] as? [[String: Any]] else {
            throw TranslationError(message: "Сервис вернул ответ не в том формате")
        }
        var result = texts
        for entry in list {
            if let id = entry["id"] as? Int, let text = entry["text"] as? String, result.indices.contains(id) {
                result[id] = text
            }
        }
        return result
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw TranslationError(message: "Ошибка \(status): \(msg)")
        }
        return obj
    }

    /// Anthropic Messages API: structured output, low effort, server-side
    /// fallback when a request is declined.
    private static func claude(key: String, system: String, user: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": TranslationSettings.claudeModel,
            "max_tokens": 16000,
            "fallbacks": "default",
            "system": system,
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let obj = try await send(req)
        if obj["stop_reason"] as? String == "refusal" {
            throw TranslationError(message: "Модель отказалась переводить этот текст")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw TranslationError(message: "Пустой ответ от Claude")
        }
        return text
    }

    /// OpenAI Chat Completions with a strict JSON schema.
    private static func openAI(key: String, system: String, user: String) async throws -> String {
        let model = TranslationSettings.openAIModel
        guard !model.isEmpty else {
            throw TranslationError(message: "Не выбрана модель OpenAI. В Настройках (⌘,) нажмите «Загрузить модели».")
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "translations", "strict": true, "schema": schema]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let obj = try await send(req)
        let message = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw TranslationError(message: "Модель отказалась переводить: \(refusal)")
        }
        guard let text = message["content"] as? String else { throw TranslationError(message: "Пустой ответ от OpenAI") }
        return text
    }

    /// Model ids the key can use (for the Settings picker).
    static func availableModels(_ provider: TranslationProvider, key: String) async throws -> [String] {
        var req: URLRequest
        switch provider {
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 30)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .claude:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!, timeoutInterval: 30)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        }
        let obj = try await send(req)
        let data = obj["data"] as? [[String: Any]] ?? []
        let sorted = data.sorted {
            let a = ($0["created"] as? Double) ?? 0, b = ($1["created"] as? Double) ?? 0
            return a > b
        }
        let ids = sorted.compactMap { $0["id"] as? String }
        // Chat models only for OpenAI (skip embeddings, audio, images, moderation…).
        guard provider == .openai else { return ids }
        return ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o") || id.contains("chat"))
                && !["embedding", "audio", "realtime", "tts", "transcribe", "image", "search", "moderation", "whisper", "dall"]
                .contains(where: id.contains)
        }
    }
}

// MARK: - Page text blocks

/// A paragraph / cell of page text and its translation, drawn over the original.
final class TranslatedBlock {
    let rect: CGRect
    let source: String
    let sourceFontSize: CGFloat
    var text: String?
    var background: NSColor = .white
    /// Largest font size (≤ the original) at which the translation fits the rect.
    var fittedSize: CGFloat = 10
    /// Height the text needs at `fittedSize`; more than the rect when even the
    /// smallest readable size doesn't fit (the card then grows downward).
    var fittedHeight: CGFloat = 0

    /// Smallest size still worth shrinking to; below it the card grows instead.
    static let minimumSize: CGFloat = 5

    init(rect: CGRect, source: String, fontSize: CGFloat) {
        self.rect = rect
        self.source = source
        sourceFontSize = fontSize
    }

    static func font(_ size: CGFloat) -> NSFont { .defaultFill(size) }

    private func textHeight(_ size: CGFloat) -> CGFloat {
        guard let text else { return 0 }
        return ceil((text as NSString).boundingRect(with: CGSize(width: max(4, rect.width), height: 100_000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: [.font: Self.font(size)]).height)
    }

    func fit() {
        var size = max(Self.minimumSize, sourceFontSize)
        while size > Self.minimumSize, textHeight(size) > rect.height {
            size -= 0.25
        }
        fittedSize = max(Self.minimumSize, size)
        fittedHeight = max(rect.height, textHeight(fittedSize))
    }

    /// Where the text is drawn: the original area, extended down if needed.
    var textRect: CGRect {
        CGRect(x: rect.minX, y: rect.maxY - fittedHeight, width: rect.width, height: fittedHeight)
    }

    /// White card with the full translation; the page around it is dimmed by the overlay.
    func draw() {
        guard let text else { return }
        let card = textRect.insetBy(dx: -3, dy: -2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: card, xRadius: 2.5, yRadius: 2.5).fill()
        NSGraphicsContext.restoreGraphicsState()
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: [.font: Self.font(fittedSize), .foregroundColor: NSColor.black])
    }
}

enum PageTextBlocks {
    private struct Line {
        let rect: CGRect
        let text: String
        let fontSize: CGFloat
    }

    /// Lines of text (PDFKit's line selections), each split where the gap
    /// between characters is wide: table columns, form labels side by side.
    private static func lines(on page: PDFPage, in area: CGRect) -> [Line] {
        guard let sel = page.selection(for: area) else { return [] }
        var result: [Line] = []

        func add(_ text: String, _ rect: CGRect) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !rect.isNull, rect.width > 1, rect.height > 1 else { return }
            var size = rect.height * 0.75
            if let part = page.selection(for: rect), let attr = part.attributedString, attr.length > 0,
               let f = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
               f.pointSize > rect.height * 0.4, f.pointSize < rect.height * 1.6 {
                size = f.pointSize
            }
            result.append(Line(rect: rect, text: t, fontSize: size))
        }

        for line in sel.selectionsByLine() {
            let text = line.string ?? ""
            let r = line.bounds(for: page)
            guard text.contains(" "), r.width > r.height * 4 else { add(text, r); continue }
            // Probe the line with thin vertical slices; several empty slices in a
            // row mean a column gap. Uses PDFKit's own geometry for the text.
            let step = max(1.5, r.height * 0.4)
            var occupied: [Bool] = []
            var x = r.minX
            while x < r.maxX {
                let slice = CGRect(x: x, y: r.minY + r.height * 0.25, width: step, height: r.height * 0.5)
                occupied.append(!(page.selection(for: slice)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                x += step
            }
            let minGap = Int(ceil(r.height * 1.2 / step))
            var segments: [ClosedRange<Int>] = []
            var start: Int?
            var empty = 0
            for (k, on) in occupied.enumerated() {
                if on {
                    if start == nil { start = k }
                    empty = 0
                } else if let s0 = start {
                    empty += 1
                    if empty >= minGap {
                        segments.append(s0...(k - empty))
                        start = nil
                        empty = 0
                    }
                }
            }
            if let s0 = start { segments.append(s0...(occupied.count - 1 - empty)) }
            guard segments.count > 1 else { add(text, r); continue }
            for seg in segments {
                let segRect = CGRect(x: r.minX + CGFloat(seg.lowerBound) * step, y: r.minY,
                                     width: CGFloat(seg.count) * step, height: r.height)
                if let part = page.selection(for: segRect) {
                    add(part.string ?? "", part.bounds(for: page))
                }
            }
        }
        return result
    }

    /// Text inside `area` (whole page when nil) grouped into paragraphs:
    /// close vertical spacing, same column, similar size.
    static func blocks(on page: PDFPage, in area: CGRect? = nil) -> [TranslatedBlock] {
        var lines = lines(on: page, in: area ?? page.bounds(for: .cropBox))
        // Reading order: top to bottom, then left to right.
        lines.sort { abs($0.rect.maxY - $1.rect.maxY) > 2 ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX }

        var groups: [[Line]] = []
        for line in lines {
            if var g = groups.last, let prev = g.last {
                let gap = prev.rect.minY - line.rect.maxY
                let lineH = max(prev.rect.height, line.rect.height)
                let sameColumn = abs(prev.rect.minX - line.rect.minX) < lineH * 2.5
                    || (line.rect.minX >= g.map(\.rect.minX).min()! - 2 && line.rect.maxX <= g.map(\.rect.maxX).max()! + 2)
                let similarSize = abs(prev.fontSize - line.fontSize) <= max(1, prev.fontSize * 0.2)
                if gap > -lineH * 0.3, gap < lineH * 0.8, sameColumn, similarSize, g.count < 40 {
                    g.append(line)
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append([line])
        }
        return groups.map { g in
            let rect = g.dropFirst().reduce(g[0].rect) { $0.union($1.rect) }
            // Join lines; a word hyphenated across a line break is glued back.
            var text = ""
            for line in g {
                if text.hasSuffix("-"), text.dropLast().last?.isLetter == true, line.text.first?.isLowercase == true {
                    text.removeLast()
                } else if !text.isEmpty {
                    text += " "
                }
                text += line.text
            }
            let sizes = g.map(\.fontSize).sorted()
            return TranslatedBlock(rect: rect, source: text, fontSize: sizes[sizes.count / 2])
        }
    }
}
