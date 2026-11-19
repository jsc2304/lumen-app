import Foundation

// Invented sample data in the shapes gh prints; no real repositories, titles or people.

private let prJSON = """
[{"number": 42, "title": "Add retry to the sync job", "url": "https://github.com/acme/widgets/pull/42",
  "repository": {"name": "widgets", "nameWithOwner": "acme/widgets"}, "author": {"login": "alex", "is_bot": false},
  "labels": [{"name": "bug", "color": "d73a4a"}, {"name": "backend", "color": "0e8a16"}], "commentsCount": 3,
  "updatedAt": "2026-10-21T18:17:44Z", "isDraft": false, "body": "Fixes the flaky sync.\\r\\n\\r\\n<!-- template hint\\nstays out -->\\nSecond line."},
 {"number": 7, "title": "WIP: new importer", "url": "https://github.com/acme/tools/pull/7",
  "repository": {"name": "tools", "nameWithOwner": "acme/tools"}, "author": {"login": "sam"}, "labels": null,
  "commentsCount": 0, "updatedAt": "2026-10-20T08:00:00Z", "isDraft": true, "body": null}]
""".data(using: .utf8)!

private let issueJSON = """
[{"number": 9, "title": "Crash on empty input", "url": "https://github.com/acme/widgets/issues/9",
  "repository": {"name": "widgets", "nameWithOwner": "acme/widgets"}, "author": {"login": "kim"},
  "labels": [], "commentsCount": 1, "updatedAt": "2026-10-19T12:30:00Z", "body": "Steps to reproduce"}]
""".data(using: .utf8)!

private let notesJSON = """
[{"id": "1001", "unread": true, "reason": "review_requested", "updated_at": "2026-10-22T09:00:00Z",
  "subject": {"title": "Add retry to the sync job", "url": "https://api.github.com/repos/acme/widgets/pulls/42",
              "latest_comment_url": null, "type": "PullRequest"},
  "repository": {"full_name": "acme/widgets", "html_url": "https://github.com/acme/widgets", "private": true}},
 {"id": "1002", "unread": true, "reason": "ci_activity", "updated_at": "2026-10-22T08:00:00Z",
  "subject": {"title": "CI workflow run failed for main", "url": null, "latest_comment_url": null, "type": "CheckSuite"},
  "repository": {"full_name": "acme/tools", "html_url": "https://github.com/acme/tools"}}]
""".data(using: .utf8)!

private let reposJSON = """
[{"nameWithOwner": "acme/widgets", "description": "Widget factory", "isPrivate": true, "isArchived": false,
  "pushedAt": "2026-10-21T10:00:00Z", "primaryLanguage": {"name": "Swift"}, "stargazerCount": 12},
 {"nameWithOwner": "acme/old-tools", "description": null, "isPrivate": false, "isArchived": true,
  "pushedAt": null, "primaryLanguage": null, "stargazerCount": 0}]
""".data(using: .utf8)!

private func ticket(_ title: String, repo: String = "acme/widgets", number: Int = 1, author: String = "alex",
                    labels: [String] = [], updated: Double = 0, isPull: Bool = true, draft: Bool = false) -> GitHub.Ticket {
    GitHub.Ticket(title: title, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, number: number, author: author, body: "",
                  labels: labels, comments: 0, updated: Date(timeIntervalSince1970: updated), isPull: isPull, draft: draft)
}

func checkGitHub() {
    checkGitHubParsing()
    checkGitHubWebURL()
    checkGitHubHelpers()
    checkGitHubRows()
}

private func checkGitHubParsing() {
    let prs = GitHub.parseTickets(prJSON, pull: true)
    expect(prs?.count == 2, "pull requests decode")
    if let pr = prs?.first {
        expect(pr.title == "Add retry to the sync job" && pr.repo == "acme/widgets" && pr.number == 42, "pull request identity")
        expect(pr.author == "alex" && pr.labels == ["bug", "backend"] && pr.comments == 3, "pull request author, labels, comments")
        expect(pr.isPull && !pr.draft, "pull request is not a draft")
        expect(pr.updated == Date(timeIntervalSince1970: 1_792_606_664), "updatedAt is parsed as UTC")
        expect(pr.body == "Fixes the flaky sync.\n\n\nSecond line.", "body loses HTML comments and carriage returns")
    }
    if let draft = prs?.last {
        expect(draft.draft && draft.labels.isEmpty && draft.body.isEmpty, "draft with null labels and null body")
    }
    let issues = GitHub.parseTickets(issueJSON, pull: false)
    expect(issues?.count == 1 && issues?[0].isPull == false && issues?[0].draft == false, "issues decode without isDraft")
    expect(GitHub.parseTickets(Data("[]".utf8), pull: true)?.isEmpty == true, "empty search result")
    expect(GitHub.parseTickets(Data("{\"message\": \"Bad credentials\"}".utf8), pull: true) == nil, "an error object is not a list")

    let notes = GitHub.parseNotes(notesJSON)
    expect(notes?.count == 2, "notifications decode")
    expect(notes?[0].id == "1001" && notes?[0].reason == "review_requested" && notes?[0].repo == "acme/widgets", "notification fields")
    expect(notes?[0].url == "https://github.com/acme/widgets/pull/42", "pull request notification opens the pull request")
    expect(notes?[1].url == "https://github.com/acme/tools/actions", "CI notification without a subject URL opens the Actions page")

    let repos = GitHub.parseRepos(reposJSON)
    expect(repos?.count == 2, "repositories decode")
    expect(repos?[0].owner == "acme" && repos?[0].name == "widgets" && repos?[0].full == "acme/widgets", "repository owner and name")
    expect(repos?[0].language == "Swift" && repos?[0].stars == 12 && repos?[0].isPrivate == true, "repository details")
    expect(repos?[1].language == "" && repos?[1].description == "" && repos?[1].isArchived == true, "repository with null language and description")

    let cache = try? JSONEncoder().encode(prs ?? [])
    expect(cache.flatMap { try? JSONDecoder().decode([GitHub.Ticket].self, from: $0) } == prs, "tickets survive the cache round trip")
}

private func checkGitHubWebURL() {
    let repo = "https://github.com/acme/widgets"
    func web(_ path: String?, _ type: String = "Issue") -> String {
        GitHub.webURL(subject: path.map { "https://api.github.com/repos/acme/widgets/" + $0 }, type: type, repo: repo)
    }
    expect(web("pulls/42", "PullRequest") == repo + "/pull/42", "pulls/N becomes pull/N")
    expect(web("issues/9") == repo + "/issues/9", "issues/N stays issues/N")
    expect(web("commits/abc123", "Commit") == repo + "/commit/abc123", "commits/SHA becomes commit/SHA")
    expect(web("discussions/5", "Discussion") == repo + "/discussions/5", "discussions/N stays")
    expect(web("releases/12345", "Release") == repo + "/releases", "a release id has no web page, so the releases page opens")
    expect(web("check-suites/1", "CheckSuite") == repo, "unknown kinds fall back to the repository")
    expect(web(nil) == repo, "no subject URL falls back to the repository")
    expect(web(nil, "CheckSuite") == repo + "/actions", "no subject URL on a CI run opens Actions")
    expect(GitHub.webURL(subject: "not a url", type: "Issue", repo: repo) == repo, "garbage subject falls back to the repository")
    expect(GitHub.webURL(subject: "https://api.github.com/repos/acme/widgets", type: "Issue", repo: repo) == repo, "a short subject path falls back")
}

private func checkGitHubHelpers() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func age(_ seconds: Double) -> String { GitHub.age(now.addingTimeInterval(-seconds), now: now) }
    expect(age(5) == "now" && age(-100) == "now", "just now, also for clocks slightly ahead")
    expect(age(59 * 60) == "59m" && age(3600) == "1h", "minutes and hours")
    expect(age(2 * 3600 + 100) == "2h" && age(24 * 3600) == "1d" && age(3 * 86_400 + 5000) == "3d", "hours and days")
    expect(age(29 * 86_400) == "29d" && age(30 * 86_400) == "1mo" && age(200 * 86_400) == "6mo", "days and months")
    expect(age(365 * 86_400) == "1y" && age(800 * 86_400) == "2y", "years")

    expect(GitHub.preview("  hello\r\nworld \n") == "hello\nworld", "preview trims and normalises line breaks")
    expect(GitHub.preview("a<!-- x\ny -->b<!--z-->c") == "abc", "preview removes multi-line HTML comments")
    expect(GitHub.preview(String(repeating: "x", count: 5000)).count == 4001, "preview is cut at 4000 characters plus an ellipsis")
    expect(GitHub.preview(String(repeating: "x", count: 4000)).count == 4000, "a body of exactly 4000 characters is kept")
    expect(GitHub.preview("") == "", "empty body")

    let t = ticket("Fix login redirect", repo: "acme/widgets", number: 128, author: "robin", labels: ["needs-review"])
    expect(GitHub.matches(t, ""), "empty query matches everything")
    expect(GitHub.matches(t, "login"), "matches the title")
    expect(GitHub.matches(t, "widgets"), "matches the repository")
    expect(GitHub.matches(t, "128") && GitHub.matches(t, "#128"), "matches the number")
    expect(GitHub.matches(t, "robin"), "matches the author")
    expect(GitHub.matches(t, "needs"), "matches a label")
    expect(!GitHub.matches(t, "zzz"), "does not match unrelated text")

    let a = ticket("A", number: 1, updated: 100), b = ticket("B", number: 2, updated: 300), c = ticket("C", number: 3, updated: 200)
    expect(GitHub.merged([[a, c], [b, c]]).map(\.title) == ["B", "C", "A"], "merged lists drop duplicates and sort newest first")
    expect(GitHub.merged([]).isEmpty, "merging nothing")

    let repos = GitHub.parseRepos(reposJSON) ?? []
    expect(GitHub.rankedRepos(repos, "").map(\.name) == ["widgets", "old-tools"], "repositories keep their order without a query")
    expect(GitHub.rankedRepos(repos, "old").map(\.name) == ["old-tools"], "repositories are filtered by name")
    expect(GitHub.rankedRepos(repos, "acme/w").map(\.name) == ["widgets"], "repositories match owner/name")
    expect(GitHub.rankedRepos(repos, "zzz").isEmpty, "no repository matches")
    let same = [GitHub.Repo(owner: "o", name: "alpha-tool", description: "", isPrivate: false, isArchived: false, language: "", stars: 0, pushed: .distantPast),
                GitHub.Repo(owner: "o", name: "tool", description: "", isPrivate: false, isArchived: false, language: "", stars: 0, pushed: .distantPast)]
    expect(GitHub.rankedRepos(same, "tool").map(\.name) == ["tool", "alpha-tool"], "the better match comes first")

    expect(GitHub.failure(status: 4, message: "") == .notLoggedIn, "exit status 4 means not logged in")
    expect(GitHub.failure(status: 1, message: "To get started, run: gh auth login") == .notLoggedIn, "the login hint means not logged in")
    expect(GitHub.failure(status: 1, message: "Error: /private/fixture\nupstream diagnostics") == .requestFailed, "upstream diagnostics stay out of the error value")
    expect(GitHub.failure(status: 2, message: "") == .requestFailed, "unclassified failures use a fixed error")
}

private func checkGitHubRows() {
    // Items are built from the same functions the lists use; the closures are not run.
    let pr = GitHub.parseTickets(prJSON, pull: true) ?? []
    let issue = GitHub.parseTickets(issueJSON, pull: false) ?? []
    guard pr.count == 2, issue.count == 1 else { return }
    let rows = (pr + issue).map { GitHub.ticketItem($0, refreshing: [.mine]) }

    expect(rows[0].subtitle == "acme/widgets#42" && rows[0].id == "gh.acme/widgets#42", "row subtitle and id")
    expect(rows[0].kind == GitHub.age(pr[0].updated), "a pull request row shows its age")
    expect(rows[1].kind == "Draft", "a draft row shows Draft")
    expect(rows.map(\.icon).map(symbol) == ["arrow.triangle.pull", "circle.dotted", "smallcircle.filled.circle"], "icons: pull request, draft, issue")
    expect(!rows[0].track, "GitHub rows do not count for ranking")
    expect(rows[0].detail?.markdown.hasPrefix("**Add retry to the sync job**") == true, "detail starts with the title")
    expect(rows[0].detail?.metadata.map(\.0) == ["Repository", "Author", "Labels", "Comments", "Updated"], "detail metadata with labels")
    expect(rows[1].detail?.metadata.map(\.0) == ["Repository", "Author", "Comments", "Updated"], "detail metadata without labels")
    expect(rows[1].detail?.markdown.hasSuffix("No description provided.") == true, "empty body says so")

    let titles = rows[0].actions.map(\.title)
    expect(titles == ["Open in Browser", "Copy URL", "Copy Title", "Copy Number", "Open Repository", "Refresh"], "ticket actions in order")
    expect(rows[0].actions.map { $0.shortcut?.label ?? "-" } == ["-", "-", "⇧⌘C", "⇧⌘N", "⇧⌘O", "⌘R"], "ticket shortcuts")

    let notes = GitHub.parseNotes(notesJSON) ?? []
    let repos = GitHub.parseRepos(reposJSON) ?? []
    guard let note = notes.first, let repo = repos.first else { return }
    let noteActions = GitHub.noteItem(note).actions
    expect(noteActions.map(\.title) == ["Open", "Copy URL", "Mark as Read", "Refresh"], "notification actions in order")
    expect(noteActions.map { $0.shortcut?.label ?? "-" } == ["-", "-", "⇧⌘R", "⌘R"], "notification shortcuts")
    let repoActions = GitHub.repoItem(repo).actions
    expect(repoActions.map(\.title) == ["Open in Browser", "Copy Clone URL", "Copy HTTPS URL", "Open Pull Requests", "Open Issues", "Refresh"],
           "repository actions in order")
    expect(repoActions.map { $0.shortcut?.label ?? "-" } == ["-", "-", "⇧⌘C", "⇧⌘P", "⇧⌘I", "⌘R"], "repository shortcuts")
    expect(GitHub.repoItem(repo).kind == "Private" && GitHub.repoItem(repos[1]).kind == "Archived", "repository kind")

    // Extra shortcuts need ⌘, ⌃ or ⌥ and must not take the keys the panel and the system keep.
    let taken: Set<String> = ["⌘K", "⌘,", "⌘C", "⌘V", "⌘X", "⌘A", "⌘Z"]
    for action in rows[0].actions + noteActions + repoActions {
        guard let s = action.shortcut else { continue }
        expect(!s.modifiers.isDisjoint(with: [.command, .control, .option]) && !taken.contains(s.label), "shortcut \(s.label) is allowed")
    }
}

private func symbol(_ icon: Icon) -> String {
    if case .symbol(let name) = icon { return name }
    return ""
}
