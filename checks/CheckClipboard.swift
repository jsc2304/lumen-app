import AppKit

// Checks for Clipboard.swift: entry types, old history files, pins, the 500 cap, paste order, search, security rule.
// Pure functions only: nothing here touches the pasteboard or the history on disk.
func checkClipboard() {
    typealias Entry = Clipboard.Entry
    let t = { (s: Double) in Date(timeIntervalSinceReferenceDate: s) }

    // clipboard.json written by the previous version has no files, pinned, app or bundleID.
    let old = #"""
    [{"id":"2F1C5B9E-6B5E-4C57-9E43-7D9A1B0C0A11","text":"hello","date":782000000.5},
     {"id":"7A6F0E44-3C1B-4D0E-8E55-0B1F6C2D9A22","image":"AB12.png","date":782000100}]
    """#
    let loaded = try? JSONDecoder().decode([Entry].self, from: Data(old.utf8))
    expect(loaded?.count == 2, "history file of the previous version still loads")
    expect(loaded?[0].text == "hello" && loaded?[0].isPinned == false && loaded?[0].files == nil && loaded?[0].app == nil,
           "old text entry: new fields are empty")
    expect(loaded?[1].image == "AB12.png" && loaded?[1].kind == .image, "old image entry")
    let full = Entry(text: "x", files: ["/tmp/a.txt"], pinned: true, app: "Safari", bundleID: "com.apple.Safari")
    let again = (try? JSONEncoder().encode([full])).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
    expect(again?.first?.files == ["/tmp/a.txt"] && again?.first?.isPinned == true && again?.first?.app == "Safari"
           && again?.first?.bundleID == "com.apple.Safari", "new fields survive a round trip")

    // Types
    expect(Entry(text: "just words").kind == .text, "text")
    expect(Entry(text: "https://example.com/a?b=1").kind == .link, "link")
    expect(Entry(text: "#ff8800").kind == .color, "color")
    expect(Entry(files: ["/tmp/a.txt"]).kind == .file, "file")
    expect(Entry(image: "a.png").kind == .image, "image")
    expect(Entry(files: ["/tmp/a.txt", "/tmp/b.txt"]).title == "a.txt and 1 more", "file title")
    expect(Entry(text: "\n  first line\nsecond").title == "first line", "text title is the first line")
    expect(Entry(text: String(repeating: "x", count: 1_000_000)).title == String(repeating: "x", count: 200), "a huge line is cut to 200")
    expect(Entry(text: " \n" + String(repeating: "y", count: 300) + "\nz").title.count == 200, "cut after leading blank lines")

    expect(Clipboard.link("  https://example.com/path?q=1#x\n") != nil, "link with surrounding whitespace")
    expect(Clipboard.link("http://localhost:3000") != nil, "link to localhost")
    expect(Clipboard.link("mailto:me@example.com") != nil, "mailto link")
    expect(Clipboard.link("example.com") == nil, "no scheme, no link")
    expect(Clipboard.link("see https://example.com") == nil, "a sentence is not a link")
    expect(Clipboard.link("https://example.com and more") == nil, "two words are not a link")
    expect(Clipboard.link("foo:bar") == nil, "scheme without host")
    expect(Clipboard.link("C:/Users/me") == nil, "Windows path")

    func rgba(_ c: NSColor?) -> [Int]? {
        c.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent].map { Int(($0 * 255).rounded()) } }
    }
    expect(rgba(Clipboard.color("#FF8800")) == [255, 136, 0, 255], "hex color")
    expect(rgba(Clipboard.color("#f80")) == [255, 136, 0, 255], "short hex color")
    expect(rgba(Clipboard.color("#ff880080")) == [255, 136, 0, 128], "hex color with alpha")
    expect(rgba(Clipboard.color("#f808")) == [255, 136, 0, 136], "short hex color with alpha")
    expect(rgba(Clipboard.color(" rgb(255, 136, 0) ")) == [255, 136, 0, 255], "rgb()")
    expect(rgba(Clipboard.color("RGBA(0,0,0,.5)")) == [0, 0, 0, 128], "rgba() with fractional alpha")
    expect(rgba(Clipboard.color("rgb(255 136 0 / 50%)")) == [255, 136, 0, 128], "space-separated rgb with percent alpha")
    expect(Clipboard.color("rgb(256, 0, 0)") == nil, "channel above 255")
    expect(Clipboard.color("#12345") == nil, "five hex digits")
    expect(Clipboard.color("#ggg") == nil, "not hex")
    expect(Clipboard.color("#") == nil, "bare hash")
    expect(Clipboard.color("red") == nil, "color names are text")
    expect(Clipboard.color("use #fff here") == nil, "color inside a sentence")

    // Pins and the cap
    let newest = Entry(text: "new", date: t(10))
    let r1 = Clipboard.adding(newest, to: [Entry(text: "a", date: t(3)), Entry(text: "b", date: t(2)), Entry(text: "c", date: t(1))], cap: 2)
    expect(r1.kept.map(\.text) == ["new", "a"] && r1.dropped.map(\.text) == ["b", "c"], "cap drops the oldest")
    let pinnedOld = Entry(text: "c", date: t(1), pinned: true)
    let r2 = Clipboard.adding(newest, to: [Entry(text: "a", date: t(3)), Entry(text: "b", date: t(2)), pinnedOld], cap: 2)
    expect(r2.kept.map(\.text) == ["new", "a", "c"] && r2.dropped.map(\.text) == ["b"], "pinned entries stay beyond the cap")
    let r3 = Clipboard.adding(Entry(text: "x", date: t(11)), to: [Entry(text: "p", date: t(5), pinned: true), Entry(text: "a", date: t(3))], cap: 1)
    expect(r3.kept.map(\.text) == ["x", "p"] && r3.dropped.map(\.text) == ["a"], "pins do not count against the cap")
    let r4 = Clipboard.adding(Entry(text: "same", date: t(12)), to: [Entry(text: "other", date: t(4)), Entry(text: "same", date: t(3), pinned: true)], cap: 5)
    expect(r4.kept.map(\.text) == ["same", "other"] && r4.kept[0].isPinned && r4.dropped.isEmpty,
           "copying a pinned text again moves it up and keeps the pin")
    let img = Entry(image: "x.png", date: t(1))
    var moved = img
    moved.date = t(20)
    let r5 = Clipboard.adding(moved, to: [Entry(text: "a", date: t(5)), img], cap: 5)
    expect(r5.kept.count == 2 && r5.kept[0].id == img.id && r5.kept[0].date == t(20) && r5.dropped.isEmpty,
           "an image moved to the top is not duplicated")
    let f = Entry(files: ["/tmp/a", "/tmp/b"], date: t(1))
    expect(Clipboard.adding(Entry(files: ["/tmp/a", "/tmp/b"], date: t(2)), to: [f], cap: 5).kept.count == 1, "same files are one entry")

    // Paste order: oldest entry after the cursor
    let history = [Entry(text: "c", date: t(30)), Entry(text: "b", date: t(20)), Entry(text: "a", date: t(10)), Entry(text: "old", date: t(1))]
    expect(Clipboard.next(after: t(5), in: history)?.text == "a", "sequence starts at the oldest entry after the start")
    expect(Clipboard.next(after: t(10), in: history)?.text == "b", "then goes on in copy order")
    expect(Clipboard.next(after: t(30), in: history) == nil, "nothing after the newest entry ends the sequence")
    expect(Clipboard.next(after: t(30), in: history + [Entry(text: "d", date: t(40))])?.text == "d", "a later copy continues the sequence")
    expect(Clipboard.next(after: .distantPast, in: []) == nil, "empty history")

    // Search: content, type name, source app, file paths
    let page = Entry(text: "https://example.com", app: "Safari")
    expect(Clipboard.matches(page, "EXAMPLE"), "search finds text, any case")
    expect(Clipboard.matches(page, "link"), "search finds the type name")
    expect(Clipboard.matches(page, "safari"), "search finds the source app")
    expect(!Clipboard.matches(page, "firefox"), "no false match")
    expect(Clipboard.matches(Entry(files: ["/Users/me/Report.pdf"]), "report.pdf"), "search finds file names")
    expect(Clipboard.matches(Entry(image: "a.png"), "image"), "search finds images by type")
    expect(Clipboard.matches(page, ""), "empty query matches everything")
    expect(Clipboard.matches(Entry(text: "plain"), "color", kind: .color) && !Clipboard.matches(page, "link", kind: .text),
           "search uses the kind it is given (the cached one)")

    // Security rule
    for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                 "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
                 "Pasteboard generator type", "net.antelle.keeweb"] {
        expect(Clipboard.isSecret([.string, NSPasteboard.PasteboardType(type)]), "\(type) is never stored")
    }
    expect(!Clipboard.isSecret([.string, .png]), "ordinary types are stored")

    // The detail pane renders Markdown: copied text must come out unchanged.
    let samples = ["*bold* _it_ `code` [a](http://x) <b>tag</b>", "\\back # not a heading\n1. not a list\n> not a quote",
                   "&amp; ~~x~~ ![i](u) | a | b |", "  indented\n\ttabbed\n\nblank line", "plain"]
    for s in samples {
        let rendered = try? AttributedString(markdown: Clipboard.escaped(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        expect(rendered.map { String($0.characters) } == s, "markdown escaping keeps: " + s)
    }
}
