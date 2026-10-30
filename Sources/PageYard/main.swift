import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugSnapshot.scheduleIfRequested()
        ScreenshotTour.scheduleIfRequested()
        ZoomTest.scheduleIfRequested()
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty, ProcessInfo.processInfo.environment["PAGEYARD_SCREENSHOTS"] == nil,
               ProcessInfo.processInfo.environment["PAGEYARD_ZOOMTEST"] == nil {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }

        let name = "PageYard"
        _ = submenu(name, [
            item("О программе \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Скрыть \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Скрыть остальные", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Показать все", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Завершить \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let exportMenu = NSMenu(title: "Экспорт")
        exportMenu.addItem(item("Текущая страница как изображение…", #selector(EditorWindowController.exportCurrentPageImage(_:)), "e", [.command, .shift]))
        exportMenu.addItem(item("Страницы как изображения…", #selector(EditorWindowController.exportPageImages(_:)), "e", [.command, .shift, .option]))
        let exportItem = NSMenuItem(title: "Экспорт", action: nil, keyEquivalent: "")
        exportItem.submenu = exportMenu

        let recent = NSMenu(title: "Открыть недавние")
        recent.addItem(item("Очистить меню", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "Открыть недавние", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        _ = submenu("Файл", [
            item("Новый пустой PDF", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Открыть…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Закрыть", #selector(NSWindow.performClose(_:)), "w"),
            item("Сохранить", #selector(NSDocument.save(_:)), "s"),
            item("Сохранить как…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Вернуть к сохранённому", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Вставить страницы из файла…", #selector(EditorWindowController.insertPagesFromFile(_:)), "i", [.command, .shift]),
            item("Вставить пустую страницу", #selector(EditorWindowController.insertBlankPage(_:))),
            {
                let i = NSMenuItem(title: "Импорт с iPhone или iPad", action: nil, keyEquivalent: "")
                i.identifier = NSMenuItem.importFromDeviceIdentifier
                return i
            }(),
            exportItem,
            .separator(),
            item("Печать…", #selector(NSDocument.printDocument(_:)), "p"),
        ])

        _ = submenu("Правка", [
            item("Отменить", Selector(("undo:")), "z"),
            item("Повторить", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Вырезать", #selector(NSText.cut(_:)), "x"),
            item("Копировать", #selector(NSText.copy(_:)), "c"),
            item("Вставить", #selector(NSText.paste(_:)), "v"),
            item("Выбрать всё", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Удалить объект  ⌫", #selector(EditorWindowController.deleteSelection(_:))),
        ])

        var toolItems = EditorMode.allCases.map {
            item($0.title, #selector(EditorWindowController.selectModeFromMenu(_:)), "\($0.rawValue + 1)", tag: $0.rawValue)
        }
        toolItems.append(.separator())
        toolItems += Tool.allCases.map {
            item("\($0.title)   \($0.keyLabel)", #selector(EditorWindowController.selectToolFromMenu(_:)), tag: $0.rawValue)
        }
        toolItems += [
            .separator(),
            item("Новая подпись…", #selector(EditorWindowController.newSignature(_:))),
            item("Подсветить места для заполнения", #selector(EditorWindowController.toggleHints(_:)), "f", [.command, .shift]),
        ]
        _ = submenu("Режим", toolItems)

        _ = submenu("Вид", [
            item("Увеличить", #selector(EditorWindowController.zoomInAction(_:)), "="),
            item("Уменьшить", #selector(EditorWindowController.zoomOutAction(_:)), "-"),
            item("Реальный размер", #selector(EditorWindowController.actualSizeAction(_:)), "0"),
            item("По размеру окна", #selector(EditorWindowController.fitAction(_:)), "9"),
            .separator(),
            item("Панель страниц", #selector(EditorWindowController.toggleThumbnails(_:)), "s", [.command, .option]),
            item("Показывать пометки маркером", #selector(EditorWindowController.toggleMarks(_:)), "m", [.command, .shift]),
        ])

        let window = submenu("Окно", [
            item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Изменить масштаб", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }
}

let app = NSApplication.shared
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--detect" {
    for path in CommandLine.arguments.dropFirst(2) {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { print("cannot open \(path)"); continue }
        let counts = (0..<doc.pageCount).compactMap(doc.page(at:)).map { FieldDetector.detect($0).count }
        print("\((path as NSString).lastPathComponent): \(doc.pageCount) pages, fields per page \(counts)")
    }
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest" {
    SelfTest.run(outputDirectory: CommandLine.arguments[2])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
