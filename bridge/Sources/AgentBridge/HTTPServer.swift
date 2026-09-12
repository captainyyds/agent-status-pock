import Foundation

// MARK: - HTTP request

struct HTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var version: String = "HTTP/1.1"
    var connection: String = ""
    var body: Data = Data()

    /// RFC 7230: 1.1 holds the connection open unless asked not to, 1.0 only
    /// when asked to.
    var wantsKeepAlive: Bool {
        let token = connection.lowercased()
        if token.contains("close") { return false }
        if version.hasSuffix("1.0") { return token.contains("keep-alive") }
        return true
    }

    func jsonBody() -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

// MARK: - HTTP server (POSIX sockets, thread-per-connection)

final class HTTPServer: @unchecked Sendable {

    private let hub: AgentHub
    private let port: UInt16
    private var listenFd: Int32 = -1
    private var running = true

    /// How long a kept-alive connection may sit idle. Each connection owns a
    /// thread, so one that goes quiet has to be let go.
    private static let idleTimeout: Int32 = 15

    init(hub: AgentHub, port: UInt16) {
        self.hub = hub
        self.port = port
    }

    func start() throws {
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw ServerError.socket(errno) }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ServerError.bind(errno) }
        guard listen(listenFd, 32) == 0 else { throw ServerError.listen(errno) }

        print("[AgentBridge] listening on http://127.0.0.1:\(port)")

        while running {
            let clientFd = accept(listenFd, nil, nil)
            guard clientFd >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(clientFd)
            }
        }
    }

    func stop() {
        running = false
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
    }

    // MARK: Connection handling

    private enum ReadOutcome {
        case request(HTTPRequest)
        /// The peer hung up, or the connection sat idle past the ceiling.
        case closed
        case malformed
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int32) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Serves requests on one connection until the peer goes away, the
    /// connection sits idle, or a request asks to close.
    ///
    /// The widget polls several times a second. Closing after every response
    /// turned each poll into a fresh TCP connection, and the spent sockets
    /// piled into TIME_WAIT faster than the kernel drained them.
    private func handle(_ fd: Int32) {
        defer { close(fd) }
        setReadTimeout(fd, seconds: Self.idleTimeout)

        while running {
            switch readRequest(fd) {
            case .closed:
                return
            case .malformed:
                writeResponse(fd, status: 400, json: ["error": "bad request"], keepAlive: false)
                return
            case .request(let request):
                let keepAlive = request.wantsKeepAlive
                route(request, fd: fd, keepAlive: keepAlive)
                guard keepAlive else { return }
            }
        }
    }

    /// Reads one request. Assumes the peer waits for each response before
    /// sending the next, which every client here does; a pipelined request
    /// arriving inside the same read would be dropped.
    private func readRequest(_ fd: Int32) -> ReadOutcome {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var total = 0
        var headerEnd: Int?

        while total < buffer.count {
            let n = read(fd, &buffer[total], buffer.count - total)
            if n <= 0 { break }
            total += n
            if headerEnd == nil {
                if let range = Data(buffer[0..<total]).range(of: Data("\r\n\r\n".utf8)) {
                    headerEnd = range.endIndex
                    break
                }
            }
        }

        // Nothing at all means the peer closed or the read timed out.
        guard total > 0 else { return .closed }
        guard let headerLength = headerEnd else { return .malformed }
        let headerData = Data(buffer[0..<headerLength])
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .malformed }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .malformed }

        var request = HTTPRequest()
        request.method = String(parts[0]).uppercased()
        request.path = String(parts[1])
        if parts.count >= 3 { request.version = String(parts[2]) }

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            } else if name == "connection" {
                request.connection = value
            }
        }

        if contentLength > 0 {
            var body = Data(buffer[headerLength..<min(total, buffer.count)])
            while body.count < contentLength && body.count < 4_000_000 {
                var chunk = [UInt8](repeating: 0, count: min(65536, contentLength - body.count))
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                body.append(contentsOf: chunk[0..<n])
            }
            request.body = body.prefix(contentLength)
        }
        return .request(request)
    }

    // MARK: Router

    private func route(_ request: HTTPRequest, fd: Int32, keepAlive: Bool) {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        switch (request.method, path) {
        case ("GET", "/v1/health"):
            writeResponse(fd, status: 200, json: ["ok": true], keepAlive: keepAlive)

        case ("GET", "/v1/state"):
            let state = hub.snapshot()
            writeResponse(fd, status: 200, encodable: state, keepAlive: keepAlive)

        case ("POST", "/v1/usage"):
            guard let body = request.jsonBody() else {
                writeResponse(fd, status: 400, json: ["error": "invalid body"], keepAlive: keepAlive)
                return
            }
            let agent = AgentID(rawValue: body["agent"] as? String ?? "") ?? .claude
            func window(_ key: String) -> UsageWindow? {
                guard let raw = body[key] as? [String: Any],
                      let used = raw["used_percent"] as? Double,
                      let resets = raw["resets_at"] as? Double else { return nil }
                return UsageWindow(usedPercent: used, resetsAt: resets)
            }
            let reported = AgentUsage(
                fiveHour: window("five_hour"),
                sevenDay: window("seven_day"),
                contextTokens: body["context_tokens"] as? Int,
                sessionSeconds: body["session_seconds"] as? Double,
                model: body["model"] as? String,
                contextWindow: body["context_window"] as? Int,
                cwd: body["cwd"] as? String,
                updatedAt: Date().timeIntervalSince1970
            )
            hub.recordUsage(reported, for: agent)
            writeResponse(fd, status: 200, json: ["ok": true], keepAlive: keepAlive)

        case ("POST", "/v1/event"):
            guard let body = request.jsonBody() else {
                writeResponse(fd, status: 400, json: ["error": "invalid body"], keepAlive: keepAlive)
                return
            }
            let agent = AgentID(rawValue: body["agent"] as? String ?? "") ?? .claude
            let event = body["event"] as? String ?? ""
            let tool = body["tool"] as? String
            let detail = body["detail"] as? String
            let ts = body["ts"] as? Double
            hub.record(event: event, agent: agent, tool: tool, detail: detail, ts: ts,
                       cwd: body["cwd"] as? String)
            writeResponse(fd, status: 200, json: ["ok": true], keepAlive: keepAlive)

        default:
            writeResponse(fd, status: 404, json: ["error": "not found"], keepAlive: keepAlive)
        }
    }

    // MARK: Response writer

    private func writeResponse(_ fd: Int32, status: Int, json: [String: Any], keepAlive: Bool) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data("{}".utf8)
        write(fd, data: data, status: status, keepAlive: keepAlive)
    }

    private func writeResponse(_ fd: Int32, status: Int, encodable: Encodable, keepAlive: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(encodable)) ?? Data("{}".utf8)
        write(fd, data: data, status: status, keepAlive: keepAlive)
    }

    private func write(_ fd: Int32, data: Data, status: Int, keepAlive: Bool) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(data.count)\r\n"
        if keepAlive {
            head += "Connection: keep-alive\r\n"
            head += "Keep-Alive: timeout=\(Self.idleTimeout)\r\n\r\n"
        } else {
            head += "Connection: close\r\n\r\n"
        }
        var out = Data(head.utf8)
        out.append(data)
        out.withUnsafeBytes { buffer in
            var sent = 0
            while sent < out.count {
                let n = out[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                sent += n
            }
        }
    }

    enum ServerError: Error {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }
}
