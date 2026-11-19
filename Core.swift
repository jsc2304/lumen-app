import Foundation

// Pure logic shared by the app and check.swift: fuzzy matching, usage ranking, calculator.

/// How well `query` matches `text`; 0 means no match. Prefix beats word start beats initials
/// ("vsc" → Visual Studio Code) beats substring beats a loose in-order subsequence.
func matchScore(_ query: String, _ text: String) -> Double {
    let q = query.lowercased(), t = text.lowercased()
    guard !q.isEmpty else { return 1 }
    if t == q { return 100 }
    if t.hasPrefix(q) { return 80 + 10 * Double(q.count) / Double(t.count) }
    let chars = Array(text)
    var initials = "", wordStartMatch = false
    for (i, c) in chars.enumerated() where c.isLetter || c.isNumber {
        let prev: Character? = i > 0 ? chars[i - 1] : nil
        let isStart = prev.map { !($0.isLetter || $0.isNumber) || (c.isUppercase && $0.isLowercase) } ?? true
        guard isStart else { continue }
        initials += c.lowercased()
        if String(chars[i...]).lowercased().hasPrefix(q) { wordStartMatch = true }
    }
    if wordStartMatch { return 60 }
    if initials.hasPrefix(q) { return 50 }
    if t.contains(q) { return 40 }
    var score = 0.0, run = 0.0, ti = t.startIndex
    for qc in q {
        guard let found = t[ti...].firstIndex(of: qc) else { return 0 }
        run = found == ti ? run + 1 : 0
        score += 1 + run
        ti = t.index(after: found)
    }
    return min(30, 10 + score)
}

/// Usage that fades with a half-life, so recent and frequent choices rank first ("frecency").
struct Usage: Codable, Equatable {
    var score: Double
    var last: Double
}

let usageHalfLife = 14.0 * 86_400

func currentScore(_ u: Usage?, now: Double) -> Double {
    guard let u else { return 0 }
    return u.score * pow(0.5, (now - u.last) / usageHalfLife)
}

func recordUse(_ u: Usage?, now: Double) -> Usage {
    Usage(score: currentScore(u, now: now) + 1, last: now)
}

/// Text match first; general usage and usage for this exact query can lift a weaker match.
func rank(match: Double, usage: Double, queryUsage: Double) -> Double {
    match + 12 * log2(1 + usage) + 40 * min(1, queryUsage)
}

enum StreamEvent: Equatable {
    case text(String), refusal, error(String)
}

/// Reads one server-sent-events line from the Anthropic Messages API or an OpenAI-style
/// /chat/completions stream; nil for lines that carry no text (event names, thinking, [DONE]).
func parseStreamLine(_ line: String) -> StreamEvent? {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard payload != "[DONE]",
          let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
    if let error = json["error"] as? [String: Any] { return .error(error["message"] as? String ?? "stream error") }
    if let delta = json["delta"] as? [String: Any] {   // Anthropic: content_block_delta, message_delta
        if delta["stop_reason"] as? String == "refusal" { return .refusal }
        return (delta["text"] as? String).map(StreamEvent.text)
    }
    let choices = json["choices"] as? [[String: Any]]
    return ((choices?.first?["delta"] as? [String: Any])?["content"] as? String).map(StreamEvent.text)
}

/// Evaluates arithmetic such as "2*(3+4)^2", "1,5*2", "50%*80", "15% of 80", "80 + 15%", "sqrt(2)", "0xff".
/// Returns nil for plain numbers and anything that is not a complete expression.
func calculate(_ input: String) -> Double? {
    let typed = input.lowercased().trimmingCharacters(in: .whitespaces)
    let text = typed.filter { !$0.isWhitespace }
    guard text.contains(where: { "+-*/^%x×÷(".contains($0) }) || text.hasPrefix("0b") || text.hasPrefix("0o") else { return nil }
    // Searches that merely look like math: a number with only a sign, parentheses or a trailing %, and phone numbers,
    // dates and ids: three or more dash-joined groups ("2024-10-22"), year-month ("2024-10"), a leading 0 or +
    // ("030-1234", "+49 30 1234-56") or spaced digit groups with a dash. Quick math like "100-20" stays math;
    // tested on what was typed, because spaces matter for phone numbers.
    guard groups(#"[+\-(]*[\d.,]+[%)]*"#, text) == nil,
          groups(#"\+?\d+(?:-\d+){2,}|\d{4}-\d{1,2}|\+?0\d+(?:[-/ ]\d+)+|\+\d+(?:[- ]\d+)+|\d+(?: \d+)+-\d+"#, typed) == nil
    else { return nil }
    return amount(text)
}

/// A number or arithmetic expression; unlike calculate(), a plain number counts.
private func amount(_ input: String) -> Double? {
    let text = input.lowercased()
        .replacingOccurrences(of: "×", with: "*")
        .replacingOccurrences(of: "÷", with: "/")
        .filter { !$0.isWhitespace }
        .replacingOccurrences(of: "%of", with: "%*")
        .replacingOccurrences(of: "%von", with: "%*")
    var p = Calc(s: Array(text))
    guard let v = p.expr(), p.i == p.s.count, v.isFinite else { return nil }
    return v
}

func formatNumber(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
    return String(format: "%.10g", v)
}

private struct Calc {
    var s: [Character]
    var i = 0

    var peek: Character? { i < s.count ? s[i] : nil }

    mutating func eat(_ c: Character) -> Bool {
        guard peek == c else { return false }
        i += 1
        return true
    }

    // A right operand ending in % is a share of the left one: 80 + 15% is 92.
    mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while true {
            if eat("+") { guard let r = term() else { return nil }; v += s[i - 1] == "%" ? v * r : r }
            else if eat("-") { guard let r = term() else { return nil }; v -= s[i - 1] == "%" ? v * r : r }
            else { return v }
        }
    }

    mutating func term() -> Double? {
        guard var v = unary() else { return nil }
        while true {
            if eat("*") || eat("x") { guard let r = unary() else { return nil }; v *= r }
            else if eat("/") { guard let r = unary() else { return nil }; v /= r }
            else { return v }
        }
    }

    // Unary minus binds looser than ^, so -2^2 is -4.
    mutating func unary() -> Double? {
        if eat("-") { return unary().map { -$0 } }
        if eat("+") { return unary() }
        return power()
    }

    mutating func power() -> Double? {
        guard var base = atom() else { return nil }
        while eat("%") { base /= 100 }
        guard eat("^") else { return base }
        return unary().map { pow(base, $0) }
    }

    mutating func atom() -> Double? {
        if eat("(") {
            let v = expr()
            return eat(")") ? v : nil
        }
        if s[i...].starts(with: "sqrt") {
            i += 4
            guard eat("("), let v = expr(), eat(")") else { return nil }
            return v.squareRoot()
        }
        if s[i...].starts(with: "pi") { i += 2; return .pi }
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where s[i...].starts(with: prefix) {
            i += 2
            let start = i
            while let c = peek, c.isHexDigit { i += 1 }
            return Int(String(s[start..<i]), radix: radix).map(Double.init)
        }
        let start = i
        while let c = peek, c.isASCII, c.isNumber || c == "." || c == "," { i += 1 }
        return Double(String(s[start..<i]).replacingOccurrences(of: ",", with: "."))
    }
}

// MARK: Calculator results: units, currencies, time zones, dates, number bases, colors

/// Euro reference rates from the ECB: currency code → units per euro.
struct CurrencyRates: Codable, Equatable {
    var date: String   // publication date, yyyy-MM-dd
    var perEuro: [String: Double]
    var fetched: Date
}

/// Reads https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml.
func parseECBRates(_ xml: String, fetched: Date) -> CurrencyRates? {
    var perEuro = ["EUR": 1.0]
    for m in xml.matches(of: try! Regex(#"currency=['"]([A-Z]{3})['"]\s+rate=['"]([\d.]+)['"]"#)) {
        perEuro[String(m.output[1].substring!)] = Double(String(m.output[2].substring!))
    }
    guard let time = xml.firstMatch(of: try! Regex(#"time=['"]([\d-]+)['"]"#))?.output[1].substring, perEuro.count > 1
    else { return nil }
    return CurrencyRates(date: String(time), perEuro: perEuro, fetched: fetched)
}

struct CalcContext {
    var now = Date()
    var timeZone = TimeZone.current
    var rates: CurrencyRates? = nil   // currencies give no result until rates exist
}

struct CalcResult: Equatable {
    var answer: String
    var note = ""                // shown after the expression: rate date, weekday, …
    var rgb: [Double]? = nil     // sRGB 0…1 for color results
}

/// Everything the root search computes from a query. Only a fully parsed input gives a result,
/// so ordinary searches ("time", "1password", "2fa") stay untouched. Colors give one result per format.
func calculatorResults(_ input: String, _ ctx: CalcContext) -> [CalcResult] {
    let s = input.trimmingCharacters(in: .whitespaces).lowercased()
    if let colors = colorResults(s) { return colors }
    if let r = dateResult(s, ctx) { return [r] }
    if let g = groups(#"(.+)(?:\s+(?:in|to|as|into)\s+|\s*=\s*)(.+)"#, s) {
        let from = g[1].trimmingCharacters(in: .whitespaces), to = g[2]
        if let r = baseResult(from, to) ?? timeResult(from, to, ctx) ?? currencyResult(from, to, ctx.rates) ?? unitResult(from, to) {
            return [r]
        }
    }
    return calculate(s).map { [CalcResult(answer: formatNumber($0))] } ?? []
}

/// Capture groups ("" for a group that did not take part) when `pattern` matches all of `s`.
private func groups(_ pattern: String, _ s: String) -> [String]? {
    guard let m = try? Regex(pattern).wholeMatch(in: s) else { return nil }
    return m.output.map { $0.substring.map(String.init) ?? "" }
}

/// Conversion results: two decimals, three significant digits below 1.
private func formatAmount(_ v: Double) -> String {
    formatNumber(abs(v) >= 1 ? (v * 100).rounded() / 100 : Double(String(format: "%.3g", v)) ?? v)
}

/// "10 km" → (10, "km"), "$50" → (50, "$"); the number may be an expression.
private func quantity(_ s: String) -> (value: Double, unit: String)? {
    if let g = groups(#"([$€£¥])\s*(.+)"#, s), let v = amount(g[2]) { return (v, g[1]) }
    guard let g = groups(#"(.+?)\s*([\p{L}°$€£¥][\p{L}°²³/\d]*)"#, s), let v = amount(g[1]) else { return nil }
    return (v, g[2])
}

private let bases: [String: (radix: Int, prefix: String)] = [
    "hex": (16, "0x"), "hexadecimal": (16, "0x"), "binary": (2, "0b"), "bin": (2, "0b"),
    "octal": (8, "0o"), "oct": (8, "0o"), "decimal": (10, ""), "dec": (10, ""),
]

private func baseResult(_ from: String, _ to: String) -> CalcResult? {
    guard let base = bases[to], let v = amount(from), v == v.rounded(), abs(v) < 1e15 else { return nil }
    let n = Int(v)
    return CalcResult(answer: (n < 0 ? "-" : "") + base.prefix + String(abs(n), radix: base.radix).uppercased())
}

// MARK: Units

private let unitNames: [(Dimension, String)] = [
    (UnitLength.millimeters, "mm millimeter millimetre"), (UnitLength.centimeters, "cm centimeter centimetre"),
    (UnitLength.meters, "m meter metre"), (UnitLength.kilometers, "km kilometer kilometre"),
    (UnitLength.inches, "in inch inches zoll"), (UnitLength.feet, "ft foot feet fuß"), (UnitLength.yards, "yd yard"),
    (UnitLength.miles, "mi mile meile meilen"), (UnitLength.nauticalMiles, "nmi seemeile seemeilen"),
    (UnitMass.milligrams, "mg milligram milligramm"), (UnitMass.grams, "g gram gramm"),
    (UnitMass.kilograms, "kg kilo kilogram kilogramm"), (UnitMass.metricTons, "t tonne tonnen"),
    (UnitMass.ounces, "oz ounce unze unzen"), (UnitMass.pounds, "lb pound pfund"), (UnitMass.stones, "st stone"),
    (UnitTemperature.celsius, "c °c celsius"), (UnitTemperature.fahrenheit, "f °f fahrenheit"),
    (UnitTemperature.kelvin, "k kelvin"),
    (UnitVolume.milliliters, "ml milliliter millilitre"), (UnitVolume.centiliters, "cl"), (UnitVolume.deciliters, "dl"),
    (UnitVolume.liters, "l liter litre"), (UnitVolume.cubicMeters, "m3 m³"), (UnitVolume.gallons, "gal gallon gallone gallonen"),
    (UnitVolume.quarts, "qt quart"), (UnitVolume.pints, "pt pint"), (UnitVolume.cups, "cup tasse tassen"),
    (UnitVolume.fluidOunces, "floz"), (UnitVolume.tablespoons, "tbsp el"), (UnitVolume.teaspoons, "tsp tl"),
    (UnitArea.squareCentimeters, "cm2 cm²"), (UnitArea.squareMeters, "m2 m² sqm"), (UnitArea.squareKilometers, "km2 km²"),
    (UnitArea.hectares, "ha hectare hektar"), (UnitArea.acres, "ac acre"), (UnitArea.squareFeet, "ft2 ft² sqft"),
    (UnitArea.squareMiles, "mi2 mi² sqmi"),
    (UnitSpeed.metersPerSecond, "m/s"), (UnitSpeed.kilometersPerHour, "km/h kmh kph"), (UnitSpeed.milesPerHour, "mph"),
    (UnitSpeed.knots, "kn knot knoten"),
    (UnitDuration.milliseconds, "ms millisecond"), (UnitDuration.seconds, "s sec second sekunde sekunden"),
    (UnitDuration.minutes, "min minute minuten"), (UnitDuration.hours, "h hr hour std stunde stunden"),
    (UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "d day tag tage"),
    (UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "wk week woche wochen"),
    (UnitInformationStorage.bits, "bit"), (UnitInformationStorage.bytes, "b byte"),
    (UnitInformationStorage.kilobytes, "kb"), (UnitInformationStorage.megabytes, "mb"),
    (UnitInformationStorage.gigabytes, "gb"), (UnitInformationStorage.terabytes, "tb"),
    (UnitInformationStorage.kibibytes, "kib"), (UnitInformationStorage.mebibytes, "mib"),
    (UnitInformationStorage.gibibytes, "gib"), (UnitInformationStorage.tebibytes, "tib"),
    (UnitInformationStorage.megabits, "mbit"), (UnitInformationStorage.gigabits, "gbit"),
]

private let unitsByName = Dictionary(unitNames.flatMap { unit, names in names.split(separator: " ").map { (String($0), unit) } },
                                     uniquingKeysWith: { first, _ in first })

/// Looks up a unit name, also as a plural ("hours", "lbs").
private func unit(_ name: String) -> Dimension? {
    unitsByName[name] ?? (name.hasSuffix("s") ? unitsByName[String(name.dropLast())] : nil)
}

private func unitResult(_ from: String, _ to: String) -> CalcResult? {
    guard let q = quantity(from), let a = unit(q.unit), let b = unit(to), type(of: a) == type(of: b) else { return nil }
    let v = b.converter.value(fromBaseUnitValue: a.converter.baseUnitValue(fromValue: q.value))
    return CalcResult(answer: formatAmount(v) + " " + b.symbol)
}

// MARK: Currencies

private let currencyNames = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY",
                             "dollar": "USD", "dollars": "USD", "euro": "EUR", "euros": "EUR"]

private func currencyResult(_ from: String, _ to: String, _ rates: CurrencyRates?) -> CalcResult? {
    func rate(_ name: String) -> (code: String, perEuro: Double)? {
        let code = currencyNames[name] ?? name.uppercased()
        return rates?.perEuro[code].map { (code, $0) }
    }
    guard let rates, let q = quantity(from), let a = rate(q.unit), let b = rate(to) else { return nil }
    return CalcResult(answer: String(format: "%.2f", q.value / a.perEuro * b.perEuro) + " " + b.code,
                      note: "ECB rate of " + rates.date)
}

// MARK: Time zones

/// Cities and German names that are not the last part of a time zone identifier (Tokyo, New_York, … are found there).
let calcCities = [
    "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles", "san diego": "America/Los_Angeles",
    "las vegas": "America/Los_Angeles", "washington": "America/New_York", "boston": "America/New_York",
    "miami": "America/New_York", "atlanta": "America/New_York", "philadelphia": "America/New_York",
    "dallas": "America/Chicago", "houston": "America/Chicago", "austin": "America/Chicago",
    "montreal": "America/Toronto", "rio": "America/Sao_Paulo", "rio de janeiro": "America/Sao_Paulo",
    "são paulo": "America/Sao_Paulo", "munich": "Europe/Berlin", "münchen": "Europe/Berlin", "hamburg": "Europe/Berlin",
    "frankfurt": "Europe/Berlin", "cologne": "Europe/Berlin", "köln": "Europe/Berlin", "düsseldorf": "Europe/Berlin",
    "stuttgart": "Europe/Berlin", "geneva": "Europe/Zurich", "genf": "Europe/Zurich", "basel": "Europe/Zurich",
    "zürich": "Europe/Zurich", "wien": "Europe/Vienna", "rom": "Europe/Rome", "milan": "Europe/Rome",
    "mailand": "Europe/Rome", "barcelona": "Europe/Madrid", "lissabon": "Europe/Lisbon", "brüssel": "Europe/Brussels",
    "prag": "Europe/Prague", "warschau": "Europe/Warsaw", "athen": "Europe/Athens", "moskau": "Europe/Moscow",
    "kopenhagen": "Europe/Copenhagen", "edinburgh": "Europe/London", "manchester": "Europe/London",
    "beijing": "Asia/Shanghai", "peking": "Asia/Shanghai", "shenzhen": "Asia/Shanghai", "tokio": "Asia/Tokyo",
    "osaka": "Asia/Tokyo", "kolkata": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
    "bangalore": "Asia/Kolkata", "abu dhabi": "Asia/Dubai", "tel aviv": "Asia/Jerusalem", "kairo": "Africa/Cairo",
    "cape town": "Africa/Johannesburg", "kapstadt": "Africa/Johannesburg", "canberra": "Australia/Sydney",
    "wellington": "Pacific/Auckland",
]

/// A city, abbreviation (PST, CET, UTC) or the last part of a time zone identifier ("new york").
private func zone(_ name: String) -> TimeZone? {
    if let id = calcCities[name] ?? TimeZone.abbreviationDictionary[name.uppercased()] { return TimeZone(identifier: id) }
    let id = TimeZone.knownTimeZoneIdentifiers.first {
        $0.split(separator: "/").last?.replacingOccurrences(of: "_", with: " ").lowercased() == name
    }
    return id.flatMap(TimeZone.init(identifier:))
}

private func formatted(_ date: Date, _ zone: TimeZone, _ format: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = format
    return f.string(from: date)
}

private func gregorian(_ zone: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal
}

/// "time in tokyo", "now in london", "15:00 berlin in new york", "3pm in pst".
private func timeResult(_ from: String, _ to: String, _ ctx: CalcContext) -> CalcResult? {
    guard let target = zone(to) else { return nil }
    var source = ctx.timeZone, date = ctx.now
    if !["time", "now", "zeit", "uhrzeit", "jetzt"].contains(from) {
        guard let g = groups(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm|uhr)?\s*(.*)"#, from), !(g[2] + g[3]).isEmpty,
              var hour = Int(g[1]), let minute = Int(g[2].isEmpty ? "0" : g[2]), minute < 60 else { return nil }
        if g[3] == "am" || g[3] == "pm" {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (g[3] == "pm" ? 12 : 0)
        }
        guard hour < 24 else { return nil }
        if !g[4].isEmpty {
            guard let z = zone(g[4]) else { return nil }
            source = z
        }
        guard let d = gregorian(source).date(bySettingHour: hour, minute: minute, second: 0, of: ctx.now) else { return nil }
        date = d
    }
    let otherDay = gregorian(source).component(.day, from: date) != gregorian(target).component(.day, from: date)
    let offset = target.secondsFromGMT(for: date), minutes = abs(offset) / 60 % 60
    let utc = "UTC" + (offset < 0 ? "-" : "+") + String(abs(offset) / 3600) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    let place = target.identifier.split(separator: "/").last!.replacingOccurrences(of: "_", with: " ")
    return CalcResult(answer: formatted(date, target, otherDay ? "EEE HH:mm" : "HH:mm"),
                      note: formatted(date, target, "EEEE, d MMMM") + " · " + place + " (" + utc + ")")
}

// MARK: Dates

private let dateUnits: [(Calendar.Component, String)] = [
    (.day, "d day days tag tage tagen"), (.weekOfYear, "w wk week weeks woche wochen"),
    (.month, "month months monat monate monaten"), (.year, "y year years jahr jahre jahren"),
]

/// "days until 24.12.", "tage seit 1.1.", "today + 30 days", "24.12. - 2 weeks", "in 3 weeks".
private func dateResult(_ s: String, _ ctx: CalcContext) -> CalcResult? {
    let cal = gregorian(ctx.timeZone), today = cal.startOfDay(for: ctx.now)
    if let g = groups(#"(?:days?|tage?)\s+(until|till|to|bis|since|seit)\s+(.+)"#, s), let d = day(g[2], cal, today) {
        let since = g[1] == "since" || g[1] == "seit"
        var date = d.date
        // A date without a year means the next one ("until") or the last one ("since").
        if !d.hasYear, since ? date > today : date < today { date = cal.date(byAdding: .year, value: since ? -1 : 1, to: date)! }
        let n = cal.dateComponents([.day], from: since ? date : today, to: since ? today : date).day!
        return CalcResult(answer: "\(n) " + (abs(n) == 1 ? "day" : "days"), note: formatted(date, ctx.timeZone, "EEEE, d MMMM yyyy"))
    }
    var base = today, sign = "+", count = "", unitName = ""
    if let g = groups(#"in\s+(\d+)\s*(\p{L}+)"#, s) {
        (count, unitName) = (g[1], g[2])
    } else if let g = groups(#"(.+?)\s*([+-])\s*(\d+)\s*(\p{L}+)"#, s), let d = day(g[1], cal, today) {
        (base, sign, count, unitName) = (d.date, g[2], g[3], g[4])
    } else {
        return nil
    }
    guard let n = Int(count), let component = dateUnits.first(where: { $0.1.split(separator: " ").contains(Substring(unitName)) })?.0,
          let date = cal.date(byAdding: component, value: sign == "-" ? -n : n, to: base) else { return nil }
    return CalcResult(answer: formatted(date, ctx.timeZone, "EEEE, d MMMM yyyy"))
}

/// "today", "24.12.", "24.12.2026", "2026-12-24", "24 dec", "december 24, 2026" at midnight.
private func day(_ s: String, _ cal: Calendar, _ today: Date) -> (date: Date, hasYear: Bool)? {
    let named = ["today": 0, "heute": 0, "now": 0, "tomorrow": 1, "morgen": 1, "yesterday": -1, "gestern": -1]
    if let offset = named[s] { return (cal.date(byAdding: .day, value: offset, to: today)!, true) }
    var d: Int?, m: Int?, y: Int?
    if let g = groups(#"(\d{1,2})\.(\d{1,2})(?:\.(\d{4}|\d{2})?)?"#, s) {
        (d, m, y) = (Int(g[1]), Int(g[2]), Int(g[3]))
    } else if let g = groups(#"(\d{4})-(\d{1,2})-(\d{1,2})"#, s) {
        (y, m, d) = (Int(g[1]), Int(g[2]), Int(g[3]))
    } else if let g = groups(#"(\d{1,2})\.?\s*(\p{L}+)\.?(?:\s+(\d{4}))?"#, s) {
        (d, m, y) = (Int(g[1]), month(g[2]), Int(g[3]))
    } else if let g = groups(#"(\p{L}+)\.?\s*(\d{1,2})(?:,?\s+(\d{4}))?"#, s) {
        (m, d, y) = (month(g[1]), Int(g[2]), Int(g[3]))
    }
    guard let d, let m else { return nil }
    if let short = y, short < 100 { y = 2000 + short }
    guard let date = cal.date(from: DateComponents(year: y ?? cal.component(.year, from: today), month: m, day: d)),
          cal.component(.day, from: date) == d, cal.component(.month, from: date) == m else { return nil }   // no 31.02.
    return (date, y != nil)
}

/// English or German month name, at least three letters: "dec", "dez", "märz", "october".
private func month(_ name: String) -> Int? {
    guard name.count >= 3 else { return nil }
    for id in ["en_US", "de_DE"] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: id)
        if let i = cal.monthSymbols.firstIndex(where: { $0.lowercased().hasPrefix(name) }) { return i + 1 }
    }
    return nil
}

// MARK: Colors

/// "#ff8800", "#f80" or "rgb(255, 136, 0)" in the other notations (hex, rgb, hsl).
private func colorResults(_ s: String) -> [CalcResult]? {
    let c: [Int], input: String
    // "#123" is an issue number, not a color; "#123456" and "#12a" stay colors.
    if let g = groups(#"#([0-9a-f]{3}|[0-9a-f]{6})"#, s), !(g[1].count == 3 && g[1].allSatisfy(\.isNumber)) {
        let hex = g[1].count == 3 ? g[1].map { "\($0)\($0)" }.joined() : g[1]
        let n = Int(hex, radix: 16)!
        (c, input) = ([n >> 16, n >> 8 & 0xff, n & 0xff], "hex")
    } else if let g = groups(#"rgb\(\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*\)"#, s) {
        (c, input) = (g[1...3].map { Int($0)! }, "rgb")
    } else {
        return nil
    }
    guard c.allSatisfy({ $0 <= 255 }) else { return nil }
    let rgb = c.map { Double($0) / 255 }
    let (r, g, b) = (rgb[0], rgb[1], rgb[2])
    let hi = rgb.max()!, lo = rgb.min()!, l = (hi + lo) / 2, d = hi - lo
    var h = 0.0, sat = 0.0
    if d > 0 {
        sat = d / (1 - abs(2 * l - 1))
        switch hi {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
    }
    let all = [("hex", String(format: "#%02X%02X%02X", c[0], c[1], c[2])),
               ("rgb", "rgb(\(c[0]), \(c[1]), \(c[2]))"),
               ("hsl", "hsl(\(Int(h.rounded())), \(Int((sat * 100).rounded()))%, \(Int((l * 100).rounded()))%)")]
    return all.filter { $0.0 != input }.map { CalcResult(answer: $0.1, rgb: rgb) }
}
