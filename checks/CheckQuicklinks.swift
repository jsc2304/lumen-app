import Foundation

// Checks for Quicklinks.swift: placeholders, encoding, URL and path detection, keyword parsing, import/export.
func checkQuicklinks() {
    let q = Quicklinks.self

    // Placeholders
    expect(q.arguments(in: "https://x.com/?q={query}") == ["Query"], "{query} is one argument")
    expect(q.arguments(in: "https://x.com/{Argument}/{ARGUMENT}") == ["Argument"], "placeholders are case-insensitive and repeats collapse")
    expect(q.arguments(in: #"https://x.com/{argument name="City"}/{argument name="Country" default="DE"}/{argument name="city"}"#)
           == ["City", "Country"], "named arguments, defaults ignored, names compared case-insensitively")
    expect(q.arguments(in: "https://example.com/{arguments}{clipboard}") == [], "other braces are not arguments")
    expect(q.arguments(in: "https://example.com").isEmpty, "plain link has no argument")

    // Substitution and percent-encoding
    let search = "https://www.google.com/search?q={query}"
    expect(q.fill(search, ["swift ui"]) == "https://www.google.com/search?q=swift%20ui", "space")
    expect(q.fill(search, ["a&b=c#d"]) == "https://www.google.com/search?q=a%26b%3Dc%23d", "& = # cannot leak into the URL structure")
    expect(q.fill(search, ["1+1"]) == "https://www.google.com/search?q=1%2B1", "plus")
    expect(q.fill(search, ["a/b?c:d"]) == "https://www.google.com/search?q=a%2Fb%3Fc%3Ad", "/ ? :")
    expect(q.fill(search, ["Müller Straße"]) == "https://www.google.com/search?q=M%C3%BCller%20Stra%C3%9Fe", "umlauts as UTF-8")
    expect(q.fill(search, ["a-b_c.d~e"]) == "https://www.google.com/search?q=a-b_c.d~e", "unreserved characters stay")
    expect(q.fill(search, ["  hi \n"]) == "https://www.google.com/search?q=hi", "values are trimmed")
    expect(q.fill(search, []) == "https://www.google.com/search?q=", "missing value is empty")
    expect(q.fill("https://x/{query}/{Query}", ["a b"]) == "https://x/a%20b/a%20b", "same argument twice")
    expect(q.fill(#"https://x/{argument name="A"}/{argument name="B"}"#, ["1", "2 3"]) == "https://x/1/2%203", "two arguments in order")
    expect(q.fill("~/Notes/{argument}.md", ["a b&c"]) == "~/Notes/a b&c.md", "file paths take the text as typed")
    expect(q.fill("https://example.com/a%20b", ["x"]) == "https://example.com/a%20b", "no placeholder, no change")
    expect(q.encode("") == "", "empty value")

    // Link targets
    expect(q.target("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1", "https link")
    expect(q.target("slack://channel?team=T1&id=C1") != nil, "app deeplink")
    expect(q.target("mailto:a@example.com") != nil, "mailto without //")
    expect(q.target("/tmp")?.path == "/tmp", "absolute path")
    expect(q.target("~/Documents")?.path == NSHomeDirectory() + "/Documents", "tilde path")
    expect(q.target("github.com/x")?.absoluteString == "https://github.com/x", "bare domain gets https")
    expect(q.target("just some words") == nil, "words are no target")
    expect(q.target("example") == nil, "single word is no target")
    expect(q.problem(Quicklink(name: "", link: "https://x.com")) != nil, "name required")
    expect(q.problem(Quicklink(name: "X", link: "")) != nil, "link required")
    expect(q.problem(Quicklink(name: "X", link: "not a link")) != nil, "link must be a URL or path")
    expect(q.problem(Quicklink(name: "X", link: "https://x.com/?q={query}")) == nil, "valid search link")
    expect(q.problem(Quicklink(name: "X", link: "~/Projects/{argument}")) == nil, "valid path link")

    // URL and domain detection
    expect(q.webURL("github.com/x")?.absoluteString == "https://github.com/x", "domain with path")
    expect(q.webURL("example.com")?.absoluteString == "https://example.com", "bare domain")
    expect(q.webURL("Sub.Example.CO.uk")?.absoluteString == "https://Sub.Example.CO.uk", "subdomains, any case")
    expect(q.webURL("https://example.com/a?b=1#c")?.absoluteString == "https://example.com/a?b=1#c", "full URL")
    expect(q.webURL("http://localhost:3000/x")?.absoluteString == "http://localhost:3000/x", "URL with localhost")
    expect(q.webURL("localhost:3000")?.absoluteString == "http://localhost:3000", "localhost with port is http")
    expect(q.webURL("localhost")?.absoluteString == "http://localhost", "localhost")
    expect(q.webURL("127.0.0.1:8080/x")?.absoluteString == "http://127.0.0.1:8080/x", "IPv4 with port and path")
    expect(q.webURL("example.com:8443/a")?.absoluteString == "https://example.com:8443/a", "domain with port")
    expect(q.webURL("slack://channel?team=T1") != nil, "any scheme with //")
    expect(q.webURL("main.swift") == nil, "source file is no domain")
    expect(q.webURL("main.swift:12") == nil, "file:line is no domain")
    expect(q.webURL("Safari.app") == nil, "app bundle is no domain")
    expect(q.webURL("report.pdf") == nil, "document is no domain")
    expect(q.webURL("notes.md") == nil, "markdown file is no domain")
    expect(q.webURL("v1.2.3") == nil, "version number is no domain")
    expect(q.webURL("3.14") == nil, "number is no domain")
    expect(q.webURL("999.1.1.1") == nil, "invalid IPv4")
    expect(q.webURL("99999999999999999999.1.1.1") == nil, "huge IPv4 octet does not crash")
    expect(q.webURL("e.g.") == nil, "abbreviation is no domain")
    expect(q.webURL("hello") == nil, "plain word")
    expect(q.webURL("example.com foo") == nil, "text with a space is a search")
    expect(q.webURL("-bad.com") == nil && q.webURL("a..com") == nil && q.webURL(".com") == nil, "malformed labels")
    expect(q.webURL("example.com:abc") == nil, "port must be digits")
    expect(q.webURL("https://") == nil, "scheme alone")
    expect(q.webURL("") == nil, "empty")

    // Existing paths
    expect(q.existingPath("/tmp") == "/tmp", "existing absolute path")
    expect(q.existingPath("~/") == NSHomeDirectory(), "home folder")
    expect(q.existingPath("/definitely/not/here") == nil, "missing path")
    expect(q.existingPath("tmp") == nil, "relative text is not a path")

    // Keyword and argument
    expect(q.split("google swift ui", name: "Google")?.rest == "swift ui", "name, space, argument")
    expect(q.split("GOOGLE swift", name: "google")?.rest == "swift", "case-insensitive")
    expect(q.split("google", name: "Google") == nil, "name alone")
    expect(q.split("google   ", name: "Google") == nil, "name and spaces only")
    expect(q.split("googlemaps x", name: "Google") == nil, "name must be followed by a space")
    expect(q.split("goo x", name: "Google") == nil, "partial name")
    expect(q.split("google  swift", name: "Google")?.rest == "swift", "extra spaces")
    expect(q.split("google maps berlin", name: "Google Maps")?.rest == "berlin", "multi-word name")
    expect(q.split("google berlin", name: "Google Maps")?.rest == "berlin", "first word of the name")
    expect(q.split("google maps berlin", name: "Google Maps")!.score > q.split("google maps berlin", name: "Google")!.score,
           "full longer name beats a shorter quicklink")
    expect(q.split("google berlin", name: "Google")!.score > q.split("google berlin", name: "Google Maps")!.score,
           "full name beats a first word of the same length")
    expect(q.split("ä x", name: "Ä")?.rest == "x", "non-ASCII name")
    expect(q.split("x y", name: "") == nil, "empty name never matches")

    // Export and import
    let list = [Quicklink(name: "Google", link: "https://www.google.com/search?q={query}"),
                Quicklink(name: "Notes", link: "~/Notes", openWith: "Visual Studio Code")]
    let exported = q.exportData(list).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
    expect(exported?.count == 2, "export is an array")
    expect(Set(exported?[0].keys.map { $0 } ?? []) == ["name", "link"], "no openWith when empty, no id")
    expect(Set(exported?[1].keys.map { $0 } ?? []) == ["name", "link", "openWith"], "Raycast's shape")
    expect(String(data: q.exportData(list) ?? Data(), encoding: .utf8)?.contains("https://www.google.com/search?q={query}") == true,
           "slashes are not escaped")
    let raycast = #"[{"name":"Maps","link":"https://maps.google.com/?q={Query}","openWith":"Safari"},{"name":"Docs","link":"~/Docs"},{"name":"","link":"x"}]"#
    let imported = q.imported(Data(raycast.utf8), existing: [])
    expect(imported?.map(\.name) == ["Maps", "Docs"], "import skips entries without a name")
    expect(imported?[0].openWith == "Safari" && imported?[1].openWith == "", "openWith is optional")
    expect(q.imported(Data(raycast.utf8), existing: [Quicklink(name: "maps", link: "https://maps.google.com/?q={Query}")])?.map(\.name) == ["Docs"],
           "import skips what exists")
    expect(q.imported(Data("{}".utf8), existing: []) == nil, "not an export")
    expect(q.imported(Data("nope".utf8), existing: []) == nil, "not JSON")
    let roundTrip = q.exportData(list).flatMap { q.imported($0, existing: []) }
    expect(roundTrip?.map(\.link) == list.map(\.link) && roundTrip?.map(\.openWith) == list.map(\.openWith), "export, import round trip")
    expect(Set(roundTrip?.map(\.id) ?? []).isDisjoint(with: Set(list.map(\.id))), "imported quicklinks get new ids")

    // Files from older versions lack keys; a failed decode would load as an empty list and the next save would overwrite it.
    let id = "0F6C8E9A-3B1D-4C52-9E7A-5D2B8A4C1E10"
    let saved = Data(#"[{"name":"Old","link":"https://a.com"},{"id":"\#(id)","name":"New","link":"~/x","openWith":"Safari"}]"#.utf8)
    let loaded = try? JSONDecoder().decode([Quicklink].self, from: saved)
    expect(loaded?.map(\.name) == ["Old", "New"], "a file without id and openWith still loads")
    expect(loaded?[0].openWith == "" && loaded?[0].id != loaded?[1].id, "missing keys get defaults, a missing id a fresh one")
    expect(loaded?[1].id.uuidString == id && loaded?[1].openWith == "Safari", "present keys are kept")
    expect((try? JSONDecoder().decode([Quicklink].self, from: Data(#"[{"name":"No link"}]"#.utf8))) == nil, "name and link stay required")
    let again = (try? JSONEncoder().encode(list)).flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) }
    expect(again?.map(\.id) == list.map(\.id) && again?.map(\.openWith) == list.map(\.openWith) && again?.map(\.link) == list.map(\.link),
           "encode and decode round trip")
}
