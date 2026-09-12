import Foundation

let port = UInt16(ProcessInfo.processInfo.environment["AGENTBRIDGE_PORT"] ?? "3939") ?? 3939

let hub = AgentHub()
let server = HTTPServer(hub: hub, port: port)

signal(SIGPIPE, SIG_IGN)

// Codex publishes its limits to disk rather than through a hook, so they are
// picked up on a timer instead of on an event.
hub.refreshCodexUsage()
hub.refreshClaudeUsage()
let usageTimer = Timer(timeInterval: 30, repeats: true) { _ in
    hub.refreshCodexUsage()
    hub.refreshClaudeUsage()
}
RunLoop.main.add(usageTimer, forMode: .common)

do {
    try server.start()
} catch {
    fputs("[AgentBridge] failed to start: \(error)\n", stderr)
    exit(1)
}

RunLoop.main.run()