import Foundation

// Checks for Script Commands: metadata parsing, arguments, running and output handling, creating, scanning.
// Only invented scripts in a temporary folder are run; nothing of the user's, and no shortcut.
func checkScripts() {
    let bash = """
    #!/bin/bash

    # Required parameters:
    # @raycast.schemaVersion 1
    # @raycast.title Say Hello
    # @raycast.mode compact

    # Optional parameters:
    # @raycast.icon 👋
    # @raycast.packageName Demo
    # @raycast.needsConfirmation true
    # @raycast.currentDirectoryPath ~/demo
    # @raycast.argument1 { "type": "text", "placeholder": "Name", "percentEncoded": true }
    # @raycast.argument2 { "type": "text", "placeholder": "Greeting", "optional": true }

    # Documentation:
    # @raycast.description Greets someone, by name.

    echo hello
    """
    let hello = Scripts.parse(bash, path: "/s/hello.sh")
    expect(hello?.title == "Say Hello" && hello?.mode == .compact && hello?.package == "Demo", "bash metadata: title, mode, package")
    expect(hello?.icon == "👋" && hello?.summary == "Greets someone, by name.", "bash metadata: icon and description")
    expect(hello?.needsConfirmation == true && hello?.directory == "~/demo", "bash metadata: confirmation and directory")
    expect(hello?.arguments == [Scripts.Argument(placeholder: "Name", optional: false, percentEncoded: true),
                                Scripts.Argument(placeholder: "Greeting", optional: true, percentEncoded: false)],
           "argument JSON: placeholder, optional, percentEncoded")

    let node = Scripts.parse("#!/usr/bin/env node\n\n// @raycast.schemaVersion 1\n// @raycast.title Node One\n// @raycast.mode fullOutput\n", path: "/s/n.js")
    expect(node?.title == "Node One" && node?.mode == .fullOutput, "node comment style (//)")
    let python = Scripts.parse("#!/usr/bin/env python3\n# @raycast.title Py One\n# @raycast.mode silent\n", path: "/s/p.py")
    expect(python?.title == "Py One" && python?.mode == .silent, "python comment style (#)")
    let apple = Scripts.parse("#!/usr/bin/osascript\n-- @raycast.title Apple One\n-- @raycast.mode inline\n", path: "/s/a.applescript")
    expect(apple?.title == "Apple One" && apple?.mode == .inline, "AppleScript comment style (--)")
    let windows = Scripts.parse("# @raycast.title Crlf\r\n# @raycast.mode silent\r\n", path: "/s/w.sh")
    expect(windows?.title == "Crlf" && windows?.mode == .silent, "CRLF line endings")

    expect(Scripts.parse("#!/bin/bash\n# @raycast.mode silent\necho hi\n", path: "/s/x.sh") == nil, "no title, no command")
    expect(Scripts.parse("#!/bin/bash\necho '# @raycast.title Nope'\n", path: "/s/x.sh") == nil, "a title inside code is not metadata")
    expect(Scripts.parse("# @raycast.title No Mode\n", path: "/s/x.sh")?.mode == .fullOutput, "no mode shows the whole output")
    expect(Scripts.parse("# @raycast.title Odd\n# @raycast.mode LOUD\n", path: "/s/x.sh")?.mode == .fullOutput, "unknown mode shows the whole output")
    expect(Scripts.parse("# @raycast.title Case\n# @raycast.mode FullOutput\n", path: "/s/x.sh")?.mode == .fullOutput, "mode is case-insensitive")

    let broken = Scripts.parse("# @raycast.title B\n# @raycast.argument1 {oops\n# @raycast.argument2 {\"type\":\"text\",\"placeholder\":\"Second\"}\n", path: "/s/x.sh")
    expect(broken?.arguments.count == 2 && broken?.arguments[0].placeholder == "" && broken?.arguments[1].placeholder == "Second",
           "a broken argument stays a field, so $2 keeps its place")
    let ordered = Scripts.parse("# @raycast.title O\n# @raycast.argument2 {\"placeholder\":\"two\"}\n# @raycast.argument1 {\"placeholder\":\"one\"}\n# @raycast.argument4 {\"placeholder\":\"four\"}\n", path: "/s/x.sh")
    expect(ordered?.arguments.map(\.placeholder) == ["one", "two"], "arguments sort by number; argument4 does not exist")
    expect(Scripts.parse("# @raycast.title H\n#   argument1 {\"type\": \"text\"}\n# See @raycast.argument1 above\n", path: "/s/x.sh")?.arguments.isEmpty == true,
           "hints that only mention @raycast. are not metadata")

    // Arguments
    let args = hello!
    expect(Scripts.missing(args, ["", ""]) == "Enter name.", "a required argument must be filled")
    expect(Scripts.missing(args, ["  ", "x"]) == "Enter name.", "blank counts as empty")
    expect(Scripts.missing(args, ["Jan", ""]) == nil, "an optional argument may stay empty")
    expect(Scripts.values(args, [" Jan Schmidt ", ""]) == ["Jan%20Schmidt", ""], "percentEncoded argument is encoded and trimmed; optional keeps its place")
    expect(Scripts.values(args, ["a&b/c", "x y"]) == ["a%26b%2Fc", "x y"], "only percentEncoded arguments are encoded")
    expect(Scripts.label(0, Scripts.Argument()) == "Argument 1", "an argument without placeholder is named by position")

    // Working directory
    expect(Scripts.workingDirectory(Scripts.Script(path: "/s/sub/x.sh", title: "x")) == "/s/sub", "default directory is the script's folder")
    expect(Scripts.workingDirectory(Scripts.Script(path: "/s/x.sh", title: "x", directory: "/tmp")) == "/tmp", "absolute directory")
    expect(Scripts.workingDirectory(Scripts.Script(path: "/s/x.sh", title: "x", directory: "../data")) == "/s/../data", "relative directory counts from the script's folder")
    expect(Scripts.workingDirectory(Scripts.Script(path: "/s/x.sh", title: "x", directory: "~/demo")) == NSHomeDirectory() + "/demo", "tilde directory")

    // Output handling
    expect(Scripts.lastLine("one\ntwo\n\n  \n") == "two", "last output line skips trailing blanks")
    expect(Scripts.lastLine("\n\n") == nil && Scripts.lastLine("") == nil, "no output, no line")
    expect(Scripts.lastLine(String(repeating: "x", count: 300))?.count == 121, "a long line is cut for the HUD")
    expect(Scripts.problem(Scripts.Output(status: 1, out: "fine", err: "boom\nlast error\n")) == "last error", "failure names the last stderr line")
    expect(Scripts.problem(Scripts.Output(status: 1, out: "only out\n")) == "only out", "without stderr it falls back to stdout")
    expect(Scripts.problem(Scripts.Output(status: 7)) == "exit status 7", "silent failure names the status")
    expect(Scripts.problem(Scripts.Output(status: 15, timedOut: true)) == "timed out", "timeout is named")
    expect(Scripts.problem(Scripts.Output(status: 15, out: "xxx", flooded: true)) == "too much output", "a flood is named")

    let text = "plain *star* _under_ [x](y) `tick` ```fence```\n  indented\n\nlast  "
    let rendered = (try? AttributedString(markdown: Scripts.codeBlock(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        .map { String($0.characters) }
    expect(rendered == text, "output renders as typed, line breaks and markdown characters included: \(rendered ?? "nil")")
    expect(Scripts.codeBlock("a\n   \nb") == "` a `\n\n` b `", "a whitespace-only line becomes an empty line")
    expect(Scripts.codeBlock("1\n2\n3\n4", limit: 2).hasPrefix("2 earlier lines not shown\n` 3 `"), "only the last lines are shown")

    // Shortcuts
    expect(Scripts.parseShortcuts("Alpha\nBeta Two\n\n  \nAlpha\n Gamma \n") == ["Alpha", "Beta Two", " Gamma "],
           "shortcut names: one per line, no blanks, no repeats, spelling kept")

    // Create
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-scripts-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    expect(Scripts.slug("Say Hello, World!") == "say-hello-world" && Scripts.slug("***") == "", "file name from the title")
    let made = try? Scripts.create(title: "Say Hello!", mode: .silent, package: "Demo", in: base.appendingPathComponent("new").path)
    expect(made?.lastPathComponent == "say-hello.sh", "created file name")
    expect(made.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true, "created script is executable")
    let madeScript = made.flatMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap { Scripts.parse($0, path: made!.path) } }
    expect(madeScript?.title == "Say Hello!" && madeScript?.mode == .silent && madeScript?.package == "Demo" && madeScript?.arguments.isEmpty == true,
           "the template parses back to what was asked for, its hints are not metadata")
    expect((try? Scripts.create(title: "Say Hello!", mode: .compact, package: "", in: base.appendingPathComponent("new").path))?.lastPathComponent
           == "say-hello-2.sh", "a second script with the same title gets a number")
    expect((try? Scripts.create(title: "***", mode: .compact, package: "", in: base.appendingPathComponent("new").path))?.lastPathComponent
           == "script.sh", "a title without letters still gets a file name")

    // Scan: nested folders, executable bit, title, hidden files
    let tree = base.appendingPathComponent("tree")
    func put(_ path: String, _ body: String, executable: Bool = true) {
        let url = tree.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
    put("b.sh", "#!/bin/sh\n# @raycast.title Beta\n# @raycast.mode silent\n")
    put("sub/a.py", "#!/usr/bin/env python3\n# @raycast.title alpha\n# @raycast.mode compact\n")
    put("plain.sh", "#!/bin/sh\n# @raycast.title Not Executable\n", executable: false)
    put("untitled.sh", "#!/bin/sh\necho hi\n")
    put(".hidden.sh", "#!/bin/sh\n# @raycast.title Hidden\n")
    let found = Scripts.scan([tree.path, tree.path, base.appendingPathComponent("missing").path])
    expect(found.map(\.title) == ["alpha", "Beta"], "scan finds executable scripts with a title, nested, sorted, once: \(found.map(\.title))")

    // Running: arguments, working directory, PATH, both streams, exit status
    put("run.sh", "#!/bin/sh\necho \"out:$1|$2|$(pwd)\"\necho \"err line\" >&2\necho \"path:$PATH\"\nexit 3\n")
    let ran = Scripts.run(tree.appendingPathComponent("run.sh").path, ["one", "two words"], cwd: tree.appendingPathComponent("sub").path)
    expect(ran.status == 3 && !ran.timedOut, "exit status is kept")
    expect(ran.out.contains("out:one|two words|") && ran.out.contains("/sub\n"), "arguments and working directory reach the script: \(ran.out)")
    expect(ran.err == "err line\n", "stderr is kept apart")
    expect(ran.out.contains("/opt/homebrew/bin:") && ran.out.contains("/usr/local/bin:"), "PATH includes the Homebrew folders")
    expect(Scripts.run("/nonexistent/lumen-check", []).status == -1, "a script that cannot start reports it")

    // Timeout, and a background child that keeps the output open must not block the wait
    put("slow.sh", "#!/bin/sh\necho started\nsleep 6\n")
    let began = Date()
    let slow = Scripts.run(tree.appendingPathComponent("slow.sh").path, [], timeout: 1)
    expect(slow.timedOut && slow.status != 0 && slow.out == "started\n", "a script past the limit is stopped, its output so far kept")
    expect(Date().timeIntervalSince(began) < 4, "the limit is enforced")
    put("child.sh", "#!/bin/sh\n(sleep 6) &\necho parent done\n")
    let spawned = Date()
    let child = Scripts.run(tree.appendingPathComponent("child.sh").path, [])
    expect(child.status == 0 && child.out == "parent done\n" && Date().timeIntervalSince(spawned) < 4, "a background child does not hold up the result")

    // A script that ignores SIGTERM is killed after the grace time; it must not block the wait for ever.
    put("stubborn.sh", "#!/bin/sh\ntrap '' TERM\necho started\nsleep 5\n")
    let stubbornStart = Date()
    let stubborn = Scripts.run(tree.appendingPathComponent("stubborn.sh").path, [], timeout: 1, grace: 0.5)
    expect(stubborn.timedOut && stubborn.status == SIGKILL && stubborn.out == "started\n", "SIGKILL follows when SIGTERM is ignored")
    expect(Date().timeIntervalSince(stubbornStart) < 3.5, "the kill does not wait for the script's own end")

    // Output: only the end is read; a flood is stopped at the limit (1 MB here, 50 MB for real)
    put("big.sh", "#!/bin/sh\nhead -c 300000 /dev/zero | tr '\\0' a\n")
    let big = Scripts.run(tree.appendingPathComponent("big.sh").path, [])
    expect(big.status == 0 && !big.flooded && big.out.utf8.count == 200_000 && big.out.allSatisfy { $0 == "a" }, "a long output is cut to its last 200 KB: \(big.out.utf8.count)")
    put("flood.sh", "#!/bin/sh\nwhile :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done\n")
    let floodStart = Date()
    let flood = Scripts.run(tree.appendingPathComponent("flood.sh").path, [], timeout: 20, outputLimit: 1_000_000)
    expect(flood.flooded && !flood.timedOut && flood.status != 0 && flood.out.utf8.count <= 200_000 && !flood.out.isEmpty, "a runaway output is stopped and its end kept")
    expect(Date().timeIntervalSince(floodStart) < 8, "the output limit is enforced")
}
