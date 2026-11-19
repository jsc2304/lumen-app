import AppKit

struct HotkeyBinding: Codable {
    let keyCode: UInt16
    let modifiers: UInt   // NSEvent.ModifierFlags raw value
    let label: String
}

/// The root search: applications and feature commands, ranked by match and usage, plus favorites,
/// aliases and per-command hotkeys.
enum Root {
    struct Prefs: Codable {
        var favorites: [String] = []
        var aliases: [String: String] = [:]
        var hotkeys: [String: HotkeyBinding] = [:]

        init() {}

        // Every key optional, so a root.json written before a new field existed still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
            aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
            hotkeys = try c.decodeIfPresent([String: HotkeyBinding].self, forKey: .hotkeys) ?? [:]
        }
    }

    private(set) static var prefs: Prefs = Store.load("root.json") ?? Prefs()
    private static var usage: [String: Usage] = Store.load("usage.json") ?? [:]
    /// Every root entry: applications plus all feature commands. Built fresh each time (about a hundred
    /// small structs), so quicklinks or snippets created a moment ago are searchable at once.
    static func entries() -> [Item] {
        Apps.items() + Features.commands()
    }

    static func items(for raw: String) -> [Item] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        let now = Date().timeIntervalSince1970
        let all = entries()
        if q.isEmpty {
            FileSearch.shared.search("")
            let favorites = prefs.favorites.compactMap { id in all.first { $0.id == id } }.map { $0.inSection("Favorites") }
            var suggestions = all.filter { !prefs.favorites.contains($0.id) }
                .map { ($0, currentScore(usage[$0.id], now: now)) }.filter { $0.1 > 0.05 }
                .sorted { $0.1 > $1.1 }.prefix(8).map { $0.0.inSection("Suggestions") }
            if suggestions.isEmpty, favorites.isEmpty {
                suggestions = all.filter { Features.starters.contains($0.id) }.map { $0.inSection("Suggestions") }
            }
            return (Features.upcoming() + favorites + suggestions).map(decorate)
        }
        let key = q.lowercased()
        let aliasHit = prefs.aliases.first { $0.value.lowercased() == key }?.key
        let ranked = all.compactMap { item -> (Item, Double)? in
            if item.id == aliasHit { return (item, 10_000) }
            let names = [item.title] + item.keywords + [prefs.aliases[item.id]].compactMap { $0 }
            let m = names.map { matchScore(q, $0) }.max() ?? 0
            guard m > 0 else { return nil }
            return (item, rank(match: m, usage: currentScore(usage[item.id], now: now),
                               queryUsage: currentScore(usage[key + "|" + item.id], now: now)))
        }.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
        FileSearch.shared.search(q)
        return (Features.queryItems(q) + ranked + FileSearch.shared.results + Features.fallbacks(q)).map(decorate)
    }

    /// Counts a run of `item` for the general ranking and for this exact query.
    static func used(_ item: Item, query: String) {
        let now = Date().timeIntervalSince1970
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        usage[item.id] = recordUse(usage[item.id], now: now)
        if !key.isEmpty { usage[key + "|" + item.id] = recordUse(usage[key + "|" + item.id], now: now) }
        usage = usage.filter { currentScore($0.value, now: now) > 0.01 }
        Store.save(usage, "usage.json")
    }

    /// Adds the actions every root entry has: favorite, alias, hotkey, ranking reset.
    private static func decorate(_ item: Item) -> Item {
        guard item.track else { return item }
        var item = item
        let favorite = prefs.favorites.contains(item.id)
        let hotkey = prefs.hotkeys[item.id]
        let id = item.id, title = item.title
        item.actions += [
            Action(title: favorite ? "Remove from Favorites" : "Add to Favorites", icon: favorite ? "star.slash" : "star",
                   shortcut: Shortcut([.command, .shift], "f"), closes: false, general: true) {
                if favorite { prefs.favorites.removeAll { $0 == id } } else { prefs.favorites.append(id) }
                save()
                Launcher.shared.reload()
            },
            Action(title: prefs.aliases[id] == nil ? "Set Alias…" : "Change Alias…", icon: "character.cursor.ibeam", closes: false, general: true) {
                Launcher.shared.push(.form(FormSpec(title: "Alias for " + title,
                    fields: [FormField(label: "Alias", value: prefs.aliases[id] ?? "", placeholder: "e.g. " + title.prefix(2).lowercased())],
                    submitTitle: "Save Alias") { values in
                        let alias = values[0].trimmingCharacters(in: .whitespaces)
                        prefs.aliases[id] = alias.isEmpty ? nil : alias
                        save()
                        return nil
                    }))
            },
            Action(title: hotkey.map { "Change Hotkey (" + $0.label + ")…" } ?? "Set Hotkey…", icon: "keyboard", closes: false, general: true) {
                Launcher.shared.push(.recordHotkey(item))
            },
            Action(title: "Reset Ranking", icon: "arrow.counterclockwise", closes: false, general: true) {
                usage = usage.filter { $0.key != id && !$0.key.hasSuffix("|" + id) }
                Store.save(usage, "usage.json")
                Launcher.shared.reload()
            },
        ]
        return item
    }

    private static func save() { Store.save(prefs, "root.json") }

    // MARK: Hotkeys per entry

    private static let firstHotkeyID: UInt32 = 100

    /// Registers every entry hotkey; returns the ids whose combination another app already holds.
    @discardableResult
    static func registerHotkeys() -> [String] {
        HotKeys.unregister(from: firstHotkeyID)
        return prefs.hotkeys.sorted(by: { $0.key < $1.key }).enumerated().compactMap { i, entry in
            let (id, b) = entry
            let ok = HotKeys.register(id: firstHotkeyID + UInt32(i), keyCode: b.keyCode,
                                      modifiers: NSEvent.ModifierFlags(rawValue: b.modifiers)) { run(id) }
            return ok ? nil : id
        }
    }

    static func setHotkey(_ binding: HotkeyBinding?, for item: Item) {
        prefs.hotkeys[item.id] = binding
        if let binding, registerHotkeys().contains(item.id) {
            prefs.hotkeys[item.id] = nil
            registerHotkeys()
            HUD.show(binding.label + " is taken by another app")
        } else if let binding {
            HUD.show(binding.label + " opens " + item.title)
        } else {
            registerHotkeys()
        }
        save()
    }

    /// Runs a root entry's main action from its hotkey; drops hotkeys whose entry is gone.
    static func run(_ id: String) {
        guard let item = entries().first(where: { $0.id == id }), let action = item.actions.first else {
            prefs.hotkeys[id] = nil
            save()
            registerHotkeys()
            HUD.show("That command no longer exists; its hotkey was removed")
            return
        }
        used(item, query: "")
        if action.closes { PanelController.shared.hide() } else { PanelController.shared.show() }
        action.run()
    }
}

/// File name search through the Spotlight index, limited to the home folder.
final class FileSearch: NSObject {
    static let shared = FileSearch()
    private let query = NSMetadataQuery()
    private var current = ""
    private(set) var results: [Item] = []
    private let folders: [Item] = [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory, .picturesDirectory, .musicDirectory, .moviesDirectory].compactMap {
        FileManager.default.urls(for: $0, in: .userDomainMask).first
    }.map {
        var item = FileSearch.item($0.path)
        item.kind = "Folder"
        return item
    }
    var onUpdate: (() -> Void)?

    override init() {
        super.init()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered),
                                               name: .NSMetadataQueryDidFinishGathering, object: query)
    }

    func search(_ text: String) {
        guard text != current else { return }
        current = text
        query.stop()
        results = folders.filter { !text.isEmpty && $0.title.localizedCaseInsensitiveContains(text) }
        guard text.count >= 3 else { return }
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        query.start()
    }

    @objc private func gathered() {
        query.stop()
        let paths = (0..<query.resultCount).compactMap {
            (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }
        let common = folders.filter { $0.title.localizedCaseInsensitiveContains(current) }
        let ids = Set(common.map(\.id))
        results = Array((common + Self.rankedPaths(paths, matching: current).filter { !ids.contains($0) }.prefix(8).map(Self.item)).prefix(8))
        onUpdate?()
    }

    /// Rank before truncation so recent substring hits cannot hide exact names.
    static func rankedPaths(_ paths: [String], matching text: String) -> [String] {
        func tier(_ path: String) -> Int {
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            let key = text.lowercased()
            return name == key ? 0 : name.hasPrefix(key) ? 1 : 2
        }
        return paths.enumerated().sorted {
            let a = tier($0.element), b = tier($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    static func item(_ path: String) -> Item {
        let url = URL(fileURLWithPath: path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Item(id: path, title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"),
                    kind: "File", icon: .image(NSWorkspace.shared.icon(forFile: path)), section: "Files", track: false,
                    actions: [
                        Action(title: "Open", icon: "arrow.up.forward.square") { NSWorkspace.shared.open(url) },
                        Action(title: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                        Action(title: "Quick Look", icon: "eye", shortcut: Shortcut(.command, "y")) {
                            shell("/usr/bin/qlmanage", "-p", path)
                        },
                        .copy("Copy Path", shortcut: Shortcut([.command, .shift], "p")) { path },
                        Action(title: "Copy File", icon: "doc.on.doc", shortcut: Shortcut([.command, .shift], "c")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([url as NSURL])
                            HUD.show("Copied File")
                        },
                        Action(title: "Move to Trash", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true) {
                            NSWorkspace.shared.recycle([url])
                            HUD.show("Moved to Trash")
                        },
                    ])
    }
}
