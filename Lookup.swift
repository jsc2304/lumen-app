import AppKit
import Contacts
import CoreServices
import NaturalLanguage
import Translation

/// Contacts, Define Word and Translate.
enum Lookup {
    static func commands() -> [Item] {
        [.command("lookup.contacts", "Search Contacts", kind: "Contacts", icon: "person.crop.circle",
                  keywords: ["contacts", "people", "address book", "kontakte", "phone", "email"], closes: false) {
            ContactSearch.shared.open()
        },
        .command("lookup.define", "Define Word", kind: "Dictionary", icon: "character.book.closed",
                 keywords: ["dictionary", "definition", "meaning", "lookup", "wörterbuch", "bedeutung"], closes: false) {
            Define.open()
        },
        .command("lookup.translate", "Translate", kind: "Translate", icon: "translate",
                 keywords: ["translation", "german", "english", "übersetzen", "übersetzung", "deutsch", "englisch"], closes: false) {
            Translator.shared.open()
        }]
    }

    /// The word in "define house", "house definition" or "bedeutung haus"; nil for any other query.
    static func defineWord(in query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        func word(_ s: Substring) -> String? {
            let w = s.trimmingCharacters(in: .whitespaces)
            return w.isEmpty ? nil : w
        }
        for prefix in ["define ", "bedeutung "] where lower.hasPrefix(prefix) { return word(q.dropFirst(prefix.count)) }
        return lower.hasSuffix(" definition") ? word(q.dropLast(" definition".count)) : nil
    }

    /// A root query item with the definition of `word`; nil while the dictionary is still being asked, or when
    /// no dictionary has the word. The first call reloads the root search once the answer is in.
    static func defineItem(_ word: String) -> Item? {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, case .found(let raw) = Define.entry(w) else { return nil }
        return Define.item(w, raw)
    }
}

/// Backslash-escapes the characters inline Markdown would swallow, for text shown in a Detail.
func escapeMarkdown(_ s: String) -> String {
    s.replacingOccurrences(of: #"[\\*_`\[\]]"#, with: #"\\$0"#, options: .regularExpression)
}

/// A problem in words for a row: the localized description plus the reason, when there is one.
private func describe(_ error: Error) -> String {
    let e = error as? LocalizedError
    let text = [e?.errorDescription, e?.failureReason].compactMap { $0 }.joined(separator: ". ")
    return text.isEmpty ? error.localizedDescription : text
}

// MARK: - Search Contacts

/// "Search Contacts": every contact is fetched once per open on a background queue and filtered locally.
final class ContactSearch {
    static let shared = ContactSearch()
    private let store = CNContactStore()
    private var people: [Person]?   // nil until the first fetch of this session finishes
    private var loading = false

    struct Field {
        let label: String
        let value: String
    }

    struct Person {
        let id: String
        let name: String
        var company = ""
        var emails: [Field] = []
        var phones: [Field] = []
        var birthday = ""
        var photo: NSImage? = nil
    }

    private var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    func open() {
        if status == .notDetermined {
            store.requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async { [self] in
                    if granted { load() }
                    Launcher.shared.reload()
                }
            }
        } else if status == .authorized {
            load()
        }
        Launcher.shared.push(.list(ListSpec(title: "Search Contacts", placeholder: "Search contacts…", showsDetail: true) { [weak self] in
            self?.items($0) ?? []
        }))
    }

    private static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor,
    ]

    private func load() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            var found = [Person]()
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            request.sortOrder = .userDefault
            do {
                try store.enumerateContacts(with: request) { c, _ in found.append(Self.person(c)) }
            } catch {
                NSLog("Lumen: contacts could not be read; check Contacts permission")
            }
            let result = found
            DispatchQueue.main.async { [self] in
                people = result
                loading = false
                Launcher.shared.reload()
            }
        }
    }

    private static func person(_ c: CNContact) -> Person {
        func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        let emails = c.emailAddresses.map { Field(label: label($0.label), value: $0.value as String) }
        var name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
        if name.isEmpty { name = c.organizationName }
        if name.isEmpty { name = emails.first?.value ?? "No Name" }
        return Person(id: c.identifier, name: name, company: c.organizationName, emails: emails,
                      phones: c.phoneNumbers.map { Field(label: label($0.label), value: $0.value.stringValue) },
                      birthday: birthday(c.birthday), photo: c.thumbnailImageData.flatMap { NSImage(data: $0) })
    }

    // MARK: Rows

    private func items(_ q: String) -> [Item] {
        switch status {
        case .authorized: break
        case .notDetermined:
            return [Item(id: "lookup.contacts.wait", title: "Waiting for contacts access…", icon: .symbol("hourglass"), track: false, actions: [])]
        default:
            return [Item(id: "lookup.contacts.grant", title: "Allow Lumen to read your contacts", subtitle: "Privacy & Security → Contacts",
                         icon: .symbol("lock"), track: false, actions: [Action(title: "Open Privacy Settings", icon: "gearshape") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
            }])]
        }
        guard let people else {
            return [Item(id: "lookup.contacts.loading", title: "Loading contacts…", icon: .symbol("hourglass"), track: false, actions: [])]
        }
        let found = Self.rank(people, q)
        guard !found.isEmpty else {
            return [Item(id: "lookup.contacts.none", title: q.isEmpty ? "No contacts" : "No matching contacts",
                         icon: .symbol("person.crop.circle"), track: false, actions: [])]
        }
        return found.map(Self.item)
    }

    /// Contacts matching `q` by name or company (fuzzy), e-mail address (contains) or phone number (digits contain
    /// the digits typed, from three on), best match first. At most `limit`, so a big address book stays quick.
    static func rank(_ people: [Person], _ q: String, limit: Int = 100) -> [Person] {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(people.prefix(limit)) }
        let digits = q.filter(\.isNumber)
        func score(_ p: Person) -> Double {
            var s = max(matchScore(q, p.name), matchScore(q, p.company) * 0.9)
            if p.emails.contains(where: { $0.value.localizedCaseInsensitiveContains(q) }) { s = max(s, 35) }
            if digits.count >= 3, p.phones.contains(where: { $0.value.filter(\.isNumber).contains(digits) }) { s = max(s, 35) }
            return s
        }
        let scored = people.indices.map { (index: $0, score: score(people[$0])) }.filter { $0.score > 0 }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).map { people[$0.index] }
    }

    static func item(_ p: Person) -> Item {
        let open = Action(title: "Open in Contacts", icon: "person.crop.circle", shortcut: Shortcut(.command, "o")) { openInContacts(p.id) }
        var actions: [Action]
        if let email = p.emails.first?.value {
            actions = [.copy("Copy Email", shortcut: Shortcut([.command, .shift], "e")) { email }, open,
                       Action(title: "Compose Email", icon: "envelope", shortcut: Shortcut(.command, "e")) {
                if let url = mailto(email) { NSWorkspace.shared.open(url) }
            }]
        } else {
            actions = [open]
        }
        if let phone = p.phones.first?.value {
            actions += [.copy("Copy Phone", shortcut: Shortcut([.command, .shift], "p")) { phone },
                        Action(title: "Call via FaceTime", icon: "phone", shortcut: Shortcut(.command, "t")) {
                if let url = facetime(phone) { NSWorkspace.shared.open(url) }
            }]
        }
        actions.append(.copy("Copy Name", shortcut: Shortcut([.command, .shift], "n")) { p.name })
        // More than one address or number: the others are in the ⌘K menu.
        actions += (p.emails.dropFirst() + p.phones.dropFirst()).map { f in .copy("Copy " + f.value) { f.value } }

        var meta = p.emails.map { ($0.label.isEmpty ? "Email" : "Email · " + $0.label, $0.value) }
            + p.phones.map { ($0.label.isEmpty ? "Phone" : "Phone · " + $0.label, $0.value) }
        if !p.birthday.isEmpty { meta.append(("Birthday", p.birthday)) }
        let heading = "**" + escapeMarkdown(p.name) + "**" + (p.company.isEmpty || p.company == p.name ? "" : "\n" + escapeMarkdown(p.company))
        return Item(id: "lookup.contact." + p.id, title: p.name, subtitle: p.company.isEmpty ? p.emails.first?.value ?? "" : p.company,
                    kind: "Contact", icon: p.photo.map(Icon.image) ?? .symbol("person.crop.circle"), track: false, actions: actions,
                    detail: Detail(markdown: heading, metadata: meta))
    }

    /// "Month day", with the year when the contact has one.
    static func birthday(_ b: DateComponents?) -> String {
        // 2000 is a leap year, so a birthday on 29 February survives when the year is unknown.
        guard let b, let month = b.month, let day = b.day,
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: b.year ?? 2000, month: month, day: day))
        else { return "" }
        return date.formatted(b.year == nil ? Date.FormatStyle().day().month(.wide) : Date.FormatStyle().day().month(.wide).year())
    }

    static func mailto(_ email: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        return c.url
    }

    static func facetime(_ phone: String) -> URL? {
        URL(string: "facetime-audio://" + phone.filter { $0.isNumber || $0 == "+" })
    }

    private static func openInContacts(_ id: String) {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "addressbook://" + encoded), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app"))
    }
}

// MARK: - Define Word

/// "Define Word": the system dictionaries through DCSCopyTextDefinition. The lookup runs on a background queue
/// and its answer is cached, so typing never waits for a dictionary.
enum Define {
    enum Entry {
        case pending, missing
        case found(String)
    }

    private static var cache: [String: Entry] = [:]   // main thread only
    private static let queue = DispatchQueue(label: "lumen.define", qos: .userInitiated)

    static func open() {
        Launcher.shared.push(.list(ListSpec(title: "Define Word", placeholder: "Type a word…", showsDetail: true) { items($0) }))
    }

    static func entry(_ word: String) -> Entry {
        if let known = cache[word] { return known }
        cache[word] = .pending
        queue.async {
            let range = CFRange(location: 0, length: word.utf16.count)
            let text = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?
            DispatchQueue.main.async {
                cache[word] = text.map(Entry.found) ?? .missing
                Launcher.shared.reload()
            }
        }
        return .pending
    }

    private static func items(_ q: String) -> [Item] {
        let word = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = Icon.symbol("character.book.closed")
        guard !word.isEmpty else { return [Item(id: "lookup.define.empty", title: "Type a word to define", icon: icon, track: false, actions: [])] }
        switch entry(word) {
        case .found(let raw):
            return [item(word, raw)]
        case .pending:
            return [Item(id: "lookup.define.wait", title: "Looking up “\(word)”…", icon: .symbol("hourglass"), track: false, actions: [])]
        case .missing:
            return [Item(id: "lookup.define.none", title: "No definition for “\(word)”", subtitle: "Open Dictionary to search more sources",
                         icon: icon, track: false, actions: [openAction(word)],
                         detail: Detail(markdown: "None of the dictionaries on this Mac has this word. If Dictionary has no dictionary turned on, open it, go to Settings and enable one."))]
        }
    }

    static func item(_ word: String, _ raw: String) -> Item {
        let lines = lines(raw)
        let (head, rest) = split(lines.first ?? word, word: word)
        let body = [(head.isEmpty ? "" : "**" + escapeMarkdown(head) + "**") + escapeMarkdown(rest)] + lines.dropFirst().map(escapeMarkdown)
        return Item(id: "lookup.define." + word.lowercased(), title: head.isEmpty ? word : head, subtitle: summary(lines), kind: "Definition",
                    icon: .symbol("character.book.closed"), track: false,
                    actions: [.copy("Copy Definition", shortcut: Shortcut([.command, .shift], "c")) { lines.joined(separator: "\n") }, openAction(word)],
                    detail: Detail(markdown: body.joined(separator: "\n")))
    }

    /// One line for the row: the first numbered sense, else the first long line, taken from before PHRASES, ORIGIN
    /// and the like; entries that start with such labels (German) use their first numbered sense.
    static func summary(_ lines: [String]) -> String {
        func numbered(_ l: String) -> Bool { l.range(of: #"^\d+ "#, options: .regularExpression) != nil }
        let body = lines.dropFirst()
        let main = body.prefix { $0.range(of: "^" + section, options: .regularExpression) == nil }
        let line = main.first(where: numbered) ?? main.first { $0.count > 20 } ?? body.first(where: numbered) ?? ""
        return line.replacingOccurrences(of: #"^(?:\d+ )?(?:(?:\#(partsOfSpeech)) )?"#, with: "", options: .regularExpression)
    }

    private static func openAction(_ word: String) -> Action {
        Action(title: "Open in Dictionary", icon: "book", shortcut: Shortcut(.command, "o")) {
            if let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed), let url = URL(string: "dict://" + encoded) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static let partsOfSpeech = "noun|verb|adjective|adverb|exclamation|pronoun|preposition|conjunction|determiner|abbreviation|prefix|suffix|interjection"
    // A part of speech right after a sentence end, a pronunciation or a note starts a group of senses.
    private static let groupStart = #"(?<=[.?!|)] )(?:\#(partsOfSpeech))\b"#
    // Section labels in capitals (PHRASES, ORIGIN, SYNONYME, …), also when glued to the word before.
    private static let section = #"(?<!\p{Lu})\p{Lu}{5,}(?: \p{Lu}{5,})*\b"#

    /// The entry as lines: headword first, then groups of senses, bullets and sections. DCSCopyTextDefinition returns
    /// one flat string, so lines are cut before each part of speech, each sense number (1, 2, 3 … per group), each
    /// • and ▶, and each label in capitals. A string that already has line breaks is only trimmed.
    /// ponytail: tuned on the New Oxford American Dictionary and the German dictionary of this Mac; a stray " 2 " or
    /// an acronym of five letters inside a sense cuts it early, and German entries stay long and rough.
    static func lines(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("\n") {
            s = s.replacingOccurrences(of: groupStart, with: "\n$0", options: .regularExpression)
            s = s.components(separatedBy: "\n").map(numbered).joined(separator: "\n")
            for mark in ["▶", "•"] { s = s.replacingOccurrences(of: mark, with: "\n" + mark) }
            s = s.replacingOccurrences(of: section, with: "\n$0", options: .regularExpression)
        }
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Cuts before the sense numbers 1, 2, 3 … in order; after the last one the count starts again at 1.
    private static func numbered(_ text: String) -> String {
        var s = text as NSString
        var n = 1, from = 0
        while from < s.length {
            // Not before "|": that is a homograph number as in "bank 1 | baNGk |".
            let r = s.range(of: #"(?<=\s)\#(n) (?=[^\s\d|])"#, options: .regularExpression, range: NSRange(location: from, length: s.length - from))
            if r.location != NSNotFound {
                s = s.replacingCharacters(in: NSRange(location: r.location, length: 0), with: "\n") as NSString
                from = r.location + r.length + 1
                n += 1
            } else if n > 1 {
                n = 1
            } else {
                break
            }
        }
        return s as String
    }

    /// The headword (the typed word when the entry starts with it, else its first word) and the rest of the line.
    static func split(_ first: String, word: String) -> (head: String, rest: String) {
        let n = first.lowercased().hasPrefix(word.lowercased()) ? word.count : first.prefix { !$0.isWhitespace }.count
        return (String(first.prefix(n)), String(first.dropFirst(n)))
    }
}

// MARK: - Translate

/// "Translate": the list's query is the text. German goes to English, everything else to German; ⌘L cycles
/// French, Spanish, Italian. Translation runs on this Mac through Apple's Translation framework (needs the
/// language pair downloaded). The text only goes to the configured AI when the user picks "Translate with AI".
final class Translator {
    static let shared = Translator()
    static let languages = ["en", "de", "fr", "es", "it"]
    private static let rowID = "lookup.translate.row"

    enum State {
        case working
        case done(String, onDevice: Bool)
        case download           // the language pair is supported but not installed
        case unsupported        // Apple does not translate this pair on this Mac
        case failed(String)
    }

    struct Job {
        let text: String
        let source: String?     // language code; nil when the text has none (digits, symbols)
        let target: String
        var ai: Bool
        var state = State.working
    }

    private var job: Job?
    private var override: String?   // target picked with ⌘L
    private var task: Task<Void, Never>?

    func open() {
        task?.cancel()
        job = nil
        override = nil
        Launcher.shared.push(.list(ListSpec(title: "Translate", placeholder: "Text to translate…", showsDetail: true) { [weak self] in
            self?.items($0) ?? []
        }))
    }

    private func items(_ q: String) -> [Item] {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            task?.cancel()
            job = nil
            return [Item(id: Self.rowID, title: "Type text to translate", subtitle: "English and German automatically, ⌘L for French, Spanish, Italian",
                         icon: .symbol("translate"), track: false, actions: [])]
        }
        let source = Self.detect(text)
        let target = Self.target(source: source, override: override)
        if job?.text != text || job?.target != target { start(text, source, target) }
        return [row(job!)]
    }

    // MARK: Languages

    /// German text goes to English, everything else to German. A target picked with ⌘L sticks, unless it is the
    /// text's own language.
    static func target(source: String?, override: String?) -> String {
        if let override, override != source { return override }
        return source == "de" ? "en" : "de"
    }

    /// The language after `current` in the ⌘L cycle, leaving out the text's own.
    static func next(after current: String, source: String?) -> String {
        let order = languages.filter { $0 != source }
        return order[((order.firstIndex(of: current) ?? -1) + 1) % order.count]
    }

    /// The code of the most likely language. For a word or two the recognizer often picks a neighbour language
    /// ("Hund" as Swedish, "table" as French), so unless it is fairly sure (0.6), English or German wins when either
    /// is among the candidates.
    static func language(of hypotheses: [NLLanguage: Double]) -> String? {
        guard let top = hypotheses.max(by: { $0.value < $1.value }) else { return nil }
        let own = [NLLanguage.english, .german].filter { hypotheses[$0, default: 0] > 0.05 }.max { hypotheses[$0]! < hypotheses[$1]! }
        return (top.value < 0.6 ? own ?? top.key : top.key).rawValue
    }

    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return language(of: recognizer.languageHypotheses(withMaximum: 8))
    }

    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: Translating

    /// Debounces typing (0.4 s), then translates in the background and reloads the list. A new target or an
    /// explicit retry starts at once.
    private func start(_ text: String, _ source: String?, _ target: String, ai: Bool = false) {
        let typing = job?.text != text
        task?.cancel()
        job = Job(text: text, source: source, target: target, ai: ai)
        guard let source else {
            job?.state = .failed("No language recognised in this text")
            return
        }
        task = Task { @MainActor [weak self] in
            if typing { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            let state = await Self.translate(text, from: source, to: target, ai: ai)
            guard !Task.isCancelled, let self else { return }
            job?.state = state
            Launcher.shared.reload()
        }
    }

    /// What the pair's availability says without translating: nil when it can be translated on this Mac. Never the AI:
    /// the typed text leaves the Mac only through the "Translate with AI" action.
    static func unavailable(_ status: LanguageAvailability.Status) -> State? {
        switch status {
        case .installed: return nil
        case .supported: return .download
        default: return .unsupported
        }
    }

    @MainActor
    static func translate(_ text: String, from source: String, to target: String, ai: Bool) async -> State {
        if !ai {
            let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
            if let state = unavailable(await LanguageAvailability().status(from: from, to: to)) { return state }
            do {
                return .done(try await TranslationSession(installedSource: from, target: to).translate(text).targetText, onDevice: true)
            } catch TranslationError.notInstalled {
                return .download
            } catch {
                return .failed(describe(error))
            }
        }
        var out = ""
        let prompt = "Translate the text from \(name(source)) to \(name(target)).\n\n" + AI.untrustedText(text)
        do {
            try await AI.stream(system: aiCommandSystem, prompt: prompt) { out += $0 }
        } catch {
            return .failed(describe(error))
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? .failed("The AI service returned no text") : .done(out, onDevice: false)
    }

    // MARK: Rows

    func row(_ job: Job) -> Item {
        let target = Self.name(job.target)
        let pair = job.source.map { Self.name($0) + " → " + target } ?? ""
        let nextTarget = Self.next(after: job.target, source: job.source)
        let cycle = Action(title: "Translate to " + Self.name(nextTarget), icon: "globe", shortcut: Shortcut(.command, "l"), closes: false) { [self] in
            override = nextTarget
            Launcher.shared.reload()
        }
        let copySource = Action.copy("Copy Source", shortcut: Shortcut([.command, .shift], "c")) { job.text }
        // The only way the text reaches the AI.
        let useAI = Action(title: "Translate with AI", icon: "sparkles", closes: false) { [self] in
            start(job.text, job.source, job.target, ai: true)
            Launcher.shared.reload()
        }
        func item(_ title: String, _ symbol: String, _ actions: [Action], _ detail: Detail? = nil, subtitle: String? = nil) -> Item {
            Item(id: Self.rowID, title: title, subtitle: subtitle ?? pair, kind: target, icon: .symbol(symbol), track: false, actions: actions, detail: detail)
        }

        switch job.state {
        case .working:
            return item("Translating…", "hourglass", [cycle, copySource])
        case .done(let result, let onDevice):
            let swap = Action(title: "Swap Languages", icon: "arrow.left.arrow.right", shortcut: Shortcut(.command, "s"), closes: false) { [self] in
                override = job.source
                Launcher.shared.query = result   // translates the translation back into the language it came from
            }
            // The kind column already names the target, so the subtitle stays empty and the long text gets the room.
            return item(result, "translate", [.copy("Copy Translation") { result },
                                              Action(title: "Paste Translation", icon: "doc.on.clipboard") { Clipboard.shared.paste(text: result) },
                                              swap, cycle, copySource],
                        Detail(markdown: escapeMarkdown(result), metadata: [("From", Self.name(job.source ?? "")), ("To", target),
                                                                            ("Engine", onDevice ? "This Mac" : "AI")]),
                        subtitle: "")
        case .download:
            let settings = Action(title: "Open Translation Settings", icon: "gearshape") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
            }
            return item("Translation languages are not downloaded", "arrow.down.circle", [settings, useAI, cycle, copySource],
                        Detail(markdown: "Translating on this Mac needs the language data for **\(Self.name(job.source ?? ""))** and **\(target)**. "
                               + "Open Translation Settings, go to General → Language & Region → Translation Languages and download them, "
                               + "or translate this text with AI (⌘↵)."))
        case .unsupported:
            return item("This language pair is not supported on this Mac", "exclamationmark.circle", [useAI, cycle, copySource],
                        Detail(markdown: "Translation on this Mac does not support **\(Self.name(job.source ?? ""))** to **\(target)**. "
                               + "Pick another target language (⌘L), or translate this text with AI (↵). "
                               + "That sends the text to the AI service set up in Settings."))
        case .failed(let message):
            let retry = Action(title: "Try Again", icon: "arrow.clockwise", shortcut: Shortcut(.command, "r"), closes: false) { [self] in
                start(job.text, job.source, job.target, ai: job.ai)
                Launcher.shared.reload()
            }
            return item(message, "exclamationmark.triangle", [retry, cycle, copySource], Detail(markdown: escapeMarkdown(message)))
        }
    }
}
