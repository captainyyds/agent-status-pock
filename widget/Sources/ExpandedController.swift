import AppKit
import PockKit

/// The whole Touch Bar, laid out as fields rather than a sentence.
///
/// The collapsed widget has 360 points and one line, so it can only ever say
/// one thing. Taking the bar over gives about a thousand, and the useful shape
/// for that is a row of labelled fields filling the full height — the state,
/// the tool, the command that was being cut off, and whatever numbers apply.
/// Tapping anywhere hands the bar back.
final class ExpandedController: PKTouchBarController {

    private static let itemIdentifier = NSTouchBarItem.Identifier("com.touchbar.agentstatus.expanded")

    /// Room for the collapse control and the agent mark, both on the left.
    private static let iconStrip: CGFloat = 64

    /// Only this strip collapses the bar. Dismiss-on-any-tap reads as a
    /// misfire: the expanded bar is something you opened in order to read,
    /// and brushing the command you came to look at should not close it.
    private static let collapseZone: CGFloat = 34
    private static let barHeight: CGFloat = 30
    private static let gutter: CGFloat = 22

    var onDismiss: (() -> Void)?

    private let container = ResizingView(frame: NSRect(x: 0, y: 0, width: 1000, height: barHeight))
    private var currentFields: [Field] = []
    private let collapseIcon = NSImageView(frame: .zero)
    private let agentIcon = NSImageView(frame: .zero)
    private var fieldViews: [FieldView] = []

    // MARK: Content

    private struct Field {
        let caption: String
        let value: String
        /// The one field that absorbs whatever width is left — the command.
        var greedy: Bool = false
    }

    func update(agent: BridgeClient.AgentInfo?) {
        agentIcon.image = agent.flatMap { StatusView.logoImage(for: $0.agent) }
        agentIcon.isHidden = agentIcon.image == nil
        currentFields = Self.fields(for: agent)
        layoutFields(currentFields)
    }

    func show(agent: BridgeClient.AgentInfo?) {
        guard !isVisible else { return }
        touchBar = makeExpandedTouchBar()
        update(agent: agent)
        present()
    }

    func hide() {
        guard isVisible else { return }
        dismiss()
        onDismiss?()
    }

    /// Two modes, and they do not overlap. A working agent is asked one
    /// question — what are you running — so the command takes the bar and
    /// nothing competes with it. An idle one has no answer to that, so the
    /// space goes to what it has left instead.
    private static func fields(for agent: BridgeClient.AgentInfo?) -> [Field] {
        guard let agent else { return [Field(caption: "agent", value: "none running")] }

        let busy = ["working", "thinking", "answering", "needsInput", "connected", "responseReady"]
        if busy.contains(agent.status) {
            var fields = [Field(caption: "state", value: agent.label)]
            if let tool = agent.tool, !tool.isEmpty, tool != agent.label {
                fields.append(Field(caption: "tool", value: tool))
            }
            if let detail = agent.detail, !detail.isEmpty {
                fields.append(Field(caption: "command", value: detail, greedy: true))
            }
            return fields
        }

        // Idle: the logo says which agent, so the fields say which model, which
        // project, and how much is left.
        var fields: [Field] = []
        if let model = agent.usage?.model, !model.isEmpty {
            fields.append(Field(caption: "model", value: Self.shortModel(model)))
        }
        // A hook reports the directory live; an agent that logs its own gets
        // used as the fallback, which is how Codex fills this in.
        if let cwd = agent.cwd ?? agent.usage?.cwd, !cwd.isEmpty {
            fields.append(Field(caption: "project", value: (cwd as NSString).lastPathComponent))
        }
        if let usage = agent.usage {
            if let window = usage.fiveHour {
                fields.append(Field(caption: "5h left",
                                    value: String(format: "%.0f%%", max(0, 100 - window.usedPercent))))
            }
            if let window = usage.sevenDay {
                fields.append(Field(caption: "7d left",
                                    value: String(format: "%.0f%%", max(0, 100 - window.usedPercent))))
            }
            if let reset = [usage.fiveHour, usage.sevenDay]
                .compactMap({ $0?.resetsAt })
                .filter({ $0 > Date().timeIntervalSince1970 })
                .min() {
                fields.append(Field(caption: "resets", value: Self.clock(reset)))
            }
            if let tokens = usage.contextTokens {
                // A share beats a count, but only an agent that states its
                // window size can be shown one. Claude does not, so it gets
                // the raw figure instead of an invented denominator.
                if let window = usage.contextWindow, window > 0 {
                    fields.append(Field(
                        caption: "context",
                        value: String(format: "%.0f%%", min(100, Double(tokens) / Double(window) * 100))
                    ))
                } else {
                    fields.append(Field(caption: "context", value: Self.compact(tokens)))
                }
            }
            if let seconds = usage.sessionSeconds, seconds > 60 {
                fields.append(Field(caption: "session", value: Self.duration(seconds)))
            }
        }
        if fields.isEmpty {
            fields.append(Field(caption: "state", value: agent.label))
        }
        return fields
    }

    // MARK: Layout

    private func layoutFields(_ fields: [Field]) {
        fieldViews.forEach { $0.removeFromSuperview() }
        fieldViews = fields.map { field in
            let view = FieldView()
            view.apply(caption: field.caption, value: field.value)
            container.addSubview(view)
            return view
        }

        guard !fields.isEmpty else { return }
        let available = container.bounds.width - Self.iconStrip - 12
        let gutters = CGFloat(fields.count - 1) * Self.gutter
        var widths = zip(fields, fieldViews).map { field, view in
            field.greedy ? 0 : view.naturalWidth
        }
        let greedyCount = fields.filter { $0.greedy }.count

        // Fixed fields come first and are never cut: a caption reading "CONT"
        // is worse than no field at all. If they cannot all fit, scale them
        // down together rather than letting the tail fall off the bar.
        let fixed = widths.reduce(0, +)
        let room = available - gutters - (greedyCount > 0 ? 80 : 0)
        if fixed > room, fixed > 0 {
            let scale = max(room / fixed, 0.1)
            widths = widths.map { $0 * scale }
        }
        let slack = max(available - gutters - widths.reduce(0, +), 0)

        var x = Self.iconStrip
        for (index, field) in fields.enumerated() {
            let width = field.greedy
                ? max(slack / CGFloat(max(greedyCount, 1)), 80)
                : widths[index]
            fieldViews[index].frame = NSRect(x: x, y: 0, width: width, height: Self.barHeight)
            x += width + Self.gutter
        }
    }

    private func makeExpandedTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.itemIdentifier]
        return bar
    }

    public func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else { return nil }

        collapseIcon.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: "Collapse"
        )?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        collapseIcon.contentTintColor = .white
        collapseIcon.imageScaling = .scaleProportionallyDown
        collapseIcon.frame = NSRect(x: 10, y: (Self.barHeight - 18) / 2, width: 18, height: 18)

        agentIcon.imageScaling = .scaleProportionallyDown
        agentIcon.frame = NSRect(x: 38, y: (Self.barHeight - 18) / 2, width: 18, height: 18)

        container.addSubview(collapseIcon)
        container.addSubview(agentIcon)
        // The system sizes this view; 1000 above is only a starting guess, and
        // laying fields out against it would push the last ones off the bar.
        container.onLayout = { [weak self] in
            guard let self else { return }
            self.layoutFields(self.currentFields)
        }

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = .direct
        container.addGestureRecognizer(tap)

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = container
        return item
    }

    @objc private func handleTap(_ gesture: NSClickGestureRecognizer) {
        guard gesture.location(in: container).x < Self.collapseZone else { return }
        hide()
    }

    // MARK: Formatting

    /// Drops the vendor prefix only. The logo beside it already says Claude,
    /// and anything cleverer risks mangling a name we have not seen yet.
    private static func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    private static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(tokens / 1_000)k" }
        return "\(tokens)"
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static func clock(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

/// A view that tells its owner when the system has resized it.
private final class ResizingView: NSView {
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        onLayout?()
    }
}

// MARK: - One labelled field

/// A caption over a value, stacked to fill the bar's full height rather than
/// floating one small line in the middle of it.
private final class FieldView: NSView {

    private let captionLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        captionLabel.font = .systemFont(ofSize: 9, weight: .medium)
        captionLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.45)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.usesSingleLineMode = true
        captionLabel.cell?.wraps = false
        valueLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.usesSingleLineMode = true
        valueLabel.cell?.wraps = false
        addSubview(captionLabel)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(caption: String, value: String) {
        captionLabel.stringValue = caption.uppercased()
        valueLabel.stringValue = value
        needsLayout = true
    }

    /// Width the pair wants before any squeezing. Measured from the strings:
    /// `intrinsicContentSize` on a label set to truncate reports the truncated
    /// width, which is how "CONTEXT" ended up rendering as "CONT". The pad
    /// covers NSTextField's own inset, without which the last glyph clips.
    var naturalWidth: CGFloat {
        func width(_ field: NSTextField) -> CGFloat {
            guard let font = field.font else { return 0 }
            return (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        }
        return max(width(captionLabel), width(valueLabel)) + 8
    }

    /// Each row is given its font's full line height rather than a guessed
    /// one: 15pt type in a 17pt box was being sliced through the middle.
    override func layout() {
        super.layout()
        let valueHeight = ceil(valueLabel.font?.boundingRectForFont.height ?? 18) + 2
        let captionHeight = max(bounds.height - valueHeight, 10)
        valueLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: valueHeight)
        captionLabel.frame = NSRect(
            x: 0,
            y: valueHeight,
            width: bounds.width,
            height: captionHeight
        )
    }
}
