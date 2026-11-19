import AppKit
import UniformTypeIdentifiers

/// Script Commands (Raycast's script format) and Apple Shortcuts. Scripts come from the folders in
/// scripts.json, shortcuts from `shortcuts list`; both are cached, so the root search never waits for them.
enum Scripts {
    enum Mode: String, CaseIterable, Codable {
        case silent, compact, fullOutput, inline

        init?(named name: String) {
            let name = name.trimmingCharacters(in: .whitespaces)
            guard let mode = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            self = mode
        }
    }

    struct Argument: Codable, Equatable {
        var placeholder = ""
        var optional = false
        var percentEncoded = false
    }

    struct Script: Codable, Equatable {
        var path: String
        var title: String
        var mode = Mode.fullOutput
        var package = ""
        var icon = ""               // an emoji; anything else gets the default symbol
        var summary = ""
        var needsConfirmation = false
        var directory = ""          // @raycast.currentDirectoryPath as written
        var arguments: [Argument] = []
    }

    /// What a finished process left behind. `status` is -1 when it could not be started.
    struct Output {
        var status: Int32
        var out = ""
        var err = ""
        var timedOut = false
        var flooded = false   // stopped for writing more output than `run` keeps a file for
    }

    private static let defaultDirectory = "~/.config/lumen/scripts"
    private static var directories: [String] = Store.load("scripts.json") ?? [defaultDirectory]
    // The last scan stays on disk: after a launch the entries (and their hotkeys) exist before the first rescan ends.
    private static var scripts: [Script] = Store.load("scripts-cache.json") ?? []
    private static var shortcuts: [String] = Store.load("shortcuts-cache.json") ?? []
    private static var scanned = Date.distantPast
    private static var scanning = false
    private static var rescan = false

    static func commands() -> [Item] {
        refresh()
        return [
            .command("script.create", "Create Script Command", kind: "Script", icon: "plus.square.on.square",
                     keywords: ["new", "add", "raycast", "bash"], closes: false) { createForm() },
            .command("script.search", "Search Script Commands", kind: "Script", icon: "terminal",
                     keywords: ["scripts", "raycast"], closes: false) {
                Launcher.shared.push(.list(ListSpec(title: "Script Commands", placeholder: "Search script commands…",
                                                    showsDetail: true) { scriptRows($0) }))
            },
            .command("script.reload", "Reload Script Commands", kind: "Script", icon: "arrow.clockwise",
                     keywords: ["rescan", "refresh", "shortcuts"]) {
                refresh(force: true)
                HUD.show("Reloading scripts and shortcuts…")
            },
            .command("script.add-dir", "Add Script Directory…", kind: "Script", icon: "folder.badge.plus",
                     keywords: ["folder", "scripts"]) { addDirectory() },
            .command("shortcut.search", "Search Shortcuts", kind: "Shortcut", icon: "square.stack.3d.up",
                     keywords: ["shortcuts", "siri", "apple"], closes: false) {
                Launcher.shared.push(.list(ListSpec(title: "Shortcuts", placeholder: "Search shortcuts…") { shortcutRows($0) }))
            },
        ] + scripts.map { item($0, listed: false) } + shortcuts.map { shortcutItem($0, listed: false) }
    }

    // MARK: Cache

    /// Rescans the script folders and the shortcut list in the background, at most every 30 seconds unless forced.
    static func refresh(force: Bool = false) {
        guard !scanning else { rescan = rescan || force; return }
        guard force || Date().timeIntervalSince(scanned) > 30 else { return }
        scanning = true
        let dirs = directories
        DispatchQueue.global(qos: .utility).async {
            let found = scan(dirs)
            let names = shortcutNames()
            DispatchQueue.main.async {
                scanning = false
                let changed = scanned == .distantPast || found != scripts || (names ?? shortcuts) != shortcuts   // the first scan also ends "Loading…"
                scanned = Date()
                scripts = found
                if let names { shortcuts = names }   // keep the cached names when `shortcuts list` fails
                if changed {
                    Store.save(scripts, "scripts-cache.json")
                    Store.save(shortcuts, "shortcuts-cache.json")
                    Launcher.shared.reload()
                }
                if rescan { rescan = false; refresh(force: true) }
            }
        }
    }

    /// Every executable file with a @raycast.title below the folders. Gives up after 5000 files, so a folder like ~ cannot
    /// make every rescan read the whole disk.
    static func scan(_ dirs: [String]) -> [Script] {
        let fm = FileManager.default
        var found: [Script] = [], seen = Set<String>(), visited = 0
        for dir in dirs {
            let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in files {
                visited += 1
                if visited > 5000 { break }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      fm.isExecutableFile(atPath: url.path), seen.insert(url.path).inserted,
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                // The header sits at the top; never read a whole binary.
                let head = (try? handle.read(upToCount: 16_384)) ?? Data()
                try? handle.close()
                if let script = parse(String(decoding: head, as: UTF8.self), path: url.path) { found.append(script) }
            }
        }
        return found.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    private static func shortcutNames() -> [String]? {
        let o = run("/usr/bin/shortcuts", ["list"], timeout: 20)
        return o.status == 0 ? parseShortcuts(o.out) : nil
    }

    // MARK: Metadata (pure)

    // `# @raycast.title …` in bash, python, ruby and AppleScript's shebang form, `// …` in node and swift, `-- …` in AppleScript.
    private static let header = try! NSRegularExpression(pattern: #"^\s*(?:#|//|--)\s*@raycast\.(\w+)[ \t]*(.*?)\s*$"#)

    private struct ArgumentJSON: Decodable {
        var placeholder: String?
        var optional: Bool?
        var percentEncoded: Bool?
    }

    /// Reads the @raycast.* lines in the first 100 non-empty lines of a file; nil without a title.
    static func parse(_ text: String, path: String) -> Script? {
        var script = Script(path: path, title: "")
        var arguments: [(number: Int, argument: Argument)] = []
        for line in text.split(whereSeparator: \.isNewline).prefix(100).map(String.init) {
            guard let m = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let keyRange = Range(m.range(at: 1), in: line) else { continue }
            let key = String(line[keyRange])
            let value = Range(m.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            switch key {
            case "title": script.title = value
            case "mode": script.mode = Mode(named: value) ?? .fullOutput
            case "packageName": script.package = value
            case "icon": script.icon = value
            case "description": script.summary = value
            case "needsConfirmation": script.needsConfirmation = value.lowercased() == "true"
            case "currentDirectoryPath": script.directory = value
            case _ where key.hasPrefix("argument"):
                // A broken argument stays a plain text field, so the later ones keep their position ($2, $3).
                guard let n = Int(key.dropFirst(8)), (1...3).contains(n) else { continue }
                let json = try? JSONDecoder().decode(ArgumentJSON.self, from: Data(value.utf8))
                arguments.append((n, Argument(placeholder: json?.placeholder ?? "", optional: json?.optional ?? false,
                                              percentEncoded: json?.percentEncoded ?? false)))
            default: break
            }
        }
        guard !script.title.isEmpty else { return nil }
        script.arguments = arguments.sorted { $0.number < $1.number }.map(\.argument)
        return script
    }

    static func label(_ i: Int, _ a: Argument) -> String { a.placeholder.isEmpty ? "Argument \(i + 1)" : a.placeholder }

    /// The first required argument left empty, as a form error.
    static func missing(_ script: Script, _ typed: [String]) -> String? {
        for (i, a) in script.arguments.enumerated() where !a.optional {
            if (typed.indices.contains(i) ? typed[i] : "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter " + label(i, a).lowercased() + "."
            }
        }
        return nil
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// What the script receives as $1, $2, $3: trimmed, and percent-encoded where it asked for that.
    static func values(_ script: Script, _ typed: [String]) -> [String] {
        script.arguments.indices.map { i in
            let v = (typed.indices.contains(i) ? typed[i] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            return script.arguments[i].percentEncoded ? v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? v : v
        }
    }

    /// The script's own folder, unless it names another one (relative paths count from its folder).
    static func workingDirectory(_ script: Script) -> String {
        let folder = (script.path as NSString).deletingLastPathComponent
        guard !script.directory.isEmpty else { return folder }
        let dir = (script.directory as NSString).expandingTildeInPath
        return dir.hasPrefix("/") ? dir : folder + "/" + dir
    }

    /// The last non-empty line, cut to fit a HUD.
    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            .map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 }
    }

    /// Why a run failed: a timeout, else the last line of stderr, else of stdout, else the exit status.
    static func problem(_ o: Output) -> String {
        o.timedOut ? "timed out" : o.flooded ? "too much output" : lastLine(o.err) ?? lastLine(o.out) ?? "exit status \(o.status)"
    }

    /// One name per line; blank lines and repeats dropped (an id must be unique).
    static func parseShortcuts(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
    }

    /// Output for the detail pane. The pane renders inline Markdown only, where a fenced block would fold its lines into one,
    /// so every line is its own code span (monospaced, and the line breaks stay). Keeps the last `limit` lines.
    static func codeBlock(_ text: String, limit: Int = 400) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var spans = lines.suffix(limit).map { line -> String in
            guard !line.allSatisfy(\.isWhitespace) else { return "" }
            var run = 0, longest = 0
            for c in line { run = c == "`" ? run + 1 : 0; longest = max(longest, run) }
            let fence = String(repeating: "`", count: longest + 1)
            return fence + " " + line + " " + fence   // the padding is stripped again; it keeps a backtick at the edge apart from the fence
        }
        if lines.count > limit { spans.insert("\(lines.count - limit) earlier lines not shown", at: 0) }
        return spans.joined(separator: "\n")
    }

    // MARK: Script rows

    private static func item(_ s: Script, listed: Bool) -> Item {
        let url = URL(fileURLWithPath: s.path)
        let needsPanel = !s.arguments.isEmpty || s.mode == .fullOutput   // a form or the output view
        var rows = [("Mode", s.mode.rawValue)]
        if !s.package.isEmpty { rows.append(("Package", s.package)) }
        if !s.arguments.isEmpty { rows.append(("Arguments", String(s.arguments.count))) }
        rows.append(("Path", (s.path as NSString).abbreviatingWithTildeInPath))
        return Item(id: "script." + s.path, title: s.title, subtitle: s.summary, kind: s.package.isEmpty ? "Script" : s.package,
                    icon: icon(s), keywords: s.package.isEmpty ? [] : [s.package], track: !listed, actions: [
                        Action(title: "Run Script", icon: "play", closes: !needsPanel) { start(s) },
                        Action(title: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                        Action(title: "Edit Script", icon: "pencil", shortcut: Shortcut(.command, "e")) { edit(url) },
                        .copy("Copy Path", shortcut: Shortcut([.command, .shift], "p")) { s.path },
                    ], detail: Detail(markdown: s.summary.isEmpty ? "No description." : s.summary, metadata: rows))
    }

    private static func icon(_ s: Script) -> Icon {
        guard let c = s.icon.first, c.unicodeScalars.first.map({ $0.value > 127 }) == true else { return .symbol("terminal") }
        let text = NSAttributedString(string: String(c), attributes: [.font: NSFont.systemFont(ofSize: 15)])
        return .image(NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        })
    }

    private static func scriptRows(_ q: String) -> [Item] {
        refresh()
        guard !scripts.isEmpty || scanned != .distantPast else {
            return [Item(id: "script.loading", title: "Loading script commands…", icon: .symbol("hourglass"), track: false, actions: [])]
        }
        let hits = scripts.map { s in
            (s, max(matchScore(q, s.title), matchScore(q, s.package), s.summary.localizedCaseInsensitiveContains(q) ? 30 : 0))
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard !hits.isEmpty else {
            return [Item(id: "script.none", title: q.isEmpty ? "No script commands yet" : "No matching script commands",
                         subtitle: q.isEmpty ? "Folders: " + directories.joined(separator: ", ") : "", icon: .symbol("terminal"), track: false,
                         actions: [Action(title: "Create Script Command", icon: "plus.square.on.square", closes: false) { createForm() },
                                   Action(title: "Add Script Directory…", icon: "folder.badge.plus") { addDirectory() }])]
        }
        return hits.map { item($0.0, listed: true) }
    }

    // MARK: Running

    /// Asks for the arguments first when the script has any.
    private static func start(_ s: Script) {
        guard !s.arguments.isEmpty else { execute(s, []); return }
        let fields = s.arguments.enumerated().map {
            FormField(label: label($0.offset, $0.element) + ($0.element.optional ? " (optional)" : ""))
        }
        Launcher.shared.push(.form(FormSpec(title: s.title, fields: fields, submitTitle: "Run Script") { typed in
            if let error = missing(s, typed) { return error }
            let args = values(s, typed)
            // The form closes itself once this returns, so the output view is pushed after that.
            if s.mode == .fullOutput { later(0) { execute(s, args) } } else { PanelController.shared.hide(); execute(s, args) }
            return nil
        }))
    }

    private static func execute(_ s: Script, _ values: [String]) {
        if s.needsConfirmation {
            guard confirm("Run “" + s.title + "”?") else { return }
            if s.mode == .fullOutput { PanelController.shared.show(reset: false) }   // the alert hid the panel
        }
        let go = { run(s.path, values, cwd: workingDirectory(s)) }
        guard s.mode == .fullOutput else {
            DispatchQueue.global(qos: .userInitiated).async {
                let o = go()
                DispatchQueue.main.async { report(s, o) }
            }
            return
        }
        // The output view opens at once and fills in when the script ends.
        final class Box { var output: Output? }
        let box = Box()
        Launcher.shared.push(.list(ListSpec(title: s.title, placeholder: "Script output", showsDetail: true) { _ in [outputRow(s, box.output)] }))
        DispatchQueue.global(qos: .userInitiated).async {
            let o = go()
            DispatchQueue.main.async {
                box.output = o
                if o.status != 0 { HUD.show("Script failed: " + problem(o)) }
                Launcher.shared.reload()
            }
        }
    }

    /// silent: the last line, if any; compact and inline: the last line, or a plain "Ran"; any failure: its reason.
    private static func report(_ s: Script, _ o: Output) {
        if o.status != 0 { HUD.show("Script failed: " + problem(o)); return }
        if let line = lastLine(o.out) { HUD.show(line) } else if s.mode != .silent { HUD.show("Ran " + s.title) }
    }

    private static func outputRow(_ s: Script, _ o: Output?) -> Item {
        guard let o else {
            return Item(id: "script.output", title: s.title, subtitle: "Running…", kind: "Output", icon: .symbol("hourglass"), track: false,
                        actions: [], detail: Detail(markdown: "Running…"))
        }
        let text = [o.out, o.err].map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        let ok = o.status == 0
        return Item(id: "script.output", title: s.title, subtitle: ok ? "Done" : "Failed: " + problem(o), kind: "Output",
                    icon: .symbol(ok ? "checkmark.circle" : "xmark.circle"), track: false,
                    actions: [.copy("Copy Output") { text }],
                    detail: Detail(markdown: text.isEmpty ? "No output." : codeBlock(text),
                                   metadata: [("Exit status", String(o.status))] + (o.timedOut ? [("Stopped", "after 60 s")] : o.flooded ? [("Stopped", "after 50 MB of output")] : [])))
    }

    /// Runs an executable and waits for it, so call it off the main thread. Output goes to temp files: a script that leaves
    /// a background child holding stdout cannot block the wait, and a full pipe cannot stall the script. A script is
    /// stopped (SIGTERM, then SIGKILL after `grace`) when it runs past `timeout` or its output files pass `outputLimit` bytes
    /// together; only the last 200 KB of each stream are read back.
    static func run(_ path: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 60,
                    outputLimit: Int = 50_000_000, grace: TimeInterval = 3) -> Output {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("lumen-" + UUID().uuidString)
        let files = [base.appendingPathExtension("out"), base.appendingPathExtension("err")]
        defer { files.forEach { try? fm.removeItem(at: $0) } }
        guard files.allSatisfy({ fm.createFile(atPath: $0.path, contents: nil) }),
              let out = try? FileHandle(forWritingTo: files[0]), let err = try? FileHandle(forWritingTo: files[1]) else {
            return Output(status: -1, err: "Could not create a temporary file")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        let started = Date()
        do { try p.run() } catch { return Output(status: -1, err: error.localizedDescription) }
        try? out.close()
        try? err.close()
        // The watcher checks every 0.2 s until the script is gone. `why` is written there and read after the wait.
        final class Why { let lock = NSLock(); var timedOut = false, flooded = false }
        let why = Why()
        let watcher = DispatchWorkItem {
            let bytes = { files.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) } }
            var terminated: Date?
            while p.isRunning {
                if let at = terminated {
                    if Date().timeIntervalSince(at) >= grace { if p.isRunning { kill(p.processIdentifier, SIGKILL) }; return }   // it ignored SIGTERM
                } else {
                    let late = Date().timeIntervalSince(started) >= timeout
                    if late || bytes() > outputLimit {
                        why.lock.lock()
                        if late { why.timedOut = true } else { why.flooded = true }
                        why.lock.unlock()
                        p.terminate()
                        terminated = Date()
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        DispatchQueue.global().async(execute: watcher)
        p.waitUntilExit()
        watcher.cancel()
        // Only the end of a runaway output is kept, and only the end is read.
        let read = { (url: URL) -> String in
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
            return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        }
        why.lock.lock()
        let (timedOut, flooded) = (why.timedOut, why.flooded)
        why.lock.unlock()
        return Output(status: p.terminationStatus, out: read(files[0]), err: read(files[1]), timedOut: timedOut, flooded: flooded)
    }

    // MARK: Create, edit, add

    static func slug(_ title: String) -> String {
        let dashed = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return dashed.split(separator: "-").joined(separator: "-")
    }

    static func template(title: String, mode: Mode, package: String) -> String {
        var lines = ["#!/bin/bash", "", "# @raycast.schemaVersion 1", "# @raycast.title " + title, "# @raycast.mode " + mode.rawValue]
        if !package.isEmpty { lines.append("# @raycast.packageName " + package) }
        lines += ["",
                  "# More metadata goes in lines like the ones above, starting with @raycast. :",
                  "#   icon (an emoji), description, needsConfirmation true, currentDirectoryPath,",
                  "#   argument1 to argument3 as JSON, e.g. {\"type\": \"text\", \"placeholder\": \"Name\", \"optional\": true}",
                  "# Arguments arrive as $1, $2 and $3. silent and compact show the last line of output when the script ends,",
                  "# fullOutput shows all of it.",
                  "",
                  "echo \"Hello from Lumen\"",
                  ""]
        return lines.joined(separator: "\n")
    }

    /// Writes an executable bash script with the metadata into `dir` (created on first use) and returns its URL.
    static func create(title: String, mode: Mode, package: String, in dir: String) throws -> URL {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = slug(title).isEmpty ? "script" : slug(title)
        var url = folder.appendingPathComponent(base + ".sh"), n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).sh")
            n += 1
        }
        try template(title: title, mode: mode, package: package).write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func createForm() {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        Launcher.shared.push(.form(FormSpec(
            title: "Create Script Command",
            fields: [FormField(label: "Title", placeholder: "Say Hello"),
                     FormField(label: "Mode", value: "compact", placeholder: "silent, compact, fullOutput or inline"),
                     FormField(label: "Package (optional)", placeholder: "Groups scripts; shown instead of “Script”")],
            submitTitle: "Create Script Command") { v in
                guard !trim(v[0]).isEmpty else { return "Enter a title." }
                guard let mode = Mode(named: v[1]) else { return "Mode must be silent, compact, fullOutput or inline." }
                do {
                    let url = try create(title: trim(v[0]), mode: mode, package: trim(v[2]), in: directories.first ?? defaultDirectory)
                    PanelController.shared.hide()
                    edit(url)
                    refresh(force: true)
                    HUD.show("Created " + url.lastPathComponent)
                } catch {
                    return error.localizedDescription
                }
                return nil
            }))
    }

    /// Opens the file in whatever the user set for its type (a shell script would otherwise run in Terminal).
    private static func edit(_ url: URL) {
        let ws = NSWorkspace.shared
        let type = UTType(filenameExtension: url.pathExtension) ?? .plainText
        guard let app = ws.urlForApplication(toOpen: type) ?? ws.urlForApplication(toOpen: .plainText) else { ws.open(url); return }
        ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func addDirectory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a folder with Script Commands"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !directories.contains(where: { ($0 as NSString).expandingTildeInPath == url.path }) else {
            HUD.show(url.lastPathComponent + " is already a script directory")
            return
        }
        directories.append((url.path as NSString).abbreviatingWithTildeInPath)
        Store.save(directories, "scripts.json")
        refresh(force: true)
        HUD.show("Added " + url.lastPathComponent)
    }

    // MARK: Shortcuts

    private static func shortcutItem(_ name: String, listed: Bool) -> Item {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
        return Item(id: "shortcut." + name, title: name, kind: "Shortcut", icon: .symbol("square.stack.3d.up"), track: !listed, actions: [
            Action(title: "Run Shortcut", icon: "play") { runShortcut(name) },
            Action(title: "Open in Shortcuts", icon: "arrow.up.forward.square") {
                if let url = URL(string: "shortcuts://open-shortcut?name=" + escaped) { NSWorkspace.shared.open(url) }
            },
            .copy("Copy Name", shortcut: Shortcut([.command, .shift], "n")) { name },
        ])
    }

    private static func shortcutRows(_ q: String) -> [Item] {
        refresh()
        let scored: [(name: String, score: Double)] = shortcuts.map { (name: $0, score: matchScore(q, $0)) }.filter { $0.score > 0 }
        let hits = scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard !hits.isEmpty else {
            let loading = shortcuts.isEmpty && scanned == .distantPast
            return [Item(id: "shortcut.none", title: loading ? "Loading shortcuts…" : q.isEmpty ? "No shortcuts" : "No matching shortcuts",
                         icon: .symbol("square.stack.3d.up"), track: false, actions: [])]
        }
        return hits.map { shortcutItem($0.name, listed: true) }
    }

    /// Up to ten minutes: a shortcut may wait for the user inside the Shortcuts app.
    private static func runShortcut(_ name: String) {
        HUD.show("Running " + name + "…")
        DispatchQueue.global(qos: .userInitiated).async {
            let o = run("/usr/bin/shortcuts", ["run", name], timeout: 600)
            let why = problem(o)
            DispatchQueue.main.async { HUD.show(o.status == 0 ? "Ran " + name : "Shortcut failed: " + why.replacingOccurrences(of: "Error: ", with: "")) }
        }
    }
}
