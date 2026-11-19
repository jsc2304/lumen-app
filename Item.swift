import AppKit

enum Icon {
    case image(NSImage)
    case symbol(String)
    case color(NSColor)
}

/// A key combination for an action. Matched against the character the key produces in the current
/// keyboard layout, so ⌘⇧C works on QWERTY and QWERTZ alike.
struct Shortcut {
    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    let modifiers: NSEvent.ModifierFlags   // contains ⌘, ⌥ or ⌃, so plain typing never triggers it
    let key: String                        // lowercase character

    init(_ modifiers: NSEvent.ModifierFlags, _ key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    func matches(_ e: NSEvent) -> Bool {
        e.modifierFlags.intersection(Self.relevant) == modifiers && e.charactersIgnoringModifiers?.lowercased() == key
    }

    var label: String { Self.symbols(modifiers) + key.uppercased() }

    static func symbols(_ m: NSEvent.ModifierFlags) -> String {
        (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") +
            (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    }
}

/// Something an item can do. An item's first action runs on ↵, the second on ⌘↵, all of them are
/// listed in the ⌘K menu, and any action's shortcut works straight from the list.
struct Action {
    let title: String
    var icon = "circle"
    var shortcut: Shortcut? = nil
    var destructive = false
    var closes = true   // hides the panel before running
    var general = false // added to every root entry (favorite, alias, …); never the ⌘↵ action
    let run: () -> Void

    /// Copies text and confirms with a HUD.
    /// The ⌘↵ action of a list: the second one, unless that is a general root action.
    static func secondary(of actions: [Action]) -> Action? {
        actions.count > 1 && !actions[1].general ? actions[1] : nil
    }

    static func copy(_ title: String, shortcut: Shortcut? = nil, _ text: @escaping () -> String) -> Action {
        Action(title: title, icon: "doc.on.doc", shortcut: shortcut) {
            copyToClipboard(text())
            HUD.show("Copied to Clipboard")
        }
    }
}

/// One row in a list.
struct Item {
    let id: String
    let title: String
    var subtitle = ""
    var kind = "Command"
    var icon = Icon.symbol("command")
    var keywords: [String] = []
    var section = ""
    var track = true   // root entry: counts for ranking and gets favorite/alias/hotkey actions
    var actions: [Action]
    var detail: Detail? = nil   // shown beside the list when its ListSpec has showsDetail

    /// A command with a single action.
    static func command(_ id: String, _ title: String, kind: String = "Command", icon: String, keywords: [String] = [],
                        closes: Bool = true, run: @escaping () -> Void) -> Item {
        Item(id: id, title: title, kind: kind, icon: .symbol(icon), keywords: keywords,
             actions: [Action(title: closes ? "Run Command" : "Open Command", icon: icon, closes: closes, run: run)])
    }

    func inSection(_ s: String) -> Item {
        var copy = self
        copy.section = s
        return copy
    }
}

/// Preview pane for the selected item: text (inline Markdown), an optional image, label/value rows.
struct Detail {
    var markdown = ""
    var image: NSImage? = nil
    var metadata: [(String, String)] = []
}

/// A searchable list pushed onto the panel (Clipboard History, My Schedule, …).
struct ListSpec {
    let title: String
    let placeholder: String
    var showsDetail = false
    var initialSelection: (([Item]) -> Int)? = nil
    let items: (String) -> [Item]
}

struct FormField {
    let label: String
    var value = ""
    var placeholder = ""
    var multiline = false
}

/// A form pushed onto the panel; ⌘↵ submits. `onSubmit` returns an error message to keep it open.
struct FormSpec {
    let title: String
    let fields: [FormField]
    let submitTitle: String
    let onSubmit: ([String]) -> String?
}

/// Files the app keeps in ~/Library/Application Support/Lumen.
enum Store {
    private static var storage = SecureStorage(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lumen"), key: ArchiveKeychain.key, interactiveLookup: ArchiveKeychain.interactiveLookup, onFailure: {
            DispatchQueue.main.async {
                guard NSApp != nil else { return }
                let alert = NSAlert()
                alert.messageText = "Protected storage is unavailable"
                alert.informativeText = SecureStorage.message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        })
    static var dir: URL {
        let root = storage.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static var protectedAvailable: Bool { storage.available }
    static func prepareSensitiveStorage() { storage.prepare(interactive: true) }
    // Called once at the beginning of the check executable, before any feature singleton is used.
    static func useForChecks(_ isolatedStorage: SecureStorage) { storage = isolatedStorage }
    static func loadBlob(_ name: String) -> Data? { storage.loadBlob("clipboard/" + name) }
    @discardableResult
    static func saveBlob(_ data: Data, _ name: String) -> Bool { storage.saveBlob(data, "clipboard/" + name) }

    static func load<T: Decodable>(_ name: String) -> T? {
        if SecureStorage.protected(name) { return storage.load(name) }
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Keep an unreadable file instead of letting the next save overwrite the user's data.
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("Lumen: a data file could not be decoded; recovery attempted")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        if SecureStorage.protected(name) { storage.save(value, name); return }
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func later(_ seconds: Double = 0.15, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
}

func shell(_ path: String, _ args: String...) {
    _ = try? Process.run(URL(fileURLWithPath: path), arguments: args)
}

/// Runs AppleScript through /usr/bin/osascript in the background, so a slow Finder or System Events
/// (Empty Trash can take minutes) never blocks Lumen.
func osascript(_ source: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        guard (try? p.run()) != nil else { return }
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { NSLog("Lumen: AppleScript failed with status %d", p.terminationStatus) }
    }
}

/// Escapes text for use inside an AppleScript string literal.
func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func confirm(_ question: String) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = question
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
