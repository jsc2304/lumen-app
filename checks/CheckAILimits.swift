import Foundation

func checkAILimits() {
    expect(AI.compatibleEndpoint("https://example.com/v1/")?.absoluteString == "https://example.com/v1/chat/completions",
           "compatible HTTPS endpoint")
    expect(AI.compatibleEndpoint("http://localhost:11434/v1") != nil, "loopback compatible endpoint")
    for address in ["http://example.com/v1", "https://name:password@example.com/v1", "https://example.com/v1?token=example"] {
        expect(AI.compatibleEndpoint(address) == nil, "unsafe compatible endpoint rejected")
    }

    func refused(_ system: String = "", _ messages: [AIMessage]) -> Bool {
        do { try AILimits.validate(system: system, messages: messages); return false }
        catch AILimitError.input { return true }
        catch { return false }
    }
    expect(!refused("", [AIMessage(role: .user, text: String(repeating: "x", count: AILimits.textBytes))]), "text boundary accepted")
    expect(refused("x", [AIMessage(role: .user, text: String(repeating: "x", count: AILimits.textBytes))]), "system plus input over cap refused")
    expect(refused("", [AIMessage(role: .user, text: String(repeating: "é", count: AILimits.textBytes))]), "UTF-8 bytes counted")
    expect(!refused("", Array(repeating: AIMessage(role: .user, text: "x"), count: 40)), "history boundary accepted")
    expect(refused("", Array(repeating: AIMessage(role: .user, text: "x"), count: 41)), "history over cap refused")
    expect(refused("", [AIMessage(role: .user, text: "", images: Array(repeating: Data([0]), count: 13))]), "image count refused")
    expect(refused("", [AIMessage(role: .user, text: "", images: [Data(count: AILimits.imageBytes + 1)])]), "image bytes refused")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ledger = AILedger(directory: dir), now = Date()
    for _ in 0..<500 { try! ledger.reserve(now: now) }
    do { try AILedger(directory: dir).reserve(now: now); expect(false, "501st refused across reload") }
    catch { expect(error as? AILimitError == .daily, "daily cause") }
    try! ledger.reserve(now: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
    let counter = try! JSONDecoder().decode(AILedger.Counter.self, from: Data(contentsOf: dir.appendingPathComponent("ai-budget.json")))
    expect(counter.calls == 1, "next local day resets")
    try! Data("broken".utf8).write(to: dir.appendingPathComponent("ai-budget.json"))
    for _ in 0..<2 {
        do { try ledger.reserve(); expect(false, "corrupt budget fails closed") }
        catch { expect(error as? AILimitError == .storage, "corrupt budget stays blocked as storage") }
    }
    expect(AILedger.modelLabel("sk-abc123") == "default-or-custom" && AILedger.modelLabel("gpt-5.1") == "gpt-5.1", "key-like model label redacted")
    let record = AILedger.Record(time: now, provider: "claude", model: AILedger.modelLabel("secret prompt\nkey"), duration: 1, result: "error")
    try! ledger.record(record)
    let log = try! String(contentsOf: dir.appendingPathComponent("ai-calls.jsonl"), encoding: .utf8)
    expect(!log.contains("secret") && !log.contains("prompt") && !log.contains("key") && !log.contains("response"), "typed metadata has no content or upstream error")
    try! Data(repeating: 120, count: 1_048_576).write(to: dir.appendingPathComponent("ai-calls.jsonl"))
    try! ledger.record(record)
    expect((try! Data(contentsOf: dir.appendingPathComponent("ai-calls.jsonl"))).count < 1024, "log rotation bounds disk")
    var output = AILimits.Output()
    try! output.accept(String(repeating: "x", count: AILimits.outputTokens))
    do { try output.accept("x"); expect(false, "output overflow refused") }
    catch { expect(error as? AILimitError == .output, "output cause") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["10"]
    try! process.run()
    let processDeadline = AIDeadline(seconds: 0.02) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    process.waitUntilExit()
    expect(processDeadline.didExpire && process.terminationReason == .uncaughtSignal, "watchdog kills real offline process")
    processDeadline.cancel()
    // A CLI that leaves a helper holding stdout: killing the tree must close the pipe.
    let shell = Process(), pipe = Pipe()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "sleep 30 & wait"]
    shell.standardOutput = pipe
    try! shell.run()
    usleep(200_000)
    let helpers = AIProcess.descendants(shell.processIdentifier)
    AIProcess.killTree(shell.processIdentifier)
    let eof = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = pipe.fileHandleForReading.readDataToEndOfFile(); eof.signal() }
    expect(!helpers.isEmpty && eof.wait(timeout: .now() + 2) == .success, "process tree kill closes the pipe")
    let signal = DispatchSemaphore(value: 0)
    let deadline = AIDeadline(seconds: 0.01) { signal.signal() }
    expect(signal.wait(timeout: .now() + 1) == .success && deadline.didExpire, "deadline fires without network")
    deadline.cancel()
    let cancelled = AIDeadline(seconds: 0.02) { signal.signal() }
    cancelled.cancel()
    expect(signal.wait(timeout: .now() + 0.05) == .timedOut && !cancelled.didExpire, "completed operation cancels watchdog")
    for provider in [AIProvider.claude, .compatible] {
        let body = AI.body(provider, model: "test", system: "", messages: [])
        expect((body[provider == .claude ? "max_tokens" : "max_completion_tokens"] as? Int) == 16_384, "HTTP output cap")
    }
}
