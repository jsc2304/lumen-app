import AppKit

/// A named set of apps to keep away while focusing.
struct FocusCategory: Codable {
    var id = UUID()
    var name: String
    var apps: [String] = []   // display names, as listed in Apps
}

extension FocusCategory {
    /// Only the name is required, so a file from an older version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
    }
}

/// A focus session. Progress is the seconds already focused plus the start of the current run (nil while
/// paused), so pausing, restarting Lumen and a sleeping Mac all count correctly.
struct FocusSession: Codable {
    var goal: String
    var category = ""            // the category it started with, for display
    var blocked: [String] = []   // copied from the category: editing the category later does not change a running session
    var duration: TimeInterval?  // nil: until stopped
    var banked: TimeInterval = 0
    var runningSince: Date?

    func elapsed(at now: Date) -> TimeInterval { banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
    func remaining(at now: Date) -> TimeInterval? { duration.map { $0 - elapsed(at: now) } }
    func isDone(at now: Date) -> Bool { remaining(at: now).map { $0 <= 0 } ?? false }

    mutating func pause(at now: Date) { banked = elapsed(at: now); runningSince = nil }
    mutating func resume(at now: Date) { if runningSince == nil { runningSince = now } }
}

extension FocusSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decode(String.self, forKey: .goal)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        banked = try c.decodeIfPresent(TimeInterval.self, forKey: .banked) ?? 0
        runningSince = try c.decodeIfPresent(Date.self, forKey: .runningSince)
    }
}

/// Everything in focus.json.
struct FocusFile: Codable {
    var categories: [FocusCategory]
    var session: FocusSession?
}

extension FocusFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decodeIfPresent([FocusCategory].self, forKey: .categories) ?? []
        session = try c.decodeIfPresent(FocusSession.self, forKey: .session)
    }
}

/// Focus sessions: a timer that keeps distracting apps away.
enum Focus {
    private static let file = "focus.json"
    // First run (no file yet) starts with one example category.
    private static var state: FocusFile = Store.load(file) ?? FocusFile(categories: [FocusCategory(name: "Deep Work")])
    private static var timer: Timer?

    // MARK: Root

    // All six stay listed whatever the state, so a hotkey or favorite on one never points at a missing command.
    static func commands() -> [Item] {
        [.command("focus.start", "Start Focus Session", kind: "Focus", icon: "scope",
                  keywords: ["timer", "concentrate", "pomodoro", "block apps", "deep work"], closes: false) { startForm() },
         .command("focus.categories", "Search Focus Categories", kind: "Focus", icon: "square.stack",
                  keywords: ["blocked apps", "edit focus category", "new focus category"], closes: false) {
            Launcher.shared.push(.list(ListSpec(title: "Focus Categories", placeholder: "Search focus categories…") { categoryItems($0) }))
        },
         .command("focus.pause", "Pause Focus Session", kind: "Focus", icon: "pause.circle", keywords: ["break"]) { pause() },
         .command("focus.resume", "Resume Focus Session", kind: "Focus", icon: "play.circle", keywords: ["continue"]) { resume() },
         .command("focus.complete", "Complete Focus Session", kind: "Focus", icon: "checkmark.circle",
                  keywords: ["end", "stop", "finish", "done"]) { complete() },
         .command("focus.edit", "Edit Focus Session", kind: "Focus", icon: "pencil.circle",
                  keywords: ["change goal", "change duration", "extend"], closes: false) { editForm() }]
    }

    /// Restores a running session after a restart; called once at launch.
    static func start() {
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                enforce($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
        guard let s = state.session else { return }
        if !hasUsableDuration(s) || s.isDone(at: Date()) {
            finish(announce: false)   // ran out while Lumen was not running (or a damaged focus.json: its duration cannot be shown)
        } else {
            sync()
            enforce(NSWorkspace.shared.frontmostApplication)
        }
    }

    // MARK: Session

    private static func save() { Store.save(state, file) }

    private static func set(_ session: FocusSession?) {
        state.session = session
        save()
        sync()
    }

    /// Brings the menu bar item and the clock in line with the session. Only a running session ticks.
    private static func sync() {
        timer?.invalidate()
        timer = nil
        guard let s = state.session else { return Bar.shared.hide() }
        Bar.shared.show(s)
        guard s.runningSince != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps counting while the menu bar menu is open
        timer = t
    }

    private static func tick() {
        guard let s = state.session else { return }
        if s.isDone(at: Date()) { finish(announce: true) } else { Bar.shared.update(s) }
    }

    private static func finish(announce: Bool) {
        set(nil)
        if announce { HUD.show("Focus session complete", seconds: 5); NSSound(named: "Glass")?.play() }
    }

    static func pause() {
        guard var s = state.session else { return HUD.show("No focus session") }
        guard s.runningSince != nil else { return HUD.show("Focus session is already paused") }
        s.pause(at: Date())
        set(s)
        HUD.show("Focus session paused")
    }

    static func resume() {
        guard var s = state.session else { return HUD.show("No focus session") }
        guard s.runningSince == nil else { return HUD.show("Focus session is running") }
        s.resume(at: Date())
        set(s)
        HUD.show("Focus session resumed")
        enforce(NSWorkspace.shared.frontmostApplication)
    }

    static func complete() {
        guard state.session != nil else { return HUD.show("No focus session") }
        finish(announce: true)
    }

    static func togglePause() {
        if state.session?.runningSince == nil { resume() } else { pause() }
    }

    /// Hides a blocked app the moment it comes to the front (or starts). Never Lumen, nothing while paused.
    private static func enforce(_ app: NSRunningApplication?) {
        guard let s = state.session, s.runningSince != nil, let app, app.processIdentifier != getpid(),
              blocks(s.blocked, appName: app.localizedName, fileName: app.bundleURL?.deletingPathExtension().lastPathComponent)
        else { return }
        app.hide()
        HUD.show("Focus: \(s.goal) — \(app.localizedName ?? "App") is blocked")
    }

    // MARK: Forms

    private static func startForm(category: String = "") {
        guard state.session == nil else { return HUD.show("A focus session is already running") }
        Launcher.shared.push(.form(FormSpec(
            title: "Start Focus Session",
            fields: [FormField(label: "Goal", placeholder: "What are you working on?"),
                     FormField(label: "Duration", placeholder: "25m, 1h or empty to run until you stop it"),
                     FormField(label: "Category (optional)", value: category, placeholder: "Name of a focus category, e.g. Deep Work")],
            submitTitle: "Start Session") { v in
                guard state.session == nil else { return "A focus session is already running." }
                let plan = plan(v, categories: state.categories, current: nil, now: Date())
                guard let session = plan.session else { return plan.error }
                PanelController.shared.hide()
                set(session)
                HUD.show("Focus session started")
                enforce(NSWorkspace.shared.frontmostApplication)
                return nil
            }))
    }

    private static func editForm() {
        guard let s = state.session else { return HUD.show("No focus session") }
        Launcher.shared.push(.form(FormSpec(
            title: "Edit Focus Session",
            fields: [FormField(label: "Goal", value: s.goal),
                     FormField(label: "Duration", value: s.duration.map(formatDuration) ?? "", placeholder: "25m, 1h or empty to run until you stop it"),
                     FormField(label: "Category (optional)", value: s.category, placeholder: "Name of a focus category")],
            submitTitle: "Save Session") { v in
                guard let current = state.session else { return "The focus session has ended." }
                let plan = plan(v, categories: state.categories, current: current, now: Date())
                guard let session = plan.session else { return plan.error }
                set(session)
                HUD.show("Focus session updated")
                enforce(NSWorkspace.shared.frontmostApplication)
                return nil
            }))
    }

    // MARK: Categories

    private static func update(_ change: (inout [FocusCategory]) -> Void) {
        change(&state.categories)
        save()
        Launcher.shared.reload()
    }

    private static func categoryItems(_ q: String) -> [Item] {
        let rows = state.categories.map { ($0, matchScore(q, $0.name)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { categoryItem($0.0) }
        guard rows.isEmpty else { return rows }
        return [Item(id: "focus.category.none", title: q.isEmpty ? "No Focus Categories" : "No matching focus categories",
                     icon: .symbol("square.stack"), track: false, actions: [createAction])]
    }

    private static var createAction: Action {
        Action(title: "Create Focus Category", icon: "plus", shortcut: Shortcut(.command, "n"), closes: false) { categoryForm(nil) }
    }

    private static func categoryItem(_ c: FocusCategory) -> Item {
        Item(id: "focus.category." + c.id.uuidString, title: c.name,
             subtitle: c.apps.isEmpty ? "No blocked apps" : c.apps.joined(separator: ", "),
             kind: "Focus Category", icon: .symbol("scope"), track: false, actions: [
                Action(title: "Start Focus Session", icon: "play.circle", closes: false) { startForm(category: c.name) },
                Action(title: "Edit Focus Category", icon: "pencil", shortcut: Shortcut(.command, "e"), closes: false) { categoryForm(c) },
                createAction,
                Action(title: "Delete Focus Category", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) {
                    // The alert takes key focus from the panel and hides it; bring the list back afterwards.
                    let ok = confirm("Delete the focus category “\(c.name)”?")
                    PanelController.shared.show(reset: false)
                    guard ok else { return }
                    update { $0.removeAll { $0.id == c.id } }
                    HUD.show("Deleted Focus Category")
                },
             ])
    }

    /// Create (nil) or edit.
    private static func categoryForm(_ existing: FocusCategory?) {
        Launcher.shared.push(.form(FormSpec(
            title: existing == nil ? "Create Focus Category" : "Edit Focus Category",
            fields: [FormField(label: "Name", value: existing?.name ?? "", placeholder: "Deep Work"),
                     FormField(label: "Blocked Apps (optional)", value: existing?.apps.joined(separator: ", ") ?? "",
                               placeholder: "Comma-separated app names, e.g. Slack, Mail, Messages")],
            submitTitle: existing == nil ? "Create Category" : "Save Category") { v in
                let name = v[0].trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { return "Enter a name." }
                if state.categories.contains(where: { $0.id != existing?.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    return "A focus category named “\(name)” already exists."
                }
                let apps = resolveApps(v[1], installed: Apps.items())
                if !apps.missing.isEmpty { return "Application not found: " + apps.missing.joined(separator: ", ") }
                let c = FocusCategory(id: existing?.id ?? UUID(), name: name, apps: apps.names)
                update { list in
                    if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
                }
                return nil
            }))
    }

    // MARK: Pure helpers

    /// The session a Start or Edit form describes. `current` (Edit) keeps its progress. Returns an error text instead
    /// when a field is wrong.
    static func plan(_ v: [String], categories: [FocusCategory], current: FocusSession?, now: Date) -> (session: FocusSession?, error: String?) {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let goal = trim(v[0]), length = trim(v[1]), name = trim(v[2])
        if goal.isEmpty { return (nil, "Enter a goal.") }
        var s = current ?? FocusSession(goal: goal, runningSince: now)
        s.goal = goal
        s.duration = nil
        if !length.isEmpty {
            guard let d = parseDuration(length) else { return (nil, "Duration: use 25m, 1h, 1h 30m, or leave it empty.") }
            if d <= s.elapsed(at: now) { return (nil, "The duration must be longer than the \(formatDuration(s.elapsed(at: now))) already focused.") }
            s.duration = d
        }
        if name.isEmpty {
            (s.category, s.blocked) = ("", [])
        } else if let c = categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            (s.category, s.blocked) = (c.name, c.apps)
        } else if s.category.caseInsensitiveCompare(name) != .orderedSame {
            return (nil, "No focus category named “\(name)”.")
        }   // else: the session's own category was deleted meanwhile; it keeps its copy of the apps
        return (s, nil)
    }

    private static let durationPart = try! NSRegularExpression(pattern: #"^\s*(\d+(?:[.,]\d+)?)\s*([a-z]*)\s*"#)
    private static let units: [String: Double] = [
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
    ]

    /// The longest session: a week. Longer (or not even a finite number, as 400 typed digits give) is a typo.
    static let maxDuration: TimeInterval = 7 * 24 * 3600

    /// Whether a stored session has a duration the clock and menu bar text can handle.
    static func hasUsableDuration(_ s: FocusSession) -> Bool { s.duration.map { $0.isFinite && $0 <= maxDuration } ?? true }

    /// Seconds as a whole number the display can take: 0 for anything not finite, never more than an Int32 (the format's %d).
    private static func whole(_ t: TimeInterval) -> Int { t.isFinite ? Int(max(-Double(Int32.max), min(t, Double(Int32.max)))) : 0 }

    /// "25m", "1h", "1h 30m", "1.5h", "90s" in seconds; a bare number is minutes. Nil for anything else, for zero and
    /// for more than a week.
    static func parseDuration(_ text: String) -> TimeInterval? {
        var rest = text.lowercased(), total = 0.0, parts = 0
        while !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let m = durationPart.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let number = Range(m.range(at: 1), in: rest), let unit = Range(m.range(at: 2), in: rest),
                  let value = Double(rest[number].replacingOccurrences(of: ",", with: ".")),
                  let seconds = rest[unit].isEmpty ? (parts == 0 ? 60 : nil) : units[String(rest[unit])]
            else { return nil }
            total += value * seconds
            parts += 1
            rest = String(rest[Range(m.range, in: rest)!.upperBound...])
        }
        return total > 0 && total <= maxDuration ? total : nil
    }

    /// The text `parseDuration` reads back: "25m", "1h 30m", "1m 30s".
    static func formatDuration(_ t: TimeInterval) -> String {
        let n = whole(t.rounded())
        return [(n / 3600, "h"), (n % 3600 / 60, "m"), (n % 60, "s")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }

    /// "24:13", or "1:02:05" from an hour on.
    static func clock(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The menu bar text: "◎ 24:13 Goal" counting down, "◎ Goal 12:40" counting up when open-ended, "⏸" while paused.
    static func statusTitle(_ s: FocusSession, now: Date) -> String {
        let goal = s.goal.count > 24 ? String(s.goal.prefix(23)) + "…" : s.goal
        let paused = s.runningSince == nil ? "⏸ " : ""
        guard let remaining = s.remaining(at: now) else { return "◎ \(paused)\(goal) \(clock(whole(s.elapsed(at: now))))" }
        return "◎ \(paused)\(clock(whole(remaining.rounded(.up)))) \(goal)"
    }

    /// Whether a running app is one of `names` (case-insensitive), by its display name or its file name.
    static func blocks(_ names: [String], appName: String?, fileName: String?) -> Bool {
        names.contains { n in [appName, fileName].contains { $0?.caseInsensitiveCompare(n) == .orderedSame } }
    }

    /// App names typed as "Slack, mail": the display names of the installed apps they match (case-insensitive, also by
    /// file name), and the names that match none.
    static func resolveApps(_ text: String, installed: [Item]) -> (names: [String], missing: [String]) {
        var names: [String] = [], missing: [String] = []
        for part in text.split(separator: ",") {
            let typed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { continue }
            if let app = installed.first(where: { ([$0.title] + $0.keywords).contains { $0.caseInsensitiveCompare(typed) == .orderedSame } }) {
                if !names.contains(app.title) { names.append(app.title) }
            } else {
                missing.append(typed)
            }
        }
        return (names, missing)
    }

    // MARK: Menu bar item

    /// The menu bar item of a running session, with Pause/Resume and Complete.
    private final class Bar: NSObject {
        static let shared = Bar()
        private var item: NSStatusItem?

        func show(_ s: FocusSession) {
            let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let menu = NSMenu()
            menu.addItem(withTitle: s.goal + (s.category.isEmpty ? "" : " · " + s.category), action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(.separator())
            menu.addItem(withTitle: s.runningSince == nil ? "Resume" : "Pause", action: #selector(toggle), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Complete", action: #selector(complete), keyEquivalent: "").target = self
            item.menu = menu
            update(s)
        }

        func update(_ s: FocusSession) { item?.button?.title = Focus.statusTitle(s, now: Date()) }

        func hide() {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
        }

        @objc private func toggle() { Focus.togglePause() }
        @objc private func complete() { Focus.complete() }
    }
}
