import Foundation

func checkEmoji() {
    let emoji = Emoji.emoji, symbols = Emoji.symbols
    // Everything below passes `recent:` explicitly, so the checks never read or write the real recents file.
    func titles(_ q: String) -> [String] { Emoji.items(matching: q, recent: []).map(\.title) }
    func chars(_ q: String) -> [String] { Emoji.items(matching: q, recent: []).map { String($0.id.dropFirst(6)) } }

    // Catalogue
    let grin = emoji.first { $0.id == "emoji.😀" }
    expect(grin?.title == "Grinning Face" && grin?.kind == "Emoji" && grin?.section == "Emoji", "catalogue has 😀 as Grinning Face")
    expect(emoji.count > 1500, "catalogue lists the emoji and the flags (\(emoji.count))")
    expect(emoji.first?.id == "emoji.😀", "faces come first")
    expect(emoji.contains { $0.id == "emoji.❤️" }, "text-default emoji get U+FE0F (❤️)")
    expect(!emoji.contains { $0.id == "emoji.❤" }, "no text-style duplicate of ❤️")
    expect(!emoji.contains { $0.id.unicodeScalars.contains { $0.value == 0x200D || (0x1F3FB...0x1F3FF).contains($0.value) } },
           "no ZWJ or skin-tone variants")
    expect(emoji.filter { $0.title.hasPrefix("Flag: ") }.count > 250, "all flags are listed")
    expect(Set((emoji + symbols).map(\.id)).count == emoji.count + symbols.count, "ids are unique")
    expect(!emoji.contains { $0.id == "emoji.©️" || $0.id == "emoji.™️" }, "© and ™ only exist as symbols")
    expect(symbols.count >= 50 && symbols.allSatisfy { $0.kind == "Symbol" && $0.section == "Symbols" }, "symbols set")
    expect((emoji + symbols).allSatisfy { i in i.actions.count == 4 && !i.track && i.id.hasPrefix("emoji.") }, "every row has its four actions")

    // Names and code points
    expect(Emoji.codePoint("😀") == "U+1F600", "code point of 😀")
    expect(Emoji.codePoint("❤️") == "U+2764", "code point drops the variation selector")
    expect(Emoji.codePoint("🇩🇪") == "U+1F1E9 U+1F1EA", "a flag is two code points")
    expect(Emoji.codePoint("±") == "U+00B1", "code points have four digits at least")
    expect(emoji.first { $0.id == "emoji.😂" }?.title == "Face with Tears of Joy", "small words stay lowercase in titles")
    let shortcuts = (grin?.actions ?? []).compactMap { $0.shortcut?.label }
    expect(shortcuts == ["⇧⌘N", "⇧⌘U"] && grin?.actions.map(\.title).prefix(2) == ["Paste", "Copy to Clipboard"], "actions and shortcuts")

    // Search
    expect(chars("heart").contains("❤️"), "search heart finds ❤️")
    expect(chars("red heart").first == "❤️", "alias: red heart finds ❤️ first")
    expect(chars("peace").contains("✌️"), "alias keys match the base scalars (✌️)")
    expect(chars("germany").first == "🇩🇪", "flag by English name")
    expect(titles("germany").first == "Flag: Germany", "flag title")
    expect(chars("deutschland").first == "🇩🇪", "flag by German name")
    expect(chars("flagge: frankreich").first == "🇫🇷", "flag by German phrase")
    expect(chars("jp").first == "🇯🇵", "flag by country code")
    expect(!emoji.contains { $0.id == "emoji.🇪🇿" || $0.id == "emoji.🇶🇴" }, "regions without a flag glyph are skipped")
    expect(chars("euro").first == "€" && Emoji.items(matching: "euro", recent: []).first?.section == "Symbols",
           "a better symbol hit puts Symbols before Emoji")
    expect(chars("command").first == "⌘", "symbol: command key")
    expect(chars("rechts").first == "→" && chars("pfeil").contains("←"), "symbol by German word")
    expect(chars("thumbs up").first == "👍", "emoji by name")
    expect(chars("GRINNING").first == "😀", "search ignores case")
    expect(chars("  grinning face ").first == "😀", "search ignores surrounding spaces")
    expect(titles("qqzzxx") == ["No matching emoji or symbols"], "no match gives one placeholder row")
    expect(Emoji.items(matching: "qqzzxx", recent: []).first?.actions.isEmpty == true, "placeholder has no actions")
    expect(!chars("grn").contains("😀"), "loose in-order matches are not results")
    let sections = Emoji.items(matching: "arrow", recent: []).map(\.section)
    expect(Set(sections).count == 2 && zip(sections, sections.dropFirst()).filter { $0 != $1 }.count == 1, "results stay grouped by section")

    // Recently used
    expect(Emoji.promote("a", in: ["b", "a", "c"]) == ["a", "b", "c"], "recent: moved to front, no duplicates")
    expect(Emoji.promote("x", in: (0..<24).map(String.init)).count == 24 && Emoji.promote("x", in: (0..<24).map(String.init)).first == "x",
           "recent: capped at 24")
    let recents = Emoji.items(matching: "", recent: ["❤️", "😀", "€"])
    expect(recents.prefix(3).map(\.id) == ["emoji.❤️", "emoji.😀", "emoji.€"], "recent rows come first, most recent first")
    expect(recents.prefix(3).allSatisfy { $0.section == "Recently Used" }, "recent section name")
    expect(recents.count == 3 + emoji.count + symbols.count && recents[3].section == "Emoji" && recents.last?.section == "Symbols",
           "then Emoji, then Symbols")
    expect(Emoji.items(matching: "", recent: ["not a character"]).count == emoji.count + symbols.count, "unknown recents are ignored")
    expect(Emoji.items(matching: "heart", recent: ["😀", "❤️"]).first?.id == "emoji.❤️", "recents are filtered by the query")
    expect(!Emoji.items(matching: "heart", recent: ["😀"]).contains { $0.section == "Recently Used" }, "non-matching recents are hidden")

    // Icons
    if case .image(let image) = grin?.icon { expect(image.size.width == 22 && !image.isTemplate, "emoji icon is a 22pt color image") }
    else { expect(false, "emoji icon is an image") }
    if case .image(let image) = symbols.first?.icon { expect(image.isTemplate, "symbol icons are template images") }
    else { expect(false, "symbol icon is an image") }

    // Typing stays fast: a few keystrokes over the whole catalogue (-Onone here, so this bound is loose).
    let start = Date()
    for q in ["h", "he", "hea", "heart", "ger"] { _ = Emoji.items(matching: q, recent: []) }
    expect(Date().timeIntervalSince(start) < 2, "filtering the catalogue five times took \(Date().timeIntervalSince(start)) s")
}
