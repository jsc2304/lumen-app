import AppKit

/// GitHub across all repositories through the gh CLI: pull requests, review requests, issues,
/// notifications and repositories. Lists open from a cache (memory and gh-cache.json) and refresh in
/// the background when the data is older than two minutes or on ⌘R. Read-only towards GitHub, except
/// "Mark as Read" on a notification.
enum GitHub {
    // MARK: Model

    /// A pull request or an issue.
    struct Ticket: Codable, Equatable {
        let title: String
        let url: String
        let repo: String        // owner/name
        let number: Int
        let author: String
        let body: String        // Markdown, already cleaned and trimmed by preview()
        let labels: [String]
        let comments: Int
        let updated: Date
        let isPull: Bool
        let draft: Bool
    }

    struct Note: Codable, Equatable {
        let id: String          // thread id, for Mark as Read
        let title: String
        let type: String        // PullRequest, Issue, CheckSuite, …
        let reason: String
        let repo: String        // owner/name
        let url: String         // web URL
        let updated: Date
    }

    struct Repo: Codable, Equatable {
        let owner: String
        let name: String
        let description: String
        let isPrivate: Bool
        let isArchived: Bool
        let language: String
        let stars: Int
        let pushed: Date

        var full: String { owner + "/" + name }
    }

    enum Source: String {
        case review, mine, assigned, created, notifications, repos

        /// Seconds until the cached data is refreshed in the background; the repository list changes rarely.
        var maxAge: TimeInterval { self == .repos ? 3600 : 120 }
    }

    enum Failure: Error, Equatable {
        case missing, notLoggedIn
        case couldNotStart, timedOut, unexpectedResponse, requestFailed
    }

    private enum Payload {
        case tickets([Ticket]), notes([Note]), repos([Repo])
    }

    private struct Cache: Codable {
        var tickets: [String: [Ticket]] = [:]   // by Source.rawValue
        var notes: [Note] = []
        var repos: [Repo] = []
        var fetched: [String: Date] = [:]
    }

    // Main thread only; the gh calls run in the background and hand their results over.
    private static var cache: Cache = Store.load("gh-cache.json") ?? Cache()
    private static var loading: Set<Source> = []
    private static var attempted: [Source: Date] = [:]
    private static var problems: [Source: Failure] = [:]

    static let ticketLimit = 50         // per search
    static let overviewLimit = 30       // rows per section in the overview
    static let notificationLimit = 100  // one page of the notifications API

    // MARK: Commands

    static func commands() -> [Item] {
        let common = ["github", "gh", "pr", "pull request", "issue"]
        func command(_ id: String, _ title: String, icon: String, _ extra: [String], _ show: @escaping () -> Void) -> Item {
            .command(id, title, kind: "GitHub", icon: icon, keywords: common + extra, closes: false, run: show)
        }
        return [
            command("gh.overview", "GitHub", icon: "chevron.left.forwardslash.chevron.right",
                    ["review", "notifications", "repo", "overview"]) {
                show("GitHub", "Search pull requests, issues and notifications…") { overview($0) }
            },
            command("gh.my-prs", "My Pull Requests", icon: "arrow.triangle.pull", ["mine", "open", "author"]) {
                show("My Pull Requests", "Search my pull requests…") { tickets([.mine], $0, empty: "No open pull requests") }
            },
            command("gh.review-requests", "Review Requests", icon: "eye", ["review", "requested", "reviewer"]) {
                show("Review Requests", "Search review requests…") { tickets([.review], $0, empty: "No review requests") }
            },
            command("gh.my-issues", "My Issues", icon: "smallcircle.filled.circle", ["assigned", "created", "mine", "open"]) {
                show("My Issues", "Search my issues…") { tickets([.assigned, .created], $0, empty: "No open issues") }
            },
            command("gh.notifications", "Notifications", icon: "bell", ["unread", "inbox"], showNotifications),
            command("gh.repos", "Search Repositories", icon: "books.vertical", ["repo", "repository", "organisation", "organization", "org"]) {
                show("Repositories", "Search repositories…") { repositories($0) }
            },
        ]
    }

    private static func show(_ title: String, _ placeholder: String, items: @escaping (String) -> [Item]) {
        Launcher.shared.push(.list(ListSpec(title: title, placeholder: placeholder, showsDetail: true, items: items)))
    }

    private static func showNotifications() {
        show("Notifications", "Search notifications…") { notifications($0) }
    }

    // MARK: Lists

    private static func overview(_ q: String) -> [Item] {
        let sources: [Source] = [.review, .mine, .assigned, .notifications]
        sources.forEach { update($0) }
        var rows = statusRows(sources)
        for (title, source) in [("Review Requested", Source.review), ("My Pull Requests", .mine), ("Assigned Issues", .assigned)] {
            rows += (cache.tickets[source.rawValue] ?? []).filter { matches($0, q) }.prefix(overviewLimit)
                .map { ticketItem($0, refreshing: sources).inSection(title) }
        }
        if q.isEmpty || matchScore(q, "Notifications") > 0 {
            let n = cache.notes.count
            let count = n >= notificationLimit ? "\(n)+" : "\(n)"
            rows.append(Item(id: "gh.notifications.count", title: n == 0 ? "No unread notifications" : count + (n == 1 ? " unread notification" : " unread notifications"),
                             kind: "Notifications", icon: .symbol(n == 0 ? "bell" : "bell.badge"), track: false,
                             actions: [Action(title: "Open Notifications", icon: "bell", closes: false, run: showNotifications),
                                       refreshAction(sources)]).inSection("Unread Notifications"))
        }
        return rows
    }

    private static func tickets(_ sources: [Source], _ q: String, empty: String) -> [Item] {
        sources.forEach { update($0) }
        let found = merged(sources.map { cache.tickets[$0.rawValue] ?? [] }).filter { matches($0, q) }
        return withStatus(sources, found.map { ticketItem($0, refreshing: sources) }, q, empty)
    }

    private static func notifications(_ q: String) -> [Item] {
        update(.notifications)
        let found = cache.notes.filter { n in [n.title, n.repo, n.reason, n.type].contains { matchScore(q, $0) > 0 } }
        return withStatus([.notifications], found.map(noteItem), q, "No unread notifications")
    }

    private static func repositories(_ q: String) -> [Item] {
        update(.repos)
        return withStatus([.repos], rankedRepos(cache.repos, q).map(repoItem), q, "No repositories")
    }

    /// Problem and loading rows above the data; a single "nothing here" row when a loaded list is empty.
    private static func withStatus(_ sources: [Source], _ rows: [Item], _ q: String, _ empty: String) -> [Item] {
        let status = statusRows(sources)
        if rows.isEmpty, status.isEmpty, q.isEmpty {
            return [Item(id: "gh.empty", title: empty, icon: .symbol("checkmark.circle"), track: false, actions: [refreshAction(sources)])]
        }
        return status + rows
    }

    private static func statusRows(_ sources: [Source]) -> [Item] {
        if let failure = sources.lazy.compactMap({ problems[$0] }).first {
            let title: String, subtitle: String
            var actions = [Action(title: "Try Again", icon: "arrow.clockwise", shortcut: Shortcut(.command, "r"), closes: false) {
                sources.forEach { update($0, force: true) }
            }]
            switch failure {
            case .missing, .notLoggedIn:
                title = failure == .missing ? "GitHub CLI not found" : "GitHub CLI is not logged in"
                subtitle = failure == .missing ? "Install it with “brew install gh”, then run “gh auth login”"
                                               : "Run “gh auth login” in Terminal, then try again"
                actions.append(.copy("Copy “gh auth login”") { "gh auth login" })
            case .couldNotStart:
                (title, subtitle) = ("Could not start GitHub CLI", "Check that gh runs in Terminal, then try again")
            case .timedOut:
                (title, subtitle) = ("GitHub took too long to respond", "Check your connection, then try again")
            case .unexpectedResponse:
                (title, subtitle) = ("Unexpected response from GitHub CLI", "Try again or check for a gh update")
            case .requestFailed:
                (title, subtitle) = ("Could not load from GitHub", "Check your connection and repository access, then try again")
            }
            return [Item(id: "gh.problem", title: title, subtitle: subtitle, kind: "gh", icon: .symbol("exclamationmark.triangle"),
                         track: false, actions: actions)]
        }
        if sources.contains(where: { cache.fetched[$0.rawValue] == nil }) {
            return [Item(id: "gh.loading", title: "Loading from GitHub…", icon: .symbol("hourglass"), track: false, actions: [])]
        }
        return []
    }

    // MARK: Rows

    static func ticketItem(_ t: Ticket, refreshing sources: [Source]) -> Item {
        let repoURL = "https://github.com/" + t.repo
        var meta = [("Repository", t.repo), ("Author", t.author)]
        if !t.labels.isEmpty { meta.append(("Labels", t.labels.joined(separator: ", "))) }
        meta += [("Comments", "\(t.comments)"), ("Updated", t.updated.formatted(date: .abbreviated, time: .shortened))]
        return Item(id: "gh.\(t.repo)#\(t.number)", title: t.title, subtitle: "\(t.repo)#\(t.number)", kind: t.draft ? "Draft" : age(t.updated),
                    icon: .symbol(!t.isPull ? "smallcircle.filled.circle" : t.draft ? "circle.dotted" : "arrow.triangle.pull"), track: false,
                    actions: [openAction("Open in Browser", t.url),
                              .copy("Copy URL") { t.url },
                              .copy("Copy Title", shortcut: Shortcut([.command, .shift], "c")) { t.title },
                              .copy("Copy Number", shortcut: Shortcut([.command, .shift], "n")) { "#\(t.number)" },
                              openAction("Open Repository", repoURL, shortcut: Shortcut([.command, .shift], "o")),
                              refreshAction(sources)],
                    detail: Detail(markdown: "**\(t.title)**\n\n" + (t.body.isEmpty ? "No description provided." : t.body), metadata: meta))
    }

    static func noteItem(_ n: Note) -> Item {
        let icon = switch n.type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Discussion": "bubble.left.and.bubble.right"
        case "CheckSuite": "play.circle"
        default: "bell"
        }
        return Item(id: "gh.note." + n.id, title: n.title, subtitle: n.repo, kind: age(n.updated), icon: .symbol(icon), track: false,
                    actions: [openAction("Open", n.url),
                              .copy("Copy URL") { n.url },
                              Action(title: "Mark as Read", icon: "checkmark.circle", shortcut: Shortcut([.command, .shift], "r"), closes: false) { markRead(n) },
                              refreshAction([.notifications])],
                    detail: Detail(markdown: "**\(n.title)**", metadata: [
                        ("Repository", n.repo), ("Type", n.type), ("Reason", n.reason.replacingOccurrences(of: "_", with: " ")),
                        ("Updated", n.updated.formatted(date: .abbreviated, time: .shortened))]))
    }

    static func repoItem(_ r: Repo) -> Item {
        let web = "https://github.com/" + r.full
        var meta = [("Visibility", r.isPrivate ? "Private" : "Public")]
        if !r.language.isEmpty { meta.append(("Language", r.language)) }
        meta += [("Stars", "\(r.stars)"), ("Last push", r.pushed.formatted(date: .abbreviated, time: .shortened))]
        return Item(id: "gh.repo." + r.full, title: r.name, subtitle: r.owner, kind: r.isArchived ? "Archived" : r.isPrivate ? "Private" : "Public",
                    icon: .symbol(r.isPrivate ? "lock" : "book.closed"), track: false,
                    actions: [openAction("Open in Browser", web),
                              .copy("Copy Clone URL") { "git@github.com:\(r.full).git" },
                              .copy("Copy HTTPS URL", shortcut: Shortcut([.command, .shift], "c")) { web + ".git" },
                              openAction("Open Pull Requests", web + "/pulls", shortcut: Shortcut([.command, .shift], "p")),
                              openAction("Open Issues", web + "/issues", shortcut: Shortcut([.command, .shift], "i")),
                              refreshAction([.repos])],
                    detail: Detail(markdown: r.description, metadata: meta))
    }

    private static func openAction(_ title: String, _ url: String, shortcut: Shortcut? = nil) -> Action {
        Action(title: title, icon: "arrow.up.forward.square", shortcut: shortcut) {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
    }

    private static func refreshAction(_ sources: [Source]) -> Action {
        Action(title: "Refresh", icon: "arrow.clockwise", shortcut: Shortcut(.command, "r"), closes: false) {
            HUD.show("Refreshing GitHub…")
            sources.forEach { update($0, force: true) }
        }
    }

    // MARK: Loading

    /// Fetches `source` in the background unless it is fresh or already loading, then reloads the list.
    private static func update(_ source: Source, force: Bool = false) {
        let last = max(attempted[source] ?? .distantPast, cache.fetched[source.rawValue] ?? .distantPast)
        guard !loading.contains(source), force || Date().timeIntervalSince(last) > source.maxAge else { return }
        loading.insert(source)
        attempted[source] = Date()   // a failed attempt waits out maxAge too, so reload() cannot loop
        DispatchQueue.global(qos: .userInitiated).async {
            let result = download(source)
            DispatchQueue.main.async {
                loading.remove(source)
                switch result {
                case .failure(let failure):
                    problems[source] = failure
                case .success(let payload):
                    problems[source] = nil
                    switch payload {
                    case .tickets(let list): cache.tickets[source.rawValue] = list
                    case .notes(let list): cache.notes = list
                    case .repos(let list): cache.repos = list
                    }
                    cache.fetched[source.rawValue] = Date()
                    Store.save(cache, "gh-cache.json")
                }
                Launcher.shared.reload()
            }
        }
    }

    private static func markRead(_ n: Note) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(["api", "-X", "PATCH", "notifications/threads/" + n.id, "--silent"])
            DispatchQueue.main.async {
                guard case .success = result else { HUD.show("Could not mark as read"); return }
                cache.notes.removeAll { $0.id == n.id }
                Store.save(cache, "gh-cache.json")
                Launcher.shared.reload()
                HUD.show("Marked as Read")
            }
        }
    }

    private static func download(_ source: Source) -> Result<Payload, Failure> {
        switch source {
        case .review: return search("prs", "--review-requested=@me")
        case .mine: return search("prs", "--author=@me")
        case .assigned: return search("issues", "--assignee=@me")
        case .created: return search("issues", "--author=@me")
        case .notifications:
            return run(["api", "notifications?per_page=\(notificationLimit)"]).flatMap { data in
                parseNotes(data).map { .success(.notes($0)) } ?? .failure(.unexpectedResponse)
            }
        case .repos: return downloadRepos()
        }
    }

    private static func search(_ kind: String, _ filter: String) -> Result<Payload, Failure> {
        let pull = kind == "prs"
        let fields = "number,title,url,repository,author,labels,commentsCount,updatedAt,body" + (pull ? ",isDraft" : "")
        return run(["search", kind, filter, "--state=open", "--sort", "updated", "--order", "desc",
                    "--limit", "\(ticketLimit)", "--json", fields]).flatMap { data in
            parseTickets(data, pull: pull).map { .success(.tickets($0)) } ?? .failure(.unexpectedResponse)
        }
    }

    /// The signed-in user's repositories plus those of each organisation. A failing organisation (for
    /// example one that enforces SAML) is skipped; only a failing user list fails the refresh.
    private static func downloadRepos() -> Result<Payload, Failure> {
        let orgs: [String]
        switch run(["api", "user/orgs?per_page=100"]) {
        case .failure(let failure): return .failure(failure)
        case .success(let data): orgs = ((try? JSONDecoder().decode([Login].self, from: data)) ?? []).map(\.login)
        }
        let owners = [""] + orgs   // "" lists the user's own repositories
        let fields = "nameWithOwner,description,isPrivate,isArchived,pushedAt,primaryLanguage,stargazerCount"
        var results = [Result<Data, Failure>](repeating: .failure(.unexpectedResponse), count: owners.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: owners.count) { i in
            let result = run(["repo", "list"] + (owners[i].isEmpty ? [] : [owners[i]]) + ["--limit", "1000", "--json", fields])
            lock.lock()
            results[i] = result
            lock.unlock()
        }
        var repos: [Repo] = []
        for (i, result) in results.enumerated() {
            switch result {
            case .success(let data):
                guard let list = parseRepos(data) else { if i == 0 { return .failure(.unexpectedResponse) } else { continue } }
                repos += list
            case .failure(let failure):
                if i == 0 { return .failure(failure) }
            }
        }
        return .success(.repos(repos.sorted { $0.pushed > $1.pushed }))
    }

    private struct Login: Decodable { let login: String }

    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs gh and returns its standard output. Gives up after 30 seconds so a dead network cannot
    /// leave a list loading forever.
    private static func run(_ args: [String]) -> Result<Data, Failure> {
        guard let executable else { return .failure(.missing) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.couldNotStart) }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        timeout.cancel()
        if p.terminationStatus == 0 { return .success(data) }
        return .failure(p.terminationReason == .uncaughtSignal ? .timedOut : failure(status: p.terminationStatus, message: message))
    }

    // MARK: Pure helpers

    /// gh exits with 4 when it needs authentication.
    static func failure(status: Int32, message: String) -> Failure {
        if status == 4 || message.contains("gh auth login") { return .notLoggedIn }
        return .requestFailed
    }

    private struct SearchHit: Decodable {
        struct Person: Decodable { let login: String }
        struct Repository: Decodable { let nameWithOwner: String }
        struct Label: Decodable { let name: String }
        let number: Int
        let title: String
        let url: String
        let body: String?
        let updatedAt: String
        let author: Person?
        let repository: Repository
        let labels: [Label]?
        let commentsCount: Int?
        let isDraft: Bool?
    }

    /// Parses `gh search prs|issues --json …`.
    static func parseTickets(_ data: Data, pull: Bool) -> [Ticket]? {
        guard let hits = try? JSONDecoder().decode([SearchHit].self, from: data) else { return nil }
        return hits.map {
            Ticket(title: $0.title, url: $0.url, repo: $0.repository.nameWithOwner, number: $0.number, author: $0.author?.login ?? "ghost",
                   body: preview($0.body ?? ""), labels: ($0.labels ?? []).map(\.name), comments: $0.commentsCount ?? 0,
                   updated: date($0.updatedAt), isPull: pull, draft: $0.isDraft ?? false)
        }
    }

    private struct NoteJSON: Decodable {
        struct Subject: Decodable { let title: String; let url: String?; let type: String }
        struct Repository: Decodable { let fullName: String; let htmlUrl: String }
        let id: String
        let reason: String
        let updatedAt: String
        let subject: Subject
        let repository: Repository
    }

    /// Parses `gh api notifications`.
    static func parseNotes(_ data: Data) -> [Note]? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let list = try? decoder.decode([NoteJSON].self, from: data) else { return nil }
        return list.map {
            Note(id: $0.id, title: $0.subject.title, type: $0.subject.type, reason: $0.reason, repo: $0.repository.fullName,
                 url: webURL(subject: $0.subject.url, type: $0.subject.type, repo: $0.repository.htmlUrl), updated: date($0.updatedAt))
        }
    }

    private struct RepoJSON: Decodable {
        struct Language: Decodable { let name: String }
        let nameWithOwner: String
        let description: String?
        let isPrivate: Bool
        let isArchived: Bool
        let pushedAt: String?
        let primaryLanguage: Language?
        let stargazerCount: Int
    }

    /// Parses `gh repo list --json …`.
    static func parseRepos(_ data: Data) -> [Repo]? {
        guard let list = try? JSONDecoder().decode([RepoJSON].self, from: data) else { return nil }
        return list.compactMap { r in
            let parts = r.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return Repo(owner: parts[0], name: parts[1], description: r.description ?? "", isPrivate: r.isPrivate, isArchived: r.isArchived,
                        language: r.primaryLanguage?.name ?? "", stars: r.stargazerCount, pushed: date(r.pushedAt))
        }
    }

    /// The page for a notification. `subject` is the API URL (https://api.github.com/repos/o/r/pulls/7),
    /// `repo` the repository's web URL. Subjects without an API URL (CI runs) and unknown kinds fall
    /// back to the repository.
    static func webURL(subject: String?, type: String, repo: String) -> String {
        guard let subject, let parts = URL(string: subject)?.pathComponents, parts.count >= 6, parts[1] == "repos" else {
            return type == "CheckSuite" ? repo + "/actions" : repo
        }
        let kind = parts[4], id = parts[5]
        switch kind {
        case "pulls": return "\(repo)/pull/\(id)"
        case "issues", "discussions": return "\(repo)/\(kind)/\(id)"
        case "commits": return "\(repo)/commit/\(id)"
        case "releases": return repo + "/releases"
        default: return repo
        }
    }

    /// "now", "5m", "2h", "3d", "2mo", "1y".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        case ..<(30 * 86_400): return "\(s / 86_400)d"
        case ..<(365 * 86_400): return "\(s / (30 * 86_400))mo"
        default: return "\(s / (365 * 86_400))y"
        }
    }

    private static let htmlComments = try! NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators)

    private static func date(_ s: String?) -> Date { s.flatMap { try? Date($0, strategy: .iso8601) } ?? .distantPast }

    /// A body for the detail pane: without HTML comments (pull request templates are full of them),
    /// trimmed, and cut at `limit` characters.
    static func preview(_ body: String, limit: Int = 4000) -> String {
        let clean = htmlComments.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    /// Whether the query matches the title, repository, number, author or a label.
    static func matches(_ t: Ticket, _ q: String) -> Bool {
        ([t.title, t.repo, String(t.number), "#\(t.number)", t.author] + t.labels).contains { matchScore(q, $0) > 0 }
    }

    /// Several lists as one: each ticket once, newest update first.
    static func merged(_ lists: [[Ticket]]) -> [Ticket] {
        var seen = Set<String>()
        return lists.joined().filter { seen.insert($0.url).inserted }.sorted { $0.updated > $1.updated }
    }

    /// Repositories matching the query by name or owner/name, best match first; without a query by last push.
    static func rankedRepos(_ repos: [Repo], _ q: String) -> [Repo] {
        guard !q.isEmpty else { return repos }
        return repos.enumerated()
            .compactMap { i, r -> (Int, Double, Repo)? in
                let score = max(matchScore(q, r.name), matchScore(q, r.full))
                return score > 0 ? (i, score, r) : nil
            }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }   // higher score first, then the earlier position
            .map(\.2)
    }
}
