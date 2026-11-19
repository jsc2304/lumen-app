import AppKit
import Combine
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Search Files (a dedicated Spotlight view with filters) and Screenshots (search, paste latest).
/// Both lists read the Spotlight index through NSMetadataQuery: nothing blocks, results arrive by notification.
enum Files {
    static let limit = 60

    static func commands() -> [Item] {
        [.command("files.search", "Search Files", kind: "Files", icon: "doc.text.magnifyingglass",
                  keywords: ["find", "file", "files", "spotlight", "datei", "dateien", "suchen"], closes: false) {
            push(.files)
        },
         .command("files.screenshots", "Search Screenshots", kind: "Files", icon: "camera.viewfinder",
                  keywords: ["screenshot", "screenshots", "screen capture", "bildschirmfoto", "bildschirmfotos"], closes: false) {
            push(.screenshots)
        },
         .command("files.paste-latest-screenshot", "Paste Latest Screenshot", kind: "Files", icon: "photo.on.rectangle.angled",
                  keywords: ["screenshot", "paste", "latest", "last", "newest", "bildschirmfoto", "einfügen"]) {
            pasteLatest()
        }]
    }

    private static func push(_ mode: Mode) {
        let listing = Listing(mode)
        Launcher.shared.push(.list(ListSpec(title: mode.title, placeholder: mode.placeholder, showsDetail: true) { listing.items($0) }))
    }

    // MARK: Query language (checked in checks/CheckFiles.swift)

    /// What a typed query asks for. Plain words are name parts; `kind:`, `in:`, `content:`, `ext:` and `modified:` filter.
    struct Query {
        var terms: [String] = []     // the name contains all of these
        var content: [String] = []   // the text inside contains all of these
        var types: [String] = []     // content types, any of
        var ext: String? = nil
        var scope: String? = nil     // absolute folder path
        var since: Date? = nil
        var error: String? = nil

        /// A bare name of one letter matches half the disk, so it needs two letters or a filter.
        var isSearchable: Bool {
            terms.contains { $0.count >= 2 } || content.contains { $0.count >= 2 } || !types.isEmpty || ext != nil || since != nil
        }
    }

    /// Words split at spaces; a double-quoted stretch stays together, so `in:"~/My Folder"` and `"annual report"` work.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = [], word = "", quoted = false
        for c in text {
            if c == "\"" {
                quoted.toggle()
            } else if c.isWhitespace, !quoted {
                if !word.isEmpty { out.append(word) }
                word = ""
            } else {
                word.append(c)
            }
        }
        return word.isEmpty ? out : out + [word]
    }

    private static let filters = ["kind", "in", "content", "ext", "modified"]

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Query {
        var q = Query()
        for token in tokens(text) {
            guard let colon = token.firstIndex(of: ":"), case let key = token[..<colon].lowercased(), filters.contains(key) else {
                q.terms.append(token)
                continue
            }
            let value = String(token[token.index(after: colon)...])
            if value.isEmpty { continue }   // still being typed
            switch key {
            case "kind": if let t = types(for: value) { q.types = t } else { q.error = "Unknown kind “\(value)”" }
            case "in": q.scope = scope(value)
            case "content": q.content += value.split(whereSeparator: \.isWhitespace).map(String.init)
            case "ext": q.ext = value.drop(while: { $0 == "." }).lowercased()
            default: if let d = since(value, now: now, calendar: calendar) { q.since = d } else { q.error = "Unknown period “\(value)”" }
            }
        }
        if q.ext == "" { q.ext = nil }
        return q
    }

    private static let kinds: [(names: [String], types: [String])] = [
        (["pdf"], ["com.adobe.pdf"]),
        (["image", "images", "picture", "pictures", "photo", "photos"], ["public.image"]),
        (["folder", "folders", "directory"], ["public.folder"]),
        (["app", "apps", "application", "applications"], ["com.apple.application-bundle"]),
        (["doc", "docs", "document", "documents"], ["public.composite-content"]),
        (["text"], ["public.plain-text"]),
        // Not public.movie: it also covers .ts, so every TypeScript file would be a video.
        (["video", "videos", "movie", "movies"], ["public.mpeg-4", "com.apple.quicktime-movie", "public.avi", "org.matroska.mkv",
                                                  "org.webmproject.webm", "public.mpeg", "public.avchd-mpeg-2-transport-stream"]),
        (["audio", "music", "sound"], ["public.audio"]),
        (["archive", "archives"], ["public.archive"]),
        (["code", "source"], ["public.source-code"]),
        (["presentation", "slides"], ["public.presentation"]),
        (["spreadsheet", "sheet"], ["public.spreadsheet"]),
    ]

    /// Content types behind `kind:`: a word from the list above or any file extension that macOS knows (swift, md, zip, …).
    static func types(for kind: String) -> [String]? {
        let k = kind.lowercased()
        if let match = kinds.first(where: { $0.names.contains(k) }) { return match.types }
        guard let type = UTType(filenameExtension: k), type.isDeclared else { return nil }
        return [type.identifier]
    }

    /// A folder for `in:`: `~/Documents`, `/Volumes/Disk` or `Documents` (relative to the home folder).
    static func scope(_ value: String) -> String {
        let path = (value as NSString).expandingTildeInPath
        return ((path.hasPrefix("/") ? path : NSHomeDirectory() + "/" + path) as NSString).standardizingPath
    }

    /// Start of the `modified:` period: today since midnight, week the last 7 days, month the last month.
    static func since(_ period: String, now: Date, calendar: Calendar) -> Date? {
        switch period.lowercased() {
        case "today": return calendar.startOfDay(for: now)
        case "week": return calendar.date(byAdding: .day, value: -7, to: now)
        case "month": return calendar.date(byAdding: .month, value: -1, to: now)
        default: return nil
        }
    }

    /// NSMetadataQuery throws on a compound predicate with a single part.
    private static func compound(_ parts: [NSPredicate], any: Bool = false) -> NSPredicate {
        if parts.count == 1 { return parts[0] }
        return any ? NSCompoundPredicate(orPredicateWithSubpredicates: parts) : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    static func predicate(_ q: Query) -> NSPredicate? {
        var all = q.terms.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        all += q.content.map { NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", $0) }
        if !q.types.isEmpty {
            all.append(compound(q.types.map { NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", $0) }, any: true))
        }
        if let ext = q.ext { all.append(NSPredicate(format: "%K ENDSWITH[cd] %@", NSMetadataItemFSNameKey, "." + ext)) }
        if let since = q.since { all.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, since as NSDate)) }
        return all.isEmpty ? nil : compound(all)
    }

    // MARK: Formatting and files

    private static let byteCount: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ bytes: Int64?) -> String { bytes.map { byteCount.string(fromByteCount: $0) } ?? "—" }

    static func date(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "—" }

    /// The file as PNG: a PNG stays as it is, anything else macOS can draw (JPEG, HEIC, TIFF, PDF) is converted.
    static func pngData(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSImage(data: data)?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
    }

    /// Whether Lumen may read the file. In a protected folder this is where macOS asks for permission.
    static func canRead(_ path: String) -> Bool { FileHandle(forReadingAtPath: path) != nil }

    /// Reads the file as PNG off the main thread (it may sit in a protected or cloud folder) and hands it over on the
    /// main thread; tells the user when the file cannot be read.
    private static func withPNG(_ path: String, _ use: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let png = pngData(of: URL(fileURLWithPath: path))
            DispatchQueue.main.async { if let png { use(png) } else { HUD.show("Lumen cannot read this file") } }
        }
    }

    private static func put(_ png: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    private static func pasteIntoFrontmostApp(_ png: Data) {
        put(png)
        later { AX.key(9, .maskCommand) }
    }

    // MARK: Screenshots

    private static let screenshot = NSPredicate(format: "kMDItemIsScreenCapture == 1")

    /// Screenshots that also match the typed filters.
    static func screenshotPredicate(_ q: Query) -> NSPredicate { compound([screenshot] + [predicate(q)].compactMap { $0 }) }

    private static let screenshotSort = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)]
    private static let screenshotScopes: [Any] = [NSMetadataQueryLocalComputerScope]

    /// Where macOS saves screenshots: the folder set with the screencapture `location` default (may start with ~), else the Desktop.
    static func screenshotFolder(location: String? = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")) -> URL {
        let path = (location.map { ($0 as NSString).expandingTildeInPath } ?? "").trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() + "/Desktop" : path, isDirectory: true)
    }

    /// The newest screenshot image in `folder` by creation date. macOS marks a screenshot (kMDItemIsScreenCapture) when it writes
    /// the file, so it is found here before Spotlight has indexed it. May touch a protected folder: call it off the main thread.
    static func newestScreenshotFile(in folder: URL) -> (path: String, created: Date)? {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentTypeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { url -> (path: String, created: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), let created = values.creationDate,
                  values.contentType?.conforms(to: .image) == true,
                  getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 else { return nil }
            return (url.path, created)
        }.max { $0.created < $1.created }
    }

    /// Spotlight's newest screenshot against the newest one in the folder: Spotlight may not know a new one for a second or
    /// two, and would hand back the one before it. The newer wins (Spotlight on a tie, it may be in another folder).
    static func latestScreenshot(spotlight: (path: String, created: Date?)?, folder: (path: String, created: Date)?) -> String? {
        guard let folder else { return spotlight?.path }
        guard let spotlight else { return folder.path }
        return folder.created > (spotlight.created ?? .distantPast) ? folder.path : spotlight.path
    }

    private static func pasteLatest() {
        let search = Spotlight(live: false)
        search.onChange = { [search] hits in
            search.onChange = nil   // ends the cycle this closure makes with `search`
            let indexed = hits.first.map { (path: $0.path, created: $0.created) }
            DispatchQueue.global(qos: .userInitiated).async {
                let path = latestScreenshot(spotlight: indexed, folder: newestScreenshotFile(in: screenshotFolder()))
                DispatchQueue.main.async {
                    guard let path else { return HUD.show("No screenshots found") }
                    withPNG(path, pasteIntoFrontmostApp)
                }
            }
        }
        search.start(screenshot, scopes: screenshotScopes, sort: screenshotSort)
    }

    // MARK: Open With

    /// Pushes the apps that can open `url`, the default one first.
    private static func openWith(_ url: URL) {
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: url)
        func name(_ app: URL) -> String { app.deletingPathExtension().lastPathComponent }
        func order(_ app: URL) -> (Int, String) { (app == defaultApp ? 0 : 1, name(app).lowercased()) }
        let apps = workspace.urlsForApplications(toOpen: url).sorted { order($0) < order($1) }
        guard !apps.isEmpty else { HUD.show("No app can open this file"); return }
        let rows = apps.map { app in
            Item(id: app.path, title: name(app), subtitle: app.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                 kind: app == defaultApp ? "Default" : "", icon: .image(workspace.icon(forFile: app.path)), track: false,
                 actions: [Action(title: "Open With " + name(app), icon: "arrow.up.forward.app") {
                     workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                         if error != nil { DispatchQueue.main.async { HUD.show("Lumen cannot open this file") } }
                     }
                 }])
        }
        Launcher.shared.push(.list(ListSpec(title: "Open With…", placeholder: "Search apps…") { query in
            query.isEmpty ? rows : rows.filter { matchScore(query, $0.title) > 0 }
        }))
    }

    private static let help = """
        Type part of a file name. Add filters anywhere in the query:

        `kind:pdf` also image, folder, app, doc, text, video, audio, archive, code or a file type such as `swift`
        `in:~/Documents` only inside that folder; put paths with spaces in quotes: `in:"~/My Folder"`
        `content:invoice` text inside files
        `ext:swift` file extension
        `modified:today` or `week` or `month`
        """
}

// MARK: Spotlight

extension Files {
    private enum Mode {
        case files, screenshots

        var title: String { self == .files ? "Search Files" : "Search Screenshots" }
        var placeholder: String { self == .files ? "Search files… kind: in: content: ext: modified:" : "Search screenshots… modified:week" }
    }

    /// One Spotlight result with the attributes the lists show.
    private struct Hit {
        let path: String
        let kind: String
        let size: Int64?
        let created: Date?
        let modified: Date?
        let pixels: String?

        init?(_ m: NSMetadataItem) {
            guard let path = m.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            self.path = path
            kind = m.value(forAttribute: NSMetadataItemKindKey) as? String ?? "File"
            size = (m.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value   // nil for folders
            created = m.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
            modified = m.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            if let w = (m.value(forAttribute: "kMDItemPixelWidth") as? NSNumber)?.intValue,
               let h = (m.value(forAttribute: "kMDItemPixelHeight") as? NSNumber)?.intValue {
                pixels = "\(w) × \(h)"
            } else {
                pixels = nil
            }
        }
    }

    /// An NSMetadataQuery that reports its first `Files.limit` results. `live` keeps it running and reports every
    /// change (new screenshots); otherwise it stops after the first gather.
    private final class Spotlight: NSObject {
        private let query = NSMetadataQuery()
        private let live: Bool
        var onChange: (([Hit]) -> Void)?

        init(live: Bool) {
            self.live = live
            super.init()
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: query)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            query.stop()
        }

        func start(_ predicate: NSPredicate, scopes: [Any], sort: [NSSortDescriptor]) {
            query.stop()
            query.predicate = predicate
            query.searchScopes = scopes
            query.sortDescriptors = sort
            query.start()
        }

        func stop() { query.stop() }

        @objc private func changed() {
            // A notification that was already queued when the query restarted belongs to the old one.
            guard !query.isStopped, !query.isGathering else { return }
            let hits = (0..<min(query.resultCount, Files.limit)).compactMap { (query.result(at: $0) as? NSMetadataItem).flatMap(Hit.init) }
            if !live { query.stop() }
            onChange?(hits)
        }
    }

    /// The list behind Search Files and Search Screenshots. `items` only reads what the last gather left; Spotlight and
    /// the thumbnail generator fill it in and reload the list.
    private final class Listing {
        private static func note(_ title: String, _ symbol: String, detail: Detail? = nil) -> Item {
            Item(id: "files.status", title: title, kind: "", icon: .symbol(symbol), track: false, actions: [], detail: detail)
        }

        private static let large = CGSize(width: 400, height: 220)   // detail pane
        private static let small = CGSize(width: 44, height: 44)     // row icon

        private let mode: Mode
        private let spotlight: Spotlight
        private var results: [Item] = []
        private var status: Item?          // hint, problem, "Searching…" or "no results"; replaces the results while set
        private var current: String?       // the query text the results belong to
        private var pending = Set<String>()
        private var reloadScheduled = false
        private var selection: AnyCancellable?

        init(_ mode: Mode) {
            self.mode = mode
            spotlight = Spotlight(live: mode == .screenshots)
            spotlight.onChange = { [weak self] in self?.gathered($0) }
            // Arrowing to another row asks for its thumbnail; the list closure cannot see the selection.
            selection = Launcher.shared.$selection.sink { [weak self] _ in
                DispatchQueue.main.async { self?.loadSelected() }
            }
        }

        /// Whether the panel is showing this list; a list under another one (Open With) must not reload the wrong one.
        private var isCurrent: Bool {
            if case .list(let spec) = Launcher.shared.mode { return spec.title == mode.title }
            return false
        }

        func items(_ typed: String) -> [Item] {
            let text = typed.trimmingCharacters(in: .whitespaces)
            if text != current { start(text) }
            return status.map { [$0] } ?? results
        }

        private func start(_ text: String) {
            current = text
            var q = Files.parse(text)
            if let folder = q.scope, q.error == nil {
                var isFolder: ObjCBool = false
                if !(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue) {
                    q.error = "No folder at " + (folder as NSString).abbreviatingWithTildeInPath
                }
            }
            let criteria = Files.predicate(q)
            if q.error != nil || (mode == .files && !q.isSearchable) {
                spotlight.stop()
                results = []
                status = Self.note(q.error ?? "Search Files", q.error == nil ? "magnifyingglass" : "exclamationmark.triangle",
                                   detail: mode == .files ? Detail(markdown: Files.help) : nil)
                return
            }
            if results.isEmpty { status = Self.note("Searching…", "hourglass") }
            switch mode {
            case .files:
                // Applications live outside the home folder, so `kind:app` needs their folders too.
                let scopes: [Any] = [NSMetadataQueryUserHomeScope, "/Applications", "/System/Applications"]
                spotlight.start(criteria ?? NSPredicate(value: false), scopes: q.scope.map { [$0] } ?? scopes,
                                sort: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false),
                                       NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)])
            case .screenshots:
                spotlight.start(Files.screenshotPredicate(q), scopes: q.scope.map { [$0] } ?? Files.screenshotScopes, sort: Files.screenshotSort)
            }
        }

        private func gathered(_ hits: [Hit]) {
            // Rows that stay keep the thumbnails they already have.
            let old = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            results = hits.map { hit in
                var item = mode == .files ? fileItem(hit) : screenshotItem(hit)
                if let o = old[item.id] {
                    item.icon = o.icon
                    item.detail?.image = o.detail?.image
                }
                return item
            }
            status = results.isEmpty ? Self.note(mode == .files ? "No files found" : "No screenshots found", "questionmark.folder") : nil
            if isCurrent { Launcher.shared.reload() }
            if mode == .screenshots {
                for item in results { if case .symbol = item.icon { thumbnail(item.id, Self.small) { $0.icon = .image($1) } } }
            }
            loadSelected()
        }

        // MARK: Thumbnails

        private func loadSelected() {
            guard isCurrent, let id = Launcher.shared.selected?.id, let item = results.first(where: { $0.id == id }),
                  item.detail?.image == nil else { return }
            thumbnail(id, Self.large) { $0.detail?.image = $1 }
        }

        /// Asks QuickLook for the file's thumbnail and puts it into the item through `set`. A file without a preview gets
        /// its icon; one Lumen cannot read gets the icon too, and the HUD says so when it is the selected row.
        private func thumbnail(_ path: String, _ size: CGSize, _ set: @escaping (inout Item, NSImage) -> Void) {
            let key = path + "\(size.width)"
            guard pending.insert(key).inserted else { return }
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size,
                                                       scale: screenWithMouse()?.backingScaleFactor ?? 2, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                let unreadable = rep == nil || (rep?.type == .icon && !Files.canRead(path))
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(key)
                    guard let i = self.results.firstIndex(where: { $0.id == path }) else { return }
                    set(&self.results[i], rep?.nsImage ?? NSWorkspace.shared.icon(forFile: path))
                    if unreadable, Launcher.shared.selected?.id == path, self.isCurrent { HUD.show("Lumen cannot read this file") }
                    self.reloadSoon()
                }
            }
        }

        /// Thumbnails arrive in bursts (one per screenshot row): one reload for all of them.
        private func reloadSoon() {
            guard !reloadScheduled else { return }
            reloadScheduled = true
            later(0.1) { [weak self] in
                self?.reloadScheduled = false
                if self?.isCurrent == true { Launcher.shared.reload() }
            }
        }

        // MARK: Rows

        private func fileItem(_ hit: Hit) -> Item {
            var item = FileSearch.item(hit.path)
            let reused = item.actions
            func reuse(_ title: String) -> Action? { reused.first { $0.title == title } }
            let url = URL(fileURLWithPath: hit.path)
            item.subtitle = url.deletingLastPathComponent().lastPathComponent
            item.kind = ""
            item.section = ""
            item.actions = [
                reuse("Open"), reuse("Show in Finder"), reuse("Quick Look"),
                Action(title: "Open With…", icon: "square.and.arrow.up.on.square", shortcut: Shortcut([.command, .shift], "o"), closes: false) {
                    Files.openWith(url)
                },
                reuse("Copy Path"), reuse("Copy File"),
                Action.copy("Copy Name", shortcut: Shortcut([.command, .shift], "n")) { url.lastPathComponent },
                trash(hit.path),
            ].compactMap { $0 }
            item.detail = Detail(markdown: "**" + Clipboard.escaped(item.title) + "**",
                                 metadata: [("Kind", hit.kind), ("Size", Files.size(hit.size)), ("Modified", Files.date(hit.modified)),
                                            ("Path", (hit.path as NSString).abbreviatingWithTildeInPath)])
            return item
        }

        private func screenshotItem(_ hit: Hit) -> Item {
            let path = hit.path
            let url = URL(fileURLWithPath: path)
            var metadata = [("Taken", Files.date(hit.created))]
            if let pixels = hit.pixels { metadata.append(("Dimensions", pixels)) }
            metadata += [("Size", Files.size(hit.size)), ("Path", (path as NSString).abbreviatingWithTildeInPath)]
            // The date tells screenshots apart; their file names all start alike and would be cut off in the narrow list.
            return Item(id: path, title: hit.created == nil ? url.lastPathComponent : Files.date(hit.created), kind: "", icon: .symbol("photo"),
                        track: false, actions: [
                            Action(title: "Paste Screenshot", icon: "doc.on.clipboard") { Files.withPNG(path, Files.pasteIntoFrontmostApp) },
                            Action(title: "Copy Screenshot", icon: "doc.on.doc") {
                                Files.withPNG(path) { Files.put($0); HUD.show("Copied Screenshot") }
                            },
                            Action(title: "Open", icon: "arrow.up.forward.square", shortcut: Shortcut(.command, "o")) { NSWorkspace.shared.open(url) },
                            Action(title: "Reveal in Finder", icon: "folder", shortcut: Shortcut([.command, .shift], "r")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            },
                            .copy("Copy Path", shortcut: Shortcut([.command, .shift], "p")) { path },
                            trash(path),
                        ], detail: Detail(metadata: metadata))
        }

        /// Reversible, so no confirmation. The row goes at once; Spotlight needs a moment to notice.
        private func trash(_ path: String) -> Action {
            Action(title: "Move to Trash", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) { [weak self] in
                NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
                    DispatchQueue.main.async {
                        guard error == nil else { HUD.show("Lumen cannot move this file to the Trash"); return }
                        HUD.show("Moved to Trash")
                        self?.remove(path)
                    }
                }
            }
        }

        private func remove(_ path: String) {
            results.removeAll { $0.id == path }
            if results.isEmpty { status = Self.note("No more results", "questionmark.folder") }
            if isCurrent { Launcher.shared.reload() }
        }
    }
}
