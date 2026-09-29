import Foundation

let port = UInt16(ProcessInfo.processInfo.environment["AGENTBRIDGE_PORT"] ?? "3939") ?? 3939

let hub = AgentHub()
let server = HTTPServer(hub: hub, port: port)

signal(SIGPIPE, SIG_IGN)

// Neither agent hands its limits to a hook, so they are picked up on timers.
//
// Claude's come from files on disk and cost nothing to re-read, so every thirty
// seconds. Codex's have to be asked of the Codex client, which means starting
// one and a request to the backend, so every five minutes: its windows are
// hours and days long, and a reading five minutes old is not a stale one.
DispatchQueue.global(qos: .utility).async {
    hub.refreshCodexUsage()
    hub.refreshClaudeUsage()
}
let claudeTimer = Timer(timeInterval: 30, repeats: true) { _ in
    DispatchQueue.global(qos: .utility).async { hub.refreshClaudeUsage() }
}
let codexTimer = Timer(timeInterval: 300, repeats: true) { _ in
    DispatchQueue.global(qos: .utility).async { hub.refreshCodexUsage() }
}
RunLoop.main.add(claudeTimer, forMode: .common)
RunLoop.main.add(codexTimer, forMode: .common)

// The accept loop blocks for as long as the bridge lives, so it gets a thread
// of its own. It used to run right here on the main thread, which meant the run
// loop below was never reached and neither timer above ever fired: limits were
// read once at launch and served unchanged for as long as the bridge ran —
// measured at fourteen days, long after both of Codex's windows had reset.
Thread.detachNewThread {
    do {
        try server.start()
    } catch {
        fputs("[AgentBridge] failed to start: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()