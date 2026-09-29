import Foundation

/// Reads Codex's rate limits.
///
/// The first choice is to ask Codex itself. The ChatGPT app — which is where
/// Codex lives now, under bundle id `com.openai.codex` — stopped writing the
/// JSONL rollouts this used to read and keeps its history in SQLite, where rate
/// limits are not stored at all. The current numbers exist only on the backend,
/// and the supported way to get them is the Codex app-server's
/// `account/rateLimits/read`: the same request the app makes to draw its own
/// usage meter, made by the user's own client with the user's own login.
///
/// That costs about a second of wall time per reading, most of it waiting on
/// the network, which is why it is taken every few minutes rather than every
/// few seconds. If no Codex client can be found or the request fails, the old
/// rollout logs are read instead, for installs that still write them.
///
/// Windows are identified by their length rather than by position. "Primary"
/// and "secondary" are Codex's names for whichever windows a plan has, and
/// plans differ: Plus had a five-hour primary and a seven-day secondary, while
/// Pro Lite has a single seven-day primary and no secondary at all.
enum CodexUsage {

    private static let fiveHourMinutes = 300
    private static let sevenDayMinutes = 10080

    static func read() -> AgentUsage? {
        let rollout = newestRollout()
        guard var usage = readLive() ?? rollout.flatMap(readRollout) else { return nil }

        // Model, working directory and context size only exist in a rollout,
        // and only mean anything while that rollout is the session in use. A
        // quiet one is as likely to be weeks old — the last one here was
        // seventeen days old — and would put a finished session's model and
        // project on the bar as if they were current.
        if let rollout, isRecent(rollout) {
            let session = sessionFacts(in: rollout)
            usage.model = session.model
            usage.cwd = session.cwd
            usage.contextWindow = session.contextWindow
            usage.contextTokens = session.contextTokens
        }
        return usage
    }

    // MARK: Asking Codex

    /// One `account/rateLimits/read` against a freshly started app-server.
    private static func readLive() -> AgentUsage? {
        guard let codex = codexExecutable() else { return nil }

        let task = Process()
        task.executableURL = codex
        task.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }

        // Every read below blocks until a line arrives or the pipe closes, so
        // a client that hangs would hang the refresh with it. Killing it
        // closes the pipe, which ends the read.
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
        }

        let replies = LineReader(output.fileHandleForReading)
        func send(_ message: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }

        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "agentbridge", "version": "1"]]])
        guard replies.response(to: 1)?["result"] != nil else { return nil }
        send(["method": "initialized"])
        send(["id": 2, "method": "account/rateLimits/read"])
        guard let result = replies.response(to: 2)?["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else { return nil }

        var usage = emptyUsage()
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            // A window without a reset time is still worth showing; zero is
            // what `Hub.rollingOver` reads as "not given".
            let resets = (window["resetsAt"] as? NSNumber)?.doubleValue ?? 0
            assign(UsageWindow(usedPercent: used, resetsAt: resets),
                   minutes: (window["windowDurationMins"] as? NSNumber)?.intValue, to: &usage)
        }
        return (usage.fiveHour == nil && usage.sevenDay == nil) ? nil : usage
    }

    /// The Codex client to ask. The bridge runs as a launch agent with a bare
    /// PATH, so the usual places are looked in by name.
    private static func codexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Newline-delimited JSON, read until the reply with a given id turns up.
    /// Notifications arriving in between are skipped.
    private final class LineReader {
        private let handle: FileHandle
        private var buffer = Data()

        init(_ handle: FileHandle) { self.handle = handle }

        func response(to id: Int) -> [String: Any]? {
            while true {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       (message["id"] as? NSNumber)?.intValue == id {
                        return message
                    }
                }
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }   // closed: the client exited or was killed
                buffer.append(chunk)
            }
        }
    }

    // MARK: Rollout logs

    /// Only the tail of a rollout is read. A long session's file reaches
    /// megabytes and the limits are always near the end.
    private static let tailBytes = 256 * 1024

    /// A rollout written to within this long is taken to be the session in use.
    private static let recentSeconds: TimeInterval = 6 * 3600

    private static func readRollout(_ url: URL) -> AgentUsage? {
        guard let limits = lastRateLimits(in: url) else { return nil }
        var usage = emptyUsage()
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double,
                  let resets = window["resets_at"] as? Double else { continue }
            assign(UsageWindow(usedPercent: used, resetsAt: resets),
                   minutes: window["window_minutes"] as? Int, to: &usage)
        }
        return (usage.fiveHour == nil && usage.sevenDay == nil) ? nil : usage
    }

    private static func isRecent(_ url: URL) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return false }
        return Date().timeIntervalSince(modified) < recentSeconds
    }

    struct SessionFacts {
        var model: String?
        var contextWindow: Int?
        var contextTokens: Int?
        var cwd: String?
    }

    /// Codex records more about itself than Claude does: the model, the size of
    /// its context window — which is what makes a real percentage possible —
    /// the tokens the last turn carried, and the directory it is working in.
    /// They arrive on different lines, so the tail is walked once for all four.
    private static func sessionFacts(in url: URL) -> SessionFacts {
        var facts = SessionFacts()
        guard let data = tail(of: url) else { return facts }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }

            if facts.model == nil, let name = payload["model"] as? String, !name.isEmpty {
                facts.model = name
            }
            if facts.cwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                facts.cwd = cwd
            }
            if facts.contextWindow == nil, let window = payload["model_context_window"] as? Int {
                facts.contextWindow = window
            }
            if let info = payload["info"] as? [String: Any] {
                if facts.contextWindow == nil, let window = info["model_context_window"] as? Int {
                    facts.contextWindow = window
                }
                if facts.contextTokens == nil,
                   let last = info["last_token_usage"] as? [String: Any],
                   let total = last["total_tokens"] as? Int, total > 0 {
                    facts.contextTokens = total
                }
            }
            if facts.model != nil, facts.cwd != nil,
               facts.contextWindow != nil, facts.contextTokens != nil { break }
        }
        return facts
    }

    /// The most recently written rollout across the date-nested folders.
    private static func newestRollout() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }

    /// The last `rate_limits` object in the file, scanning the tail backwards.
    private static func lastRateLimits(in url: URL) -> [String: Any]? {
        guard let data = tail(of: url), !data.isEmpty else { return nil }
        // A tail read can start mid-line; that fragment simply fails to parse.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            return limits
        }
        return nil
    }

    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return try? handle.readToEnd()
    }

    // MARK: Shared

    private static func emptyUsage() -> AgentUsage {
        AgentUsage(
            fiveHour: nil, sevenDay: nil, contextTokens: nil, sessionSeconds: nil,
            model: nil, contextWindow: nil, cwd: nil,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    private static func assign(_ window: UsageWindow, minutes: Int?, to usage: inout AgentUsage) {
        switch minutes {
        case fiveHourMinutes: usage.fiveHour = window
        case sevenDayMinutes: usage.sevenDay = window
        default: break
        }
    }
}
