import Foundation

// Checks for Schedule.swift: parsing and validation behind the Create Event form. Pure functions only,
// the calendar store is never touched.
func checkSchedule() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
    let now = at(2026, 10, 22, 10, 7, 42)   // a Thursday

    func parse(_ text: String) -> (start: Date, allDay: Bool)? { try? EventInput.parseWhen(text, now: now, calendar: cal) }
    func timed(_ text: String, _ start: Date) -> Bool { parse(text)?.start == start && parse(text)?.allDay == false }
    func allDay(_ text: String, _ start: Date) -> Bool { parse(text)?.start == start && parse(text)?.allDay == true }
    func problem(_ text: String) -> String? {
        do { _ = try EventInput.parseWhen(text, now: now, calendar: cal); return nil } catch let e as EventInput.Invalid { return e.message } catch { return "other error" }
    }

    // Day words and weekdays
    expect(timed("tomorrow 10:00", at(2026, 10, 23, 10)), "tomorrow 10:00")
    expect(timed("  Tomorrow   10:00 ", at(2026, 10, 23, 10)), "case and spacing")
    expect(timed("Fri 14:30", at(2026, 10, 23, 14, 30)), "Fri 14:30")
    expect(timed("fr. 9:00", at(2026, 10, 23, 9)), "German weekday with a dot")
    expect(timed("Thu 14:30", at(2026, 10, 22, 14, 30)), "today's weekday still ahead means today")
    expect(timed("Thu 9:00", at(2026, 10, 29, 9)), "today's weekday already past means next week")
    expect(allDay("thursday", at(2026, 10, 29)), "a bare weekday on that weekday means next week")
    expect(allDay("Montag", at(2026, 10, 26)), "German weekday")
    expect(timed("heute 15:30", at(2026, 10, 22, 15, 30)), "heute")
    expect(timed("morgen um 10 Uhr", at(2026, 10, 23, 10)), "morgen um 10 Uhr")
    expect(timed("übermorgen 8:00", at(2026, 10, 24, 8)), "übermorgen")
    expect(timed("day after tomorrow 8:00", at(2026, 10, 24, 8)), "day after tomorrow")
    expect(timed("tomorrow at noon", at(2026, 10, 23, 12)), "noon")

    // Dates
    expect(timed("24.12. 18 Uhr", at(2026, 12, 24, 18)), "24.12. 18 Uhr")
    expect(timed("24.12.2026 18.30 Uhr", at(2026, 12, 24, 18, 30)), "dd.MM.yyyy with 18.30 Uhr")
    expect(timed("am 24.12. um 18:00", at(2026, 12, 24, 18)), "German filler words")
    expect(allDay("24.12.", at(2026, 12, 24)), "date only is all-day")
    expect(allDay("22.10.", at(2026, 10, 22)), "today is not past")
    expect(allDay("21.10.", at(2027, 10, 21)), "a passed date without year means next year")
    expect(allDay("1.1.27", at(2027, 1, 1)), "two-digit year")
    expect(timed("2026-12-24 18:00", at(2026, 12, 24, 18)), "ISO date")
    expect(allDay("2026-12-24", at(2026, 12, 24)), "ISO date only")
    expect(allDay("tomorrow", at(2026, 10, 23)), "tomorrow without time is all-day")

    // Times
    expect(timed("today 3pm", at(2026, 10, 22, 15)), "today 3pm")
    expect(timed("today at 3:30 PM", at(2026, 10, 22, 15, 30)), "3:30 PM")
    expect(timed("today 12am", at(2026, 10, 22, 0)), "12am is midnight")
    expect(timed("today 12pm", at(2026, 10, 22, 12)), "12pm is noon")
    expect(timed("15:30", at(2026, 10, 22, 15, 30)), "time only, still ahead")
    expect(timed("9:00", at(2026, 10, 23, 9)), "time only, already past means tomorrow")

    // Relative
    expect(timed("in 2 hours", at(2026, 10, 22, 12, 7)), "in 2 hours drops the seconds")
    expect(timed("in 90 min", at(2026, 10, 22, 11, 37)), "in 90 min")
    expect(timed("in 1,5 Stunden", at(2026, 10, 22, 11, 37)), "decimal comma")
    expect(allDay("in 4 Tagen", at(2026, 10, 26)), "in 4 days is all-day, across the DST change")
    expect(allDay("in 2 weeks", at(2026, 11, 5)), "in 2 weeks")
    // Huge numbers are clamped (100000), not trapped in Int() or the calendar math.
    expect(allDay("in 99999999999999999999 days", cal.date(byAdding: .day, value: 100_000, to: at(2026, 10, 22))!), "huge number of days")
    expect(allDay("in 1" + String(repeating: "0", count: 400) + " weeks", cal.date(byAdding: .day, value: 700_000, to: at(2026, 10, 22))!), "number beyond Double")
    expect(timed("in 99999999999999999999 hours", cal.dateInterval(of: .minute, for: now.addingTimeInterval(100_000 * 3600))!.start), "huge number of hours")

    // What NSDataDetector adds. It reads "now" from the real clock, so only check the parts that do not depend on it.
    expect(allDay("dec 24 2030", at(2030, 12, 24)), "detector: absolute date")
    expect(timed("december 24 2030 6pm", at(2030, 12, 24, 18)), "detector day, time from the text")
    let friday = parse("next friday 14:30")
    expect(friday.map { cal.component(.weekday, from: $0.start) == 6 && !$0.allDay
                        && cal.component(.hour, from: $0.start) == 14 && cal.component(.minute, from: $0.start) == 30 } == true,
           "detector: next friday 14:30")
    expect(parse("next friday")?.allDay == true, "detector: date without time is all-day")

    // Errors name the offending input
    expect(problem("") != nil && problem("   ") != nil, "empty When")
    expect(problem("tomorrow 25:00")?.contains("“25:00”") == true, "hour out of range")
    expect(problem("tomorrow 10:75")?.contains("“10:75”") == true, "minute out of range")
    expect(problem("tomorrow 13pm")?.contains("“13pm”") == true, "13pm")
    expect(problem("31.02.")?.contains("“31.02.”") == true, "31 February")
    expect(problem("29.02.2027")?.contains("not a valid date") == true, "29 February in a common year")
    expect(problem("18.30")?.contains("not a valid date") == true, "18.30 is a date, not a time")
    expect(problem("blah")?.hasPrefix("Could not read “blah”") == true, "gibberish")
    expect(problem("tomorrow blah") != nil, "unknown word next to a date")

    let agenda = [(at(2026, 10, 22), at(2026, 10, 23), true),
                  (at(2026, 10, 22, 8), at(2026, 10, 22, 9), false),
                  (at(2026, 10, 22, 10), at(2026, 10, 22, 11), false),
                  (at(2026, 10, 22, 12), at(2026, 10, 22, 13), false)]
    expect(Schedule.agendaSelection(agenda, now: now) == 2, "agenda selects running meeting over all-day and past events")
    expect(Schedule.agendaSelection(Array(agenda.prefix(2)) + [agenda[3]], now: now) == 2, "agenda selects next timed meeting")
    expect(Schedule.agendaSelection(Array(agenda.prefix(2)), now: now) == 0, "agenda falls back to current all-day event")
    let past = [(at(2026, 10, 21, 8), at(2026, 10, 21, 9), false), agenda[1]]
    expect(Schedule.agendaSelection(past, now: now) == 1, "agenda falls back to last past event")
    let recurring = [past[0], agenda[2]]
    let recurringIDs = recurring.map { Schedule.eventID("standup", start: $0.0) }
    let selected = Schedule.agendaSelection(recurring, now: now)!
    expect(recurringIDs[0] != recurringIDs[1] && recurringIDs.firstIndex(of: recurringIDs[selected]) == 1,
           "recurring occurrences have distinct IDs and select the running occurrence")
    let featuredEvents = [(now.addingTimeInterval(-300), now, false),
                          (now.addingTimeInterval(-240), now.addingTimeInterval(600), false),
                          (now, now.addingTimeInterval(3600), true)]
    expect(Schedule.upcomingIndex(featuredEvents, now: now) == 1, "upcoming excludes ended and all-day events")
    expect(Schedule.upcomingIndex([featuredEvents[0], featuredEvents[2]], now: now) == nil, "no upcoming timed event")
    expect(Schedule.agendaSelection([], now: now) == nil, "empty agenda")

    // Featured meeting at the top of the root: starts within the hour or began under 10 minutes ago
    func offsets(_ minutes: [Double]) -> [Date] { minutes.map { now.addingTimeInterval($0 * 60) } }
    expect(Schedule.featured([], now: now) == nil, "no events")
    expect(Schedule.featured(offsets([-120, 23]), now: now) == 1, "a long running block does not hide the next meeting")
    expect(Schedule.featured(offsets([-120, -5, 40]), now: now) == 1, "a meeting that began 5 minutes ago comes first")
    expect(Schedule.featured(offsets([-120, -11, 40]), now: now) == 2, "one that began 11 minutes ago makes way for the next")
    expect(Schedule.featured(offsets([-120, -11, 90]), now: now) == 1, "nothing in the next hour: the running event that started last")
    expect(Schedule.featured(offsets([-120]), now: now) == 0, "a lone running event")
    expect(Schedule.featured(offsets([61, 180]), now: now) == nil, "nothing within the hour")
    expect(Schedule.featured(offsets([59.9]), now: now) == 0 && Schedule.featured(offsets([60]), now: now) == nil, "the hour is exclusive")

    // Duration
    func duration(_ text: String) -> TimeInterval? { try? EventInput.parseDuration(text) }
    expect(duration("") == 1800, "default 30 minutes")
    for (text, seconds) in [("45", 2700.0), ("90m", 5400), ("1h", 3600), ("1.5h", 5400), ("1,5 h", 5400), ("1:30", 5400), ("1h30", 5400),
                            ("1h 30m", 5400), ("2 hours", 7200), ("45 Min", 2700), ("1 Std", 3600), ("1 Stunde 15 Minuten", 4500)] {
        expect(duration(text) == seconds, "duration " + text)
    }
    for text in ["abc", "0", "1x", "-5", "h", "8d", "99999"] { expect(duration(text) == nil, "bad duration " + text) }
    do { _ = try EventInput.parseDuration("8d") } catch let e as EventInput.Invalid {
        expect(e.message == "The duration must be between 1 minute and 7 days.", "duration range message")
    } catch { expect(false, "duration error type") }

    expect(EventInput.endDate(start: at(2026, 10, 23, 10), allDay: false, duration: 1800, calendar: cal) == at(2026, 10, 23, 10, 30), "timed end")
    expect(EventInput.endDate(start: at(2026, 10, 23), allDay: true, duration: 1800, calendar: cal) == at(2026, 10, 23, 23, 59, 59), "all-day is one day")
    expect(EventInput.endDate(start: at(2026, 10, 23), allDay: true, duration: 48 * 3600, calendar: cal) == at(2026, 10, 24, 23, 59, 59), "all-day, 48h")
    expect(EventInput.endDate(start: at(2026, 10, 24), allDay: true, duration: 25 * 3600, calendar: cal) == at(2026, 10, 25, 23, 59, 59), "all-day rounds up to whole days")

    // Calendar names
    let titles = ["Home", "Work", "Family"]
    func pick(_ name: String) -> String {
        do { return try EventInput.calendarIndex(name, in: titles).map { titles[$0] } ?? "default" } catch let e as EventInput.Invalid { return e.message } catch { return "other error" }
    }
    expect(pick("") == "default" && pick("  ") == "default", "empty calendar means the default one")
    expect(pick(" WORK ") == "Work", "calendar names ignore case and spaces")
    expect(pick("Hobby") == "No writable calendar named “Hobby”. Use one of: Home, Work, Family.", "unknown calendar lists the valid names")
    expect(EventInput.names(["A", "A", "B"]) == "A, B" && EventInput.names([]) == "none available", "names are listed once")

    // Location or link
    expect(EventInput.link("https://teams.microsoft.com/l/meetup-join/abc")?.host == "teams.microsoft.com", "link")
    expect(EventInput.link("HTTPS://zoom.us/j/1") != nil, "scheme ignores case")
    for text in ["", "Room 4", "zoom.us/j/1", "https://x.com/a b", "Room 4 https://zoom.us/j/1"] { expect(EventInput.link(text) == nil, "not a bare link: " + text) }
}
