import AppKit

/// Books time in mite through the mite CLI (`mite book`), from a calendar event or from scratch.
/// Projects and services come from `mite projects` / `mite services`. The [[rule]] blocks of
/// ~/.config/mite-cli/calendar.toml (the rules `mite suggest` uses) and the last booking for the same
/// note preselect them, so a known meeting goes straight to the confirmation form.
enum Mite {
    struct Target: Codable, Equatable {
        let projectID: Int
        let projectName: String
        let serviceID: Int
        let serviceName: String
    }

    struct CatalogEntry: Equatable, Codable {
        let id: Int
        let name: String
        let customer: String
    }

    struct Rule: Equatable {
        var match = ""
        var projectID = 0
        var serviceID = 0
        var note: String? = nil
        var minutes: Int? = nil
    }

    // Kept on disk so project and service names show at once, refreshed in the background at launch.
    private static var projects: [CatalogEntry]? = Store.load("mite-projects.json")
    private static var services: [CatalogEntry]? = Store.load("mite-services.json")
    private static var loading: Set<String> = []
    private static var remembered: [String: Target] = Store.load("mite.json") ?? [:]   // last target per note

    static let executable: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/mite", "/opt/homebrew/bin/mite", "/usr/local/bin/mite"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Refreshes the project and service lists in the background; called once at launch.
    static func prefetch() {
        guard executable != nil else { return }
        load("projects")
        load("services")
    }

    static func commands() -> [Item] {
        guard executable != nil else { return [] }
        return [.command("mite.book", "Book Time in mite", kind: "mite", icon: "clock.badge.checkmark",
                         keywords: ["mite", "time", "zeit", "buchen", "zeiterfassung"], closes: false) {
            book(note: "", date: Date(), minutes: 30)
        }]
    }

    /// "Book in mite" for a calendar event; nil when the mite CLI is not installed.
    static func bookAction(title: String, start: Date, end: Date) -> Action? {
        guard executable != nil else { return nil }
        return Action(title: "Book in mite", icon: "clock.badge.checkmark", shortcut: Shortcut(.command, "b"), closes: false) {
            book(note: title, date: start, minutes: max(1, Int(end.timeIntervalSince(start) / 60)))
        }
    }

    // MARK: Flow: project → service → form

    static func book(note: String, date: Date, minutes: Int) {
        let rule = rules().first { matches($0, note) }
        let fixedMinutes = rule?.minutes ?? minutes
        let filledNote = rule?.note.map { fill($0, title: note, date: date) } ?? note
        if let target = (remembered[note] ?? rule.flatMap(target(for:))).map(named) {
            Launcher.shared.push(.form(form(note: filledNote, date: date, minutes: fixedMinutes, target: target, rememberAs: note)))
            return
        }
        Launcher.shared.push(.list(ListSpec(title: "mite Project", placeholder: "Search projects…") { q in
            catalogRows("projects", q, kind: "Project") { project in
                Launcher.shared.push(.list(ListSpec(title: "mite Service · " + project.name, placeholder: "Search services…") { q in
                    catalogRows("services", q, kind: "Service") { service in
                        let target = Target(projectID: project.id, projectName: project.name, serviceID: service.id, serviceName: service.name)
                        Launcher.shared.push(.form(form(note: filledNote, date: date, minutes: fixedMinutes, target: target, rememberAs: note)))
                    }
                }))
            }
        }))
    }

    private static func form(note: String, date: Date, minutes: Int, target: Target, rememberAs key: String) -> FormSpec {
        FormSpec(title: "Book in mite · " + target.projectName + " / " + target.serviceName,
                 fields: [FormField(label: "Note", value: note),
                          FormField(label: "Date", value: isoDate(date), placeholder: "YYYY-MM-DD"),
                          FormField(label: "Duration", value: "\(minutes)m", placeholder: "e.g. 45m, 1h30m, 1:30")],
                 submitTitle: "Book in mite") { values in
            guard let minutes = bookingMinutes(values[2]) else {
                return "Enter a duration from 1 minute to 24 hours, such as 45m or 1:30."
            }
            guard validBookingDate(values[1]) else { return "Enter a valid date in YYYY-MM-DD format." }
            guard target.projectID > 0, target.serviceID > 0 else { return "Select a valid mite project and service." }
            let duration = "\(minutes)m"
            let args = ["book", "-d", duration, "--note=" + values[0], "--date", values[1],
                        "-p", String(target.projectID), "-s", String(target.serviceID)]
            // Returning nil closes the form, so the booking cannot be submitted twice, and the slow CLI runs off the main thread.
            PanelController.shared.hide()
            HUD.show("Booking…")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run(args, input: "y\n")
                DispatchQueue.main.async {
                    if let failure = bookingFailure(ok: result.ok, output: result.output) {
                        HUD.show(failure)
                        return
                    }
                    if !key.isEmpty {
                        remembered[key] = target
                        Store.save(remembered, "mite.json")
                    }
                    HUD.show("Booked " + duration + " in mite")
                }
            }
            return nil
        }
    }

    private static let bookingDurationPattern = try! NSRegularExpression(
        pattern: #"(?:(?<clockHours>[0-9]+)\s*:\s*(?<clockMinutes>[0-9]+)|(?<hours>[0-9]+(?:\.[0-9]+)?)\s*h(?:\s*(?<hourMinutes>[0-9]+)\s*m)?|(?<minutes>[0-9]+)(?:\s*m)?)"#,
        options: .caseInsensitive
    )

    /// Parses the mite CLI's documented duration forms. One booking covers at most one calendar day.
    static func bookingMinutes(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let range = NSRange(location: 0, length: value.length)
        guard let match = bookingDurationPattern.firstMatch(in: value as String, range: range), match.range == range else {
            return nil
        }
        func number(_ name: String) -> Double {
            let part = match.range(withName: name)
            return part.location == NSNotFound ? 0 : Double(value.substring(with: part)) ?? .infinity
        }
        let hours = number("hours") + number("clockHours")
        let minutes = number("minutes") + number("clockMinutes") + number("hourMinutes")
        let total = (hours * 60).rounded(.down) + minutes
        guard (1...1440).contains(total) else { return nil }
        return Int(total)
    }

    static func validBookingDate(_ value: String) -> Bool {
        guard value.utf8.count == 10, let date = isoDateFormatter.date(from: value) else { return false }
        return isoDate(date) == value
    }

    static func bookingFailure(ok: Bool, output: String) -> String? {
        if ok, output.contains("Booked") { return nil }
        return "Could not confirm the booking. Check your entries in mite."
    }

    /// Rows of the cached project or service catalogue; loads it in the background on first use.
    private static func catalogRows(_ kind: String, _ q: String, kind label: String, choose: @escaping (CatalogEntry) -> Void) -> [Item] {
        guard let entries = kind == "projects" ? projects : services else {
            load(kind)
            return [Item(id: "mite.loading", title: "Loading " + kind + " from mite…", icon: .symbol("hourglass"), track: false, actions: [])]
        }
        let recent = Set(remembered.values.map { kind == "projects" ? $0.projectID : $0.serviceID })
        return entries
            .filter { q.isEmpty || matchScore(q, $0.name) > 0 || matchScore(q, $0.customer) > 0 }
            .sorted { recent.contains($0.id) && !recent.contains($1.id) }
            .map { e in
                Item(id: "mite.\(kind).\(e.id)", title: e.name, subtitle: e.customer, kind: label, icon: .symbol("folder"),
                     section: recent.contains(e.id) ? "Recently Used" : "", track: false,
                     actions: [Action(title: "Choose " + label, icon: "checkmark", closes: false) { choose(e) }])
            }
    }

    private static func load(_ kind: String) {
        guard !loading.contains(kind) else { return }
        loading.insert(kind)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run([kind])
            let entries = parseCatalog(result.output)
            DispatchQueue.main.async {
                loading.remove(kind)
                guard result.ok else { return }   // keep the cached list when mite cannot be reached
                if kind == "projects" { projects = entries } else { services = entries }
                Store.save(entries, "mite-\(kind).json")
                Launcher.shared.reload()
            }
        }
    }

    /// The target with current project and service names from the cached lists.
    private static func named(_ t: Target) -> Target {
        Target(projectID: t.projectID, projectName: projects?.first { $0.id == t.projectID }?.name ?? t.projectName,
               serviceID: t.serviceID, serviceName: services?.first { $0.id == t.serviceID }?.name ?? t.serviceName)
    }

    private static func target(for rule: Rule) -> Target? {
        guard rule.projectID > 0, rule.serviceID > 0 else { return nil }
        let project = projects?.first { $0.id == rule.projectID }?.name ?? "Project \(rule.projectID)"
        let service = services?.first { $0.id == rule.serviceID }?.name ?? "Service \(rule.serviceID)"
        return Target(projectID: rule.projectID, projectName: project, serviceID: rule.serviceID, serviceName: service)
    }

    // MARK: Pure helpers

    /// Parses `mite projects` / `mite services` output: "     123  Name  (Customer)".
    static func parseCatalog(_ output: String) -> [CatalogEntry] {
        let pattern = try! NSRegularExpression(pattern: #"^\s*(\d+)  (.+?)(?:  \((.*)\))?\s*$"#)
        return output.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let id = Range(m.range(at: 1), in: s).flatMap({ Int(s[$0]) }),
                  let name = Range(m.range(at: 2), in: s).map({ String(s[$0]) }) else { return nil }
            let customer = Range(m.range(at: 3), in: s).map { String(s[$0]) } ?? ""
            return CatalogEntry(id: id, name: name, customer: customer)
        }
    }

    /// Reads the [[rule]] blocks of calendar.toml (basic and literal strings, integers).
    static func parseRules(_ toml: String) -> [Rule] {
        var rules: [Rule] = [], current: Rule?
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { rules.append(current) }
                current = line == "[[rule]]" ? Rule() : nil
                continue
            }
            guard current != nil, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = tomlValue(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            switch key {
            case "match": current?.match = value
            case "project_id": current?.projectID = Int(value) ?? 0
            case "service_id": current?.serviceID = Int(value) ?? 0
            case "note": current?.note = value
            case "minutes": current?.minutes = Int(value)
            default: break
            }
        }
        if let current { rules.append(current) }
        return rules
    }

    private static func tomlValue(_ v: String) -> String {
        if v.hasPrefix("'"), let end = v.dropFirst().firstIndex(of: "'") { return String(v[v.index(after: v.startIndex)..<end]) }
        guard v.hasPrefix("\"") else { return String(v.prefix { $0 != " " && $0 != "#" }) }
        var out = "", escaped = false
        for c in v.dropFirst() {
            if escaped { out.append(c == "n" ? "\n" : c == "t" ? "\t" : c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { break }
            else { out.append(c) }
        }
        return out
    }

    static func matches(_ rule: Rule, _ title: String) -> Bool {
        guard !rule.match.isEmpty, let re = try? NSRegularExpression(pattern: rule.match) else { return false }
        return re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    static func fill(_ template: String, title: String, date: Date) -> String {
        template.replacingOccurrences(of: "{title}", with: title).replacingOccurrences(of: "{date}", with: isoDate(date))
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func isoDate(_ d: Date) -> String { isoDateFormatter.string(from: d) }

    private static func rules() -> [Rule] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mite-cli/calendar.toml")
        return (try? String(contentsOf: path, encoding: .utf8)).map(parseRules) ?? []
    }

    /// Runs the mite CLI; output is uncoloured because stdout is not a terminal.
    private static func run(_ args: [String], input: String? = nil) -> (ok: Bool, output: String) {
        guard let executable else { return (false, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), stdin = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = stdin
        do { try p.run() } catch { return (false, "") }
        if let input {
            // A process that already exited would raise SIGPIPE, which ends Lumen; with this flag the write just throws.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        }
        try? stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

extension Mite.Target {
    /// Only the IDs are required: a decode that fails on a missing key would drop every remembered target. The
    /// names fall back to the same placeholders as a rule target and are replaced from the cached catalogue.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(Int.self, forKey: .projectID)
        serviceID = try c.decode(Int.self, forKey: .serviceID)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? "Project \(projectID)"
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? "Service \(serviceID)"
    }
}
