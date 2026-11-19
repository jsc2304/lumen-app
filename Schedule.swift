import AppKit
import EventKit

/// "My Schedule": recent and upcoming events from all calendars, with join, open and copy actions. The next
/// meeting also shows at the top of the empty root search.
final class Schedule {
    static let shared = Schedule()
    private let store = EKEventStore()
    private var cache: (events: [EKEvent], at: Date)?   // 14 days in either direction, see events()

    private static let joinPattern = try! NSRegularExpression(
        pattern: #"https://(teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|[\w.-]*zoom\.us/j|meet\.google\.com|[\w.-]*webex\.com/(meet|join))/[^\s<>"]+"#)

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [self] _ in
            cache = nil
            Launcher.shared.reload()
        }
    }

    private var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func commands() -> [Item] {
        [.command("cal.schedule", "My Schedule", kind: "Calendar", icon: "calendar",
                  keywords: ["agenda", "calendar", "kalender", "termine", "meetings"], closes: false) { [self] in
            if status == .notDetermined {
                store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { Launcher.shared.reload() } }
            }
            Launcher.shared.push(.list(ListSpec(title: "My Schedule", placeholder: "Search events…", initialSelection: { [weak self] items in
                guard let self else { return 0 }
                let events = self.events()
                let now = Date()
                guard let index = Self.agendaSelection(events.map { ($0.startDate, $0.endDate, $0.isAllDay) }, now: now) else { return 0 }
                return items.firstIndex { $0.id == Self.eventID(events[index].calendarItemIdentifier, start: events[index].startDate) } ?? 0
            }) { [weak self] in
                self?.items(matching: $0) ?? []
            }))
        },
        .command("cal.create", "Create Event", kind: "Calendar", icon: "calendar.badge.plus",
                 keywords: ["new", "add", "event", "meeting", "appointment", "termin", "neu"], closes: false) { [self] in
            showCreateForm()
        }]
    }

    /// The meeting to show at the top of the root search; see `featured`.
    func upcoming() -> [Item] {
        let found = events()
        let now = Date()
        guard let i = Self.upcomingIndex(found.map { ($0.startDate, $0.endDate, $0.isAllDay) }, now: now) else { return [] }
        return [item(found[i]).inSection("Upcoming")]
    }

    /// Index of the event to feature among `starts` (ascending, events that already ended left out): one that starts
    /// within the hour or began less than 10 minutes ago, so a long block like "Focus 08:00–17:00" does not hide the
    /// next meeting. Without one, the running event that started last.
    static func featured(_ starts: [Date], now: Date) -> Int? {
        let live = starts.indices.filter { starts[$0].timeIntervalSince(now) < 3600 }
        return live.first { starts[$0].timeIntervalSince(now) > -600 } ?? live.last
    }

    static func upcomingIndex(_ events: [(start: Date, end: Date, allDay: Bool)], now: Date) -> Int? {
        let indices = events.indices.filter { !events[$0].allDay && events[$0].end > now }
        return featured(indices.map { events[$0].start }, now: now).map { indices[$0] }
    }

    static func eventID(_ identifier: String, start: Date) -> String {
        "event." + identifier + "." + String(start.timeIntervalSinceReferenceDate)
    }

    static func agendaSelection(_ events: [(start: Date, end: Date, allDay: Bool)], now: Date) -> Int? {
        events.indices.last { !events[$0].allDay && events[$0].start <= now && events[$0].end > now }
            ?? events.indices.first { !events[$0].allDay && events[$0].start > now }
            ?? events.indices.first { events[$0].end > now }
            ?? events.indices.last
    }

    /// Events from the past 14 days through the next 14 days. EventKit is queried at most once a minute (and again after a
    /// calendar change), because this runs whenever the root opens and on every keystroke in My Schedule.
    private func events() -> [EKEvent] {
        guard status == .fullAccess else { return [] }
        let now = Date()
        if let cache, now.timeIntervalSince(cache.at) < 60 { return cache.events }
        let today = Calendar.current.startOfDay(for: now)
        let start = Calendar.current.date(byAdding: .day, value: -14, to: today)!
        let end = Calendar.current.date(byAdding: .day, value: 14, to: today)!
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !(($0.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }) }
            .sorted { $0.startDate < $1.startDate }
        cache = (found, now)
        return found
    }

    private func items(matching q: String) -> [Item] {
        switch status {
        case .fullAccess: break
        case .notDetermined:
            return [Item(id: "cal.wait", title: "Waiting for calendar access…", icon: .symbol("hourglass"), track: false, actions: [])]
        default:
            return [Item(id: "cal.grant", title: "Allow Lumen to read your calendars", subtitle: "Privacy & Security → Calendars",
                         icon: .symbol("lock"), track: false, actions: [Action(title: "Open Privacy Settings", icon: "gearshape") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }])]
        }
        let found = events().filter { e in
            q.isEmpty || [e.title, e.location, e.calendar.title].compactMap { $0 }.contains { matchScore(q, $0) > 0 }
        }
        guard !found.isEmpty else {
            return [Item(id: "cal.none", title: q.isEmpty ? "No events in the past or next 14 days" : "No matching events",
                         icon: .symbol("calendar"), track: false, actions: [createAction])]
        }
        return found.map { item($0).inSection(daySection($0.startDate)) }
    }

    private func daySection(_ d: Date) -> String {
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func joinURL(_ e: EKEvent) -> URL? {
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            if let m = joinPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range, in: text) { return URL(string: String(text[r])) }
        }
        return nil
    }

    private func item(_ e: EKEvent) -> Item {
        let title = e.title ?? "Untitled"
        let link = Self.joinURL(e)
        let time = e.isAllDay ? "All day"
            : e.startDate.formatted(date: .omitted, time: .shortened) + " – " + e.endDate.formatted(date: .omitted, time: .shortened)
        let minutes = Int((e.startDate.timeIntervalSinceNow / 60).rounded(.up))
        let when = e.isAllDay ? "" : e.startDate <= Date() && e.endDate > Date() ? " · now" : e.startDate > Date() && minutes <= 60 ? " · in \(minutes) min" : ""
        let details = ([title, e.startDate.formatted(date: .complete, time: .omitted) + ", " + time, e.location, link?.absoluteString]
            .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "\n")
        let open = Action(title: "Open in Calendar", icon: "calendar", shortcut: Shortcut(.command, "o")) { Self.open(e) }
        var actions = [open]
        if let link {
            actions.insert(Action(title: "Join Meeting", icon: "video", shortcut: Shortcut(.command, "j")) { NSWorkspace.shared.open(link) }, at: 0)
        }
        actions += [
            .copy("Copy Title", shortcut: Shortcut([.command, .shift], "c")) { title },
            .copy("Copy Details", shortcut: Shortcut([.command, .shift], "d")) { details },
            .copy("Copy Time", shortcut: Shortcut([.command, .shift], "t")) { time },
        ]
        if let link { actions.append(.copy("Copy Meeting Link", shortcut: Shortcut([.command, .shift], "l")) { link.absoluteString }) }
        if !e.isAllDay, let book = Mite.bookAction(title: title, start: e.startDate, end: e.endDate) { actions.append(book) }
        actions.append(createAction)
        return Item(id: Self.eventID(e.calendarItemIdentifier, start: e.startDate), title: title, subtitle: time + when, kind: e.calendar.title,
                    icon: .color(e.calendar.color), track: false, actions: actions)
    }

    /// Calendar's ical:// scheme selects the event; falls back to opening Calendar on that day's view.
    private static func open(_ e: EKEvent) {
        let id = e.calendarItemExternalIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let url = URL(string: "ical://ekevent/" + id + "?method=show&options=more"), !id.isEmpty, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    // MARK: Create Event

    private var createAction: Action {
        Action(title: "Create Event", icon: "calendar.badge.plus", shortcut: Shortcut(.command, "n"), closes: false) { [self] in
            showCreateForm()
        }
    }

    private func showCreateForm() {
        if status == .notDetermined { store.requestFullAccessToEvents { _, _ in } }
        Launcher.shared.push(.form(FormSpec(title: "Create Event", fields: [
            FormField(label: "Title", placeholder: "Team sync"),
            FormField(label: "When", placeholder: "tomorrow 10:00, Fri 14:30, 24.12. 18 Uhr, in 2 hours"),
            FormField(label: "Duration", placeholder: "30 min (or 1h, 90m, 1:30, 45)"),
            FormField(label: "Calendar", placeholder: store.defaultCalendarForNewEvents?.title ?? "Default calendar"),
            FormField(label: "Location / Link", placeholder: "Optional"),
        ], submitTitle: "Create Event") { [self] in create($0) }))
    }

    /// Validates the form top to bottom and saves the event; returns the first problem, or nil when saved.
    private func create(_ v: [String]) -> String? {
        do {
            guard status == .fullAccess else {
                throw EventInput.Invalid(status == .notDetermined ? "Allow calendar access in the system dialog, then submit again."
                    : "Lumen has no calendar access. Allow it in System Settings → Privacy & Security → Calendars.")
            }
            let title = v[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw EventInput.Invalid("Enter a title.") }
            let when = try EventInput.parseWhen(v[1])
            let duration = try EventInput.parseDuration(v[2])
            let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
            let calendar: EKCalendar
            if let i = try EventInput.calendarIndex(v[3], in: writable.map(\.title)) {
                calendar = writable[i]
            } else if let fallback = store.defaultCalendarForNewEvents {
                calendar = fallback
            } else {
                throw EventInput.Invalid("No default calendar is set. Enter one of: " + EventInput.names(writable.map(\.title)) + ".")
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.calendar = calendar
            event.isAllDay = when.allDay
            event.startDate = when.start
            event.endDate = EventInput.endDate(start: when.start, allDay: when.allDay, duration: duration)
            let place = v[4].trimmingCharacters(in: .whitespacesAndNewlines)
            if let link = EventInput.link(place) { event.url = link } else if !place.isEmpty { event.location = place }
            cache = nil   // the list behind the form shows the new event at once, not after EventKit's change notification
            do { try store.save(event, span: .thisEvent) } catch {
                throw EventInput.Invalid("Could not save the event: " + error.localizedDescription)
            }
            var format = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
            if !when.allDay { format = format.hour().minute() }
            HUD.show("Event created: \(title), " + when.start.formatted(format))
            return nil
        } catch let e as EventInput.Invalid {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }
}

/// Parsing and validation behind the Create Event form. Pure functions (the clock and calendar are
/// parameters), so checks/CheckSchedule.swift can run them against a fixed "now".
enum EventInput {
    /// A problem with the user's input, worded for the form.
    struct Invalid: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static let units: [String: Double] = {
        var u = [String: Double]()
        for (names, seconds) in [("m min mins minute minutes minuten", 60.0), ("h hr hrs hour hours std stunde stunden", 3600),
                                 ("d day days tag tage tagen", 86400), ("w week weeks woche wochen", 604_800)] {
            for n in names.split(separator: " ") { u[String(n)] = seconds }
        }
        return u
    }()

    private static let dayWords = ["today": 0, "heute": 0, "tomorrow": 1, "tmrw": 1, "morgen": 1,
                                   "day after tomorrow": 2, "übermorgen": 2, "uebermorgen": 2]
    private static let weekdays = [
        "sun": 1, "sunday": 1, "so": 1, "sonntag": 1, "mon": 2, "monday": 2, "mo": 2, "montag": 2,
        "tue": 3, "tues": 3, "tuesday": 3, "di": 3, "dienstag": 3, "wed": 4, "wednesday": 4, "mi": 4, "mittwoch": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "do": 5, "donnerstag": 5, "fri": 6, "friday": 6, "fr": 6, "freitag": 6,
        "sat": 7, "saturday": 7, "sa": 7, "samstag": 7, "sonnabend": 7,
    ]

    // MARK: When

    /// Natural-language date and time: "tomorrow 10:00", "Fri 14:30", "24.12. 18 Uhr", "in 2 hours", "today 3pm",
    /// "2026-12-24 18:00". A date without a time gives an all-day event (start at midnight). Everything this does
    /// not recognise goes to NSDataDetector, which has no reference-date parameter, so it only supplies the day
    /// ("next friday", "Dec 24"); the time always comes from the text itself, because the detector reads a bare
    /// "9:00" as 21:00 and invents a default time for dates without one.
    static func parseWhen(_ text: String, now: Date = Date(), calendar cal: Calendar = .current) throws -> (start: Date, allDay: Bool) {
        let s = tidy(text.lowercased())
        guard !s.isEmpty else { throw Invalid("Enter when the event starts, e.g. “tomorrow 10:00”.") }
        let today = cal.startOfDay(for: now)

        if let g = match(#"^in (\d+(?:[.,]\d+)?) ?([a-zäöü]+)$"#, in: s)?.groups, let unit = units[g[2]],
           let typed = Double(g[1].replacingOccurrences(of: ",", with: ".")) {
            let n = min(typed, 100_000)   // far beyond any real plan, and keeps Int() and the calendar math from trapping
            if unit >= 86400 { return (cal.date(byAdding: .day, value: Int((n * unit / 86400).rounded()), to: today)!, true) }
            return (cal.dateInterval(of: .minute, for: now.addingTimeInterval(n * unit))!.start, false)
        }

        var rest = s
        var time: (h: Int, m: Int)?
        if let g = take(#"(?<![\d.:])(\d{1,2}):(\d{2})(?!\d)(?:\s*(am|pm|uhr)\b)?"#, &rest)
            ?? take(#"(?<![\d.:])(\d{1,2})(?:\.(\d{2}))?\s*(am|pm|uhr)\b"#, &rest) {
            time = try clock(g)
        } else if take(#"\b(?:noon|midday|mittags?)\b"#, &rest) != nil {
            time = (12, 0)
        }

        var left = rest
        var day = try takeDay(&left, today: today, now: now, time: time, calendar: cal)
        left = tidy(left.replacingOccurrences(of: filler, with: " ", options: .regularExpression))
        if !left.isEmpty { day = nil }   // something unknown next to the date: the detector reads the whole phrase
        if day == nil {
            let phrase = tidy(rest.replacingOccurrences(of: filler, with: " ", options: .regularExpression))
            if !phrase.isEmpty {
                guard let d = detectDay(phrase, cal) else { throw unreadable(text) }
                day = d
            }
        }

        switch (day, time) {
        case (nil, nil):
            throw unreadable(text)
        case (nil, let t?):   // time only: the next time it is that time
            let start = cal.date(bySettingHour: t.h, minute: t.m, second: 0, of: today)!
            return (start > now ? start : cal.date(byAdding: .day, value: 1, to: start)!, false)
        case (let d?, nil):
            return (d, true)
        case (let d?, let t?):
            return (cal.date(bySettingHour: t.h, minute: t.m, second: 0, of: d)!, false)
        }
    }

    private static let filler = #"\b(at|um|on|am|den|the)\b|[@,]"#

    private static func unreadable(_ text: String) -> Invalid {
        Invalid("Could not read “\(text.trimmingCharacters(in: .whitespacesAndNewlines))” as a date. "
                + "Try “tomorrow 10:00”, “Fri 14:30” or “24.12. 18 Uhr”.")
    }

    /// Single spaces, none at the ends.
    private static func tidy(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func match(_ pattern: String, in s: String) -> (groups: [String], range: Range<String.Index>)? {
        let re = try! NSRegularExpression(pattern: pattern)
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let groups = (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        return (groups, Range(m.range, in: s)!)
    }

    /// First match of `pattern` (all groups, 0 = the whole match), cut out of `s`.
    private static func take(_ pattern: String, _ s: inout String) -> [String]? {
        guard let m = match(pattern, in: s) else { return nil }
        s.replaceSubrange(m.range, with: " ")
        return m.groups
    }

    /// Groups: 1 hour, 2 minutes (maybe empty), 3 "am", "pm", "uhr" or empty.
    private static func clock(_ g: [String]) throws -> (h: Int, m: Int) {
        var h = Int(g[1])!
        let m = Int(g[2]) ?? 0
        let twelve = g[3] == "am" || g[3] == "pm"
        guard m < 60, twelve ? (1...12).contains(h) : h < 24 else { throw Invalid("“\(g[0].trimmingCharacters(in: .whitespaces))” is not a valid time.") }
        if twelve { h = h % 12 + (g[3] == "pm" ? 12 : 0) }
        return (h, m)
    }

    /// The day named by 2026-12-24, 24.12.[2026], today/tomorrow, or a weekday; cut out of `s`.
    private static func takeDay(_ s: inout String, today: Date, now: Date, time: (h: Int, m: Int)?, calendar cal: Calendar) throws -> Date? {
        if let g = take(#"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#, &s) {
            return try day(Int(g[1])!, Int(g[2])!, Int(g[3])!, raw: g[0], today: today, calendar: cal)
        }
        if let g = take(#"(?<![\d.])(\d{1,2})\.(\d{1,2})(?:\.(\d{4}|\d{2})?)?(?![\d.:])"#, &s) {
            let year = Int(g[3]).map { g[3].count == 2 ? 2000 + $0 : $0 }
            return try day(year, Int(g[2])!, Int(g[1])!, raw: g[0], today: today, calendar: cal)
        }
        let words = (Array(dayWords.keys) + weekdays.keys).sorted { $0.count > $1.count }.joined(separator: "|")
        guard let g = take(#"\b("# + words + #")\b\.?"#, &s) else { return nil }
        if let n = dayWords[g[1]] { return cal.date(byAdding: .day, value: n, to: today)! }
        // A weekday is its next occurrence; today only counts when the event is still ahead of us.
        var offset = (weekdays[g[1]]! - cal.component(.weekday, from: today) + 7) % 7
        let ahead = time.map { cal.date(bySettingHour: $0.h, minute: $0.m, second: 0, of: today)! > now } ?? false
        if offset == 0 && !ahead { offset = 7 }
        return cal.date(byAdding: .day, value: offset, to: today)!
    }

    /// Midnight of a real calendar day. Without a year: this year, or next year if that day has passed.
    private static func day(_ year: Int?, _ month: Int, _ d: Int, raw: String, today: Date, calendar cal: Calendar) throws -> Date {
        func make(_ y: Int) -> Date? {
            guard let date = cal.date(from: DateComponents(year: y, month: month, day: d)) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return c.year == y && c.month == month && c.day == d ? date : nil
        }
        let y = year ?? cal.component(.year, from: today)
        guard var date = make(y) else { throw Invalid("“\(raw.trimmingCharacters(in: .whitespaces))” is not a valid date.") }
        if year == nil, date < today {
            guard let next = make(y + 1) else { throw Invalid("“\(raw.trimmingCharacters(in: .whitespaces))” is not a valid date.") }
            date = next
        }
        return date
    }

    private static func detectDay(_ phrase: String, _ cal: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
              m.range.length == (phrase as NSString).length, let date = m.date else { return nil }
        return cal.startOfDay(for: date)
    }

    // MARK: Duration, calendar, place

    /// "45", "90m", "1h", "1.5h", "1:30", "1h30", "1h 30m", "2 hours"; empty means 30 minutes. A bare number is minutes.
    static func parseDuration(_ text: String) throws -> TimeInterval {
        let s = text.lowercased().filter { !$0.isWhitespace }
        if s.isEmpty { return 30 * 60 }
        let bad = Invalid("Could not read the duration “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”. Use 45, 90m, 1h, 1:30 or 1h30.")
        var total = 0.0
        if let g = match(#"^(\d+):(\d{2})$"#, in: s)?.groups {
            total = Double(g[1])! * 3600 + Double(g[2])! * 60
        } else {
            let parts = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)([a-zäöü]*)"#).matches(in: s, range: NSRange(s.startIndex..., in: s))
            guard !parts.isEmpty, parts.reduce(0, { $0 + $1.range.length }) == s.utf16.count else { throw bad }
            for p in parts {
                let number = String(s[Range(p.range(at: 1), in: s)!]).replacingOccurrences(of: ",", with: ".")
                let unit = String(s[Range(p.range(at: 2), in: s)!])
                guard let seconds = unit.isEmpty ? 60 : units[unit], let n = Double(number) else { throw bad }
                total += n * seconds
            }
        }
        guard (60...7 * 86400).contains(total) else { throw Invalid("The duration must be between 1 minute and 7 days.") }
        return total
    }

    /// End of the event: start plus duration. An all-day event covers whole days and ends at 23:59:59 of its
    /// last day, the way EventKit reports them.
    static func endDate(start: Date, allDay: Bool, duration: TimeInterval, calendar cal: Calendar = .current) -> Date {
        guard allDay else { return start.addingTimeInterval(duration) }
        let days = max(1, Int((duration / 86400).rounded(.up)))
        return cal.date(byAdding: .day, value: days, to: start)!.addingTimeInterval(-1)
    }

    /// Index of the calendar the field names (case-insensitive); nil for an empty field, meaning the default calendar.
    static func calendarIndex(_ name: String, in titles: [String]) throws -> Int? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return nil }
        guard let i = titles.firstIndex(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else {
            throw Invalid("No writable calendar named “\(n)”. Use one of: " + names(titles) + ".")
        }
        return i
    }

    static func names(_ titles: [String]) -> String {
        var seen = Set<String>()
        let unique = titles.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "none available" : unique.joined(separator: ", ")
    }

    /// A bare http(s) link goes into the event's URL field (so Join Meeting finds it); anything else is a location.
    static func link(_ text: String) -> URL? {
        let t = text.lowercased()
        guard t.hasPrefix("http://") || t.hasPrefix("https://"), !t.contains(where: \.isWhitespace),
              let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}
