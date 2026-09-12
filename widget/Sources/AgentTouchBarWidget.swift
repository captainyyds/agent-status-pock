import AppKit
import PockKit

/// Agent Status widget for Pock.
///
/// Shows live activity (thinking / editing / searching ...) of coding agents
/// (Claude Code, Codex, OpenCode) with a shimmering status label. Data comes
/// from the local AgentBridge daemon.
public final class AgentTouchBarWidget: NSObject, PKWidget {

    // MARK: Protocol compatibility

    @available(*, deprecated, message: "Identifier is read from the bundle's Info.plist")
    public static var identifier: String = "com.touchbar.agentstatus"

    @objc public var identifier: NSTouchBarItem.Identifier = NSTouchBarItem.Identifier("com.touchbar.agentstatus")

    public var customizationLabel = "Agent Status"
    public var view: NSView!

    private static weak var shared: AgentTouchBarWidget?

    @objc public static func viewWillAppear() { shared?.viewWillAppear() }
    @objc public static func viewDidAppear() { shared?.viewDidAppear() }
    @objc public static func viewWillDisappear() { shared?.viewWillDisappear() }
    @objc public static func viewDidDisappear() { shared?.viewDidDisappear() }
    @objc public static func prepareForCustomization() { shared?.prepareForCustomization() }
    @objc public static var imageForCustomization: NSImage { makeCustomizationImage() }

    @objc public func viewDidAppear() {}
    @objc public func viewWillDisappear() {}
    @objc public func prepareForCustomization() {}
    @objc public var imageForCustomization: NSImage { Self.makeCustomizationImage() }

    private static func makeCustomizationImage() -> NSImage {
        let size = NSSize(width: 118, height: 30)
        return NSImage(size: size, flipped: false) { rect in
            if let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
                icon.draw(in: NSRect(x: 10, y: (rect.height - 15) / 2, width: 15, height: 15))
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = "Agent Status" as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: 33, y: (rect.height - textSize.height) / 2), withAttributes: attrs)
            return true
        }
    }

    // MARK: State

    private let statusView: StatusView
    private let client = BridgeClient()
    private var pollTimer: Timer?
    private var isPolling = false
    private let expanded = ExpandedController()
    private var frontmostObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var retired: Set<String> = []
    private var latestAgents: [BridgeClient.AgentInfo] = []

    /// Which agent each app stands for. Switching to ChatGPT should move the
    /// bar to Codex; switching to anything else leaves the choice alone.
    private static let agentByBundleID: [String: String] = [
        "com.anthropic.claudefordesktop": "claude",
        "com.openai.codex": "codex",
    ]

    override public required init() {
        statusView = StatusView(frame: NSRect(x: 0, y: 0, width: StatusView.preferredWidth, height: 30))
        super.init()
        view = statusView
        statusView.onTap = { [weak self] in
            self?.statusView.cycleSelection()
        }
        statusView.onExpand = { [weak self] in
            self?.toggleExpanded()
        }
        expanded.onDismiss = { [weak self] in
            self?.statusView.needsLayout = true
        }
        AgentTouchBarWidget.shared = self
        observeFrontmostApp()
    }

    // MARK: Lifecycle

    @objc public func viewWillAppear() {
        refreshRetirement(midTurn: [])
        applyFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        startPolling()
    }

    // MARK: Expanded view

    private func toggleExpanded() {
        if expanded.isVisible {
            expanded.hide()
        } else {
            expanded.show(agent: statusView.currentAgent())
        }
    }

    // MARK: Following the front app

    private func observeFrontmostApp() {
        let center = NSWorkspace.shared.notificationCenter
        frontmostObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.applyFrontmost(app?.bundleIdentifier)
        }

        // An agent whose application has quit should leave the bar at once
        // rather than sit on its last status until a timeout notices.
        for (name, retiring) in [(NSWorkspace.didTerminateApplicationNotification, true),
                                 (NSWorkspace.didLaunchApplicationNotification, false)] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      let agent = Self.agentByBundleID[bundleID] else { return }
                if retiring { self.retired.insert(agent) } else { self.retired.remove(agent) }
                self.statusView.retiredAgents = self.retired
            })
        }
    }

    /// Re-derives which agents have no application running. Catching the
    /// termination notification is not enough on its own — miss one, because
    /// the widget was reloading or Pock restarted, and the bar stays wrong for
    /// ever. Deriving it from what is actually running is self-correcting.
    ///
    /// A busy agent is never retired: Claude Code also runs in a terminal,
    /// where there is no application to find, and its events are proof enough.
    private func refreshRetirement(midTurn: Set<String>) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var next: Set<String> = []
        for (bundleID, agent) in Self.agentByBundleID
        where !running.contains(bundleID) && !midTurn.contains(agent) {
            next.insert(agent)
        }
        guard next != retired else { return }
        retired = next
        statusView.retiredAgents = retired
    }

    /// An app that is not one of the agents leaves the current choice standing,
    /// so switching to an editor does not blank the bar.
    private func applyFrontmost(_ bundleID: String?) {
        guard let bundleID, let agent = Self.agentByBundleID[bundleID] else { return }
        // Bringing an app forward proves it is running, whatever we thought.
        if retired.remove(agent) != nil { statusView.retiredAgents = retired }
        statusView.preferredAgent = agent
    }

    @objc public func viewDidDisappear() {
        stopPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        client.fetchState { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPolling = false
                if let state = state {
                    self.latestAgents = state.agents
                    let midTurn = Set(state.agents.filter { StatusView.isMidTurn($0.status) }.map(\.agent))
                    self.refreshRetirement(midTurn: midTurn)
                    self.statusView.apply(agents: state.agents)
                    if self.expanded.isVisible {
                        self.expanded.update(agent: self.statusView.currentAgent())
                    }
                }
            }
        }
    }
}

// MARK: - Cursor-mode clicks

extension AgentTouchBarWidget: PKScreenEdgeMouseDelegate {

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseClickAtLocation location: NSPoint, in view: NSView) {
        guard let statusView = self.view as? StatusView else { return }
        let local = statusView.convert(location, from: view)
        if statusView.bounds.contains(local) {
            // Same split as the touch path: right edge expands, rest cycles.
            statusView.handleClick(at: local)
        }
    }

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseEnteredAtLocation location: NSPoint, in view: NSView) {}

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseMovedAtLocation location: NSPoint, in view: NSView) {}

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseExitedAtLocation location: NSPoint, in view: NSView) {}
}