import AppKit

func checkFiles() {
    let noise = (0..<12).map { "/fixtures/report-downloads-\($0).txt" }
    let ranked = FileSearch.rankedPaths(noise + ["/fixtures/Downloads"], matching: "downloads")
    expect(ranked.first == "/fixtures/Downloads", "exact folder survives eight-result limit")
    let search = FileSearch()
    search.search("downloads")
    expect(search.results.first?.title == "Downloads", "Downloads available before Spotlight completes")
    search.search("")
    expect(search.results.isEmpty, "empty query clears folders")

    // Quotes keep a phrase or a path with spaces together.
    expect(Files.tokens("kind:pdf in:\"~/My Folder\" annual  report") == ["kind:pdf", "in:~/My Folder", "annual", "report"], "tokens: quotes, runs of spaces")
    expect(Files.tokens("\"annual report\"") == ["annual report"], "tokens: quoted phrase")
    expect(Files.tokens("   ").isEmpty, "tokens: blank")

    // 2027-01-15 08:00 UTC
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func parse(_ text: String) -> Files.Query { Files.parse(text, now: now, calendar: utc) }
    let home = NSHomeDirectory()

    var q = parse("annual report")
    expect(q.terms == ["annual", "report"] && q.error == nil && q.isSearchable, "plain words are name parts")
    expect(!parse("a").isSearchable, "one letter alone is too broad")
    expect(parse("a kind:pdf").isSearchable, "one letter with a filter is fine")
    expect(parse("modified:today").isSearchable && parse("ext:swift").isSearchable, "a filter alone is a search")
    expect(!parse("in:~/Documents").isSearchable, "a folder alone is not a search")
    expect(parse("http://example.com").terms == ["http://example.com"], "unknown word before a colon stays a name part")
    expect(parse("").terms.isEmpty && !parse("").isSearchable, "empty query")

    q = parse("KIND:PDF report")
    expect(q.types == ["com.adobe.pdf"] && q.terms == ["report"], "kind: any case")
    q = parse("kind:")
    expect(q.terms.isEmpty && q.types.isEmpty && q.error == nil, "a filter still being typed is ignored")
    expect(parse("kind:nonsense").error != nil, "unknown kind is reported")
    expect(parse("modified:year").error != nil, "unknown period is reported")

    q = parse("in:~/Documents report")
    expect(q.scope == home + "/Documents" && q.terms == ["report"], "in: expands ~")
    expect(parse("in:Documents").scope == home + "/Documents", "in: relative to home")
    expect(parse("in:\"~/My Folder\"").scope == home + "/My Folder", "in: quoted path with a space")
    expect(Files.scope("/usr/") == "/usr" && Files.scope("~") == home, "scope normalizes the path")

    expect(parse("content:invoice content:\"due date\"").content == ["invoice", "due", "date"], "content: words")
    expect(parse("ext:.Swift").ext == "swift", "ext: lowercase, leading dot dropped")
    expect(parse("ext:.").ext == nil, "ext: only a dot is nothing")

    expect(Files.since("today", now: now, calendar: utc) == Date(timeIntervalSince1970: 1_799_971_200), "modified:today is midnight")
    expect(Files.since("WEEK", now: now, calendar: utc) == Date(timeIntervalSince1970: 1_800_000_000 - 7 * 86_400), "modified:week is 7 days")
    expect(Files.since("month", now: now, calendar: utc) == Date(timeIntervalSince1970: 1_800_000_000 - 31 * 86_400), "modified:month is a calendar month")
    expect(Files.since("yesterday", now: now, calendar: utc) == nil, "unknown period")

    expect(Files.types(for: "IMAGE") == ["public.image"], "kind word, any case")
    expect(Files.types(for: "swift") == ["public.swift-source"], "kind falls back to a file extension")
    expect(Files.types(for: "md") == ["net.daringfireball.markdown"], "markdown by extension")
    expect(Files.types(for: "nonsense") == nil, "unknown kind")
    expect(Files.types(for: "video")?.contains("public.movie") == false, "kind:video leaves out TypeScript (public.movie)")

    // The predicates the index gets; a dictionary stands in for a file.
    expect(Files.predicate(Files.Query()) == nil, "no criteria, no predicate")
    let file: [String: Any] = ["kMDItemFSName": "Annual Report 2026.PDF", "kMDItemFSContentChangeDate": now.addingTimeInterval(-3 * 86_400),
                               "kMDItemTextContent": "Invoice due soon"]
    func matches(_ text: String) -> Bool { Files.predicate(parse(text))?.evaluate(with: file) ?? false }
    expect(matches("annual report") && matches("REPORT") && matches("2026"), "name parts match in any case")
    expect(!matches("annual zzz"), "every name part has to match")
    expect(matches("ext:pdf") && !matches("ext:docx"), "ext: matches the end of the name")
    expect(matches("modified:week") && !matches("modified:today"), "modified: compares the change date")
    expect(matches("content:invoice") && matches("content:\"due soon\"") && !matches("content:invoice content:missing"), "content: words")
    expect(matches("annual ext:pdf modified:month content:due"), "filters combine")
    // NSMetadataQuery throws on a compound predicate with a single part (found by running the list, not by compiling it).
    func valid(_ p: NSPredicate) -> Bool {
        guard let c = p as? NSCompoundPredicate else { return true }
        return c.subpredicates.count >= 2 && c.subpredicates.allSatisfy { valid($0 as! NSPredicate) }
    }
    for text in ["report", "kind:pdf", "kind:video", "report kind:pdf", "ext:swift", "modified:week", "content:invoice", "a b kind:image ext:png"] {
        expect(Files.predicate(parse(text)).map(valid) == true, "predicate for \"\(text)\" has no single-part compound")
        expect(valid(Files.screenshotPredicate(parse(text))), "screenshot predicate for \"\(text)\" has no single-part compound")
    }
    expect(valid(Files.screenshotPredicate(Files.Query())), "screenshot predicate without filters")
    let kindFormat = Files.predicate(parse("kind:pdf"))?.predicateFormat ?? ""
    expect(kindFormat.contains("kMDItemContentTypeTree") && kindFormat.contains("com.adobe.pdf"), "kind: asks for the content type tree")
    expect(Files.predicate(parse("kind:video"))?.predicateFormat.contains(" OR ") == true, "a kind with several types matches any of them")

    // Formatting
    expect(Files.size(nil) == "—" && Files.date(nil) == "—", "missing size and date")
    expect(Files.size(0).hasPrefix("0") && Files.size(2_000_000).hasSuffix("MB"), "size")
    expect(Files.date(now) != "—" && !Files.date(now).isEmpty, "date")

    // PNG conversion and readability, on files made here
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-files-check-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let pngFile = dir.appendingPathComponent("a.png"), tiffFile = dir.appendingPathComponent("a.tiff")
    try? png.write(to: pngFile)
    try? bitmap.representation(using: .tiff, properties: [:])!.write(to: tiffFile)
    expect(Files.pngData(of: pngFile) == png, "a PNG is passed through unchanged")
    let converted = Files.pngData(of: tiffFile)
    expect(converted?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true && converted.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 4,
           "a TIFF becomes a PNG of the same width")
    expect(Files.pngData(of: dir.appendingPathComponent("missing.png")) == nil, "a missing file has no PNG")
    expect(Files.canRead(pngFile.path) && !Files.canRead(dir.appendingPathComponent("missing.png").path), "readability")

    // Paste Latest Screenshot: the screenshot folder, and the newest file there against what Spotlight knows
    expect(Files.screenshotFolder(location: nil).path == home + "/Desktop" && Files.screenshotFolder(location: "  ").path == home + "/Desktop", "no location: the Desktop")
    expect(Files.screenshotFolder(location: "~/Pictures/Shots").path == home + "/Pictures/Shots" && Files.screenshotFolder(location: "/tmp/shots").path == "/tmp/shots", "location, ~ expanded")
    let shots = dir.appendingPathComponent("shots")
    try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    expect(Files.newestScreenshotFile(in: shots) == nil && Files.newestScreenshotFile(in: dir.appendingPathComponent("missing")) == nil, "no folder or no files: no screenshot")
    func shot(_ name: String, age: TimeInterval, marked: Bool = true) {
        let url = shots.appendingPathComponent(name)
        try? png.write(to: url)
        if marked { _ = setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", [1], 1, 0, 0) }
        try? FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    shot("old.png", age: 100)
    shot("new.png", age: 10)
    shot("not-marked.png", age: 1, marked: false)
    shot("recording.mov", age: 2)
    shot(".hidden.png", age: 3)
    let newest = Files.newestScreenshotFile(in: shots)
    expect(newest?.path.hasSuffix("/new.png") == true, "the newest marked image wins; unmarked, non-image and hidden files do not: \(newest?.path ?? "nil")")
    let shotDate = newest?.created ?? .distantPast
    expect(abs(shotDate.timeIntervalSinceNow + 10) < 5, "with its creation date")
    expect(Files.latestScreenshot(spotlight: ("/s/lag.png", shotDate.addingTimeInterval(-60)), folder: ("/f/new.png", shotDate)) == "/f/new.png", "Spotlight lags: the newer file in the folder is pasted")
    expect(Files.latestScreenshot(spotlight: ("/s/new.png", shotDate), folder: ("/f/old.png", shotDate.addingTimeInterval(-60))) == "/s/new.png", "Spotlight knows a newer one (another folder)")
    expect(Files.latestScreenshot(spotlight: ("/s/same.png", shotDate), folder: ("/f/same.png", shotDate)) == "/s/same.png", "a tie goes to Spotlight")
    expect(Files.latestScreenshot(spotlight: ("/s/a.png", nil), folder: ("/f/b.png", shotDate)) == "/f/b.png", "Spotlight without a date loses")
    expect(Files.latestScreenshot(spotlight: ("/s/a.png", shotDate), folder: nil) == "/s/a.png" && Files.latestScreenshot(spotlight: nil, folder: ("/f/b.png", shotDate)) == "/f/b.png"
           && Files.latestScreenshot(spotlight: nil, folder: nil) == nil, "either side alone, or nothing")

    // The rows reuse the root's file actions by title; this fails when the root renames one.
    let rootActions = FileSearch.item("/nonexistent").actions
    for (title, key, modifiers) in [("Quick Look", "y", NSEvent.ModifierFlags.command), ("Copy Path", "p", [.command, .shift]), ("Copy File", "c", [.command, .shift])] {
        let action = rootActions.first { $0.title == title }
        expect(action?.shortcut?.key == key && action?.shortcut?.modifiers == modifiers, "root file action \(title) keeps its shortcut")
    }
    expect(rootActions.contains { $0.title == "Open" } && rootActions.contains { $0.title == "Show in Finder" }, "root file actions Open and Show in Finder")

    let commands = Files.commands()
    expect(commands.map(\.id) == ["files.search", "files.screenshots", "files.paste-latest-screenshot"], "command ids")
    expect(commands.map { $0.actions[0].closes } == [false, false, true], "lists stay open, Paste Latest closes the panel")
}
