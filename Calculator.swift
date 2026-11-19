import AppKit

/// Calculator results in the root search (math, units, currencies, time zones, dates, number bases, colors)
/// and the Calculator History of copied and pasted answers.
enum Calculator {
    struct Entry: Codable {
        var expression: String
        var answer: String
        var date = Date()
    }

    private static var history: [Entry] = Store.load("calculator-history.json") ?? []
    private static var rates: CurrencyRates? = Store.load("currency-rates.json")
    private static var lastAttempt = Date.distantPast

    static func commands() -> [Item] {
        [.command("calc.history", "Calculator History", kind: "Calculator", icon: "clock.arrow.circlepath",
                  keywords: ["calculator", "rechner", "verlauf"], closes: false) {
            Launcher.shared.push(.list(ListSpec(title: "Calculator History", placeholder: "Search calculations…", items: historyItems)))
        }]
    }

    static func items(_ q: String) -> [Item] {
        refreshRates()
        return calculatorResults(q, CalcContext(rates: rates)).enumerated().map { i, r in
            Item(id: i == 0 ? "calc" : "calc.\(i)", title: r.answer, subtitle: r.note.isEmpty ? q : q + " · " + r.note,
                 kind: "Calculator", icon: r.rgb.map { .color(NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1)) }
                    ?? .symbol("equal.square"),
                 track: false, actions: answerActions(q, r.answer))
        }
    }

    private static func answerActions(_ expression: String, _ answer: String) -> [Action] {
        [
            .copy("Copy Answer") { remember(expression, answer); return answer },
            Action(title: "Paste Answer", icon: "doc.on.clipboard") {
                remember(expression, answer)
                Clipboard.shared.paste(text: answer)
            },
            .copy("Copy Expression", shortcut: Shortcut([.command, .shift], "e")) { expression + " = " + answer },
        ]
    }

    private static func remember(_ expression: String, _ answer: String) {
        history.removeAll { $0.expression == expression && $0.answer == answer }
        history = Array(([Entry(expression: expression, answer: answer)] + history).prefix(100))
        Store.save(history, "calculator-history.json")
    }

    private static func historyItems(_ q: String) -> [Item] {
        let date = RelativeDateTimeFormatter()
        return history.filter { q.isEmpty || $0.expression.localizedCaseInsensitiveContains(q) || $0.answer.localizedCaseInsensitiveContains(q) }
            .map { e in
                Item(id: "calc.history." + e.expression + "=" + e.answer, title: e.answer, subtitle: e.expression,
                     kind: date.localizedString(for: e.date, relativeTo: Date()), icon: .symbol("equal.square"), track: false,
                     actions: answerActions(e.expression, e.answer) + [
                        Action(title: "Delete Entry", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) {
                            history.removeAll { $0.expression == e.expression && $0.answer == e.answer }
                            Store.save(history, "calculator-history.json")
                            Launcher.shared.reload()
                        },
                        Action(title: "Clear History", icon: "trash.slash", shortcut: Shortcut([.control, .shift], "x"), destructive: true) {
                            guard confirm("Clear the whole calculator history? This cannot be undone.") else { return }
                            history = []
                            Store.save(history, "calculator-history.json")
                        },
                     ])
            }
    }

    /// Fetches the ECB reference rates once a day (failed attempts retry after an hour); currency
    /// results appear once they arrive.
    private static func refreshRates() {
        let now = Date()
        guard !Calendar.current.isDate(rates?.fetched ?? .distantPast, inSameDayAs: now),
              now.timeIntervalSince(lastAttempt) > 3600 else { return }
        lastAttempt = now
        URLSession.shared.dataTask(with: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!) { data, _, _ in
            guard let data, let fresh = parseECBRates(String(decoding: data, as: UTF8.self), fetched: Date()) else { return }
            DispatchQueue.main.async {
                rates = fresh
                Store.save(fresh, "currency-rates.json")
                Launcher.shared.reload()
            }
        }.resume()
    }
}
