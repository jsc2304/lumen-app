import Foundation

// Checks for Core.swift: calculator, fuzzy matching, usage ranking, AI stream parsing.
func checkCore() {
    expect(calculate("2+3*4") == 14, "precedence")
    expect(calculate("(2+3)*4") == 20, "parentheses")
    expect(calculate("2^3^2") == 512, "power is right-associative")
    expect(calculate("-2^2") == -4, "unary minus binds looser than ^")
    expect(calculate("2^-1") == 0.5, "negative exponent")
    expect(calculate("50%*80") == 40, "percent")
    expect(calculate("1,5 * 2") == 3, "decimal comma")
    expect(calculate("3 x 4") == 12, "x as multiply")
    expect(calculate("sqrt(16)+1") == 5, "sqrt")
    expect(calculate("42") == nil, "a plain number is not a calculation")
    expect(calculate("xcode") == nil, "words are not calculations")
    expect(calculate("1/0") == nil, "division by zero")
    expect(calculate("2+") == nil, "incomplete expression")
    expect(formatNumber(14) == "14" && formatNumber(0.5) == "0.5", "number formatting")
    expect(calculate("15% of 80") == 12 && calculate("15 % von 80") == 12, "percent of")
    expect(calculate("80 + 15%") == 92 && calculate("80 - 20%") == 64, "adding and subtracting a percentage")
    expect(calculate("0xff") == 255 && calculate("0b1010") == 10 && calculate("0xff + 1") == 256, "base literals")
    // Searches that look like math are left alone: dates, phone numbers, ids, and numbers with a sign, parentheses or %.
    for q in ["2024-10-22", "2024-10", "1-2-3", "030-1234", "030/1234", "0221/12345-67", "+49-30-1234", "+49 30 1234-56",
              "22.10.2024", "22.10.24", "22.10.", "100%", "50 %", "1,5%", "-1", "+5", "-1,5", "--1", "(1)", "((1))", "(-1)"] {
        expect(calculate(q) == nil, "'\(q)' is not a calculation")
    }
    expect(calculate("10-20") == -10 && calculate("100-20") == 80, "quick math without spaces")
    expect(calculate("10 - 20") == -10 && calculate("10 -20") == -10 && calculate("10-20+0") == -10 && calculate("100-20*2") == 60,
           "subtraction with spaces or more terms still calculates")
    expect(calculate("24/7") == 24.0 / 7 && calculate("1/2") == 0.5 && calculate("0/5") == 0 && calculate("0.5/2") == 0.25,
           "division, also with a leading zero")
    expect(calculate("(1+2)") == 3 && calculate("(1)+2") == 3 && calculate("-(2+3)") == -5 && calculate("5--3") == 8,
           "signs and parentheses around a real expression")
    checkCalculatorResults()

    expect(matchScore("saf", "Safari") > matchScore("saf", "Microsoft Safe"), "prefix beats word start")
    expect(matchScore("code", "Visual Studio Code") == 60, "word start")
    expect(matchScore("vsc", "Visual Studio Code") == 50, "initials")
    expect(matchScore("tw", "TextWrangler") == 50, "camel-case initials")
    expect(matchScore("sfr", "Safari") > 0, "loose subsequence")
    expect(matchScore("xyz", "Safari") == 0, "no match")

    let day = 86_400.0
    let twice = recordUse(recordUse(nil, now: 0), now: 0)
    expect(twice.score == 2, "uses add up")
    expect(abs(currentScore(twice, now: usageHalfLife) - 1) < 1e-9, "usage halves after one half-life")
    expect(currentScore(nil, now: day) == 0, "unused scores zero")
    expect(rank(match: 60, usage: 8, queryUsage: 0) > rank(match: 85, usage: 0, queryUsage: 0),
           "frequent use lifts a weaker match")
    expect(parseStreamLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
           == .text("Hello"), "Anthropic text delta")
    expect(parseStreamLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#)
           == nil, "Anthropic thinking is not shown")
    expect(parseStreamLine(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) == .refusal, "refusal")
    expect(parseStreamLine(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) == nil, "normal end")
    expect(parseStreamLine(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
           == .error("Overloaded"), "stream error")
    expect(parseStreamLine("event: content_block_delta") == nil, "event name lines")
    expect(parseStreamLine(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .text("Hi"), "OpenAI-style delta")
    expect(parseStreamLine("data: [DONE]") == nil, "OpenAI-style end")
}

// Units, currencies, time zones, dates, bases and colors at a fixed moment: Thursday 2026-10-22, 12:00 UTC, in Berlin.
private func checkCalculatorResults() {
    let noon = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
    let xml = """
        <Cube><Cube time='2026-10-22'>
        <Cube currency='USD' rate='1.1205'/><Cube currency='CHF' rate='0.9211'/><Cube currency='GBP' rate='0.83770'/>
        </Cube></Cube>
        """
    let rates = parseECBRates(xml, fetched: noon)
    expect(rates?.date == "2026-10-22" && rates?.perEuro["USD"] == 1.1205 && rates?.perEuro["EUR"] == 1, "ECB rates")
    expect(parseECBRates("<html>maintenance</html>", fetched: noon) == nil, "no rates in an error page")
    let ctx = CalcContext(now: noon, timeZone: TimeZone(identifier: "Europe/Berlin")!, rates: rates)
    func answers(_ q: String, _ c: CalcContext = ctx) -> [String] { calculatorResults(q, c).map(\.answer) }

    expect(answers("2+3*4") == ["14"] && answers("80 + 15%") == ["92"], "arithmetic")
    expect(answers("10 km in mi") == ["6.21 mi"], "length")
    expect(answers("100 f to c") == ["37.78 °C"] && answers("0 °C in °F") == ["32 °F"], "temperature")
    expect(answers("5 kg to lb") == ["11.02 lb"] && answers("12 lbs as kg") == ["5.44 kg"], "mass, plural unit")
    expect(answers("1,5 l in ml") == ["1500 mL"], "volume with decimal comma")
    expect(answers("3 h in min") == ["180 min"] && answers("2 wochen in tage") == ["14 d"], "duration, German")
    expect(answers("1 gb in mb") == ["1000 MB"] && answers("1 gib in mib") == ["1024 MiB"], "data size")
    expect(answers("100 km/h in mph") == ["62.14 mph"] && answers("1 ha = m2") == ["10000 m²"], "speed, area, =")
    expect(answers("10 in to cm") == ["25.4 cm"] && answers("2*5 km in m") == ["10000 m"], "inch unit, expression amount")
    expect(answers("1 mm in km") == ["1e-06 km"], "small results keep significant digits")
    expect(answers("5 kg in km").isEmpty && answers("5 kg").isEmpty, "no conversion across dimensions or without target")

    expect(answers("100 usd in eur") == ["89.25 EUR"] && answers("20 € to $") == ["22.41 USD"], "currencies")
    expect(answers("10 chf in gbp") == ["9.09 GBP"] && answers("$5 in eur") == ["4.46 EUR"], "cross rate, prefix symbol")
    expect(calculatorResults("100 usd in eur", ctx).first?.note == "ECB rate of 2026-10-22", "rate date")
    expect(answers("100 usd in eur", CalcContext(now: noon)).isEmpty, "no currency result before rates exist")
    expect(answers("20 chf").isEmpty, "a lone amount is not a result")

    expect(answers("time in tokyo") == ["21:00"] && answers("now in london") == ["13:00"], "current time elsewhere")
    expect(calculatorResults("time in tokyo", ctx).first?.note == "Thursday, 22 October · Tokyo (UTC+9)", "time note")
    expect(answers("15:00 berlin in new york") == ["09:00"] && answers("3pm in tokyo") == ["22:00"], "time conversion")
    expect(answers("23:00 in tokyo") == ["Fri 06:00"] && answers("9:30 pst in cet") == ["18:30"], "next day, abbreviations")
    expect(answers("17 uhr münchen in kolkata") == ["20:30"], "German city, half-hour zone")
    expect(answers("time in atlantis").isEmpty && answers("25:00 in tokyo").isEmpty, "unknown place, bad time")
    expect(calcCities.values.allSatisfy { TimeZone(identifier: $0) != nil }, "city table holds valid time zones")

    expect(answers("days until 24.12.") == ["63 days"] && answers("tage bis 24.12.2026") == ["63 days"], "days until")
    expect(answers("days until dec 24") == ["63 days"] && answers("days until 1.1.") == ["71 days"], "month name, next year")
    expect(answers("days since 1.1.") == ["294 days"] && answers("days until 2026-10-23") == ["1 day"], "days since, ISO")
    expect(answers("today + 30 days") == ["Saturday, 21 November 2026"], "date arithmetic")
    expect(answers("heute - 1 woche") == ["Thursday, 15 October 2026"] && answers("in 2 weeks") == ["Thursday, 5 November 2026"],
           "German date arithmetic, in …")
    expect(answers("days until 31.02.").isEmpty, "impossible date")

    expect(answers("0xff") == ["255"] && answers("0xff in dec") == ["255"], "hex literal")
    expect(answers("255 in hex") == ["0xFF"] && answers("255 in binary") == ["0b11111111"] && answers("8 as octal") == ["0o10"],
           "number bases")
    expect(answers("1.5 in hex").isEmpty, "bases need integers")

    let orange = calculatorResults("#ff8800", ctx)
    expect(orange.map(\.answer) == ["rgb(255, 136, 0)", "hsl(32, 100%, 50%)"] && orange[0].rgb?[1] == 136.0 / 255, "hex color")
    expect(answers("rgb(255,136,0)") == ["#FF8800", "hsl(32, 100%, 50%)"] && answers("#f80") == answers("#ff8800"), "rgb color")
    expect(answers("#ggg").isEmpty && answers("rgb(300,0,0)").isEmpty, "invalid colors")
    expect(answers("#123").isEmpty && answers("#456").isEmpty, "#123 is an issue number, not a color")
    expect(!answers("#abc").isEmpty && answers("#abc") == answers("#aabbcc") && !answers("#12a").isEmpty && !answers("#123456").isEmpty,
           "other short and long hex colors stay colors")
    expect(answers("10 - 20") == ["-10"] && answers("24/7") == ["3.428571429"], "real math next to the exclusions")

    for q in ["time", "mail", "in", "safari", "1password", "2fa", "42", "time to leave", "move to trash", "sign in to github",
              "xcode", "days", "today", "c++", "#1", "2024-10-22", "030-1234", "100%", "-1", "(1)", "#123"] {
        expect(calculatorResults(q, ctx).isEmpty, "'\(q)' stays an ordinary search")
    }
}
