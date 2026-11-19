import AppKit

/// Switch Windows and Search Menu Bar Items. Both read the Accessibility tree once when the command
/// opens (in the background, the list says "Loading…" meanwhile) and filter that snapshot while the user types.
enum Navigation {
    private struct Win {
        let id: String
        let app: NSRunningApplication
        let element: AXUIElement
        let title: String
        let minimized: Bool
    }

    private struct MenuEntry {
        let element: AXUIElement
        let title: String
        let path: String
        let shortcut: String
    }

    static func commands() -> [Item] {
        [
            .command("nav.switch-windows", "Switch Windows", kind: "Window", icon: "macwindow.on.rectangle",
                     keywords: ["window", "windows", "fenster", "app", "wechseln"], closes: false) {
                let apps = windowApps()   // read first: the panel never activates Lumen
                pushGathered("Switch Windows", "Search windows…", gather: { windows(of: apps) }, items: windowItems)
            },
            .command("nav.menu-items", "Search Menu Bar Items", kind: "Menu", icon: "menubar.rectangle",
                     keywords: ["menu", "menü", "command", "befehl", "menubar"], closes: false) {
                let app = NSWorkspace.shared.frontmostApplication   // read first: the panel never activates Lumen
                pushGathered((app?.localizedName ?? "App") + " Menus", "Search menu bar items…",
                             gather: { menuEntries(of: app) }, items: menuItems)
            },
        ]
    }

    // MARK: Pure logic

    /// "File › Export › PDF"
    static func breadcrumb(_ parts: [String]) -> String { parts.joined(separator: " › ") }

    // Virtual key codes of keys that menus show by name or symbol instead of a character.
    private static let keyNames: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// A menu item's shortcut as menus draw it ("⇧⌘S") from AXMenuItemCmdChar, AXMenuItemCmdModifiers and
    /// AXMenuItemCmdVirtualKey; "" when the item has none. Modifier bits: 1 ⇧, 2 ⌥, 4 ⌃, 8 means *no* ⌘,
    /// 16 is 🌐 (seen on Finder's Move & Resize items).
    static func shortcutLabel(char: String?, modifiers: Int?, virtualKey: Int?) -> String {
        // Control characters (tab, return, backspace) and arrow-key private-use characters are not drawable.
        let drawable = char.flatMap { c in
            !c.isEmpty && c.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
                ? c.uppercased() : nil
        }
        guard let key = drawable ?? virtualKey.flatMap({ keyNames[$0] }) else { return "" }
        let m = modifiers ?? 0
        var flags: NSEvent.ModifierFlags = m & 8 == 0 ? [.command] : []
        if m & 1 != 0 { flags.insert(.shift) }
        if m & 2 != 0 { flags.insert(.option) }
        if m & 4 != 0 { flags.insert(.control) }
        return (m & 16 != 0 ? "🌐" : "") + Shortcut.symbols(flags) + key
    }

    /// Rows matching the query, best match first (ties keep their order); everything for an empty query.
    static func filter<T>(_ rows: [T], _ query: String, text: (T) -> [String]) -> [T] {
        guard !query.isEmpty else { return rows }
        return rows.enumerated()
            .compactMap { i, row -> (Int, T, Double)? in
                let score = text(row).map { matchScore(query, $0) }.max() ?? 0
                return score > 0 ? (i, row, score) : nil
            }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    // MARK: Accessibility

    private static let accessRow = Item(
        id: "nav.access", title: "Allow Lumen to use Accessibility", subtitle: "Privacy & Security → Accessibility",
        icon: .symbol("lock"), track: false,
        actions: [Action(title: "Grant Access", icon: "lock.open") { _ = AX.promptIfNeeded() }])

    private static let loadingRow = Item(id: "nav.loading", title: "Loading…", icon: .symbol("hourglass"), track: false, actions: [])

    /// Read and written on the main thread only.
    private final class Gathered<T> { var rows: [T]? }

    /// Pushes a list over the rows `gather` returns. It runs on a background queue because every Accessibility call can
    /// wait out the messaging timeout of a hung app; the list shows a "Loading…" row until the rows arrive.
    private static func pushGathered<T>(_ title: String, _ placeholder: String, gather: @escaping () -> [T],
                                        items: @escaping ([T], String) -> [Item]) {
        let trusted = AXIsProcessTrusted()
        let gathered = Gathered<T>()
        Launcher.shared.push(.list(ListSpec(title: title, placeholder: placeholder) { query in
            guard trusted else { return [accessRow] }
            return gathered.rows.map { items($0, query) } ?? [loadingRow]
        }))
        guard trusted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = gather()
            DispatchQueue.main.async {
                gathered.rows = rows
                Launcher.shared.reload()
            }
        }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        attr(e, name) as? [AXUIElement] ?? []
    }

    private static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)   // a hung app must not freeze the launcher
        return el
    }

    // MARK: Switch Windows

    /// Every regular app but Lumen, the app the user came from first, then by name.
    private static func windowApps() -> [NSRunningApplication] {
        let front = NSWorkspace.shared.frontmostApplication
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { a, b in
                (a == front) != (b == front) ? a == front
                    : (a.localizedName ?? "").localizedCaseInsensitiveCompare(b.localizedName ?? "") == .orderedAscending
            }
    }

    /// Standard windows of `apps`. Windows on other Spaces are only listed when the app reports them over Accessibility.
    private static func windows(of apps: [NSRunningApplication]) -> [Win] {
        apps.flatMap { app -> [Win] in
                let standard = elements(appElement(app), kAXWindowsAttribute)
                    .filter { attr($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }
                return standard.enumerated().map { i, w in
                    Win(id: "nav.win.\(app.processIdentifier).\(i)", app: app, element: w,
                        title: attr(w, kAXTitleAttribute) as? String ?? "",
                        minimized: attr(w, kAXMinimizedAttribute) as? Bool ?? false)
                }
            }
    }

    private static func windowItems(_ all: [Win], _ query: String) -> [Item] {
        let found = filter(all, query) { [$0.title, $0.app.localizedName ?? ""] }
        guard !found.isEmpty else {
            return [Item(id: "nav.no-windows", title: query.isEmpty ? "No windows" : "No matching windows",
                         icon: .symbol("macwindow"), track: false, actions: [])]
        }
        return found.map { w in
            let name = w.app.localizedName ?? "App"
            return Item(id: w.id, title: w.title.isEmpty ? name : w.title, subtitle: w.title.isEmpty ? "" : name,
                        kind: w.minimized ? "Minimized" : "Window", icon: w.app.icon.map(Icon.image) ?? .symbol("macwindow"),
                        track: false, actions: [
                            Action(title: "Switch to Window", icon: "macwindow") { raise(w) },
                            // Second, so a stray ⌘↵ only minimizes, which is easy to undo.
                            Action(title: w.minimized ? "Unminimize Window" : "Minimize Window", icon: "minus.rectangle",
                                   shortcut: Shortcut(.command, "m")) {
                                AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString,
                                                           w.minimized ? kCFBooleanFalse : kCFBooleanTrue)
                            },
                            Action(title: "Close Window", icon: "xmark.rectangle", shortcut: Shortcut(.command, "w")) {
                                if let button = AX.element(attr(w.element, kAXCloseButtonAttribute)) {
                                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                                }
                            },
                            Action(title: "Quit App", icon: "xmark.circle", shortcut: Shortcut(.command, "q")) { w.app.terminate() },
                            .copy("Copy Window Title", shortcut: Shortcut([.command, .shift], "c")) { w.title },
                        ])
        }
    }

    private static func raise(_ w: Win) {
        if w.minimized { AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        w.app.unhide()
        // The panel never activates Lumen, so a plain activate() can be refused; Accessibility always works.
        let frontmost = AXUIElementSetAttributeValue(appElement(w.app), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if frontmost != .success { w.app.activate() }
    }

    // MARK: Search Menu Bar Items

    // Huge menus (Services, Open Recent, fonts) stay fast; whatever lies past the caps is not searchable. The second
    // cap counts every element looked at, so separators and disabled items cannot keep a walk going either.
    private static let maxMenuItems = 800
    private static let maxVisited = 3000
    private static let maxMenuDepth = 5

    private struct Walk {
        var entries: [MenuEntry] = []
        var visited = 0
    }

    private static func menuEntries(of app: NSRunningApplication?) -> [MenuEntry] {
        guard let app, app.processIdentifier != getpid(),
              let bar = AX.element(attr(appElement(app), kAXMenuBarAttribute)) else { return [] }
        var found = Walk()
        // The first menu is always the Apple menu.
        walk(Array(elements(bar, kAXChildrenAttribute).dropFirst()), [], &found)
        return found.entries
    }

    /// `items` are menu bar items or menu items; both keep their submenu as the first child.
    private static func walk(_ items: [AXUIElement], _ parents: [String], _ out: inout Walk) {
        for item in items {
            guard out.entries.count < maxMenuItems, out.visited < maxVisited else { return }
            out.visited += 1
            guard let title = attr(item, kAXTitleAttribute) as? String, !title.isEmpty,   // separators have no title
                  attr(item, kAXEnabledAttribute) as? Bool != false else { continue }
            if let submenu = elements(item, kAXChildrenAttribute).first {
                if parents.count < maxMenuDepth { walk(elements(submenu, kAXChildrenAttribute), parents + [title], &out) }
                continue
            }
            let shortcut = shortcutLabel(char: attr(item, kAXMenuItemCmdCharAttribute) as? String,
                                         modifiers: attr(item, kAXMenuItemCmdModifiersAttribute) as? Int,
                                         virtualKey: attr(item, kAXMenuItemCmdVirtualKeyAttribute) as? Int)
            out.entries.append(MenuEntry(element: item, title: title, path: breadcrumb(parents + [title]), shortcut: shortcut))
        }
    }

    private static func menuItems(_ all: [MenuEntry], _ query: String) -> [Item] {
        let found = filter(all, query) { [$0.title, $0.path] }
        guard !found.isEmpty else {
            return [Item(id: "nav.no-menu-items", title: query.isEmpty ? "No menu bar items found" : "No matching menu bar items",
                         icon: .symbol("menubar.rectangle"), track: false, actions: [])]
        }
        return found.enumerated().map { i, e in
            Item(id: "nav.menu.\(i)", title: e.title, subtitle: e.path, kind: e.shortcut, icon: .symbol("menubar.rectangle"),
                 track: false, actions: [Action(title: "Press Menu Item", icon: "cursorarrow.click") {
                // Let the app regain focus first; the press runs off the main thread because an item that
                // opens a modal dialog does not answer until the dialog is gone.
                later {
                    DispatchQueue.global().async {
                        if AXUIElementPerformAction(e.element, kAXPressAction as CFString) != .success {
                            DispatchQueue.main.async { NSSound.beep() }
                        }
                    }
                }
            }])
        }
    }
}
