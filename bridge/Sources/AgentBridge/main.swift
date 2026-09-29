import Foundation

let port = UInt16(ProcessInfo.processInfo.environment["AGENTBRIDGE_PORT"] ?? "3939") ?? 3939

let hub = AgentHub()
let server = HTTPServer(hub: hub, port: port)

signal(SIGPIPE, SIG_IGN)

// Limits are read once now, so there is something to show, and after that only
// when they can have moved: a turn ending, or the agent being brought to the
// front. See `AgentHub.requestUsage`. Nothing is read on a timer.
hub.requestUsage(for: .codex, force: true)
hub.requestUsage(for: .claude, force: true)

// The accept loop blocks for as long as the bridge lives, so it gets a thread
// of its own. It used to run right here on the main thread, which meant the run
// loop below was never reached — so the refresh timer that used to sit above
// never fired once, and limits read at launch were served unchanged for
// fourteen days, long after both of Codex's windows had reset.
Thread.detachNewThread {
    do {
        try server.start()
    } catch {
        fputs("[AgentBridge] failed to start: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()