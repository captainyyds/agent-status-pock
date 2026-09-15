import Foundation
import AppKit

final class BridgeClient {

    struct UsageWindow: Codable {
        let usedPercent: Double
        let resetsAt: Double
    }

    struct AgentUsage: Codable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let contextTokens: Int?
        let sessionSeconds: Double?
        let model: String?
        let contextWindow: Int?
        let cwd: String?
        let updatedAt: Double
    }

    struct AgentInfo: Codable {
        let agent: String
        let name: String
        let symbol: String
        let color: String
        let status: String
        let label: String
        let tool: String?
        let detail: String?
        let lastActive: Double
        let cwd: String?
        let usage: AgentUsage?
    }

    struct BridgeState: Codable {
        let agents: [AgentInfo]
    }

    private let baseURL: URL
    private let session: URLSession

    init() {
        let env = ProcessInfo.processInfo.environment
        let urlString = env["AGENTBRIDGE_URL"] ?? "http://127.0.0.1:3939"
        baseURL = URL(string: urlString) ?? URL(string: "http://127.0.0.1:3939")!
        let config = URLSessionConfiguration.ephemeral
        // Long enough to outlast a parked request. The bridge holds a state
        // request until something changes, so a two-second timeout would have
        // cancelled every one of them.
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Asks for the state and waits for it to differ from `fingerprint`.
    ///
    /// Passing nil answers immediately; passing the fingerprint from the last
    /// answer parks the request on the bridge until the bar would look
    /// different. That turns a poll several times a second into one idle
    /// connection, and delivers a change the moment it happens rather than on
    /// the next tick.
    @discardableResult
    func watchState(
        since fingerprint: String?,
        completion: @escaping (BridgeState?, String?) -> Void
    ) -> URLSessionTask {
        // Built through URLComponents, not by pasting a query onto a path.
        // `appendingPathComponent` treats the whole string as one path
        // component and percent-encodes the "?" into "%3F", so the query became
        // part of the path, the bridge saw no parameters and answered 404 —
        // which sent this straight to the error branch, cleared the
        // fingerprint, and backed off two seconds before asking again without
        // one. The long poll never actually parked: it was two-second polling
        // with a wasted 404 every cycle.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/state"),
            resolvingAgainstBaseURL: false
        )
        if let fingerprint {
            components?.queryItems = [
                URLQueryItem(name: "since", value: fingerprint),
                URLQueryItem(name: "wait", value: "25"),
            ]
        }
        guard let url = components?.url else {
            completion(nil, nil)
            return URLSession.shared.dataTask(with: baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let task = session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data else {
                completion(nil, nil)
                return
            }
            let state = try? JSONDecoder().decode(BridgeState.self, from: data)
            completion(state, http.value(forHTTPHeaderField: "X-State-Fingerprint"))
        }
        task.resume()
        return task
    }
}

// MARK: - Shared preferences

enum AgentPrefs {
    static let suiteName = "com.touchbar.agentstatus"
    static let changedNotification = Notification.Name("AgentTouchBarPreferencesChanged")

    static var defaults: UserDefaults {
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var widgetEnabled: Bool {
        if defaults.object(forKey: "widgetEnabled") == nil { return true }
        return defaults.bool(forKey: "widgetEnabled")
    }

    static func isAgentEnabled(_ id: String) -> Bool {
        let dict = defaults.dictionary(forKey: "enabledAgents")
        if let dict = dict, let enabled = dict[id] as? Bool {
            return enabled
        }
        return true
    }

    static var shimmerEnabled: Bool {
        if defaults.object(forKey: "shimmerEnabled") == nil { return true }
        return defaults.bool(forKey: "shimmerEnabled")
    }

    /// always: full ready state, compact: 36pt logo while idle,
    /// active: near-hidden 18pt anchor while idle (keeps Pock expandable).
    static var visibilityMode: String {
        if let mode = defaults.string(forKey: "visibilityMode") { return mode }
        // Migrate the previous boolean preference.
        return showOnlyWhileActive ? "compact" : "always"
    }

    static var hasEnabledAgents: Bool {
        return ["claude", "codex", "opencode"].contains { isAgentEnabled($0) }
    }

    static var showOnlyWhileActive: Bool {
        if defaults.object(forKey: "showOnlyWhileActive") == nil { return false }
        return defaults.bool(forKey: "showOnlyWhileActive")
    }

    /// `hidden` returns the Touch Bar space to neighboring items; `icon`
    /// keeps a compact 36pt neutral indicator while agents are idle.
    static var idlePresentation: String {
        return defaults.string(forKey: "idlePresentation") ?? "hidden"
    }
}

// MARK: - Color helper

extension NSColor {
    convenience init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
