import Foundation

func checkMite() {
    let catalog = Mite.parseCatalog("    101  Demo App Support  (Example GmbH)\n         17  Internal\n  Nothing found.\n")
    expect(catalog == [Mite.CatalogEntry(id: 101, name: "Demo App Support", customer: "Example GmbH"),
                       Mite.CatalogEntry(id: 17, name: "Internal", customer: "")], "catalog lines")

    let toml = #"""
    calendars = ["work"]
    # [[rule]]
    # match = "(?i)daily"

    [[rule]]
    name = "Meetings"
    match = "(?i)demo app"
    project_id = 101
    service_id = 201
    note = "{title} ({date})"

    [[ignore]]
    match = "^Focus\\ time$"

    [[rule]]
    match = 'Weekly'
    project_id = 1
    service_id = 2
    minutes = 15
    """#
    let rules = Mite.parseRules(toml)
    expect(rules.count == 2, "only [[rule]] blocks, commented ones skipped")
    expect(rules.first == Mite.Rule(match: "(?i)demo app", projectID: 101, serviceID: 201, note: "{title} ({date})"), "rule fields")
    expect(rules.last?.minutes == 15 && rules.last?.match == "Weekly", "literal string and minutes")
    expect(Mite.matches(rules[0], "Demo App: Regular Friday Review"), "case-insensitive rule match")
    expect(!Mite.matches(rules[1], "Daily"), "non-matching rule")

    let date = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-15
    expect(Mite.fill("{title} ({date})", title: "Sync", date: date) == "Sync (" + Mite.isoDate(date) + ")", "note placeholders")

    // A remembered target without names (older mite.json) still decodes; the IDs stay required.
    let decode = { (json: String) in try? JSONDecoder().decode(Mite.Target.self, from: Data(json.utf8)) }
    expect(decode(#"{"projectID":5,"serviceID":6}"#) == Mite.Target(projectID: 5, projectName: "Project 5", serviceID: 6, serviceName: "Service 6"),
           "target without names")
    expect(decode(#"{"projectID":5,"projectName":"P","serviceID":6,"serviceName":"S"}"#) == Mite.Target(projectID: 5, projectName: "P", serviceID: 6, serviceName: "S"),
           "target with names")
    expect(decode(#"{"projectID":5,"projectName":"P"}"#) == nil, "target without a service ID")
    let target = Mite.Target(projectID: 1, projectName: "A", serviceID: 2, serviceName: "B")
    expect((try? JSONEncoder().encode(target)).flatMap { try? JSONDecoder().decode(Mite.Target.self, from: $0) } == target, "target round trip")

    for positive in ["90", "90m", "1:30", "1h30m", "1h 30m", "1.5h", " 1H 30M "] {
        expect(Mite.bookingMinutes(positive) == 90, "booking duration accepts \(positive)")
    }
    expect(Mite.bookingMinutes("24h") == 1440, "booking duration accepts one day")
    for invalid in ["", "-1", "-1m", "1:-30", "0", "24h1m", "1441", "1h extra", String(repeating: "9", count: 400)] {
        expect(Mite.bookingMinutes(invalid) == nil, "booking duration refuses invalid or out-of-range input")
    }
    expect(Mite.validBookingDate("2028-02-29"), "booking date accepts a real ISO date")
    for invalid in ["2027-02-29", "2026-2-01", "2026-01-01x", "0000-01-01"] {
        expect(!Mite.validBookingDate(invalid), "booking date refuses invalid or non-canonical dates")
    }

    // What the HUD says when booking fails
    let bookingFailure = "Could not confirm the booking. Check your entries in mite."
    expect(Mite.bookingFailure(ok: true, output: "Booked 45m") == nil, "confirmed booking succeeds")
    expect(Mite.bookingFailure(ok: false, output: "Booked 45m\nError: /private/fixture") == bookingFailure,
           "failed booking suppresses raw CLI output even if it contains the success marker")
    expect(Mite.bookingFailure(ok: true, output: "") == bookingFailure, "missing confirmation is reported safely")
}
