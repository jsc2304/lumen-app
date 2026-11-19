import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

// Lumen: a native launcher in the spirit of Raycast. ⌘Space / ⌥Space opens a search panel for apps,
// files, system and window commands, a calculator, clipboard history and AI.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    #if canImport(Sparkle)
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    #endif

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = editMenu()
        _ = AX.promptIfNeeded()
        HotKeys.registerMain { PanelController.shared.toggle() }
        Root.registerHotkeys()
        Clipboard.shared.start()
        Snippets.shared.start()
        Mite.prefetch()
        Focus.start()
        AppTools.start()
        _ = Apps.items()
        FileSearch.shared.onUpdate = { Launcher.shared.reload() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Lumen")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Lumen", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        #if canImport(Sparkle)
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                     keyEquivalent: "").target = updater
        #else
        menu.addItem(withTitle: "Check for Updates…", action: #selector(unconfiguredUpdater),
                     keyEquivalent: "").target = self
        #endif
        menu.addItem(.separator())
        let hotkeys = menu.addItem(withTitle: "Hotkeys: " + HotKeys.status, action: nil, keyEquivalent: "")
        hotkeys.isEnabled = false
        NotificationCenter.default.addObserver(forName: .init("LumenHotkeysChanged"), object: nil, queue: .main) { _ in
            hotkeys.title = "Hotkeys: " + HotKeys.status
        }
        menu.addItem(withTitle: "Quit Lumen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        if CommandLine.arguments.contains("--settings") { Settings.show() }
    }

    // Opening Lumen.app again (Finder, Dock, `open`) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelController.shared.show()
        return false
    }

    @objc private func open() { PanelController.shared.show() }
    @objc private func settings() { Settings.show() }

    @objc private func unconfiguredUpdater() {
        let alert = NSAlert()
        alert.messageText = "Updates are unavailable for this build"
        alert.informativeText = "This source build has no update channel. To update it, rebuild from newer source."
        NSApp.activate()
        alert.runModal()
    }

    /// Without a main menu, ⌘C/⌘V/⌘A do nothing in text fields of an accessory app, and ⌘W closes no window.
    private func editMenu() -> NSMenu {
        let main = NSMenu(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        return main
    }
}

// `Lumen --search <query> [--actions]` prints the ranked results (and their ⌘K actions) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
    Launcher.shared.query = CommandLine.arguments[i + 1]
    Launcher.shared.refresh()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))   // background work: app scan, file search, currency rates
    Launcher.shared.refresh()
    for item in Launcher.shared.items {
        print(item.kind.padding(toLength: 12, withPad: " ", startingAt: 0), item.title, item.subtitle)
        if CommandLine.arguments.contains("--actions") {
            print("             ⌘K:", item.actions.map { $0.title + ($0.shortcut.map { " " + $0.label } ?? "") }.joined(separator: " · "))
        }
    }
    exit(0)
}

// `Lumen --commands` lists every root command (id, kind, title) and exits.
if CommandLine.arguments.contains("--commands") {
    for item in Features.commands() { print(item.id, "|", item.kind, "|", item.title) }
    exit(0)
}

// `Lumen --ask <question>` streams the configured AI's answer to stdout, to check the AI setup.
if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
    Task { @MainActor in
        do {
            try await AI.stream(system: "Be brief.", prompt: CommandLine.arguments[i + 1]) { print($0, terminator: ""); fflush(stdout) }
            print()
            exit(0)
        } catch {
            print("error:", error.localizedDescription)
            exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
