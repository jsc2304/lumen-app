import AppKit

/// An app that Auto Quit closes once it has been in the background for `minutes`.
struct AutoQuitRule: Codable {
    var path: String
    var minutes: Int
}

/// What moving an app to the Trash takes along: the app itself and the files it left in ~/Library.
struct AppScan {
    let appBytes: Int64
    let leftovers: [(path: String, bytes: Int64)]
    var sharedWith: [String] = []   // other installed copies with the same bundle id: what they share was left alone
    let at = Date()
    var total: Int64 { appBytes + leftovers.reduce(0) { $0 + $1.bytes } }
}

/// Uninstall Applications and Auto Quit (quit apps left unused for a while).
enum AppTools {
    private static let rulesFile = "autoquit.json"
    private static var rules: [AutoQuitRule] = Store.load(rulesFile) ?? []
    private static var idleSince: [Int32: Date] = [:]   // pid: when the app went to the background
    private static var scans: [String: AppScan] = [:]   // app path: what Uninstall found
    private static var scanning = false
    private static var reloadScheduled = false
    private static var uninstallable: [String: Bool] = [:]   // app path: whether Uninstall offers it (resolving links is slow)
    private static var listed: [String] = []                 // every app the list knows, to find other copies of one
    private static var lastCheck = Date()
    private static let uninstallTitle = "Uninstall Application"

    static func commands() -> [Item] {
        [.command("apptools.uninstall", "Uninstall Application", kind: "App Tools", icon: "trash",
                  keywords: ["remove app", "delete app", "leftovers", "cleanup", "deinstallieren"], closes: false) { openUninstall() },
         .command("apptools.autoquit", "Manage Auto Quits", kind: "App Tools", icon: "clock.badge.xmark",
                  keywords: ["quit idle apps", "close unused apps", "auto close"], closes: false) { openAutoQuit() }]
    }

    /// Starts the auto-quit monitor; called once at launch.
    static func start() {
        for (name, left) in [(NSWorkspace.didActivateApplicationNotification, false), (NSWorkspace.didDeactivateApplicationNotification, true)] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                idleSince[app.processIdentifier] = left ? Date() : nil
            }
        }
        // Time asleep is not time in the background.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            let now = Date()
            idleSince = idleSince.mapValues { _ in now }
            lastCheck = now
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in check() }
    }

    // MARK: Uninstall

    private static func openUninstall() {
        scans = scans.filter { Date().timeIntervalSince($0.value.at) < 120 }
        uninstallable = [:]
        Launcher.shared.push(.list(ListSpec(title: uninstallTitle, placeholder: "Search applications…", showsDetail: true) { uninstallItems($0) }))
    }

    private static func reloadIfOpen() {
        if case .list(let spec) = Launcher.shared.mode, spec.title == uninstallTitle { Launcher.shared.reload() }
    }

    /// The scans of a few dozen apps end in a burst: one reload for all of them, at most every 0.3 s.
    private static func reloadSoon() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        later(0.3) {
            reloadScheduled = false
            reloadIfOpen()
        }
    }

    private static func offers(_ path: String, home: String, own: String) -> Bool {
        if let known = uninstallable[path] { return known }
        let ok = isUninstallable(path, resolved: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, home: home, own: own)
        uninstallable[path] = ok
        return ok
    }

    private static func uninstallItems(_ q: String) -> [Item] {
        let fm = FileManager.default, home = NSHomeDirectory(), own = Bundle.main.bundlePath
        let all = Apps.items()
        listed = all.map(\.id)
        let apps = all.filter { fm.fileExists(atPath: $0.id) && offers($0.id, home: home, own: own) }
        scanAll(apps.map(\.id))
        let scored = apps.map { (app: $0, score: matchScore(q, $0.title)) }.filter { $0.score > 0 }
        let ordered = scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.app.title.localizedCaseInsensitiveCompare(b.app.title) == .orderedAscending
        }
        return ordered.map { uninstallItem($0.app) }
    }

    private static func uninstallItem(_ app: Item) -> Item {
        let path = app.id, scan = scans[path]
        return Item(id: "apptools.uninstall." + path, title: app.title, subtitle: scan.map { sizeText($0.total) } ?? "Calculating…",
                    kind: "Application", icon: app.icon, track: false, actions: [
                        Action(title: "Move to Trash…", icon: "trash", destructive: true, closes: false) { uninstall(app) },
                        Action(title: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
                    ], detail: detail(scan))
    }

    static func detail(_ scan: AppScan?) -> Detail {
        guard let scan else { return Detail(markdown: "Looking for leftovers in ~/Library…") }
        let n = scan.leftovers.count, library = NSHomeDirectory() + "/Library/"
        let shared = scan.sharedWith.isEmpty ? "" : "\n\nAnother copy with the same bundle identifier is installed (\(escapeMarkdown(scan.sharedWith.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")))), "
            + "so the files they share are not listed and stay in place."
        return Detail(markdown: (n == 0 ? "No leftovers found in ~/Library." : "**\(n) leftover \(n == 1 ? "item" : "items")** in ~/Library move to the Trash with the app.") + shared,
                      metadata: [("Application", sizeText(scan.appBytes))]
                          + scan.leftovers.map { ($0.path.replacingOccurrences(of: library, with: ""), sizeText($0.bytes)) }
                          + [("Total", sizeText(scan.total))])
    }

    /// Looks for the leftovers of every listed app in the background, a few at a time, and refreshes the list as each is done.
    private static func scanAll(_ paths: [String]) {
        let todo = paths.filter { scans[$0] == nil }
        guard !scanning, !todo.isEmpty else { return }
        scanning = true
        let all = listed
        DispatchQueue.global(qos: .utility).async {
            let shared = sharedCopies(of: todo, among: all)
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                let result = scan(todo[i], sharedWith: shared[todo[i]] ?? [])
                DispatchQueue.main.async {
                    scans[todo[i]] = result
                    reloadSoon()
                }
            }
            DispatchQueue.main.async {
                scanning = false
                reloadIfOpen()   // picks up apps that appeared meanwhile
            }
        }
    }

    /// The scan of one app: the list's if it is recent, otherwise a fresh one.
    private static func withScan(_ path: String, _ done: @escaping (AppScan) -> Void) {
        if let s = scans[path], Date().timeIntervalSince(s.at) < 120 { return done(s) }
        HUD.show("Looking for leftovers…")
        let all = listed
        DispatchQueue.global(qos: .userInitiated).async {
            let s = scan(path, sharedWith: sharedCopies(of: [path], among: all)[path] ?? [])
            DispatchQueue.main.async {
                scans[path] = s
                done(s)
            }
        }
    }

    private static func uninstall(_ app: Item) {
        let path = app.id, name = app.title
        withScan(path) { scan in
            guard !needsAdmin(path) else { return cannotTrash(name, path, reason: "It belongs to root, so it needs administrator rights.") }
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path && $0.processIdentifier != getpid() }
            let n = scan.leftovers.count
            let ok = confirmList(
                "Move “\(name)”\(n == 0 ? "" : " and \(n) leftover \(n == 1 ? "item" : "items")") to the Trash?",
                info: (running.isEmpty ? "" : "\(name) is running and is quit first. ")
                    + (scan.sharedWith.isEmpty ? "" : "Another installed copy has the same bundle identifier, so the files they share stay in place. ")
                    + "Everything goes to the Trash, so you can put it back.",
                lines: listing(scan, path: path, home: NSHomeDirectory()))
            PanelController.shared.show(reset: false)
            guard ok else { return }
            guard !running.isEmpty else { return trash(scan, path: path, name: name) }
            HUD.show("Quitting \(name)…")
            running.forEach { $0.terminate() }
            var tries = 0
            func wait() {
                if running.allSatisfy(\.isTerminated) {
                    trash(scan, path: path, name: name)
                } else if tries >= 40 {   // 10 s: a save dialog is probably waiting
                    HUD.show(name + " did not quit")
                } else {
                    tries += 1
                    later(0.25, wait)
                }
            }
            wait()
        }
    }

    /// The app goes first: if that fails (root-owned, protected), the leftovers stay where they are.
    private static func trash(_ scan: AppScan, path: String, name: String) {
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
            DispatchQueue.main.async {
                if let error { return cannotTrash(name, path, reason: error.localizedDescription) }
                scans[path] = nil
                reloadIfOpen()
                let urls = scan.leftovers.map { URL(fileURLWithPath: $0.path) }, size = sizeText(scan.total)
                guard !urls.isEmpty else { return HUD.show("Moved \(name) to the Trash (\(size))") }
                NSWorkspace.shared.recycle(urls) { moved, error in
                    DispatchQueue.main.async {
                        HUD.show(error.map { "Moved \(name) to the Trash; \(moved.count) of \(urls.count) leftover items, then: \($0.localizedDescription)" }
                                 ?? "Moved \(name) and \(urls.count) leftover \(urls.count == 1 ? "item" : "items") to the Trash (\(size))")
                    }
                }
            }
        }
    }

    private static func cannotTrash(_ name: String, _ path: String, reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "“\(name)” was not moved to the Trash"
        alert.informativeText = reason + "\n\nNothing in ~/Library was touched. Show the app in Finder and drag it to the Trash there; "
            + "macOS asks for an administrator password. Apps protected by macOS may also need Lumen under Privacy & Security → App Management."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        PanelController.shared.show(reset: false)
    }

    /// An alert with a scrollable list of everything that will be moved.
    private static func confirmList(_ question: String, info: String, lines: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return confirmAlert(question, info: info, lines: lines).runModal() == .alertFirstButtonReturn
    }

    /// Cancel answers Return, so a quick Return never moves anything to the Trash.
    static func confirmAlert(_ question: String, info: String, lines: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = info
        alert.alertStyle = .warning
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 190)
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = lines.joined(separator: "\n")
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""     // Return must not confirm the destructive button
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    // MARK: Uninstall (pure and file system helpers)

    /// Uninstall offers apps in /Applications and ~/Applications, but not Lumen and not macOS itself: Safari and
    /// other system apps are linked into /Applications from /System (`resolved` is the path after following links).
    static func isUninstallable(_ path: String, resolved: String, home: String, own: String) -> Bool {
        (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")) && !resolved.hasPrefix("/System/") && path != own
    }

    private static func safe(_ component: String) -> Bool {
        !component.isEmpty && !component.contains("/") && !component.hasPrefix(".")
    }

    /// Paths below ~/Library where an app with this bundle id and these names keeps files; the ones that exist are leftovers.
    /// Exact names only: "com.example.App" must not pull in "com.example.App.beta", which is another app.
    static func leftoverCandidates(bundleId id: String, names: [String]) -> [String] {
        var out = names.filter(safe).flatMap { ["Application Support/\($0)", "Caches/\($0)", "Logs/\($0)"] }
        if safe(id) {
            out += ["Application Support/\(id)", "Caches/\(id)", "Preferences/\(id).plist", "Containers/\(id)", "Logs/\(id)",
                    "Saved Application State/\(id).savedState", "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies", "WebKit/\(id)"]
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A Group Containers folder that is this app's: the bundle id, with the "TEAMID." and "group." or "groups." prefixes macOS
    /// adds. Folders shared by all of a vendor's apps (TEAMID.Suite) are not, so uninstalling one app keeps the others working.
    static func isGroupContainer(_ name: String, of id: String) -> Bool {
        guard !id.isEmpty else { return false }
        var rest = Substring(name)
        if let dot = rest.firstIndex(of: "."), rest[..<dot].count == 10, rest[..<dot].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
            rest = rest[rest.index(after: dot)...]
        }
        for prefix in ["group.", "groups."] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
            break
        }
        return String(rest).caseInsensitiveCompare(id) == .orderedSame
    }

    /// A launch agent file of this app: "<bundle id>.plist" or "<bundle id>.<helper>.plist".
    static func isLaunchAgent(_ file: String, of id: String) -> Bool {
        !id.isEmpty && file.hasSuffix(".plist") && file.lowercased().hasPrefix(id.lowercased() + ".")
    }

    /// Display name without ".app".
    private static func appName(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    /// The other apps in `listed` with the same bundle id as each of `paths` (a path with none is left out). Copies that are
    /// the same app through a link do not count. Reads the Info.plist of every app: call it off the main thread.
    static func sharedCopies(of paths: [String], among listed: [String]) -> [String: [String]] {
        let ids = Dictionary(Set(paths + listed).map { ($0, Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier ?? "") }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(grouping: ids.keys.filter { !ids[$0]!.isEmpty }, by: { ids[$0]! })
        return Dictionary(paths.compactMap { path -> (String, [String])? in
            let others = (byID[ids[path] ?? ""] ?? []).filter { real($0) != real(path) }.sorted()
            return others.isEmpty ? nil : (path, others)
        }, uniquingKeysWith: { a, _ in a })
    }

    /// The app at `path` and its leftovers in `library`, with sizes. Slow for big apps: call it off the main thread.
    /// `sharedWith`: other installed copies with the same bundle id. The files the copies share must stay for them, so
    /// nothing found by bundle id (also group containers and launch agents), nor by a name they carry too, is a leftover.
    static func scan(_ path: String, library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
                     sharedWith: [String] = []) -> AppScan {
        let fm = FileManager.default
        let id = sharedWith.isEmpty ? Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier ?? "" : ""
        let fileName = { (p: String) in URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent }
        let theirs = Set(sharedWith.flatMap { [appName($0), fileName($0)] }.map { $0.lowercased() })
        let names = [appName(path), fileName(path)].filter { !theirs.contains($0.lowercased()) }
        var found = leftoverCandidates(bundleId: id, names: names).map { library.appendingPathComponent($0).path }
            .filter { fm.fileExists(atPath: $0) }
        for (folder, matches) in [("Group Containers", isGroupContainer), ("LaunchAgents", isLaunchAgent)] {
            let dir = library.appendingPathComponent(folder)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where matches(name, id) {
                found.append(dir.appendingPathComponent(name).path)
            }
        }
        return AppScan(appBytes: size(of: path), leftovers: Set(found).sorted().map { ($0, size(of: $0)) }, sharedWith: sharedWith)
    }

    /// Disk space of a file or folder, links not followed.
    static func size(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path), key = URLResourceKey.totalFileAllocatedSizeKey
        let bytes = { (u: URL) in Int64((try? u.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0) }
        var total = bytes(url)
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key]) {
            for case let file as URL in walker { total += bytes(file) }
        }
        return total
    }

    /// True when Lumen cannot move the app to the Trash: it or its folder is not writable for this user (root-owned installs).
    static func needsAdmin(_ path: String) -> Bool {
        !FileManager.default.isWritableFile(atPath: path) || !FileManager.default.isDeletableFile(atPath: path)
    }

    static func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// One line per item for the confirmation: size, path with ~, and the total.
    static func listing(_ scan: AppScan, path: String, home: String) -> [String] {
        let line = { (bytes: Int64, text: String) -> String in
            let size = sizeText(bytes)
            return String(repeating: " ", count: max(0, 10 - size.count)) + size + "  " + text
        }
        let short = { (p: String) -> String in p.hasPrefix(home + "/") ? "~" + String(p.dropFirst(home.count)) : p }
        return [line(scan.appBytes, short(path))] + scan.leftovers.map { line($0.bytes, short($0.path)) } + ["", line(scan.total, "Total")]
    }

    // MARK: Auto Quit

    private static func openAutoQuit() {
        Launcher.shared.push(.list(ListSpec(title: "Auto Quits", placeholder: "Search auto quits…") { ruleItems($0) }))
    }

    private static func update(_ change: (inout [AutoQuitRule]) -> Void) {
        change(&rules)
        Store.save(rules, rulesFile)
        Launcher.shared.reload()
    }

    private static var addAction: Action {
        Action(title: "Add Auto Quit", icon: "plus", shortcut: Shortcut(.command, "n"), closes: false) { ruleForm(nil) }
    }

    private static func ruleItems(_ q: String) -> [Item] {
        let rows = rules.map { ($0, appName($0.path)) }.filter { matchScore(q, $0.1) > 0 }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        guard !rows.isEmpty else {
            return [Item(id: "apptools.autoquit.none", title: q.isEmpty ? "No Auto Quits" : "No matching auto quits",
                         subtitle: q.isEmpty ? "Add an app that Lumen quits after it has been in the background for a while" : "",
                         icon: .symbol("clock.badge.xmark"), track: false, actions: [addAction])]
        }
        return rows.map { rule, name in
            Item(id: "apptools.autoquit." + rule.path, title: name,
                 subtitle: "Quits after \(rule.minutes) \(rule.minutes == 1 ? "minute" : "minutes") in the background",
                 kind: "Auto Quit", icon: .image(NSWorkspace.shared.icon(forFile: rule.path)), track: false, actions: [
                    Action(title: "Edit Auto Quit", icon: "pencil", shortcut: Shortcut(.command, "e"), closes: false) { ruleForm(rule) },
                    addAction,
                    Action(title: "Remove Auto Quit", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) {
                        update { $0.removeAll { $0.path == rule.path } }
                        HUD.show("Removed Auto Quit for " + name)
                    },
                 ])
        }
    }

    /// Add (nil) or edit.
    private static func ruleForm(_ existing: AutoQuitRule?) {
        Launcher.shared.push(.form(FormSpec(
            title: existing == nil ? "Add Auto Quit" : "Edit Auto Quit",
            fields: [FormField(label: "App Name", value: existing.map { appName($0.path) } ?? "", placeholder: "Slack"),
                     FormField(label: "Minutes", value: existing.map { String($0.minutes) } ?? "30",
                               placeholder: "Quit after this many minutes in the background")],
            submitTitle: existing == nil ? "Add Auto Quit" : "Save Auto Quit") { v in
                let name = v[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let app = Quicklinks.app(name), app.pathExtension == "app" else { return "Application not found: " + name }
                guard app.standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path else { return "Lumen cannot quit itself." }
                guard let limit = minutes(v[1]) else { return "Enter the minutes as a whole number, 1 or more." }
                update { list in
                    list.removeAll { $0.path == existing?.path || $0.path == app.path }
                    list.append(AutoQuitRule(path: app.path, minutes: limit))
                }
                return nil
            }))
    }

    /// Whole minutes, 1 or more; nil for anything else.
    static func minutes(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1 ? $0 : nil }
    }

    /// Once a minute: politely quits the apps with a rule that have been in the background long enough.
    private static func check() {
        let now = Date(), last = lastCheck
        lastCheck = now
        guard !rules.isEmpty else { idleSince = [:]; return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let due = Set(expired(rules, running: apps.map { ($0.processIdentifier, $0.bundleURL?.path ?? "") },
                              front: NSWorkspace.shared.frontmostApplication?.processIdentifier, idle: &idleSince, now: now, since: last))
        let quitting = apps.filter { due.contains($0.processIdentifier) }
        quitting.forEach { $0.terminate() }
        if !quitting.isEmpty { HUD.show("Auto-quit " + quitting.map { $0.localizedName ?? "App" }.joined(separator: ", ")) }
    }

    private static let sleepGap: TimeInterval = 120   // the check runs every 60 s

    private static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// The pids of running apps whose rule has run out. An app is idle from the moment it lost the front (or from the first
    /// check that sees it in the background); the frontmost app never is. A quit that does not happen (a save dialog) is
    /// tried again after another full idle period, not every minute. `idle` keeps only running apps. `last` is the time of the
    /// previous check: a gap over `sleepGap` means the Mac slept, which is not time in the background, so every idle clock
    /// restarts at `now` and nothing is due.
    static func expired(_ rules: [AutoQuitRule], running: [(pid: Int32, path: String)], front: Int32?,
                        idle: inout [Int32: Date], now: Date, since last: Date? = nil) -> [Int32] {
        let minutes = Dictionary(rules.map { (real($0.path), $0.minutes) }, uniquingKeysWith: min)
        idle = idle.filter { pid, _ in running.contains { $0.pid == pid } }
        if let last, now.timeIntervalSince(last) > sleepGap {
            idle = idle.mapValues { _ in now }
            return []
        }
        var due: [Int32] = []
        for app in running {
            guard let limit = minutes[real(app.path)] else { continue }
            if app.pid == front { idle[app.pid] = nil; continue }
            let since = idle[app.pid] ?? now
            idle[app.pid] = since
            if now.timeIntervalSince(since) >= Double(limit) * 60 {
                due.append(app.pid)
                idle[app.pid] = now
            }
        }
        return due
    }
}
