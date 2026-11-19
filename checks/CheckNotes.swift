import AppKit

// Checks for Notes.swift: titles, counts, loading older files, search order, list actions, Markdown styling.
// Only pure functions: nothing here opens the notes window or touches notes.json.
func checkNotes() {
    typealias Note = Notes.Note
    expect(Note(text: "# Shopping list\n- milk").title == "Shopping list", "title is the first line without #")
    expect(Note(text: "\n  \n ### Plan ##\nbody").title == "Plan ##", "leading blank lines are skipped, # and spaces stripped")
    expect(Note(text: "plain first line\n# later").title == "plain first line", "title of a plain first line")
    expect(Note(text: "").title == "Untitled" && Note(text: "#\nbody").title == "Untitled", "no usable first line is Untitled")
    expect(Note(text: " \n\t ").isBlank && !Note(text: " a ").isBlank, "blank means whitespace only")
    let long = String(repeating: "x", count: 5000)
    expect(Note(text: long + "\nbody").title.count == 200 && Note(text: "  " + long).title.count == 198, "a long first line is cut to 200 characters")
    expect(Note(text: String(repeating: " ", count: 500) + "\n\n  # Late").title == "Late", "blank lines of any length are skipped")
    expect(Note(text: "# Hello world\n\n- one\n- two (2)").wordCount == 5 && Note(text: "").wordCount == 0, "word count ignores Markdown marks")
    expect(Note(text: "# - > * ---").wordCount == 0 && Note(text: "don't stop — Äpfel, 3,5 kg\r\nok").wordCount == 6,
           "words are whitespace-separated pieces with a letter or digit")
    expect(Note(text: "A/B: C\nbody").fileName == "A-B- C.md", "file name replaces / and :")
    expect(Note(text: String(repeating: "x", count: 200)).fileName.count == 83, "file name is capped")

    let old = try? JSONDecoder().decode([Note].self, from: Data(#"[{"text":"hi"},{"id":"x","text":"yo","created":1000}]"#.utf8))
    expect(old?.count == 2 && old?[0].text == "hi" && old?[0].id.isEmpty == false, "notes.json with missing keys still loads")
    expect(old?[1].id == "x" && old?[1].created == Date(timeIntervalSinceReferenceDate: 1000) && old?[1].modified == old?[1].created,
           "a missing modified date falls back to created")
    var kept = Note(text: "# Saved\nbody")
    kept.created = Date(timeIntervalSinceReferenceDate: 5)
    kept.modified = Date(timeIntervalSinceReferenceDate: 9)
    let round = (try? JSONEncoder().encode([kept])).flatMap { try? JSONDecoder().decode([Note].self, from: $0) }
    expect(round == [kept], "a note survives encoding and decoding")

    func note(_ text: String, _ modified: Double) -> Note {
        var n = Note(text: text)
        n.modified = Date(timeIntervalSinceReferenceDate: modified)
        return n
    }
    let groceries = note("# Groceries\nmilk and eggs", 10), meeting = note("Meeting notes\nask about milk", 30)
    let ideas = note("Ideas", 20), empty = note("  \n", 99)
    let all = [groceries, meeting, ideas, empty]
    expect(Notes.matching(all, "").map(\.title) == ["Meeting notes", "Ideas", "Groceries"], "no query: newest first, empty notes left out")
    expect(Notes.matching(all, "meet").first?.title == "Meeting notes", "a title match finds the note")
    expect(Notes.matching(all, "milk").map(\.title) == ["Meeting notes", "Groceries"], "text matches, newest first among equals")
    expect(Notes.matching(all, "groc").first?.title == "Groceries" && Notes.matching(all, "zzzz").isEmpty, "search misses nothing it should and finds nothing else")
    expect(Notes.matching(all, "  milk ").map(\.title) == ["Meeting notes", "Groceries"], "the query is trimmed")
    let eggs = note("Eggs\ndone", 1)
    expect(Notes.matching(all + [eggs], "eggs").map(\.title) == ["Eggs", "Groceries"], "a title match beats a newer text-only match")

    let items = Notes.listItems(all, "")
    expect(items.count == 3 && items.allSatisfy { $0.id.hasPrefix("notes.") && !$0.track }, "one untracked list row per non-empty note")
    expect(items[0].detail?.markdown == meeting.text && items[0].detail?.metadata.first?.1 == "5", "the preview shows the note's Markdown")
    let actions = items[0].actions
    expect(actions.map(\.title) == ["Open Note", "Copy Note", "Delete Note", "Export as Markdown…", "Create Note"], "list actions: ↵, ⌘↵, then the rest")
    expect(Action.secondary(of: actions)?.title == "Copy Note", "⌘↵ copies the note")
    expect(actions[2].destructive && actions[2].shortcut?.label == "⌃X" && !actions[2].closes, "delete is ⌃X, destructive and keeps the panel open")
    let reserved = ["⌘K", "⌘,", "⌘C", "⌘V", "⌘X", "⌘A", "⌘Z"]
    expect(actions.compactMap(\.shortcut).allSatisfy { !reserved.contains($0.label) && !$0.modifiers.isDisjoint(with: [.command, .control, .option]) },
           "action shortcuts use ⌘, ⌃ or ⌥ and keep the reserved ones free")
    expect(Notes.listItems([], "").map(\.id) == ["notes.none"] && Notes.listItems([], "").first?.actions.first?.title == "Create Note",
           "no notes: one row that creates one")
    expect(Notes.listItems(all, "zzzz").first?.title == "No matching notes", "no match is said so")

    expect(Notes.commands().map(\.id) == ["notes.open", "notes.create", "notes.search"], "root command ids")
    expect(Notes.commands().map(\.title) == ["Lumen Notes", "Create Note", "Search Notes"], "root command titles")

    let text = "# Title\nbody\n## Two ##\n- item\n  * nested\n12. twelfth\n3) third\n-not a list\nplain # no"
    let styles = Notes.styles(text)
    let ns = text as NSString
    let heads = styles.filter { if case .heading = $0.style { return true } else { return false } }
    expect(heads.map { ns.substring(with: $0.range) } == ["# Title", "## Two ##"] && heads.map(\.style) == [.heading(1), .heading(2)],
           "headings are whole lines with their level")
    expect(styles.filter { $0.style == .marker }.map { ns.substring(with: $0.range) } == ["-", "*", "12.", "3)"],
           "list markers are the bullet or number only")
    expect(Notes.styles("####### seven\n#nospace").isEmpty, "seven # or no space is no heading")
}
