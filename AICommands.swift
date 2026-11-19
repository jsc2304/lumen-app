import AppKit
import UniformTypeIdentifiers

/// Stored in ai-commands.json as id, title, prompt, icon (an SF Symbol name) and replaces.
struct AICommand: Equatable {
    let id: String       // the root id: favorite, alias and hotkey hang on it, so it never follows the title
    let title: String
    let symbol: String
    let prompt: String
    let replaces: Bool   // ↵ pastes over the selection instead of copying

    /// Without an id this is a new command of the user's own: "ai.custom.<uuid>".
    init(id: String? = nil, title: String, symbol: String, prompt: String, replaces: Bool) {
        self.id = id ?? Self.newID()
        self.title = title
        self.symbol = symbol
        self.prompt = prompt
        self.replaces = replaces
    }

    /// A built-in command keeps "ai.<title>", the root id every command had before ids were stored,
    /// so hotkeys, favorites and aliases set on it still work.
    init(builtIn title: String, symbol: String, prompt: String, replaces: Bool) {
        self.init(id: "ai." + title, title: title, symbol: symbol, prompt: prompt, replaces: replaces)
    }

    static func newID() -> String { "ai.custom." + UUID().uuidString }
}

extension AICommand: Codable {
    enum CodingKeys: String, CodingKey { case id, title, prompt, replaces, symbol = "icon" }

    /// Only title and prompt are required, so a file from an older version still loads; an entry without an id gets a new one
    /// (AICommands saves the file again right after loading, so it keeps it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.newID()
        title = try c.decode(String.self, forKey: .title)
        prompt = try c.decode(String.self, forKey: .prompt)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? AICommands.defaultSymbol
        replaces = try c.decodeIfPresent(Bool.self, forKey: .replaces) ?? false
    }
}

/// AI Commands: the built-in ones plus the user's own (created, edited, imported).
enum AICommands {
    static let builtIn = [
        AICommand(builtIn: "Fix Spelling and Grammar", symbol: "textformat.abc",
                  prompt: "Fix spelling and grammar. Keep the language, tone, meaning and formatting.", replaces: true),
        AICommand(builtIn: "Improve Writing", symbol: "pencil.line",
                  prompt: "Improve the writing: clearer and more natural, same language, same meaning, similar length.", replaces: true),
        AICommand(builtIn: "Make Shorter", symbol: "arrow.down.right.and.arrow.up.left",
                  prompt: "Make the text shorter without losing information. Keep the language.", replaces: true),
        AICommand(builtIn: "Translate to English", symbol: "globe", prompt: "Translate the text to English.", replaces: true),
        AICommand(builtIn: "Translate to German", symbol: "globe", prompt: "Translate the text to German.", replaces: true),
        AICommand(builtIn: "Summarize", symbol: "list.bullet",
                  prompt: "Summarize the text in a few bullet points, in the text's language.", replaces: false),
        AICommand(builtIn: "Explain", symbol: "questionmark.bubble",
                  prompt: "Explain the text in simple words, in the text's language.", replaces: false),
    ]

    static let defaultSymbol = "sparkles"

    /// The user's own commands, and the titles of built-in ones they hid. Saved on every change.
    private(set) static var custom: [AICommand] = loadCustom() {
        didSet { Store.save(custom, "ai-commands.json") }
    }
    private(set) static var hidden: [String] = Store.load("ai-commands-hidden.json") ?? [] {
        didSet { Store.save(hidden, "ai-commands-hidden.json") }
    }

    /// Reads the file and writes it back at once: an entry from before ids were stored got its id while loading and keeps it.
    private static func loadCustom() -> [AICommand] {
        let list: [AICommand] = Store.load("ai-commands.json") ?? []
        if !list.isEmpty { Store.save(list, "ai-commands.json") }
        return list
    }

    /// Every AI command offered in the root search.
    static func all() -> [AICommand] { combined(custom: custom, hidden: hidden) }

    /// The built-in commands that are not hidden, then the custom ones. A title appears once, even in a hand-edited file.
    static func combined(custom: [AICommand], hidden: [String]) -> [AICommand] {
        var seen = Set<String>()
        return (builtIn.filter { !hidden.contains($0.title) } + custom).filter { seen.insert($0.title.lowercased()).inserted }
    }

    // MARK: Root

    /// Commands that manage AI commands (Create AI Command, Search AI Commands, …).
    static func commands() -> [Item] {
        [.command("aicmd.create", "Create AI Command", kind: "AI Command", icon: "plus.bubble",
                  keywords: ["new", "add", "custom", "prompt", "ai"], closes: false) { form() },
         .command("aicmd.search", "Search AI Commands", kind: "AI Command", icon: "sparkle.magnifyingglass",
                  keywords: ["ai", "custom", "prompts", "manage", "built-in"], closes: false) {
            Launcher.shared.push(.list(ListSpec(title: "AI Commands", placeholder: "Search AI commands…", showsDetail: true) { items(matching: $0) }))
        },
         .command("aicmd.import", "Import AI Commands", kind: "AI Command", icon: "square.and.arrow.down",
                  keywords: ["ai", "raycast", "json", "prompts"]) { importFile() }]
    }

    // MARK: List and row actions

    private static func items(matching q: String) -> [Item] {
        func score(_ c: AICommand) -> Double {
            max(matchScore(q, c.title), c.prompt.localizedCaseInsensitiveContains(q) ? 30 : 0)
        }
        let found = all().filter { score($0) > 0 }.sorted { (a: AICommand, b: AICommand) -> Bool in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        guard !found.isEmpty else {
            return [Item(id: "aicmd.none", title: q.isEmpty ? "No AI commands" : "No matching AI commands",
                         icon: .symbol("sparkles"), track: false, actions: listActions)]
        }
        return found.map(item)
    }

    private static func item(_ c: AICommand) -> Item {
        let isBuiltIn = has(builtIn, c.title)
        var actions = [Action(title: "Run AI Command", icon: "sparkles", closes: false) { Launcher.shared.runAICommand(c) },
                       .copy("Copy Prompt") { c.prompt }]
        if !isBuiltIn {
            actions.append(Action(title: "Edit AI Command", icon: "pencil", shortcut: Shortcut(.command, "e"), closes: false) { form(c, editing: c) })
        }
        actions.append(Action(title: "Duplicate AI Command", icon: "plus.square.on.square", shortcut: Shortcut(.command, "d"), closes: false) {
            form(AICommand(title: copyTitle(of: c.title, custom: custom), symbol: c.symbol, prompt: c.prompt, replaces: c.replaces))
        })
        actions.append(isBuiltIn
            ? Action(title: "Hide Built-in", icon: "eye.slash", shortcut: Shortcut(.control, "x"), closes: false) { hide(c) }
            : Action(title: "Delete AI Command", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) { delete(c) })
        return Item(id: "aicmd.row." + c.title, title: c.title, kind: isBuiltIn ? "Built-in" : "Custom", icon: .symbol(c.symbol),
                    track: false, actions: actions + listActions,
                    detail: Detail(markdown: c.prompt, metadata: [("Type", isBuiltIn ? "Built-in" : "Custom"),
                                                                  ("Replaces Selection", c.replaces ? "Yes" : "No")]))
    }

    private static var listActions: [Action] {
        var actions = [Action(title: "Create AI Command", icon: "plus", shortcut: Shortcut(.command, "n"), closes: false) { form() },
                       Action(title: "Export AI Commands…", icon: "square.and.arrow.up") { exportFile() },
                       Action(title: "Import AI Commands…", icon: "square.and.arrow.down") { importFile() }]
        if !hidden.isEmpty {
            actions.append(Action(title: "Show Hidden Built-ins", icon: "eye", closes: false) { showHidden() })
        }
        return actions
    }

    private static func delete(_ c: AICommand) {
        // The alert takes key focus from the panel and hides it; bring the list back afterwards.
        let ok = confirm("Delete the AI command “\(c.title)”?")
        PanelController.shared.show(reset: false)
        guard ok else { return }
        custom.removeAll { $0.id == c.id }
        Launcher.shared.reload()
        HUD.show("Deleted AI Command")
    }

    private static func hide(_ c: AICommand) {
        hidden.append(c.title)
        Launcher.shared.reload()
        HUD.show("Hid “\(c.title)”")
    }

    private static func showHidden() {
        let n = hidden.count
        hidden = []
        Launcher.shared.reload()
        HUD.show("Showing \(n) hidden built-in" + (n == 1 ? "" : "s"))
    }

    // MARK: Form

    /// Create form, prefilled when duplicating; with `original` it edits that command instead.
    private static func form(_ prefill: AICommand? = nil, editing original: AICommand? = nil) {
        Launcher.shared.push(.form(FormSpec(
            title: original == nil ? "Create AI Command" : "Edit AI Command",
            fields: [FormField(label: "Title", value: prefill?.title ?? "", placeholder: "Fix Tone"),
                     FormField(label: "Prompt ({selection} places the selected text)", value: prefill?.prompt ?? "", multiline: true),
                     FormField(label: "Paste Result Over Selection (yes or no)", value: prefill?.replaces == true ? "yes" : "no", placeholder: "yes or no"),
                     FormField(label: "Icon (optional SF Symbol name)", value: prefill?.symbol ?? "", placeholder: defaultSymbol)],
            submitTitle: original == nil ? "Create AI Command" : "Save AI Command") { v in
                if let error = problem(v, custom: custom, editing: original?.title) { return error }
                let c = command(from: v, id: original?.id)   // an edited command keeps its id, and with it favorite, alias and hotkey
                if let original {
                    guard let i = custom.firstIndex(where: { $0.id == original.id }) else { return "This AI command no longer exists." }
                    custom[i] = c
                } else {
                    custom.append(c)
                }
                HUD.show(original == nil ? "AI Command Created" : "AI Command Saved")
                return nil
            }))
    }

    // MARK: Validation and import (pure)

    private static func has(_ list: [AICommand], _ title: String) -> Bool {
        list.contains { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The AI Chat commands in the root search have titles of their own, which a command of ours must not repeat.
    private static func isChatTitle(_ title: String) -> Bool {
        AIChat.commands().contains { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    static func isSymbol(_ name: String) -> Bool { NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil }

    /// yes/ja → true, no/nein or nothing → false, anything else → nil.
    static func yesNo(_ s: String) -> Bool? {
        switch trimmed(s).lowercased() {
        case "yes", "y", "ja", "j": return true
        case "no", "n", "nein", "": return false
        default: return nil
        }
    }

    /// Why the form values (title, prompt, paste yes/no, icon) cannot be saved, or nil. A title may not be taken by
    /// a built-in command, an AI Chat command or another command of the user's.
    /// `editing` is the title of the custom command being edited, which may keep its title.
    static func problem(_ v: [String], custom: [AICommand], editing: String?) -> String? {
        let title = trimmed(v[0]), icon = trimmed(v[3])
        if title.isEmpty { return "Enter a title." }
        if has(builtIn, title) { return "“\(title)” is the title of a built-in AI command. Pick another title." }
        if isChatTitle(title) { return "“\(title)” is the title of an AI Chat command. Pick another title." }
        if has(custom.filter { $0.title != editing }, title) { return "You already have an AI command called “\(title)”." }
        if trimmed(v[1]).isEmpty { return "Enter a prompt." }
        if yesNo(v[2]) == nil { return "Paste Result Over Selection must be yes or no." }
        if !icon.isEmpty, !isSymbol(icon) { return "“\(icon)” is not an SF Symbol name. Copy one from the SF Symbols app, e.g. text.bubble." }
        return nil
    }

    /// The command the form values describe (with the id of the command it replaces, if any); call `problem` first.
    static func command(from v: [String], id: String? = nil) -> AICommand {
        let icon = trimmed(v[3])
        return AICommand(id: id, title: trimmed(v[0]), symbol: icon.isEmpty ? defaultSymbol : icon, prompt: trimmed(v[1]), replaces: yesNo(v[2]) == true)
    }

    /// "Title Copy", or "Title Copy 2", … when that is taken.
    static func copyTitle(of title: String, custom: [AICommand]) -> String {
        var copy = title + " Copy", n = 1
        while has(builtIn + custom, copy) {
            n += 1
            copy = "\(title) Copy \(n)"
        }
        return copy
    }

    /// What an import file may hold per command: Raycast's export ({title, prompt, icon, creativity, model}; creativity and model
    /// are ignored) or ours (plus replaces).
    private struct Imported: Decodable {
        var title, name, prompt, icon: String?
        var replaces: Bool?
    }

    /// The commands in a file that `existing`, the built-ins and the AI Chat commands do not have yet (by title), and how many
    /// were skipped (title taken, title or prompt missing). They get ids of their own, an id in the file is ignored. Icons that
    /// are no SF Symbol, like Raycast's, become the default one. Nil if the file is not a list of commands.
    static func imported(_ data: Data, existing: [AICommand]) -> (new: [AICommand], skipped: Int)? {
        guard let list = try? JSONDecoder().decode([Imported].self, from: data) else { return nil }
        var known = builtIn + existing, new: [AICommand] = []
        for e in list {
            let title = trimmed(e.title ?? e.name ?? ""), prompt = trimmed(e.prompt ?? "")
            guard !title.isEmpty, !prompt.isEmpty, !has(known, title), !isChatTitle(title) else { continue }
            let icon = e.icon.map(trimmed).flatMap { isSymbol($0) ? $0 : nil }
            let c = AICommand(title: title, symbol: icon ?? defaultSymbol, prompt: prompt, replaces: e.replaces ?? false)
            new.append(c)
            known.append(c)
        }
        return (new, list.count - new.count)
    }

    static func exportData(_ list: [AICommand]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(list)
    }

    // MARK: Export and import files

    private static func count(_ n: Int) -> String { n == 1 ? "1 AI Command" : "\(n) AI Commands" }

    private static func exportFile() {
        guard !custom.isEmpty else { HUD.show("No custom AI commands to export"); return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AI Commands.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportData(custom).write(to: url, options: .atomic)
            HUD.show("Exported " + count(custom.count))
        } catch {
            HUD.show("Export failed: " + error.localizedDescription)
        }
    }

    private static func importFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let result = imported(data, existing: custom) else {
            HUD.show("Not an AI commands file")
            return
        }
        custom += result.new
        Launcher.shared.reload()
        HUD.show("Imported " + count(result.new.count) + (result.skipped > 0 ? ", skipped \(result.skipped) (title taken or incomplete)" : ""))
    }
}
