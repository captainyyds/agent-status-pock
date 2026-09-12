import Foundation

/// Reads how much context the current Claude Code session is carrying.
///
/// Claude Code does not publish its five-hour or weekly limits anywhere on
/// disk — the only place those appear is the status line payload, which the
/// desktop app never asks for. What the transcript does carry is a `usage`
/// block on every assistant message, and the newest one describes the context
/// that turn was sent: fresh input, plus whatever was read from or written to
/// the prompt cache. Summed, that is the size of the conversation right now,
/// which is the more actionable number anyway.
enum ClaudeUsage {

    /// Transcripts reach megabytes; the newest turn is at the end.
    private static let tailBytes = 512 * 1024

    struct Reading {
        var contextTokens: Int?
        var sessionSeconds: Double?
        var model: String?
    }

    static func read() -> Reading? {
        guard let url = newestTranscript() else { return nil }

        var reading = Reading()
        if let message = lastMessage(in: url) {
            if let usage = message["usage"] as? [String: Any] {
                let fields = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                let total = fields.reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                reading.contextTokens = total > 0 ? total : nil
            }
            reading.model = message["model"] as? String
        }
        reading.sessionSeconds = elapsed(in: url)
        return (reading.contextTokens == nil && reading.sessionSeconds == nil) ? nil : reading
    }

    /// Wall time across the session, from the head's first stamp to the tail's
    /// last. Both ends are read directly; the megabytes between them are not
    /// touched, which matters when this runs every half minute.
    private static func elapsed(in url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let tail = (try? handle.readToEnd()) ?? Data()

        guard let start = firstStamp(in: head, reversed: false),
              let end = firstStamp(in: tail, reversed: true),
              end > start else { return nil }
        return end - start
    }

    private static func firstStamp(in data: Data, reversed: Bool) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in (reversed ? Array(lines.reversed()) : Array(lines)) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let stamp = object["timestamp"] as? String else { continue }
            if let date = formatter.date(from: stamp) ?? plain.date(from: stamp) {
                return date.timeIntervalSince1970
            }
        }
        return nil
    }

    private static func newestTranscript() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }

    /// The last assistant `message` in the file, scanning the tail backwards.
    /// It carries both the usage block and the model that turn ran on.
    private static func lastMessage(in url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // A tail read can begin mid-line; that fragment simply fails to parse.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  message["usage"] != nil else { continue }
            return message
        }
        return nil
    }
}
