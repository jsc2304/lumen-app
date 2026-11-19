import AppKit
import NaturalLanguage
import Translation

// Checks for Lookup.swift: query parsing, ranking, row and action layout, entry splitting and language choice.
// Nothing here touches Contacts, the dictionaries, Translation or the AI; the people are made up.
func checkLookup() {
    // Commands
    let commands = Lookup.commands()
    expect(commands.map(\.id) == ["lookup.contacts", "lookup.define", "lookup.translate"], "lookup command ids")
    expect(commands.map(\.title) == ["Search Contacts", "Define Word", "Translate"], "lookup command titles")
    expect(commands.allSatisfy { $0.actions.first?.closes == false }, "lookup commands open a list, they do not close the panel")

    // Define: the query forms the root search hands over
    expect(Lookup.defineWord(in: "define house") == "house", "define <word>")
    expect(Lookup.defineWord(in: "  Define   take off ") == "take off", "define, case, spacing, two words")
    expect(Lookup.defineWord(in: "House Definition") == "House", "<word> definition")
    expect(Lookup.defineWord(in: "bedeutung Haus") == "Haus", "bedeutung <wort>")
    expect(Lookup.defineWord(in: "define") == nil && Lookup.defineWord(in: "define ") == nil, "define without a word")
    expect(Lookup.defineWord(in: "definition") == nil && Lookup.defineWord(in: " definition") == nil, "definition without a word")
    expect(Lookup.defineWord(in: "redefine house") == nil && Lookup.defineWord(in: "house") == nil && Lookup.defineWord(in: "") == nil, "other queries")
    expect(Lookup.defineItem("   ") == nil, "a blank word has no item")

    // Define: splitting an entry. DCSCopyTextDefinition returns one flat string; these are made up in its shape
    // (headword, syllables, | pronunciation |, part of speech, numbered senses, • sub-senses, labels in capitals).
    let broken = "house | haʊs |\nnoun\n1 a building for human habitation.\n• a building used for a purpose.\nverb | haʊz | [with object]\n1 provide with accommodation.\nORIGIN\nOld English hūs."
    let flat = "glim glim·mer | ˈglimər | noun 1 a small thing that shines: a glim of light | a glim of hope. • a hint. 2 a rare event: a glim in the schedule. "
        + "adjective [attributive] | ˈglimər | 1 relating to shining: a glim lamp. 2 small. verb [no object] | ˈglimər | 1 shine faintly: the lamp glimmered. "
        + "2 appear briefly: hope glimmered. PHRASES glim and glam 1 shiny things. 2 show. ORIGIN Middle English: of unknown origin."
    expect(Define.lines(broken).count == 8 && Define.lines(broken)[2] == "1 a building for human habitation.", "an entry with line breaks keeps them")
    let cut = Define.lines(flat)
    expect(cut == ["glim glim·mer | ˈglimər |", "noun", "1 a small thing that shines: a glim of light | a glim of hope.", "• a hint.",
                   "2 a rare event: a glim in the schedule.", "adjective [attributive] | ˈglimər |", "1 relating to shining: a glim lamp.", "2 small.",
                   "verb [no object] | ˈglimər |", "1 shine faintly: the lamp glimmered.", "2 appear briefly: hope glimmered.", "PHRASES glim and glam",
                   "1 shiny things.", "2 show.", "ORIGIN Middle English: of unknown origin."], "a flat entry is cut into groups, senses, bullets and sections: \(cut)")
    expect(Define.lines("bank 1 | baNGk | noun 1 the edge. 2 a slope.") == ["bank 1 | baNGk |", "noun", "1 the edge.", "2 a slope."], "a homograph number stays with the headword")
    expect(Define.lines("big | big | adjective of a size: a big 2 weeks. noun a big thing.") == ["big | big |", "adjective of a size: a big 2 weeks.", "noun a big thing."],
           "a number that is not the next sense number stays inside the sense")
    expect(Define.lines("Haus | Haus | das Substantiv TYPISCHE VERBINDUNGEN alt, neu. SYNONYME Bau; HeimHERKUNFT mittelhochdeutsch")
           == ["Haus | Haus | das Substantiv", "TYPISCHE VERBINDUNGEN alt, neu.", "SYNONYME Bau; Heim", "HERKUNFT mittelhochdeutsch"], "capital labels, also glued to a word")
    expect(Define.lines("a noun phrase is a group of words: see also the verb group") == ["a noun phrase is a group of words: see also the verb group"], "a part of speech inside a sentence is not a group")
    expect(Define.lines("  \n ").isEmpty, "blank entry has no lines")
    let (head, rest) = Define.split("house noun (plural houses) | hous |", word: "house")
    expect(head == "house" && rest == " noun (plural houses) | hous |", "headword is the typed word")
    expect(Define.split("Haus | Haus |", word: "haus").head == "Haus", "typed case does not matter, the entry's spelling is shown")
    expect(Define.split("serendipity noun", word: "x").head == "serendipity", "first word when the entry starts with another word")

    // Define: the row
    let entry = Define.item("house", broken)
    expect(entry.id == "lookup.define.house" && entry.title == "house" && entry.kind == "Definition", "definition row")
    expect(entry.subtitle == "a building for human habitation.", "subtitle is the first numbered sense: \(entry.subtitle)")
    expect(Define.item("glim", flat).subtitle == "a small thing that shines: a glim of light | a glim of hope.", "subtitle of a flat entry")
    expect(Define.summary(Define.lines("zip | zip | adjective quick and neat: a zip answer. • a hint. PHRASES zip it 1 be quiet. 2 stop.")) == "quick and neat: a zip answer.",
           "subtitle without numbers: first long line, part of speech dropped, phrases ignored")
    expect(Define.summary(Define.lines("Haus | Haus | das Substantiv TYPISCHE VERBINDUNGEN alt, neu. 1 a Gebäude zum Wohnen 2 a Dynastie")) == "a Gebäude zum Wohnen", "subtitle: numbered sense after the labels")
    expect(Define.item("one", "one | wʌn | a short entry in a single line").subtitle == "", "a one-line entry has no subtitle, the detail shows it")
    expect(entry.actions.map(\.title) == ["Copy Definition", "Open in Dictionary"], "definition actions")
    expect(entry.actions.map { $0.shortcut?.label ?? "-" } == ["⇧⌘C", "⌘O"], "definition shortcuts")
    expect(entry.detail?.markdown.hasPrefix("**house** | haʊs |\nnoun\n1 a building") == true, "headword is bold, senses on new lines")
    let escaped = Define.item("a_b", "a_b | x |\n1 uses *stars* and [brackets] and `ticks`").detail?.markdown ?? ""
    let shown = (try? AttributedString(markdown: escaped, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        .map { String($0.characters) } ?? ""
    expect(shown == "a_b | x |\n1 uses *stars* and [brackets] and `ticks`", "markdown characters in a definition show literally: \(shown)")

    // Translate: languages
    expect(Translator.target(source: "de", override: nil) == "en", "German goes to English")
    expect(Translator.target(source: "en", override: nil) == "de" && Translator.target(source: "fr", override: nil) == "de", "everything else goes to German")
    expect(Translator.target(source: nil, override: nil) == "de", "no language goes to German")
    expect(Translator.target(source: "en", override: "fr") == "fr" && Translator.target(source: "de", override: "fr") == "fr", "a picked target sticks")
    expect(Translator.target(source: "fr", override: "fr") == "de" && Translator.target(source: "de", override: "de") == "en", "a picked target equal to the source is ignored")
    expect(Translator.next(after: "de", source: "en") == "fr" && Translator.next(after: "fr", source: "en") == "es", "cycle from German for English text")
    expect(Translator.next(after: "it", source: "en") == "de", "cycle wraps and skips the text's language")
    expect(Translator.next(after: "en", source: "de") == "fr" && Translator.next(after: "it", source: "de") == "en", "cycle for German text")
    expect(Translator.next(after: "de", source: "fr") == "es" && Translator.next(after: "it", source: "fr") == "en", "cycle for French text skips French")
    expect(Translator.name("de") == "German" && Translator.name("en") == "English", "language names are English")
    // Short words: a weak guess for another language yields to English or German; a sure one stands.
    func hypo(_ pairs: KeyValuePairs<NLLanguage, Double>) -> String? { Translator.language(of: Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })) }
    expect(hypo([.swedish: 0.26, .danish: 0.21, .german: 0.18]) == "de", "weak Swedish guess, German candidate")
    expect(hypo([.french: 0.49, .english: 0.34]) == "en", "weak French guess, English candidate")
    expect(hypo([.polish: 0.29, .english: 0.07, .german: 0.06]) == "en", "the likelier of English and German")
    expect(hypo([.dutch: 0.98, .german: 0.01]) == "nl", "a sure guess stands")
    expect(hypo([.french: 0.63, .english: 0.04]) == "fr", "a fairly sure guess stands")
    expect(hypo([.polish: 0.3, .czech: 0.2]) == "pl" && hypo([:]) == nil, "no English or German candidate, or no guess at all")
    expect(Translator.detect("Das ist ein Test") == "de" && Translator.detect("This is a test of the translator") == "en", "full sentences")
    expect(Translator.detect("12 + 3 = 15") == nil, "digits have no language")

    // Translate: the row in each state
    func job(_ state: Translator.State, source: String? = "de", target: String = "en", ai: Bool = false) -> Translator.Job {
        Translator.Job(text: "Guten Morgen", source: source, target: target, ai: ai, state: state)
    }
    let titles: (Item) -> [String] = { $0.actions.map(\.title) }
    let keys: (Item) -> [String] = { $0.actions.map { $0.shortcut?.label ?? "-" } }
    let working = Translator.shared.row(job(.working))
    expect(working.id == "lookup.translate.row" && working.title == "Translating…" && working.subtitle == "German → English" && working.kind == "English", "working row")
    expect(titles(working) == ["Translate to French", "Copy Source"] && keys(working) == ["⌘L", "⇧⌘C"], "working actions")
    let done = Translator.shared.row(job(.done("Good morning", onDevice: true)))
    expect(done.id == working.id && done.title == "Good morning" && done.subtitle == "" && done.kind == "English", "done row keeps the row id")
    expect(titles(done) == ["Copy Translation", "Paste Translation", "Swap Languages", "Translate to French", "Copy Source"], "done actions: ↵ copy, ⌘↵ paste")
    expect(keys(done) == ["-", "-", "⌘S", "⌘L", "⇧⌘C"], "done shortcuts")
    expect(done.detail?.markdown == "Good morning" && done.detail?.metadata.map(\.1) == ["German", "English", "This Mac"], "done detail")
    expect(Translator.shared.row(job(.done("Guten *Morgen*", onDevice: false))).detail?.metadata.last?.1 == "AI", "engine shown for AI")
    let download = Translator.shared.row(job(.download))
    expect(download.title == "Translation languages are not downloaded" && download.subtitle == "German → English", "not-downloaded row says so")
    expect(titles(download) == ["Open Translation Settings", "Translate with AI", "Translate to French", "Copy Source"], "not-downloaded actions")
    expect(download.detail?.markdown.contains("Translation Languages") == true, "not-downloaded detail names the setting")
    // A pair Apple does not translate waits for the user: a row with explicit actions, never an automatic AI call.
    if case .unsupported? = Translator.unavailable(.unsupported) {} else { expect(false, "an unsupported pair is its own state, not the AI") }
    if case .download? = Translator.unavailable(.supported) {} else { expect(false, "a supported pair that is not installed needs the download") }
    expect(Translator.unavailable(.installed) == nil, "an installed pair is translated on this Mac")
    let unsupported = Translator.shared.row(job(.unsupported))
    expect(unsupported.id == working.id && unsupported.title.contains("not supported") && unsupported.subtitle == "German → English", "unsupported row says so")
    expect(titles(unsupported) == ["Translate with AI", "Translate to French", "Copy Source"] && keys(unsupported) == ["-", "⌘L", "⇧⌘C"], "unsupported actions: AI only on request")
    expect(unsupported.detail?.markdown.contains("sends the text to the AI") == true, "unsupported detail says where the text goes")
    let failed = Translator.shared.row(job(.failed("AI is not set up yet.")))
    expect(failed.title == "AI is not set up yet." && titles(failed) == ["Try Again", "Translate to French", "Copy Source"] && keys(failed)[0] == "⌘R", "failed row")
    let noLanguage = Translator.shared.row(job(.failed("No language recognised in this text"), source: nil, target: "de"))
    expect(noLanguage.subtitle == "" && titles(noLanguage).contains("Translate to French"), "no language: no pair, cycle still works")
    expect(titles(Translator.shared.row(job(.working, source: "en", target: "de"))).first == "Translate to French", "cycle target for English text")
    expect(titles(Translator.shared.row(job(.working, source: "fr", target: "de"))).first == "Translate to Spanish", "cycle target for French text")

    // Contacts: made-up people
    func person(_ id: String, _ name: String, company: String = "", emails: [String] = [], phones: [String] = [], birthday: String = "") -> ContactSearch.Person {
        ContactSearch.Person(id: id, name: name, company: company,
                             emails: emails.map { ContactSearch.Field(label: "work", value: $0) },
                             phones: phones.map { ContactSearch.Field(label: "mobile", value: $0) }, birthday: birthday)
    }
    let anna = person("A1", "Anna Example", company: "Sample GmbH", emails: ["anna@sample.test", "a.example@home.test"], phones: ["+49 170 5550101", "030 5550102"], birthday: "5 March 1985")
    let bernd = person("B2", "Bernd Beispiel", company: "Muster AG", emails: ["bernd@muster.test"])
    let clara = person("C3", "Clara Test", phones: ["+1 (555) 010-0199"])
    let anon = person("D4", "Muster Studio")
    let all = [anna, bernd, clara, anon]
    expect(ContactSearch.rank(all, "").map(\.id) == ["A1", "B2", "C3", "D4"], "empty query lists everyone in order")
    expect(ContactSearch.rank(all, "  ").count == 4 && ContactSearch.rank(all, "", limit: 2).map(\.id) == ["A1", "B2"], "blank query, limit")
    expect(ContactSearch.rank(all, "anna").map(\.id) == ["A1"], "by name")
    expect(ContactSearch.rank(all, "BEISPIEL").map(\.id) == ["B2"], "case-insensitive name")
    expect(ContactSearch.rank(all, "muster").map(\.id) == ["D4", "B2"], "name match before company match")
    expect(ContactSearch.rank(all, "home.test").map(\.id) == ["A1"], "second e-mail address")
    expect(ContactSearch.rank(all, "555 0101").map(\.id) == ["A1"], "spaces in the typed number are ignored")
    expect(ContactSearch.rank(all, "5550101").map(\.id) == ["A1"] && ContactSearch.rank(all, "+49 170").map(\.id) == ["A1"], "phone digits")
    expect(ContactSearch.rank(all, "0199").map(\.id) == ["C3"] && ContactSearch.rank(all, "(555) 010-01").map(\.id) == ["C3"], "phone with punctuation")
    expect(ContactSearch.rank(all, "55").isEmpty, "fewer than three digits are not a phone search")
    expect(ContactSearch.rank(all, "zzzz").isEmpty, "no match")

    // Contacts: rows and actions
    let a = ContactSearch.item(anna)
    expect(a.id == "lookup.contact.A1" && a.title == "Anna Example" && a.subtitle == "Sample GmbH" && a.kind == "Contact", "contact row")
    expect(a.actions.map(\.title) == ["Copy Email", "Open in Contacts", "Compose Email", "Copy Phone", "Call via FaceTime", "Copy Name",
                                      "Copy a.example@home.test", "Copy 030 5550102"], "contact actions with email")
    expect(a.actions.map { $0.shortcut?.label ?? "-" } == ["⇧⌘E", "⌘O", "⌘E", "⇧⌘P", "⌘T", "⇧⌘N", "-", "-"], "contact shortcuts")
    let b = ContactSearch.item(bernd)
    expect(b.subtitle == "Muster AG" && b.actions.map(\.title) == ["Copy Email", "Open in Contacts", "Compose Email", "Copy Name"], "contact with an email only")
    let c = ContactSearch.item(clara)
    expect(c.subtitle == "" && c.actions.map(\.title) == ["Open in Contacts", "Copy Phone", "Call via FaceTime", "Copy Name"], "no email: Open in Contacts first")
    expect(ContactSearch.item(person("E5", "Dora Probe", emails: ["dora@probe.test"])).subtitle == "dora@probe.test", "subtitle falls back to the email")
    expect(ContactSearch.item(anon).actions.map(\.title) == ["Open in Contacts", "Copy Name"], "name only")
    expect(a.detail?.metadata.map(\.0) == ["Email · work", "Email · work", "Phone · mobile", "Phone · mobile", "Birthday"], "detail rows")
    expect(a.detail?.metadata.last?.1 == "5 March 1985" && a.detail?.markdown == "**Anna Example**\nSample GmbH", "detail text")
    expect(ContactSearch.item(person("F6", "Star *Man*")).detail?.markdown == "**Star \\*Man\\***", "markdown characters in a name are escaped")
    if case .symbol(let name) = a.icon { expect(name == "person.crop.circle", "person symbol without a photo") } else { expect(false, "icon without a photo is a symbol") }
    var photographed = anna
    photographed.photo = NSImage(size: NSSize(width: 4, height: 4))
    if case .image = ContactSearch.item(photographed).icon {} else { expect(false, "a photo becomes the icon") }

    // Contacts: URLs and birthday
    expect(ContactSearch.mailto("anna@sample.test")?.absoluteString == "mailto:anna@sample.test", "mailto url")
    expect(ContactSearch.mailto("a+b@sample.test")?.scheme == "mailto", "mailto with a plus")
    expect(ContactSearch.facetime("+49 170 5550101")?.absoluteString == "facetime-audio://+491705550101", "facetime url keeps + and digits")
    expect(ContactSearch.facetime("(555) 010-0199")?.absoluteString == "facetime-audio://5550100199", "facetime url drops punctuation")
    expect(ContactSearch.birthday(nil) == "" && ContactSearch.birthday(DateComponents(year: 1985)) == "", "no birthday")
    expect(ContactSearch.birthday(DateComponents(month: 3, day: 5)).contains("5") && !ContactSearch.birthday(DateComponents(month: 3, day: 5)).contains("2000"), "birthday without a year")
    expect(ContactSearch.birthday(DateComponents(year: 1985, month: 3, day: 5)).contains("1985"), "birthday with a year")
    expect(!ContactSearch.birthday(DateComponents(month: 2, day: 29)).isEmpty, "29 February without a year")

    // Extra shortcuts need ⌘, ⌃ or ⌥, are never doubled in one row, and must not take the keys the panel and the system keep.
    let taken: Set<String> = ["⌘K", "⌘,", "⌘C", "⌘V", "⌘X", "⌘A", "⌘Z"]
    for item in [a, b, c, entry, Define.item("x", "x | y |\n1 something long enough to be a sense"), working, done, download, unsupported, failed] {
        let labels = item.actions.compactMap { $0.shortcut?.label }
        expect(Set(labels).count == labels.count, "no shortcut twice in \(item.title)")
        for action in item.actions {
            guard let s = action.shortcut else { continue }
            expect(!s.modifiers.isDisjoint(with: [.command, .control, .option]) && !taken.contains(s.label), "shortcut \(s.label) is allowed")
        }
    }
}
