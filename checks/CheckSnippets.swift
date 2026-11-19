import Foundation
import CoreGraphics

// Checks for Snippets.swift: placeholders, typed-text buffer, keyword matching, validation, import.
func checkSnippets() {
    let day = Date(timeIntervalSince1970: 1_792_000_000)
    let e = Snippets.expand("Hi {clipboard}, {date} {time}|{datetime}|{day}", date: day, clipboard: "Ann")
    expect(e.text == "Hi Ann, " + day.formatted(date: .abbreviated, time: .omitted) + " " + day.formatted(date: .omitted, time: .shortened)
           + "|" + day.formatted(date: .abbreviated, time: .shortened) + "|" + day.formatted(.dateTime.weekday(.wide)), "date placeholders")
    expect(e.cursorOffset == 0, "no cursor, caret stays at the end")
    expect(Calendar.current.weekdaySymbols.contains(Snippets.expand("{day}", date: day, clipboard: "").text), "day is a weekday name")
    expect(Snippets.expand("{clipboard}", date: day, clipboard: "{date}").text == "{date}", "clipboard text is not expanded again")
    let c = Snippets.expand("<b>{cursor}</b>{clipboard}", date: day, clipboard: "xy")
    expect(c.text == "<b></b>xy" && c.cursorOffset == 6, "cursor offset counts the expanded text after it")
    expect(Snippets.expand("a{cursor}b{cursor}c", date: day, clipboard: "") == ("abc", 2), "only the first cursor counts")
    let u = Snippets.expand("{uuid}", date: day, clipboard: "").text
    expect(UUID(uuidString: u) != nil, "uuid")
    expect(Snippets.expand("{unknown}", date: day, clipboard: "").text == "{unknown}", "unknown placeholders stay")

    expect(Snippets.typing("ab", "c", flags: []) == "abc", "typing appends")
    expect(Snippets.typing("a", "B", flags: .maskShift) == "aB", "shift is typing")
    expect(Snippets.typing("a", "@", flags: .maskAlternate) == "a@", "option characters are typing")
    expect(Snippets.typing("abc", "\u{7F}", flags: []) == "ab", "backspace removes one")
    expect(Snippets.typing("", "\u{7F}", flags: []) == "", "backspace on empty")
    expect(Snippets.typing("abc", "\u{7F}", flags: .maskAlternate) == "", "option-backspace resets")
    expect(Snippets.typing("abc", "v", flags: .maskCommand) == "", "command shortcut resets")
    expect(Snippets.typing("abc", "a", flags: .maskControl) == "", "control shortcut resets")
    expect(Snippets.typing("abc", "\u{F702}", flags: []) == "", "arrow resets")
    expect(Snippets.typing("abc", "\r", flags: []) == "" && Snippets.typing("abc", "\t", flags: []) == ""
           && Snippets.typing("abc", "\u{1B}", flags: []) == "", "return, tab, escape reset")
    expect(Snippets.typing("ab", "", flags: []) == "ab", "dead key keeps the buffer")
    expect(Snippets.typing(String(repeating: "x", count: 64), "y", flags: []) == String(repeating: "x", count: 63) + "y", "buffer keeps 64")

    let sig = Snippet(name: "Sig", text: "Best", keyword: ";sig")
    let short = Snippet(name: "Short", text: "S", keyword: "ig")
    let none = Snippet(name: "None", text: "N")
    let list = [short, sig, none]
    expect(Snippets.match("hello ;sig", in: list) == sig, "longest keyword wins")
    expect(Snippets.match("big", in: list) == short, "suffix match")
    expect(Snippets.match(";sig!", in: list) == nil, "keyword must end the buffer")
    expect(Snippets.match("", in: list) == nil, "snippets without keyword never match")

    expect(Snippets.problem(Snippet(name: "", text: "x"), in: list, editing: nil) != nil, "name required")
    expect(Snippets.problem(Snippet(name: "a", text: ""), in: list, editing: nil) != nil, "text required")
    expect(Snippets.problem(Snippet(name: "a", text: "x", keyword: ";sig"), in: list, editing: nil) != nil, "keyword must be unique")
    expect(Snippets.problem(Snippet(name: "Sig 2", text: "x", keyword: ";sig"), in: list, editing: 1) == nil, "edited snippet keeps its keyword")
    expect(Snippets.problem(Snippet(name: "a", text: "x"), in: list, editing: nil) == nil, "valid")

    // A keyword typed on the way to another one fires first, so the longer one could never expand.
    let a = [Snippet(name: "A", text: "x", keyword: ";a")]
    expect(Snippets.problem(Snippet(name: "B", text: "y", keyword: ";ab"), in: a, editing: nil) != nil, "existing keyword is the start of the new one")
    expect(Snippets.problem(Snippet(name: "B", text: "y", keyword: ";a"), in: [Snippet(name: "AB", text: "x", keyword: ";ab")], editing: nil) != nil,
           "new keyword is the start of an existing one")
    expect(Snippets.problem(Snippet(name: "B", text: "y", keyword: "x;ab"), in: a, editing: nil) != nil, "existing keyword inside the new one")
    expect(Snippets.problem(Snippet(name: "A", text: "x", keyword: ";ab"), in: a, editing: 0) == nil, "an edited keyword is not checked against its old self")
    expect(Snippets.problem(Snippet(name: "Sig 2", text: "x", keyword: "x;sig"), in: list, editing: nil) == nil
           && Snippets.problem(Snippet(name: "G", text: "x", keyword: "g"), in: list, editing: nil) == nil,
           "ending with another keyword is fine, the longest match wins")

    let raycast = #"[{"name":"Mail","text":"me@example.com","keyword":"@@"},{"name":"Sig","text":"Best","keyword":";sig"},"#
        + #"{"name":"Plain","text":"p","keyword":""},{"name":"Short","text":"S","keyword":"ig"}]"#
    let imported = try? JSONDecoder().decode([Snippet].self, from: Data(raycast.utf8))
    expect(imported?.count == 4 && imported?[0].keyword == "@@", "Raycast export shape decodes")
    let merged = Snippets.merged([sig, short], imported ?? [])
    expect(merged.list.map(\.name) == ["Sig", "Short", "Mail", "Plain"] && merged.skipped == 2, "import skips duplicates and taken keywords")
    expect(merged.list[3].keyword == nil, "empty keyword becomes none")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys   // JSONEncoder's key order is otherwise unspecified
    let exported = (try? encoder.encode([none])).map { String(decoding: $0, as: UTF8.self) }
    expect(exported == #"[{"name":"None","text":"N"}]"#, "export omits a missing keyword")
}
