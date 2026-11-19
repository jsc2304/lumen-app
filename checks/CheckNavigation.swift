import Foundation

func checkNavigation() {
    // Shortcut labels; the raw values are what Finder reports over Accessibility.
    func label(_ c: String?, _ m: Int?, _ vk: Int? = nil) -> String { Navigation.shortcutLabel(char: c, modifiers: m, virtualKey: vk) }
    expect(label("c", 0) == "⌘C", "plain ⌘ shortcut")
    expect(label("s", 1) == "⇧⌘S", "shift adds ⇧")
    expect(label("w", 2) == "⌥⌘W", "option adds ⌥")
    expect(label("h", 3) == "⌥⇧⌘H", "modifier order ⌃⌥⇧⌘")
    expect(label("f", 7) == "⌃⌥⇧⌘F", "all four modifiers")
    expect(label("f", 6) == "⌃⌥⌘F", "control and option")
    expect(label("s", nil) == "⌘S", "missing modifiers mean ⌘")
    expect(label("q", 8) == "Q", "bit 8 removes ⌘")
    expect(label("\u{8}", 0, 51) == "⌘⌫", "Move to Trash: backspace character falls back to the key code")
    expect(label("\u{8}", 1, 51) == "⇧⌘⌫", "Empty Trash")
    expect(label("\t", 13, 48) == "⌃⇧⇥", "Show Previous Tab")
    expect(label("\t", 12, 48) == "⌃⇥", "Show Next Tab")
    expect(label(nil, 28, 123) == "🌐⌃←", "Move & Resize Left: fn bit, no ⌘")
    expect(label(nil, 31, 126) == "🌐⌃⌥⇧↑", "Move & Resize Top & Quarters")
    expect(label(" ", 2, 49) == "⌥⌘Space", "space character shows as Space")
    expect(label("\r", 0, 36) == "⌘↩", "return")
    expect(label(nil, 8, 122) == "F1", "function key without modifiers")
    expect(label("\u{F700}", 0, 126) == "⌘↑", "private-use arrow character uses the key code")
    expect(label("[", 0) == "⌘[", "punctuation key")
    expect(label("é", 0) == "⌘É", "non-ASCII key")
    expect(label(nil, 0) == "", "no key, no shortcut")
    expect(label("", 0, 999) == "", "unknown key code, no shortcut")
    expect(label(nil, nil) == "", "nothing at all")

    expect(Navigation.breadcrumb(["File", "Export", "PDF"]) == "File › Export › PDF", "menu path")
    expect(Navigation.breadcrumb(["Edit"]) == "Edit", "single-level path")
    expect(Navigation.breadcrumb([]) == "", "empty path")

    let rows = ["Mynotes", "Notes", "Safari", "Release Notes"]
    func found(_ q: String) -> [String] { Navigation.filter(rows, q) { [$0] } }
    expect(found("") == rows, "empty query keeps every row in order")
    expect(found("zzz").isEmpty, "no match, no rows")
    expect(found("notes") == ["Notes", "Release Notes", "Mynotes"], "exact beats word start beats substring")
    expect(found("SAF") == ["Safari"], "case-insensitive")
    expect(Navigation.filter(["Beta", "Alpha", "Zzz"], "a") { [$0] } == ["Alpha", "Beta"], "prefix beats substring, non-matches drop out")
    let windows = [("Inbox", "Mail"), ("Docs", "Safari"), ("Mail settings", "Mail")]
    func windowsFor(_ q: String) -> [String] { Navigation.filter(windows, q) { [$0.0, $0.1] }.map(\.0) }
    expect(windowsFor("mail") == ["Inbox", "Mail settings"], "app name matches too, ties keep their order")
    expect(windowsFor("docs") == ["Docs"], "title match")
}
