import AppKit

/// "Search Emoji & Symbols". The catalogue is built from Unicode data on first use: emoji from scalar
/// properties, flags from the ISO region list, and a hand-picked set of symbols.
enum Emoji {
    static func commands() -> [Item] {
        [.command("emoji.search", "Search Emoji & Symbols", icon: "face.smiling",
                  keywords: ["emoji", "symbols", "unicode", "smiley", "emoticon", "arrows", "sonderzeichen", "pfeile"], closes: false) {
            Launcher.shared.push(.list(ListSpec(title: "Emoji & Symbols", placeholder: "Search emoji and symbols…") {
                Emoji.items(matching: $0)
            }))
        }]
    }

    // MARK: Rows

    /// Recents first, then emoji and symbols. While searching, the group with the better top hit comes first.
    static func items(matching query: String, recent: [String] = Emoji.recent) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let recents = recent.compactMap { byID["emoji." + $0] }
        guard !q.isEmpty else { return recents.map { $0.inSection("Recently Used") } + emoji + symbols }
        let e = search(q, in: emoji), s = search(q, in: symbols)
        let found = (s.first?.0 ?? 0) > (e.first?.0 ?? 0) ? s + e : e + s
        let rows = search(q, in: recents).map { $0.2.inSection("Recently Used") } + found.map { $0.2 }
        return rows.isEmpty ? [Item(id: "emoji.none", title: "No matching emoji or symbols", icon: .symbol("magnifyingglass"),
                                    track: false, actions: [])] : rows
    }

    /// (score, catalogue position, item), best first. Only substring matches or better count: the looser
    /// in-order matches of matchScore would flood a list this long.
    private static func search(_ q: String, in list: [Item]) -> [(Double, Int, Item)] {
        list.enumerated().compactMap { n, i -> (Double, Int, Item)? in
            let score = ([i.title] + i.keywords).map { matchScore(q, $0) }.max() ?? 0
            return score >= 40 ? (score, n, i) : nil
        }.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
    }

    private static func item(_ c: String, title: String, symbol: Bool, keywords: [String]) -> Item {
        Item(id: "emoji." + c, title: title, kind: symbol ? "Symbol" : "Emoji", icon: .image(icon(c, template: symbol)),
             keywords: keywords, section: symbol ? "Symbols" : "Emoji", track: false, actions: [
                Action(title: "Paste", icon: "doc.on.clipboard") {
                    use(c)
                    Clipboard.shared.paste(text: c)
                },
                Action(title: "Copy to Clipboard", icon: "doc.on.doc") {
                    use(c)
                    copyToClipboard(c)
                    HUD.show("Copied to Clipboard")
                },
                .copy("Copy Name", shortcut: Shortcut([.command, .shift], "n")) { title },
                .copy("Copy Unicode Code Point", shortcut: Shortcut([.command, .shift], "u")) { codePoint(c) },
             ])
    }

    /// The character drawn once into a 22×22 image. Symbols are template images, so they follow light and dark mode.
    private static func icon(_ c: String, template: Bool) -> NSImage {
        let text = NSAttributedString(string: c, attributes: [.font: NSFont.systemFont(ofSize: template ? 17 : 15)])
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = template
        return image
    }

    /// "U+1F600"; a flag is two code points. The variation selector U+FE0F is not part of the name.
    static func codePoint(_ c: String) -> String {
        c.unicodeScalars.filter { $0.value != 0xFE0F }.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    // MARK: Recently used

    static var recent: [String] = Store.load("emoji-recent.json") ?? []

    private static func use(_ c: String) {
        recent = promote(c, in: recent)
        Store.save(recent, "emoji-recent.json")
    }

    /// `c` moved to the front, the list capped at 24.
    static func promote(_ c: String, in list: [String]) -> [String] {
        Array(([c] + list.filter { $0 != c }).prefix(24))
    }

    // MARK: Catalogue

    private static let byID: [String: Item] = Dictionary((emoji + symbols).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Emoji with Emoji_Presentation as they are; text-default ones (❤ ☺) get U+FE0F so they render as emoji.
    /// Skin-tone, ZWJ and keycap sequences are not listed. Faces and gestures come first, flags last.
    static let emoji: [Item] = {
        let symbolChars = Set(symbolTable.map(\.0))
        var faces: [Item] = [], rest: [Item] = []
        for v in [0xA9...0x3299, 0x1F000...0x1FFFF].joined() {
            guard let s = Unicode.Scalar(v), s.properties.isEmoji, !s.properties.isEmojiModifier,
                  !(0x1F1E6...0x1F1FF).contains(v), !symbolChars.contains(String(s)), let name = s.properties.name else { continue }
            let c = String(s) + (s.properties.isEmojiPresentation ? "" : "\u{FE0F}")
            let i = item(c, title: titleCase(name), symbol: false, keywords: aliases[String(s)] ?? [])
            if (0x1F600...0x1F64F).contains(v) { faces.append(i) } else { rest.append(i) }
        }
        return faces + rest + flags
    }()

    /// Every two-letter ISO region with a flag glyph; the German name and the code make it findable.
    private static let flags: [Item] = {
        let en = Locale(identifier: "en"), de = Locale(identifier: "de")
        return Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) && !["EZ", "QO"].contains($0) }   // EZ, QO: no glyph
            .compactMap { code -> Item? in
                guard let name = en.localizedString(forRegionCode: code) else { return nil }
                let flag = String(String.UnicodeScalarView(code.unicodeScalars.map { Unicode.Scalar(0x1F1E6 + $0.value - 65)! }))
                return item(flag, title: "Flag: " + name, symbol: false,
                            keywords: ["Flagge: " + (de.localizedString(forRegionCode: code) ?? name), code])
            }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }()

    static let symbols: [Item] = symbolTable.map {
        item($0.0, title: $0.1, symbol: true, keywords: $0.2.split(separator: " ").map(String.init))
    }

    private static func titleCase(_ name: String) -> String {
        let small: Set<Substring> = ["of", "with", "and", "in", "on", "to", "for", "the", "a", "an", "at", "from", "over", "or"]
        return name.lowercased().split(separator: " ").enumerated()
            .map { n, w in n > 0 && small.contains(w) ? String(w) : w.prefix(1).uppercased() + w.dropFirst() }
            .joined(separator: " ")
    }

    /// Search words for popular emoji whose Unicode name is not what people type.
    private static let aliases: [String: [String]] = [
        "❤": ["heart", "red heart", "love", "herz"], "☺": ["smile", "smiling face"], "☹": ["frown", "sad face"],
        "✅": ["check mark", "done"], "❌": ["x", "no", "wrong"], "⭐": ["star"], "⚡": ["lightning", "zap"],
        "😂": ["lol", "laugh"], "😊": ["smile", "happy", "blush"], "🙏": ["pray", "thanks", "please"],
        "✌": ["peace"], "✋": ["stop", "high five"], "💩": ["poop"], "💯": ["100"], "👍": ["like", "yes"],
    ]

    /// (character, name, search words): arrows and keys, math, currency, typography, check marks.
    private static let symbolTable: [(String, String, String)] = [
        ("←", "Left Arrow", "pfeil links"), ("→", "Right Arrow", "pfeil rechts"), ("↑", "Up Arrow", "pfeil hoch"),
        ("↓", "Down Arrow", "pfeil runter"), ("⇧", "Shift Key", "umschalt"), ("⌘", "Command Key", "cmd apple"),
        ("⌥", "Option Key", "alt wahl"), ("⌃", "Control Key", "ctrl strg"), ("↵", "Return Key", "enter"),
        ("⌫", "Delete Key", "backspace"), ("⎋", "Escape Key", "esc"), ("⇥", "Tab Key", "tabulator"),
        ("±", "Plus-Minus Sign", "plusminus"), ("×", "Multiplication Sign", "times multiply mal"),
        ("÷", "Division Sign", "divide geteilt"), ("≈", "Almost Equal To", "approximately ungefaehr"),
        ("≠", "Not Equal To", "ungleich"), ("≤", "Less-Than or Equal To", "kleiner"),
        ("≥", "Greater-Than or Equal To", "groesser"), ("∞", "Infinity", "unendlich"), ("√", "Square Root", "wurzel radical"),
        ("∑", "Summation", "sum sigma"), ("π", "Pi", "greek"), ("∆", "Delta", "increment triangle"),
        ("°", "Degree Sign", "grad celsius"),
        ("€", "Euro Sign", "currency waehrung"), ("£", "Pound Sign", "sterling currency waehrung"),
        ("¥", "Yen Sign", "yuan currency waehrung"), ("₿", "Bitcoin Sign", "btc crypto currency waehrung"),
        ("¢", "Cent Sign", "currency waehrung"), ("$", "Dollar Sign", "usd currency waehrung"),
        ("–", "En Dash", "gedankenstrich hyphen"), ("—", "Em Dash", "gedankenstrich"), ("…", "Ellipsis", "dots punkte"),
        ("„", "Low Double Quote", "anfuehrungszeichen german"), ("“", "Left Double Quote", "anfuehrungszeichen"),
        ("”", "Right Double Quote", "anfuehrungszeichen"), ("‚", "Low Single Quote", "anfuehrungszeichen german"),
        ("‘", "Left Single Quote", "anfuehrungszeichen"), ("’", "Right Single Quote", "apostrophe anfuehrungszeichen"),
        ("«", "Left Guillemet", "angle quote"), ("»", "Right Guillemet", "angle quote"), ("•", "Bullet", "dot punkt"),
        ("·", "Middle Dot", "interpunct"), ("™", "Trade Mark Sign", "trademark tm"),
        ("©", "Copyright Sign", "copyright"), ("®", "Registered Sign", "registered trademark"),
        ("§", "Section Sign", "paragraph paragraf"), ("¶", "Pilcrow", "paragraph absatz"), ("†", "Dagger", "cross"),
        ("✓", "Check Mark", "tick haken"), ("✔", "Heavy Check Mark", "tick haken"), ("✗", "Ballot X", "cross kreuz"),
        ("★", "Black Star", "stern"), ("☆", "White Star", "stern"),
    ]
}
