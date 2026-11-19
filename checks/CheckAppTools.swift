import Foundation

// Checks for AppTools.swift: which apps Uninstall offers, which ~/Library files count as leftovers (against a made-up
// Library in a temporary folder), the auto-quit rules. Nothing here reads or writes the real ~/Library or autoquit.json.
func checkAppTools() {
    let t = AppTools.self

    // Which apps are offered
    let home = "/Users/someone", own = "/Users/someone/Applications/Lumen.app"
    let ok = { (path: String, resolved: String?) in t.isUninstallable(path, resolved: resolved ?? path, home: home, own: own) }
    expect(ok("/Applications/Foo.app", nil) && ok("/Users/someone/Applications/Foo.app", nil), "apps in /Applications and ~/Applications")
    expect(ok("/Applications/Setapp/Foo.app", nil), "app in a subfolder")
    expect(!ok("/System/Applications/Chess.app", nil), "macOS apps")
    expect(!ok("/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"), "linked system apps")
    expect(!ok(own, nil), "Lumen itself")
    expect(!ok("/Volumes/Stick/Foo.app", nil) && !ok("/Users/someone/Downloads/Foo.app", nil), "other places")

    // Candidate paths
    let c = t.leftoverCandidates(bundleId: "com.example.fooapp", names: ["Foo", "FooApp", "foo"])
    for path in ["Application Support/Foo", "Application Support/FooApp", "Caches/Foo", "Logs/FooApp", "Application Support/com.example.fooapp",
                 "Caches/com.example.fooapp", "Preferences/com.example.fooapp.plist", "Containers/com.example.fooapp",
                 "Saved Application State/com.example.fooapp.savedState", "Logs/com.example.fooapp", "HTTPStorages/com.example.fooapp",
                 "WebKit/com.example.fooapp"] {
        expect(c.contains(path), "candidate: " + path)
    }
    expect(c.filter { $0.lowercased() == "caches/foo" }.count == 1, "a name that differs only in case is listed once")
    expect(t.leftoverCandidates(bundleId: "", names: ["Foo"]) == ["Application Support/Foo", "Caches/Foo", "Logs/Foo"], "no bundle id: names only")
    expect(t.leftoverCandidates(bundleId: "../x", names: ["a/b", "", ".hidden", ".."]).isEmpty, "no names that leave the folder")

    // Group Containers and launch agents
    let id = "com.example.fooapp"
    expect(["ABCDE12345.com.example.fooapp", "group.com.example.fooapp", "ABCDE12345.group.com.example.fooapp",
            "ABCDE12345.groups.com.example.fooapp", "com.example.fooapp", "com.example.FOOAPP"].allSatisfy { t.isGroupContainer($0, of: id) },
           "group container named after the app")
    expect(["ABCDE12345.com.example.fooapp.beta", "ABCDE12345.com.example.fooappx", "ABCDE12345.Suite", "ABCDE12345",
            "group.com.example.other", "XYZ.com.example.fooapp", "com.example.fooapp.beta"].allSatisfy { !t.isGroupContainer($0, of: id) },
           "group containers of other apps or shared by the vendor stay")
    expect(!t.isGroupContainer("ABCDE12345.", of: "") && !t.isGroupContainer("", of: ""), "no bundle id, no match")
    expect(t.isLaunchAgent("com.example.fooapp.plist", of: id) && t.isLaunchAgent("com.example.fooapp.helper.plist", of: id), "launch agents of the app")
    expect(!t.isLaunchAgent("com.example.fooappx.plist", of: id) && !t.isLaunchAgent("com.example.fooapp", of: id)
           && !t.isLaunchAgent("other.plist", of: id) && !t.isLaunchAgent("com.example.fooapp.plist", of: ""), "other launch agents stay")

    // A made-up app and Library
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("lumen-apptools-check-" + UUID().uuidString)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent("locked").path); try? fm.removeItem(at: base) }
    let lib = base.appendingPathComponent("Library"), app = base.appendingPathComponent("Applications/FooApp.app")
    let write = { (url: URL, bytes: Int) in
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: url)
    }
    try? fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try? Data("""
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fooapp</string></dict></plist>
    """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
    write(app.appendingPathComponent("Contents/MacOS/FooApp"), 100_000)
    write(lib.appendingPathComponent("Application Support/FooApp/data.db"), 50_000)
    write(lib.appendingPathComponent("Application Support/Unrelated/data.db"), 50_000)
    write(lib.appendingPathComponent("Caches/com.example.fooapp/cache.bin"), 20_000)
    write(lib.appendingPathComponent("Caches/com.example.fooapp.beta/cache.bin"), 20_000)
    write(lib.appendingPathComponent("Preferences/com.example.fooapp.plist"), 1_000)
    write(lib.appendingPathComponent("Preferences/com.example.other.plist"), 1_000)
    write(lib.appendingPathComponent("Group Containers/ABCDE12345.group.com.example.fooapp/x"), 8_000)
    write(lib.appendingPathComponent("Group Containers/ABCDE12345.Suite/x"), 8_000)
    write(lib.appendingPathComponent("LaunchAgents/com.example.fooapp.helper.plist"), 500)
    write(lib.appendingPathComponent("LaunchAgents/com.example.other.plist"), 500)
    let scan = t.scan(app.path, library: lib)
    let found = scan.leftovers.map { $0.path.replacingOccurrences(of: lib.path + "/", with: "") }
    expect(found == ["Application Support/FooApp", "Caches/com.example.fooapp", "Group Containers/ABCDE12345.group.com.example.fooapp",
                     "LaunchAgents/com.example.fooapp.helper.plist", "Preferences/com.example.fooapp.plist"],
           "leftovers found by bundle id and name, nothing else: \(found)")
    expect(scan.appBytes >= 100_000 && scan.appBytes < 200_000, "app size")
    expect(scan.leftovers.first { $0.path.hasSuffix("Application Support/FooApp") }.map { $0.bytes >= 50_000 && $0.bytes < 100_000 } == true, "folder size")
    expect(scan.total == scan.appBytes + scan.leftovers.reduce(0) { $0 + $1.bytes }, "total")
    let lines = t.listing(scan, path: app.path, home: base.path)
    expect(lines.count == scan.leftovers.count + 3 && lines.last?.hasSuffix("Total") == true && lines[0].hasSuffix("~/Applications/FooApp.app"),
           "confirmation lists the app, every leftover and the total: \(lines)")
    let none = t.scan(base.appendingPathComponent("Applications/Missing.app").path, library: lib)
    expect(none.leftovers.isEmpty && none.appBytes == 0, "an app without leftovers")

    // Another installed copy with the same bundle id: what they share stays
    let copy = base.appendingPathComponent("Other/FooApp.app"), beta = base.appendingPathComponent("Other/FooApp Beta.app")
    let unrelated = base.appendingPathComponent("Other/Unrelated.app"), link = base.appendingPathComponent("Other/FooLink.app")
    for dir in [copy, beta] {
        try? fm.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? fm.copyItem(at: app.appendingPathComponent("Contents/Info.plist"), to: dir.appendingPathComponent("Contents/Info.plist"))
    }
    try? fm.createDirectory(at: unrelated.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try? Data("""
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.unrelated</string></dict></plist>
    """.utf8).write(to: unrelated.appendingPathComponent("Contents/Info.plist"))
    try? fm.createSymbolicLink(at: link, withDestinationURL: app)
    let listed = [app.path, copy.path, beta.path, unrelated.path, link.path]
    let shares = t.sharedCopies(of: [app.path, unrelated.path], among: listed)
    expect(shares[app.path] == [beta.path, copy.path].sorted() && shares[unrelated.path] == nil && shares.count == 1,
           "other copies by bundle id; a link to the same app, another id and the app itself do not count: \(shares)")
    let sharedScan = t.scan(app.path, library: lib, sharedWith: [copy.path])
    expect(sharedScan.leftovers.isEmpty && sharedScan.sharedWith == [copy.path], "a copy with the same id and name: nothing is a leftover: \(sharedScan.leftovers.map(\.path))")
    let betaScan = t.scan(app.path, library: lib, sharedWith: [beta.path])
    expect(betaScan.leftovers.map { $0.path.replacingOccurrences(of: lib.path + "/", with: "") } == ["Application Support/FooApp"],
           "a copy with another name shares only the id: the app's own name folder is still a leftover")
    expect(t.scan(app.path, library: lib).sharedWith.isEmpty && t.detail(scan).markdown.contains("Another copy") == false, "no other copy: nothing said")
    let sharedDetail = t.detail(sharedScan).markdown
    expect(sharedDetail.contains("Another copy with the same bundle identifier") && sharedDetail.contains("stay in place"), "the detail says what was left alone")
    let alert = t.confirmAlert("Move?", info: "Info", lines: ["a", "b"])
    expect(alert.buttons.map(\.title) == ["Move to Trash", "Cancel"], "confirmation buttons")
    expect(alert.buttons[0].keyEquivalent == "" && alert.buttons[1].keyEquivalent == "\r", "Return cancels, it does not move anything to the Trash")

    // Sizes do not follow links; root-owned means admin rights
    let holder = base.appendingPathComponent("holder")
    try? fm.createDirectory(at: holder, withIntermediateDirectories: true)
    try? fm.createSymbolicLink(at: holder.appendingPathComponent("link"), withDestinationURL: app)
    expect(t.size(of: holder.path) < 10_000, "a link inside a folder counts as itself, not as what it points to")
    expect(t.size(of: base.appendingPathComponent("nothing").path) == 0, "missing path")
    let locked = base.appendingPathComponent("locked")
    try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
    expect(!t.needsAdmin(locked.path), "own folder")
    try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    expect(t.needsAdmin(locked.path), "a folder this user cannot write")

    // Auto Quit: minutes, rules, decisions
    expect(t.minutes("30") == 30 && t.minutes(" 1 ") == 1, "minutes")
    expect(t.minutes("0") == nil && t.minutes("-3") == nil && t.minutes("1.5") == nil && t.minutes("") == nil && t.minutes("soon") == nil, "bad minutes")
    let back = try? JSONDecoder().decode([AutoQuitRule].self, from: JSONEncoder().encode([AutoQuitRule(path: "/Applications/Foo.app", minutes: 15)]))
    expect(back?.first?.path == "/Applications/Foo.app" && back?.first?.minutes == 15, "rules round-trip")

    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let minutes = { (m: Double) in t0.addingTimeInterval(m * 60) }
    let rules = [AutoQuitRule(path: "/Applications/Foo.app", minutes: 30), AutoQuitRule(path: "/Applications/Bar.app", minutes: 5)]
    let running: [(pid: Int32, path: String)] = [(10, "/Applications/Foo.app"), (11, "/Applications/Bar.app"), (12, "/Applications/NoRule.app")]
    var idle: [Int32: Date] = [10: t0, 11: t0, 12: t0, 99: t0]
    expect(t.expired(rules, running: running, front: 1, idle: &idle, now: minutes(4.9)).isEmpty, "nobody is idle long enough yet")
    expect(idle[99] == nil, "apps that quit are forgotten")
    expect(t.expired(rules, running: running, front: 1, idle: &idle, now: minutes(5)) == [11], "Bar after 5 minutes; Foo needs 30, NoRule has no rule")
    expect(t.expired(rules, running: running, front: 1, idle: &idle, now: minutes(6)).isEmpty, "a quit that has not happened is not retried every minute")
    expect(t.expired(rules, running: running, front: 1, idle: &idle, now: minutes(10)) == [11], "but after another full period")
    expect(t.expired(rules, running: running, front: 1, idle: &idle, now: minutes(31)) == [10, 11], "Foo after 30 minutes")
    var idle2: [Int32: Date] = [11: t0]
    expect(t.expired(rules, running: running, front: 11, idle: &idle2, now: minutes(60)).isEmpty && idle2[11] == nil, "the frontmost app is never idle")
    var idle3: [Int32: Date] = [:]
    expect(t.expired(rules, running: running, front: nil, idle: &idle3, now: minutes(1000)).isEmpty, "an app first seen in the background starts counting then")
    expect(idle3[10] == minutes(1000) && idle3[12] == nil, "only apps with a rule are tracked")
    expect(t.expired(rules, running: running, front: nil, idle: &idle3, now: minutes(1031)) == [10, 11], "and quits once its time is up")
    expect(t.expired([], running: running, front: nil, idle: &idle3, now: minutes(5000)).isEmpty, "no rules, nothing quits")

    // Sleep is not time in the background: after a gap between checks every idle clock restarts
    var asleep: [Int32: Date] = [10: t0, 11: t0, 99: t0]
    expect(t.expired(rules, running: running, front: 1, idle: &asleep, now: minutes(600), since: minutes(59)).isEmpty, "after a sleep nothing quits")
    expect(asleep[10] == minutes(600) && asleep[11] == minutes(600) && asleep[99] == nil, "the idle clocks restart at the wake")
    expect(t.expired(rules, running: running, front: 1, idle: &asleep, now: minutes(604), since: minutes(603)).isEmpty, "and count again from there: 4 of 5 minutes")
    expect(t.expired(rules, running: running, front: 1, idle: &asleep, now: minutes(605), since: minutes(604)) == [11], "5 minutes after the wake Bar goes")
    var awake: [Int32: Date] = [11: t0]
    expect(t.expired(rules, running: running, front: 1, idle: &awake, now: minutes(5), since: minutes(4)) == [11], "a normal minute between checks quits as before")
    var late: [Int32: Date] = [11: t0]
    expect(t.expired(rules, running: running, front: 1, idle: &late, now: minutes(5), since: minutes(3)) == [11], "two minutes between checks (a busy Mac) is not yet a sleep")
    var slept: [Int32: Date] = [11: t0]
    expect(t.expired(rules, running: running, front: 1, idle: &slept, now: minutes(5), since: minutes(2.5)).isEmpty, "more than two minutes between checks is a sleep")
}
