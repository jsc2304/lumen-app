import Foundation

/// Private-use budget. Refuse rather than silently dropping context. All entry points use AI.stream.
enum AILimits {
    static let seconds: Double = 180
    static let outputTokens = 16_384
    static let dailyCalls = 500
    static let textBytes = 131_072
    static let historyMessages = 40
    static let imageBytes = 20 * 1024 * 1024

    struct Output {
        private var bytes = 0
        mutating func accept(_ text: String) throws {
            bytes += text.utf8.count
            guard bytes <= outputTokens else { throw AILimitError.output }
        }
    }

    static func validate(system: String, messages: [AIMessage]) throws {
        guard messages.count <= historyMessages,
              system.utf8.count + messages.reduce(0, { $0 + $1.text.utf8.count }) <= textBytes,
              messages.reduce(0, { $0 + $1.images.count }) <= 12,
              messages.flatMap(\.images).reduce(0, { $0 + $1.count }) <= imageBytes else {
            throw AILimitError.input
        }
    }
}

enum AILimitError: String, LocalizedError {
    case input, daily, deadline, output, storage
    var errorDescription: String? {
        switch self {
        case .input: return "AI input limit reached (128 KiB text, 40 messages, 12 images / 20 MiB). Start a shorter chat."
        case .daily: return "AI daily limit reached (500 calls). Try again tomorrow."
        case .deadline: return "AI stopped after the 180-second deadline."
        case .output: return "AI output limit reached. Ask for a shorter answer."
        case .storage: return "AI budget or log in Lumen's Application Support folder is unreadable or not writable (ai-budget.json, ai-calls.jsonl). AI stays off until it is fixed or removed."
        }
    }
}

/// Only typed metadata can enter this file: no upstream error, prompt, answer or key fields.
final class AILedger {
    struct Counter: Codable { var day: Date; var calls: Int }
    struct Record: Codable {
        var time: Date
        var provider: AIProvider.RawValue
        var model: String
        var inputTokens: Int?
        var outputTokens: Int?
        var duration: Double
        var result: String
    }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func reserve(now: Date = Date()) throws {
        let url = directory.appendingPathComponent("ai-budget.json")
        let day = Calendar.current.startOfDay(for: now)
        var counter = Counter(day: day, calls: 0)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Counter.self, from: data) else { throw AILimitError.storage }
            if saved.day >= day { counter = saved }
        }
        guard counter.calls < AILimits.dailyCalls else { throw AILimitError.daily }
        counter.calls += 1
        do { try JSONEncoder().encode(counter).write(to: url, options: .atomic) }
        catch { throw AILimitError.storage }
    }
    func record(_ record: Record) throws {
        let url = directory.appendingPathComponent("ai-calls.jsonl")
        var data = (try? Data(contentsOf: url)) ?? Data()
        let line = try JSONEncoder().encode(record) + Data([10])
        // Retain complete lines, at most 1 MiB. The daily counter is independent of rotation.
        if data.count + line.count > 1_048_576 { data = Data() }
        data.append(line)
        do { try data.write(to: url, options: .atomic) } catch { throw AILimitError.storage }
    }
    static func modelLabel(_ model: String) -> String {
        // Model identifiers only; arbitrary settings text must not become log content.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:/")
        let keyLike = ["sk-", "sk_", "key-", "ghp_", "github_pat_", "xox"].contains { model.lowercased().hasPrefix($0) }
        return !keyLike && !model.isEmpty && model.utf8.count <= 100 && model.unicodeScalars.allSatisfy(allowed.contains) ? model : "default-or-custom"
    }
}

/// Monotonic wall-clock watchdog, independent of stream activity or the main actor.
final class AIDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var finished = false
    private var work: DispatchWorkItem?
    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    init(seconds: Double = AILimits.seconds, abort: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.finished else { return }
            self.expired = true
            abort()
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }
    func cancel() { lock.lock(); finished = true; work?.cancel(); lock.unlock() }
}

/// Ends a CLI run with everything it started: a helper that inherited stdout would otherwise keep the
/// pipe open, and the read loop would never see EOF.
enum AIProcess {
    static func descendants(_ pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let children = buffer.prefix(Int(count)).filter { $0 > 0 }
        return children + children.flatMap(descendants)
    }

    /// Children first are collected before anything dies, because a killed parent hands them to launchd.
    static func killTree(_ pid: pid_t) {
        let tree = [pid] + descendants(pid)
        for p in tree { kill(p, SIGKILL) }
    }
}
