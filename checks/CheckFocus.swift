import Foundation

// Checks for Focus.swift: duration text, the session clock, the form rules, app matching, focus.json decoding.
// Only pure functions: nothing here reads or writes the real focus.json.
func checkFocus() {
    let f = Focus.self

    // Duration text
    expect(f.parseDuration("25m") == 1500, "25m")
    expect(f.parseDuration("25") == 1500, "a bare number is minutes")
    expect(f.parseDuration(" 1H ") == 3600, "1h, any case, trimmed")
    expect(f.parseDuration("1h30m") == 5400 && f.parseDuration("1h 30m") == 5400, "hours and minutes")
    expect(f.parseDuration("1.5h") == 5400 && f.parseDuration("1,5h") == 5400, "decimal hours, dot or comma")
    expect(f.parseDuration("90s") == 90 && f.parseDuration("2 hours") == 7200 && f.parseDuration("45 min") == 2700, "unit words")
    for bad in ["", "abc", "0m", "0", "25x", "-5m", "1h 30", "5m5", "m", "1h and 30m"] {
        expect(f.parseDuration(bad) == nil, "not a duration: " + bad)
    }
    // Typed or stored numbers that are too big: no duration, and never a trap in the text (saved to focus.json, a trap here would repeat at every launch)
    expect(f.parseDuration("10080m") == 604_800 && f.parseDuration("168h") == 604_800 && f.parseDuration("1h 99m") == 9_540, "a week is the longest duration")
    for huge in ["10081m", "169h", "99999999999999999999", "99999999999999999999 hours", "1h 99999999999999999999m", String(repeating: "9", count: 400),
                 String(repeating: "9", count: 400) + "s", "1" + String(repeating: "0", count: 309) + "m"] {
        expect(f.parseDuration(huge) == nil, "too long a duration: " + huge.prefix(30))
    }
    expect(f.plan(["Ship it", "99999999999999999999", ""], categories: [], current: nil, now: Date()).error?.hasPrefix("Duration") == true, "the form refuses a huge duration")
    expect(f.formatDuration(1500) == "25m" && f.formatDuration(3600) == "1h" && f.formatDuration(5400) == "1h 30m", "format")
    expect(f.formatDuration(90) == "1m 30s" && f.formatDuration(3725) == "1h 2m 5s", "format with seconds")
    expect(f.formatDuration(.infinity) == "" && f.formatDuration(.nan) == "" && f.formatDuration(1e22) != "" && f.formatDuration(-1e22) == "",
           "format never traps on a huge or non-finite number")
    for t in [60.0, 1500, 5400, 3725, 45] { expect(f.parseDuration(f.formatDuration(t)) == t, "format reads back: \(t)") }
    expect(f.clock(0) == "0:00" && f.clock(61) == "1:01" && f.clock(1453) == "24:13", "clock")
    expect(f.clock(3600) == "1:00:00" && f.clock(3725) == "1:02:05" && f.clock(-4) == "0:00", "clock from an hour, never negative")

    // The session clock: pause keeps what was focused, resume continues, a restart counts the time away.
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let at = { (s: Double) in t0.addingTimeInterval(s) }
    var s = FocusSession(goal: "Write report", duration: 1500, runningSince: t0)
    expect(s.elapsed(at: at(47)) == 47 && s.remaining(at: at(47)) == 1453, "running clock")
    expect(!s.isDone(at: at(1499)) && s.isDone(at: at(1500)) && s.isDone(at: at(9000)), "done at the end, also long after")
    s.pause(at: at(100))
    expect(s.runningSince == nil && s.banked == 100, "pause banks the time")
    expect(s.elapsed(at: at(5000)) == 100 && !s.isDone(at: at(5000)), "a paused session does not run out")
    s.pause(at: at(200))
    expect(s.banked == 100, "pausing twice changes nothing")
    s.resume(at: at(300))
    expect(s.elapsed(at: at(350)) == 150 && s.remaining(at: at(350)) == 1350, "resume continues")
    s.resume(at: at(340))
    expect(s.runningSince == at(300), "resuming a running session keeps its start")
    expect(FocusSession(goal: "x", runningSince: at(10)).elapsed(at: at(0)) == 0, "a clock set back never counts negative")
    expect(!FocusSession(goal: "x", runningSince: t0).isDone(at: at(99999)) && FocusSession(goal: "x", runningSince: t0).remaining(at: t0) == nil,
           "an open-ended session never runs out")

    // Menu bar text
    let timed = FocusSession(goal: "Write report", duration: 1500, runningSince: t0)
    expect(f.statusTitle(timed, now: at(47)) == "◎ 24:13 Write report", "counting down")
    expect(f.statusTitle(timed, now: at(47.4)) == "◎ 24:13 Write report", "partial seconds round up, like a timer")
    var paused = timed
    paused.pause(at: at(47))
    expect(f.statusTitle(paused, now: at(900)) == "◎ ⏸ 24:13 Write report", "paused")
    expect(f.statusTitle(FocusSession(goal: "Write report", runningSince: t0), now: at(760)) == "◎ Write report 12:40", "open-ended counts up")
    expect(f.statusTitle(FocusSession(goal: String(repeating: "x", count: 40), runningSince: t0), now: at(0)) == "◎ " + String(repeating: "x", count: 23) + "… 0:00",
           "long goals are cut")

    for odd in [1e22, .infinity] {
        expect(f.statusTitle(FocusSession(goal: "x", duration: odd, runningSince: t0), now: at(5)).hasSuffix(" x"), "countdown text with duration \(odd)")
    }
    expect(f.statusTitle(FocusSession(goal: "x", banked: 1e22, runningSince: t0), now: at(5)).hasPrefix("◎ x "), "count-up text with a huge banked time")
    expect(!f.hasUsableDuration(FocusSession(goal: "x", duration: 1e22)) && !f.hasUsableDuration(FocusSession(goal: "x", duration: .infinity))
           && !f.hasUsableDuration(FocusSession(goal: "x", duration: .nan)) && !f.hasUsableDuration(FocusSession(goal: "x", duration: f.maxDuration + 1)),
           "a stored session with a huge or non-finite duration is not usable")
    expect(f.hasUsableDuration(FocusSession(goal: "x")) && f.hasUsableDuration(FocusSession(goal: "x", duration: f.maxDuration)) && f.hasUsableDuration(timed),
           "no duration, a week and 25 minutes are usable")

    // Blocked apps
    expect(f.blocks(["Slack", "Mail"], appName: "slack", fileName: nil), "case-insensitive display name")
    expect(f.blocks(["Visual Studio Code"], appName: "Code", fileName: "Visual Studio Code"), "file name")
    expect(!f.blocks(["Slack"], appName: "Slack Helper", fileName: "Slack Helper"), "whole names only")
    expect(!f.blocks([], appName: "Slack", fileName: "Slack") && !f.blocks(["Slack"], appName: nil, fileName: nil), "nothing to match")

    // App names in the category form
    let installed = [Item(id: "/Applications/Slack.app", title: "Slack", actions: []),
                     Item(id: "/Applications/Visual Studio Code.app", title: "Code", keywords: ["Visual Studio Code"], actions: [])]
    let r = f.resolveApps(" slack , VISUAL studio code,Nope,, slack ", installed: installed)
    expect(r.names == ["Slack", "Code"], "matched by name or file name, listed under the display name, once")
    expect(r.missing == ["Nope"], "unknown names are reported")
    expect(f.resolveApps("", installed: installed).names.isEmpty && f.resolveApps(" , ", installed: installed).missing.isEmpty, "empty text: no apps")

    // Start and Edit forms
    let deep = FocusCategory(name: "Deep Work", apps: ["Slack", "Mail"])
    let plan = { (v: [String], current: FocusSession?, now: Double) in f.plan(v, categories: [deep], current: current, now: at(now)) }
    let started = plan(["  Ship it ", "25m", "deep work"], nil, 0).session
    expect(started?.goal == "Ship it" && started?.duration == 1500 && started?.category == "Deep Work", "start: goal, duration, category by name")
    expect(started?.blocked == ["Slack", "Mail"] && started?.runningSince == t0 && started?.banked == 0, "start: apps copied, running from now")
    expect(plan(["Ship it", "", ""], nil, 0).session?.duration == nil, "empty duration: until stopped")
    expect(plan(["Ship it", "", ""], nil, 0).session?.blocked == [], "empty category: nothing blocked")
    expect(plan(["", "25m", ""], nil, 0).error == "Enter a goal.", "goal is required")
    expect(plan(["Ship it", "soon", ""], nil, 0).error?.hasPrefix("Duration") == true, "bad duration")
    expect(plan(["Ship it", "25m", "Nope"], nil, 0).error?.contains("Nope") == true, "unknown category")
    // Edit keeps the progress and takes what changed.
    var running = started!
    running.pause(at: at(600))
    running.resume(at: at(700))
    let edited = plan(["Ship it now", "1h", ""], running, 760).session
    expect(edited?.goal == "Ship it now" && edited?.duration == 3600 && edited?.category == "" && edited?.blocked == [], "edit: new goal, duration, category")
    expect(edited?.banked == 600 && edited?.runningSince == at(700), "edit keeps what was focused so far")
    expect(plan(["Ship it", "", "Deep Work"], running, 760).session?.duration == nil, "edit: clearing the duration makes it open-ended")
    expect(plan(["Ship it", "15m", "Deep Work"], running, 760).session?.duration == 900, "edit: longer than the 11m focused so far is fine")
    expect(plan(["Ship it", "10m", "Deep Work"], running, 760).error?.contains("11m") == true, "edit: not shorter than the time already focused")
    expect(plan(["Ship it", "20m", "Deep Work"], running, 760).session?.blocked == ["Slack", "Mail"], "edit: same category")
    let orphan = f.plan(["Ship it", "25m", "Deep Work"], categories: [], current: running, now: at(760)).session
    expect(orphan?.blocked == ["Slack", "Mail"], "edit: a deleted category keeps the session's own copy of its apps")
    expect(f.plan(["Ship it", "25m", "Other"], categories: [], current: running, now: at(760)).error != nil, "edit: still no category that never existed")

    // focus.json
    let decode = { (json: String) in try? JSONDecoder().decode(FocusFile.self, from: Data(json.utf8)) }
    expect(decode("{}")?.categories.isEmpty == true && decode("{}")?.session == nil, "empty focus.json loads")
    expect(decode(#"{"categories":[{"name":"Reading"}]}"#)?.categories.first?.apps == [], "category without apps")
    let old = decode(#"{"categories":[],"session":{"goal":"Old"},"future":1}"#)
    expect(old?.session?.goal == "Old" && old?.session?.blocked == [] && old?.session?.banked == 0 && old?.session?.duration == nil,
           "a session needs only its goal; unknown keys are ignored")
    expect(decode(#"{"session":{"duration":60}}"#) == nil, "a session without a goal is rejected")
    let saved = try? JSONEncoder().encode(FocusFile(categories: [deep], session: started))
    let back = saved.flatMap { try? JSONDecoder().decode(FocusFile.self, from: $0) }
    expect(back?.categories.first?.id == deep.id && back?.session?.runningSince == t0 && back?.session?.blocked == ["Slack", "Mail"],
           "a session survives a restart")
}
