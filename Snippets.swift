import AppKit
import Carbon
import UniformTypeIdentifiers

/// A saved text. Stored in snippets.json in the same shape Raycast exports: name, text, keyword.
struct Snippet: Codable, Equatable {
    var name: String
    var text: String
    var keyword: String? = nil
}

/// Snippets: saved text pasted from search, or expanded wherever its keyword is typed.
final class Snippets {
    static let shared = Snippets()

    private var snippets: [Snippet] = Store.load("snippets.json") ?? []
    private var tap: CFMachPort?
    private var typed = ""      // the last characters typed in other apps
    private var busy = false    // while expanding; the key presses we post are not typing
    private var events = 0      // counts keys and clicks; a scheduled expansion runs only if none came after its keyword

    func commands() -> [Item] {
        [.command("snip.search", "Search Snippets", icon: "text.quote",
                  keywords: ["snippets", "text", "expand", "textbausteine"], closes: false) { [self] in
            Launcher.shared.push(.list(ListSpec(title: "Snippets", placeholder: "Search snippets…", showsDetail: true) { [weak self] in
                self?.items(matching: $0) ?? []
            }))
         },
         .command("snip.create", "Create Snippet", icon: "text.badge.plus", keywords: ["snippet", "new", "textbaustein"],
                  closes: false) { [self] in Launcher.shared.push(form()) }]
    }

    private func save() { Store.save(snippets, "snippets.json") }

    // MARK: List and form

    private func items(matching q: String) -> [Item] {
        func score(_ s: Snippet) -> Double {
            max(matchScore(q, s.name), matchScore(q, s.keyword ?? ""), s.text.localizedCaseInsensitiveContains(q) ? 30 : 0)
        }
        let found = snippets.filter { score($0) > 0 }.sorted { (a: Snippet, b: Snippet) -> Bool in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard !found.isEmpty else {
            return [Item(id: "snip.none", title: snippets.isEmpty ? "No snippets yet" : "No matching snippets",
                         icon: .symbol("text.quote"), track: false, actions: listActions)]
        }
        return found.enumerated().map { item($0.element, $0.offset) }
    }

    private func item(_ s: Snippet, _ i: Int) -> Item {
        let actions = [
            Action(title: "Paste", icon: "doc.on.clipboard") { [weak self] in later { self?.insert(s, deleting: 0) } },
            .copy("Copy to Clipboard") { Self.expand(s.text, date: Date(), clipboard: NSPasteboard.general.string(forType: .string) ?? "").text },
            Action(title: "Edit Snippet", icon: "pencil", shortcut: Shortcut(.command, "e"), closes: false) { [weak self] in
                if let self { Launcher.shared.push(form(s, editing: s)) }
            },
            Action(title: "Duplicate Snippet", icon: "plus.square.on.square", shortcut: Shortcut(.command, "d"), closes: false) { [weak self] in
                if let self { Launcher.shared.push(form(Snippet(name: s.name + " Copy", text: s.text))) }
            },
            Action(title: "Delete Snippet", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) { [weak self] in
                self?.delete(s)
            },
        ]
        return Item(id: "snip.\(i)", title: s.name, kind: s.keyword ?? "", icon: .symbol("text.quote"), track: false,
                    actions: actions + listActions,
                    detail: Detail(markdown: s.text, metadata: (s.keyword.map { [("Keyword", $0)] } ?? []) + [("Characters", "\(s.text.count)")]))
    }

    private var listActions: [Action] {
        [Action(title: "Create Snippet", icon: "plus", shortcut: Shortcut(.command, "n"), closes: false) { [weak self] in
            if let self { Launcher.shared.push(form()) }
         },
         Action(title: "Export Snippets…", icon: "square.and.arrow.up") { [weak self] in self?.export() },
         Action(title: "Import Snippets…", icon: "square.and.arrow.down") { [weak self] in self?.importFile() }]
    }

    /// The create form, prefilled when duplicating; with `original` it edits that snippet instead.
    private func form(_ prefill: Snippet = Snippet(name: "", text: ""), editing original: Snippet? = nil) -> Launcher.Mode {
        .form(FormSpec(title: original == nil ? "Create Snippet" : "Edit Snippet", fields: [
            FormField(label: "Name", value: prefill.name, placeholder: "Email Signature"),
            FormField(label: "Snippet", value: prefill.text, multiline: true),
            FormField(label: "Keyword", value: prefill.keyword ?? "", placeholder: "Optional, e.g. ;sig"),
        ], submitTitle: original == nil ? "Create Snippet" : "Save Snippet") { [weak self] v in
            guard let self else { return nil }
            let keyword = v[2].trimmingCharacters(in: .whitespaces)
            let new = Snippet(name: v[0].trimmingCharacters(in: .whitespaces), text: v[1], keyword: keyword.isEmpty ? nil : keyword)
            let index = original.flatMap { self.snippets.firstIndex(of: $0) }
            if let error = Self.problem(new, in: snippets, editing: index) { return error }
            if let index { snippets[index] = new } else { snippets.append(new) }
            save()
            HUD.show(original == nil ? "Snippet Created" : "Snippet Saved")
            return nil
        })
    }

    /// Why a snippet cannot be saved, or nil. `index` is the snippet being edited, which may keep its keyword.
    static func problem(_ s: Snippet, in list: [Snippet], editing index: Int?) -> String? {
        if s.name.isEmpty { return "Enter a name." }
        if s.text.isEmpty { return "Enter the snippet text." }
        guard let k = s.keyword else { return nil }
        for i in list.indices where i != index {
            guard let other = list[i].keyword, !other.isEmpty else { continue }
            let name = list[i].name
            if other == k { return "The keyword “\(k)” is already used by “\(name)”." }
            // A keyword expands as soon as it is typed, so one typed on the way to another blocks that one.
            // Ending with another keyword is fine: the longest match wins.
            if k.dropLast().contains(other) {
                return "The keyword “\(k)” could never expand: “\(other)” of “\(name)” expands first while it is typed."
            }
            if other.dropLast().contains(k) {
                return "The keyword “\(other)” of “\(name)” could never expand again: “\(k)” would expand first while it is typed."
            }
        }
        return nil
    }

    private func delete(_ s: Snippet) {
        guard confirm("Delete the snippet “\(s.name)”?"), let i = snippets.firstIndex(of: s) else { return }
        snippets.remove(at: i)
        save()
        Launcher.shared.reload()
    }

    // MARK: Import and export

    private func export() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "snippets.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(snippets).write(to: url, options: .atomic)
            HUD.show("Exported \(snippets.count) Snippets")
        } catch {
            HUD.show("Export failed: " + error.localizedDescription)
        }
    }

    private func importFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let imported = try? JSONDecoder().decode([Snippet].self, from: data) else {
            HUD.show("Not a snippets file")
            return
        }
        let (list, skipped) = Self.merged(snippets, imported)
        let added = list.count - snippets.count
        snippets = list
        save()
        Launcher.shared.reload()
        HUD.show("Imported \(added) Snippets" + (skipped > 0 ? ", skipped \(skipped)" : ""))
    }

    /// Adds imported snippets, skipping ones already there, incomplete ones and ones whose keyword is taken or blocked.
    static func merged(_ list: [Snippet], _ imported: [Snippet]) -> (list: [Snippet], skipped: Int) {
        var result = list
        for var s in imported {
            if s.keyword?.isEmpty == true { s.keyword = nil }
            if !result.contains(s), problem(s, in: result, editing: nil) == nil { result.append(s) }
        }
        return (result, list.count + imported.count - result.count)
    }

    // MARK: Placeholders and pasting

    /// Fills in the placeholders; returns the text and how many characters follow {cursor}.
    static func expand(_ text: String, date: Date, clipboard: String) -> (text: String, cursorOffset: Int) {
        func fill(_ s: String) -> String {
            [("{datetime}", date.formatted(date: .abbreviated, time: .shortened)),
             ("{date}", date.formatted(date: .abbreviated, time: .omitted)),
             ("{time}", date.formatted(date: .omitted, time: .shortened)),
             ("{day}", date.formatted(.dateTime.weekday(.wide))),
             ("{uuid}", UUID().uuidString),
             ("{clipboard}", clipboard)]   // last, so braces in the clipboard text stay as they are
                .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
        let parts = text.components(separatedBy: "{cursor}")
        let before = fill(parts[0]), after = fill(parts.dropFirst().joined())
        return (before + after, after.count)
    }

    /// Types a snippet into the frontmost app: deletes `count` typed characters, pastes the text through
    /// the clipboard and moves the caret back to {cursor}. The user's clipboard comes back afterwards,
    /// unless they copied something in the meantime.
    private func insert(_ s: Snippet, deleting count: Int) {
        let pb = NSPasteboard.general
        let (text, back) = Self.expand(s.text, date: Date(), clipboard: pb.string(forType: .string) ?? "")
        let saved = Clipboard.saveItems()
        busy = true
        for _ in 0..<count { AX.key(51, []) }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        let pasted = Clipboard.writeTransient([item])
        AX.key(9, .maskCommand)
        later(0.1) { for _ in 0..<back { AX.key(123, []) } }
        later(0.5) {
            Clipboard.restore(saved, unlessChangedSince: pasted)
            self.busy = false
        }
    }

    // MARK: Keyword expansion

    /// Starts keyword expansion; called once at launch. Until Lumen has Accessibility access the keyboard
    /// tap cannot be created, so it is tried again every 5 seconds.
    func start() {
        if !startTap() {
            NSLog("Lumen: keyboard event tap unavailable, snippet keywords expand once Accessibility is granted")
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [self] timer in
                if startTap() { timer.invalidate() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.typed = "" }
    }

    private func startTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = Snippets.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            if type == .keyDown { event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars) }
            let characters = String(utf16CodeUnits: chars, count: length), flags = event.flags
            DispatchQueue.main.async { Snippets.shared.handle(type, characters, flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        self.tap = tap
        // The tap gets its own thread and only hands each event to the main thread, so a busy Lumen
        // (an AppleScript, a mite booking) never holds up typing in other apps.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CFRunLoopRun()
        }
        thread.name = "Lumen snippet keys"
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ characters: String, _ flags: CGEventFlags) {
        events += 1
        switch type {
        case .keyDown where busy:
            break
        case .keyDown:
            // Lumen's own windows (search, the snippet form) and password fields are left alone. The panel
            // does not activate Lumen, so keyWindow alone does not show it.
            guard NSApp.keyWindow == nil, !PanelController.shared.isVisible, !IsSecureEventInputEnabled() else { typed = ""; return }
            typed = Self.typing(typed, characters, flags: flags)
            guard let s = Self.match(typed, in: snippets), let keyword = s.keyword else { return }
            typed = ""
            // After the keyword's last key reached the app. A key or click in between cancels: the backspaces
            // would delete the wrong characters.
            let token = events
            later(0.05) { if self.events == token { self.insert(s, deleting: keyword.count) } }
        default:
            typed = ""   // a click may have moved the caret
        }
    }

    /// The typed-text buffer after one key press. Backspace removes a character; ⌘/⌃ shortcuts, ⌥⌫ and keys
    /// that move the caret or end the input (arrows, Return, Tab, Escape, ...) start over.
    static func typing(_ buffer: String, _ characters: String, flags: CGEventFlags) -> String {
        if !flags.isDisjoint(with: [.maskCommand, .maskControl]) { return "" }
        if characters == "\u{7F}" { return flags.contains(.maskAlternate) ? "" : String(buffer.dropLast()) }
        // Arrow and function keys produce private-use characters; dead keys produce none and keep the buffer.
        guard characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return "" }
        return String((buffer + characters).suffix(64))
    }

    /// The snippet whose keyword the typed text ends with; the longest keyword wins.
    static func match(_ typed: String, in list: [Snippet]) -> Snippet? {
        list.filter { s in s.keyword.map { !$0.isEmpty && typed.hasSuffix($0) } ?? false }
            .max { $0.keyword!.count < $1.keyword!.count }
    }
}
