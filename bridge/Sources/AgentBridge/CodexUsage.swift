import Foundation

/// Reads Codex's rate limits out of Codex's own session logs.
///
/// Codex appends a `rate_limits` payload to the rollout it keeps at
/// `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`, so the numbers are
/// already on disk. Reading them there keeps this entirely local: no token, no
/// network call, nothing for the user to authorise.
///
/// The two windows are identified by `window_minutes` rather than by position,
/// because "primary" and "secondary" are Codex's names for them, not ours:
/// 300 minutes is the five-hour window, 10080 the seven-day one.
enum CodexUsage {

    /// Only the tail of a rollout is read. A long session's file reaches
    /// megabytes and the limits are always near the end.
    private static let tailBytes = 256 * 1024

    private static let fiveHourMinutes = 300
    private static let sevenDayMinutes = 10080

    static func read() -> AgentUsage? {
        guard let url = newestRollout(), let limits = lastRateLimits(in: url) else { return nil }


        let session = sessionFacts(in: url)
        var usage = AgentUsage(
            fiveHour: nil, sevenDay: nil,
            contextTokens: session.contextTokens,
            sessionSeconds: nil,
            model: session.model,
            contextWindow: session.contextWindow,
            cwd: session.cwd,
            updatedAt: Date().timeIntervalSince1970
        )
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double,
                  let resets = window["resets_at"] as? Double else { continue }
            let entry = UsageWindow(usedPercent: used, resetsAt: resets)
            switch window["window_minutes"] as? Int {
            case fiveHourMinutes: usage.fiveHour = entry
            case sevenDayMinutes: usage.sevenDay = entry
            default: break
            }
        }
        return (usage.fiveHour == nil && usage.sevenDay == nil) ? nil : usage
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
        guard let handle = try? FileHandle(forReadingFrom: url) else { return facts }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return facts }

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
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // A tail read can start mid-line; that fragment simply fails to parse.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            return limits
        }
        return nil
    }
}
