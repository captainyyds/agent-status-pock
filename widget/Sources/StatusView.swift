import AppKit

/// Main widget view. Shows the live agent status with a shimmering label.
/// Bounded width while active, can collapse when all enabled agents are idle.
///
/// Attention tiers (from agent-status UX patterns):
/// - active (thinking/answering/working) → white text + shimmer sweep
/// - response ready                       → green breathing text
/// - ready / connected                    → brand-colored text, gentle pulse
/// - needs input                          → amber pulsing text
final class StatusView: NSView {

    /// Bounded width: wide enough for useful status text, but leaves room
    /// for Pock widgets and the system control strip on either side.
    /// Fixed while active. The view is laid out from its frame rather than
    /// its intrinsic size, so resizing it to fit the text drew over the
    /// neighbouring widget instead of pushing it along. Long text is handled
    /// by shrinking the type instead — see `ShimmerLabel.fit(to:)`.
    static let preferredWidth: CGFloat = 360

    // MARK: Callbacks

    var onTap: (() -> Void)?
    var onExpand: (() -> Void)?

    /// Bundle id of the agent app in front, when it is one. The bar follows
    /// whatever the user switched to rather than whatever spoke last.
    var preferredAgent: String? {
        didSet { guard preferredAgent != oldValue else { return }; pinned = false; refresh() } }

    /// Tap target on the left that opens the full-bar view. Wide enough to
    /// hit without looking, which is the whole point of a Touch Bar control.
    private static let expandZone: CGFloat = 38

    // MARK: Subviews

    private let iconView = NSImageView(frame: .zero)
    private let label = ShimmerLabel(frame: .zero)
    private let expandIcon = NSImageView(frame: .zero)

    // MARK: State

    private var agents: [BridgeClient.AgentInfo] = []
    private var activeAgents: [BridgeClient.AgentInfo] = []
    private var selectedIndex = 0
    private var pinned = false
    private var pinnedSince: Date?
    private var presentationWidth = StatusView.preferredWidth
    private var compactWhenIdle = false

    // Anti-flicker: a displayed agent stays displayed until it has been
    // quiet for this long while another agent is active.
    private let switchHysteresis: TimeInterval = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white
        iconView.wantsLayer = true
        expandIcon.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "Expand"
        )?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        expandIcon.contentTintColor = NSColor(calibratedWhite: 0.70, alpha: 1)
        expandIcon.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
        addSubview(expandIcon)

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: presentationWidth, height: 30)
    }

    override func layout() {
        super.layout()
        if presentationWidth <= 1 {
            iconView.isHidden = true
            label.isHidden = true
            expandIcon.isHidden = true
            return
        }
        if compactWhenIdle {
            label.isHidden = true
            expandIcon.isHidden = true
            iconView.isHidden = false
            iconView.frame = NSRect(
                x: max((bounds.width - 18) / 2, 0),
                y: (bounds.height - 18) / 2,
                width: 18,
                height: 18
            )
            return
        }
        label.isHidden = false
        iconView.isHidden = false
        expandIcon.isHidden = false
        expandIcon.frame = NSRect(
            x: 10,
            y: (bounds.height - 18) / 2,
            width: 18,
            height: 18
        )
        let maxTextWidth = max(bounds.width - 56 - Self.expandZone, 60)
        label.fit(to: maxTextWidth)
        let textWidth = min(label.measuredWidth, maxTextWidth)
        let groupWidth = 16 + 8 + textWidth
        let groupX = max(
            Self.expandZone + (bounds.width - Self.expandZone - groupWidth) / 2,
            Self.expandZone
        )
        iconView.frame = NSRect(x: groupX, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: groupX + 24, y: 0, width: textWidth, height: bounds.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Tap

    @objc private func handleTap(_ gesture: NSClickGestureRecognizer) {
        handleClick(at: gesture.location(in: self))
    }

    /// Shared by the touch gesture and Pock's cursor mode.
    func handleClick(at point: NSPoint) {
        if point.x < Self.expandZone, !compactWhenIdle {
            onExpand?()
        } else {
            onTap?()
        }
    }

    func cycleSelection() {
        guard activeAgents.count > 1 else { return }
        pinned = true
        pinnedSince = Date()
        selectedIndex = (selectedIndex + 1) % activeAgents.count
        refresh()
    }

    // MARK: State

    func apply(agents: [BridgeClient.AgentInfo]) {
        self.agents = agents
        activeAgents = agents.filter { $0.lastActive > 0 }

        if let pinnedSince = pinnedSince, Date().timeIntervalSince(pinnedSince) > 300 {
            pinned = false
            self.pinnedSince = nil
        }
        if !pinned || activeAgents.isEmpty {
            selectedIndex = displayedAgentIndex()
        }
        selectedIndex = min(selectedIndex, max(activeAgents.count - 1, 0))

        // Text first: the width below is measured from it.
        refresh()
        updateIdlePresentation()
        needsLayout = true
    }

    private func updateIdlePresentation() {
        let activeStatuses: Set<String> = [
            "connected", "thinking", "answering", "working",
            "needsInput", "responseReady"
        ]
        let hasAttention = activeAgents.contains { activeStatuses.contains($0.status) }
        let mode = AgentPrefs.visibilityMode
        let widgetEnabled = AgentPrefs.widgetEnabled && AgentPrefs.hasEnabledAgents
        let shouldCollapse = !hasAttention && mode != "always"

        compactWhenIdle = shouldCollapse
        let nextWidth: CGFloat
        if !widgetEnabled {
            nextWidth = 18
        } else if shouldCollapse {
            nextWidth = mode == "active" ? 18 : 36
        } else {
            nextWidth = Self.preferredWidth
        }
        guard nextWidth != presentationWidth else { return }
        presentationWidth = nextWidth
        alphaValue = (!widgetEnabled || (shouldCollapse && mode == "active")) ? 0.12 : 1
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    private func displayedAgentIndex() -> Int {
        guard !activeAgents.isEmpty else { return 0 }
        let currentID = activeAgents[selectedIndex].agent
        let now = Date().timeIntervalSince1970
        let currentQuietFor = now - activeAgents[selectedIndex].lastActive
        let busiest = activeAgents.first!
        if currentID == busiest.agent { return selectedIndex }
        if currentQuietFor < switchHysteresis { return selectedIndex }
        return 0
    }

    private func refresh() {
        guard let agent = currentAgent() else {
            iconView.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor(calibratedWhite: 0.45, alpha: 1)
            setDisplayText("No agent running", textColor: .white, shimmer: false)
            setAmbient(.none)
            return
        }
        let brand = NSColor(hex: agent.color) ?? .white
        iconView.image = logo(for: agent.agent)
            ?? NSImage(systemSymbolName: agent.symbol, accessibilityDescription: nil)

        var text = agent.label
        if let detail = agent.detail, !detail.isEmpty {
            text = "\(agent.label) · \(detail)"
        }

        let shimmerAllowed = AgentPrefs.shimmerEnabled
        switch agent.status {
        case "thinking":
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: .white, shimmer: shimmerAllowed)
            setAmbient(.none)
        case "answering":
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: .white, shimmer: shimmerAllowed)
            setAmbient(.none)
        case "working":
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: .white, shimmer: shimmerAllowed)
            setAmbient(.none)
        case "responseReady":
            iconView.contentTintColor = NSColor.systemGreen
            setDisplayText(text, textColor: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1), shimmer: false)
            setAmbient(.breathe)
        case "connected":
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: brand, shimmer: false)
            setAmbient(.breathe)
        case "needsInput":
            iconView.contentTintColor = NSColor.systemYellow
            setDisplayText(text, textColor: NSColor.systemYellow, shimmer: false)
            setAmbient(.breathe)
        default: // ready / idle
            iconView.contentTintColor = brand
            // "X is ready" says nothing you did not already know. What is
            // worth the space is how much of this agent is left.
            setDisplayText(Self.usageText(for: agent) ?? text, textColor: .white, shimmer: false)
            setAmbient(.pulse)
        }
    }

    private func setDisplayText(_ text: String, textColor: NSColor, shimmer: Bool) {
        label.textColor = textColor
        label.text = text
        label.setShimmering(shimmer && AgentPrefs.shimmerEnabled)
        needsLayout = true
        layout()
    }

    /// The agent to show. The app in front wins outright — switching to
    /// ChatGPT should move the bar to Codex even if Codex has never run this
    /// session — and otherwise the busiest one keeps the slot.
    func currentAgent() -> BridgeClient.AgentInfo? {
        if let preferred = preferredAgent,
           let match = agents.first(where: { $0.agent == preferred }) {
            return match
        }
        guard !activeAgents.isEmpty else { return nil }
        return activeAgents[min(selectedIndex, activeAgents.count - 1)]
    }

    /// Remaining quota, the way you would ask for it: how much is left and
    /// when it comes back. `nil` when the agent has not reported limits yet,
    /// in which case the caller keeps the plain status wording.
    static func usageText(for agent: BridgeClient.AgentInfo, includeReset: Bool = true) -> String? {
        guard let usage = agent.usage else { return nil }
        var parts: [String] = []
        if let window = usage.fiveHour {
            parts.append(String(format: "5h %.0f%%", max(0, 100 - window.usedPercent)))
        }
        if let window = usage.sevenDay {
            parts.append(String(format: "7d %.0f%%", max(0, 100 - window.usedPercent)))
        }
        // Claude publishes no windows; the size of the conversation is what it
        // does expose, and it answers the same question — how much room is left.
        if parts.isEmpty, let tokens = usage.contextTokens {
            return "context " + compactTokens(tokens)
        }
        guard !parts.isEmpty else { return nil }
        guard includeReset else { return parts.joined(separator: " · ") }
        if let soonest = [usage.fiveHour, usage.sevenDay]
            .compactMap({ $0?.resetsAt })
            .filter({ $0 > Date().timeIntervalSince1970 })
            .min() {
            parts.append("↻ " + resetWording(at: soonest))
        }
        return parts.joined(separator: " · ")
    }

    /// Token counts read at a glance: 472k rather than 471,606.
    private static func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return "\(tokens / 1_000)k"
        }
        return "\(tokens)"
    }

    /// A clock time for a reset later today, a weekday within the week, and a
    /// date beyond that — whichever answers "when" in the fewest characters.
    private static func resetWording(at timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let hoursAway = timestamp - Date().timeIntervalSince1970
        if hoursAway < 20 * 3600 {
            formatter.setLocalizedDateFormatFromTemplate("Hm")
        } else if hoursAway < 6 * 24 * 3600 {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("Md")
        }
        return formatter.string(from: date)
    }

    private func logo(for agent: String) -> NSImage? {
        Self.logoImage(for: agent)
    }

    static func logoImage(for agent: String) -> NSImage? {
        let resource: String
        switch agent {
        case "claude": resource = "Claude"
        case "codex": resource = "ChatGPT"
        case "opencode": resource = "OpenCode"
        default: return nil
        }
        guard let image = Bundle(for: StatusView.self).image(forResource: resource) else {
            return nil
        }
        image.isTemplate = false
        return image
    }

    // MARK: Ambient animation

    private enum Ambient {
        case none
        case pulse      // ready: gentle
        case breathe    // response ready / needs input: stronger
    }

    private var ambient: Ambient = .none

    private func setAmbient(_ mode: Ambient) {
        guard mode != ambient else { return }
        ambient = mode
        iconView.layer?.removeAnimation(forKey: "ambientPulse")
        switch mode {
        case .none:
            iconView.layer?.opacity = 1
        case .pulse:
            addAmbientAnimation(from: 0.55, to: 1.0, duration: 2.2)
        case .breathe:
            addAmbientAnimation(from: 0.35, to: 1.0, duration: 1.4)
        }
    }

    private func addAmbientAnimation(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconView.layer?.add(animation, forKey: "ambientPulse")
    }
}