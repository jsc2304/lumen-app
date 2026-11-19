import AppKit
import UniformTypeIdentifiers

/// A saved link: a URL, a file or folder path, or an app deeplink. `{query}`, `{argument}` and
/// `{argument name="…"}` mark where text typed at search time goes (Raycast's syntax).
struct Quicklink: Codable {
    var id = UUID()
    var name: String
    var link: String
    var openWith = ""   // application name or path; empty opens with the default app
}

extension Quicklink {
    /// Only name and link are required: a decode that fails on a missing key (a file from an older version) would
    /// make the list load as empty, and the next save would overwrite the user's quicklinks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        link = try c.decode(String.self, forKey: .link)
        openWith = try c.decodeIfPresent(String.self, forKey: .openWith) ?? ""
    }
}

/// Quicklinks, web searches and URLs typed into the search.
enum Quicklinks {
    private static let file = "quicklinks.json"
    private(set) static var all: [Quicklink] = load()

    /// First run (no file yet) starts with the usual web searches.
    private static func load() -> [Quicklink] {
        if let saved: [Quicklink] = Store.load(file) { return saved }
        guard !FileManager.default.fileExists(atPath: Store.dir.appendingPathComponent(file).path) else { return [] }
        let seeded = [
            ("Google", "https://www.google.com/search?q={query}"),
            ("DuckDuckGo", "https://duckduckgo.com/?q={query}"),
            ("Bing", "https://www.bing.com/search?q={query}"),
            ("Wikipedia", "https://en.wikipedia.org/w/index.php?search={query}"),
            ("YouTube", "https://www.youtube.com/results?search_query={query}"),
            ("GitHub Search", "https://github.com/search?q={query}"),
            ("Google Maps", "https://www.google.com/maps/search/{query}"),
            ("Google Translate", "https://translate.google.com/?sl=auto&tl=en&text={query}&op=translate"),
        ].map { Quicklink(name: $0.0, link: $0.1) }
        Store.save(seeded, file)
        return seeded
    }

    private static func update(_ change: (inout [Quicklink]) -> Void) {
        change(&all)
        Store.save(all, file)
        Launcher.shared.reload()
    }

    // MARK: Root

    static func commands() -> [Item] {
        [.command("ql.create", "Create Quicklink", kind: "Quicklink", icon: "link.badge.plus",
                  keywords: ["new", "add", "web search", "bookmark"], closes: false) { form(nil) },
         .command("ql.search", "Search Quicklinks", kind: "Quicklink", icon: "link",
                  keywords: ["bookmarks", "web searches", "links"], closes: false) {
            Launcher.shared.push(.list(ListSpec(title: "Quicklinks", placeholder: "Search quicklinks…") { items(matching: $0) }))
        }] + all.map { item($0, listed: false) }
    }

    /// Items built from the query itself: a quicklink name plus its argument, a URL, or an existing path.
    /// Runs on every keystroke, so it only does string checks and one stat.
    static func queryItems(_ q: String) -> [Item] {
        if let path = existingPath(q) { return [pathItem(path, typed: q)] }
        if let url = webURL(q) {
            return [Item(id: "ql.url", title: "Open URL", subtitle: url.absoluteString, kind: "URL", icon: .symbol("globe"), track: false,
                         actions: [Action(title: "Open in Browser", icon: "arrow.up.forward.square") { NSWorkspace.shared.open(url) },
                                   .copy("Copy URL") { url.absoluteString }])]
        }
        let hits = all.compactMap { ql -> (ql: Quicklink, score: Int, rest: String)? in
            guard let m = split(q, name: ql.name), !arguments(in: ql.link).isEmpty else { return nil }
            return (ql, m.score, m.rest)
        }
        let best = hits.map(\.score).max()
        return hits.filter { $0.score == best }.map {
            filledItem($0.ql, $0.rest, id: "ql.open." + $0.ql.id.uuidString, title: "Open " + $0.ql.name, subtitle: $0.rest, kind: "Quicklink")
        }
    }

    /// Web searches offered at the end of every non-empty search; edit the Google or DuckDuckGo quicklink to change them.
    static func fallbacks(_ q: String) -> [Item] {
        ["Google", "DuckDuckGo"].compactMap { engine in
            guard let ql = all.first(where: { $0.name.caseInsensitiveCompare(engine) == .orderedSame }),
                  !arguments(in: ql.link).isEmpty else { return nil }
            return filledItem(ql, q, id: "ql.search." + engine.lowercased(), title: "Search \(engine) for '\(q)'", kind: "Web Search")
        }
    }

    private static func filledItem(_ ql: Quicklink, _ argument: String, id: String, title: String,
                                   subtitle: String = "", kind: String) -> Item {
        Item(id: id, title: title, subtitle: subtitle, kind: kind, icon: .symbol("magnifyingglass"), track: false, actions: [
            Action(title: "Open Quicklink", icon: "arrow.up.forward.square") { launch(ql, [argument]) },
            .copy("Copy Link") { fill(ql.link, [argument]) },
        ])
    }

    private static func pathItem(_ path: String, typed: String) -> Item {
        let url = URL(fileURLWithPath: path)
        return Item(id: "ql.path", title: "Open Path", subtitle: typed, kind: "Path", icon: .image(NSWorkspace.shared.icon(forFile: path)),
                    track: false, actions: [
                        Action(title: "Open", icon: "arrow.up.forward.square") { NSWorkspace.shared.open(url) },
                        Action(title: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                        .copy("Copy Path", shortcut: Shortcut([.command, .shift], "p")) { path },
                    ])
    }

    // MARK: List and row actions

    private static func items(matching q: String) -> [Item] {
        let rows = all.map { ($0, max(matchScore(q, $0.name), $0.link.localizedCaseInsensitiveContains(q) ? 10 : 0)) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { item($0.0, listed: true) }
        guard rows.isEmpty else { return rows }
        return [Item(id: "ql.none", title: q.isEmpty ? "No Quicklinks" : "No matching quicklinks", icon: .symbol("link"), track: false,
                     actions: [createAction, importAction])]
    }

    /// Root entries (`listed` false) are ranked and decorated by Root; list rows also carry create, export and import.
    private static func item(_ ql: Quicklink, listed: Bool) -> Item {
        let id = ql.id
        let hasArgument = !arguments(in: ql.link).isEmpty
        var actions: [Action] = [
            Action(title: "Open Quicklink", icon: "arrow.up.forward.square", closes: !hasArgument, run: live(id) {
                if arguments(in: $0.link).isEmpty { launch($0, []) } else { askArguments($0) }
            }),
            .copy("Copy Link") { ql.link },
            Action(title: "Edit Quicklink", icon: "pencil", shortcut: Shortcut(.command, "e"), closes: false, run: live(id) { form($0) }),
            Action(title: "Duplicate Quicklink", icon: "plus.square.on.square", shortcut: Shortcut(.command, "d"), closes: false,
                   run: live(id) { duplicate($0) }),
            Action(title: "Delete Quicklink", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false,
                   run: live(id) { delete($0) }),
        ]
        if listed { actions += [createAction, exportAction, importAction] }
        let icon = hasArgument ? "magnifyingglass" : isFilePath(ql.link) ? "folder" : "link"
        return Item(id: "ql." + id.uuidString, title: ql.name, subtitle: ql.link, kind: "Quicklink", icon: .symbol(icon),
                    keywords: ["quicklink"], track: !listed, actions: actions)
    }

    /// Runs `body` on the current version of the quicklink. Root entries are built once, so they can be out of date.
    private static func live(_ id: UUID, _ body: @escaping (Quicklink) -> Void) -> () -> Void {
        { if let ql = all.first(where: { $0.id == id }) { body(ql) } else { HUD.show("This quicklink no longer exists") } }
    }

    private static var createAction: Action {
        Action(title: "Create Quicklink", icon: "plus", shortcut: Shortcut(.command, "n"), closes: false) { form(nil) }
    }

    private static func duplicate(_ ql: Quicklink) {
        update { list in
            let copy = Quicklink(name: ql.name + " Copy", link: ql.link, openWith: ql.openWith)
            list.insert(copy, at: list.firstIndex { $0.id == ql.id }.map { $0 + 1 } ?? list.count)
        }
        HUD.show("Duplicated Quicklink")
    }

    private static func delete(_ ql: Quicklink) {
        guard confirmed("Delete the quicklink “\(ql.name)”?") else { return }
        update { list in list.removeAll { $0.id == ql.id } }
        HUD.show("Deleted Quicklink")
    }

    /// The alert takes key focus from the panel and hides it; bring the list back afterwards.
    private static func confirmed(_ question: String) -> Bool {
        let ok = confirm(question)
        PanelController.shared.show(reset: false)
        return ok
    }

    // MARK: Forms

    /// Create (nil) or edit.
    private static func form(_ existing: Quicklink?) {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        Launcher.shared.push(.form(FormSpec(
            title: existing == nil ? "Create Quicklink" : "Edit Quicklink",
            fields: [FormField(label: "Name", value: existing?.name ?? "", placeholder: "Wikipedia"),
                     FormField(label: "Link", value: existing?.link ?? "",
                               placeholder: "https://example.com/search?q={query}, a file path or an app link"),
                     FormField(label: "Open With (optional)", value: existing?.openWith ?? "", placeholder: "Application name or path, e.g. Safari")],
            submitTitle: existing == nil ? "Create Quicklink" : "Save Quicklink") { v in
                let ql = Quicklink(id: existing?.id ?? UUID(), name: trim(v[0]), link: trim(v[1]), openWith: trim(v[2]))
                if let error = problem(ql) { return error }
                if !ql.openWith.isEmpty, app(ql.openWith) == nil { return "Application not found: " + ql.openWith }
                update { list in
                    if let i = list.firstIndex(where: { $0.id == ql.id }) { list[i] = ql } else { list.append(ql) }
                }
                return nil
            }))
    }

    /// One field per argument; opens the link on ⌘↵.
    private static func askArguments(_ ql: Quicklink) {
        let labels = arguments(in: ql.link)
        Launcher.shared.push(.form(FormSpec(title: ql.name, fields: labels.map { FormField(label: $0) }, submitTitle: "Open") { values in
            guard values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return "Enter " + labels[0].lowercased() + "."
            }
            PanelController.shared.hide()
            launch(ql, values)
            return nil
        }))
    }

    // MARK: Export and import

    /// Raycast's file shape.
    private struct Exported: Codable {
        var name: String
        var link: String
        var openWith: String?
    }

    static func exportData(_ list: [Quicklink]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(list.map { Exported(name: $0.name, link: $0.link, openWith: $0.openWith.isEmpty ? nil : $0.openWith) })
    }

    /// The quicklinks in an export that `existing` does not have yet (same name and link); nil if it is not an export.
    static func imported(_ data: Data, existing: [Quicklink]) -> [Quicklink]? {
        guard let list = try? JSONDecoder().decode([Exported].self, from: data) else { return nil }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var known = Set(existing.map { ($0.name + "\n" + $0.link).lowercased() })
        return list.compactMap { e in
            let ql = Quicklink(name: trim(e.name), link: trim(e.link), openWith: trim(e.openWith ?? ""))
            guard !ql.name.isEmpty, !ql.link.isEmpty, known.insert((ql.name + "\n" + ql.link).lowercased()).inserted else { return nil }
            return ql
        }
    }

    private static var exportAction: Action {
        Action(title: "Export Quicklinks…", icon: "square.and.arrow.up", shortcut: Shortcut([.command, .shift], "e")) {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Quicklinks.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try (exportData(all) ?? Data()).write(to: url, options: .atomic)
                HUD.show("Exported \(all.count) Quicklinks")
            } catch {
                HUD.show("Export failed: " + error.localizedDescription)
            }
        }
    }

    private static var importAction: Action {
        Action(title: "Import Quicklinks…", icon: "square.and.arrow.down", shortcut: Shortcut([.command, .shift], "i")) {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url), let new = imported(data, existing: all) else {
                HUD.show("Not a Quicklinks export")
                return
            }
            update { $0 += new }
            HUD.show("Imported " + (new.count == 1 ? "1 Quicklink" : "\(new.count) Quicklinks"))
        }
    }

    // MARK: Opening

    static func launch(_ ql: Quicklink, _ values: [String]) {
        let text = fill(ql.link, values)
        guard let url = target(text) else { HUD.show("Can't open " + text.prefix(60)); return }
        guard !ql.openWith.isEmpty else {
            if !NSWorkspace.shared.open(url) { HUD.show("Can't open " + text.prefix(60)) }
            return
        }
        guard let app = app(ql.openWith) else { HUD.show("Application not found: " + ql.openWith); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { HUD.show(error.localizedDescription) } }
        }
    }

    /// An application given by name ("Safari") or path.
    static func app(_ spec: String) -> URL? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.contains("/") {
            let path = (s as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let name = s.hasSuffix(".app") ? String(s.dropLast(4)) : s
        return Apps.items().first { ([$0.title] + $0.keywords).contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            .map { URL(fileURLWithPath: $0.id) }
    }

    // MARK: Placeholders (pure)

    private static let placeholder = try! NSRegularExpression(pattern: #"\{\s*(argument|query)\b([^}]*)\}"#, options: .caseInsensitive)
    private static let argumentName = try! NSRegularExpression(pattern: #"name\s*=\s*"([^"]*)""#, options: .caseInsensitive)
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func placeholders(in link: String) -> [(range: Range<String.Index>, label: String)] {
        guard link.contains("{") else { return [] }
        return placeholder.matches(in: link, range: NSRange(link.startIndex..., in: link)).compactMap { m in
            guard let range = Range(m.range, in: link), let keyword = Range(m.range(at: 1), in: link),
                  let attrs = Range(m.range(at: 2), in: link) else { return nil }
            let attributes = String(link[attrs])
            let name = argumentName.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes))
                .flatMap { Range($0.range(at: 1), in: attributes) }
                .map { String(attributes[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
            return (range, name.isEmpty ? link[keyword].capitalized : name)
        }
    }

    /// Labels of the arguments in `link`, in order of appearance, without repeats ("Query", "Argument" or the given name).
    static func arguments(in link: String) -> [String] {
        var seen = Set<String>()
        return placeholders(in: link).map(\.label).filter { seen.insert($0.lowercased()).inserted }
    }

    /// `link` with its placeholders replaced by the values, one per argument in `arguments(in:)` order.
    /// Values are percent-encoded for a URL query component; file paths take them as typed.
    static func fill(_ link: String, _ values: [String]) -> String {
        let labels = arguments(in: link).map { $0.lowercased() }
        let isPath = isFilePath(link)
        var out = "", cursor = link.startIndex
        for p in placeholders(in: link) {
            out += link[cursor..<p.range.lowerBound]
            let i = labels.firstIndex(of: p.label.lowercased())!
            let value = i < values.count ? values[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            out += isPath ? value : encode(value)
            cursor = p.range.upperBound
        }
        return out + link[cursor...]
    }

    /// Everything except letters, digits and - . _ ~ becomes %XX, so spaces, &, #, + and umlauts survive in a query.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Checks name and link of a quicklink; nil when fine.
    static func problem(_ ql: Quicklink) -> String? {
        if ql.name.isEmpty { return "Enter a name." }
        if ql.link.isEmpty { return "Enter a link." }
        if target(fill(ql.link, arguments(in: ql.link).map { _ in "x" })) == nil { return "That is not a URL or a file path." }
        return nil
    }

    // MARK: URLs, paths and keywords (pure)

    private static func isFilePath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") || t.hasPrefix("~")
    }

    /// What a quicklink's link opens: a file, a web address or any other `scheme:` deeplink.
    static func target(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFilePath(t) { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath) }
        if let url = webURL(t) { return url }
        guard t.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:\S"#, options: .regularExpression) != nil else { return nil }
        return URL(string: t)
    }

    // Only these count as a domain when typed bare ("github.com"), so "main.swift", "Safari.app" or
    // "notes.md" are not taken for web addresses.
    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "dev", "ai", "co", "me", "tv", "info", "biz", "xyz", "cloud", "tech", "online",
        "site", "page", "de", "uk", "fr", "nl", "es", "it", "ch", "at", "eu", "us", "ca", "au", "se", "dk", "fi", "be", "pt", "ie",
        "jp", "cn", "in", "br", "no",
    ]

    /// "https://…", "github.com/x", "localhost:3000" and "127.0.0.1:8080/x" as a URL; nil for anything else.
    static func webURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if let r = text.range(of: "://") {
            guard r.upperBound < text.endIndex,
                  text[..<r.lowerBound].range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: text)
        }
        let authority = text.prefix { !"/?#".contains($0) }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        let digits = { (s: Substring) in !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) } }
        guard parts.count <= 2, parts.count == 1 || digits(parts[1]) else { return nil }
        let labels = parts[0].lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let local = labels == ["localhost"] || (labels.count == 4 && labels.allSatisfy { digits($0) && (Int($0) ?? 256) <= 255 })
        let domain = labels.count >= 2 && topLevelDomains.contains(String(labels.last!)) &&
            labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        guard local || domain else { return nil }
        return URL(string: (local ? "http://" : "https://") + text)
    }

    /// The expanded path when `q` starts with "/" or "~/" and exists.
    static func existingPath(_ q: String) -> String? {
        guard q.hasPrefix("/") || q.hasPrefix("~/") else { return nil }
        let path = (q as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The text after the quicklink's name (or its first word) when `q` continues with a space and more text.
    /// A longer key scores higher, and the full name beats a first word of the same length.
    static func split(_ q: String, name: String) -> (score: Int, rest: String)? {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        for key in [name, first] where !key.isEmpty {
            guard let r = q.range(of: key + " ", options: [.anchored, .caseInsensitive]) else { continue }
            let rest = q[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return (key.count * 2 + (key == name ? 1 : 0), rest) }
        }
        return nil
    }
}
