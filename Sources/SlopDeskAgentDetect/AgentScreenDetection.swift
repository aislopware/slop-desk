import Foundation

/// The four-way agent state a manifest rule resolves to (herdr `AgentState`, ported 1:1).
public enum AgentScreenState: String, Sendable, Equatable {
    /// Agent finished, prompt visible, nothing happening.
    case idle
    /// Actively processing.
    case working
    /// Needs human input.
    case blocked
    /// Plain shell / unrecognized — or a `skip_state_update` freeze rule.
    case unknown
}

/// One evaluation input snapshot (herdr `DetectionInput`): the caller supplies the already
/// trimmed/joined recent screen text plus the latest raw OSC title and OSC 9 progress remainder.
/// The engine does no PTY/grid work itself.
public struct AgentDetectionInput: Sendable, Equatable {
    public var screen: String
    public var oscTitle: String
    public var oscProgress: String

    public init(screen: String, oscTitle: String = "", oscProgress: String = "") {
        self.screen = screen
        self.oscTitle = oscTitle
        self.oscProgress = oscProgress
    }
}

/// The engine's verdict (herdr `AgentDetection`, ported 1:1) plus the matched-rule id for
/// debugging/tests. The `visible*` flags are true only when the SCREEN literally shows the
/// corresponding chrome (a live prompt box, a live blocker form, a live spinner) — they gate the
/// temporal layer (a visible idle bypasses the working→idle hold; a visible blocker gets the
/// steady re-publish heartbeat).
public struct AgentScreenDetection: Sendable, Equatable {
    public var state: AgentScreenState
    public var skipStateUpdate: Bool
    public var visibleIdle: Bool
    public var visibleBlocker: Bool
    public var visibleWorking: Bool
    /// The winning rule's id, or `nil` on the fallback path.
    public var matchedRuleID: String?
    /// herdr's `fallback_reason` constant when no rule matched a known agent.
    public var fallbackReason: String?

    public init(
        state: AgentScreenState,
        skipStateUpdate: Bool = false,
        visibleIdle: Bool = false,
        visibleBlocker: Bool = false,
        visibleWorking: Bool = false,
        matchedRuleID: String? = nil,
        fallbackReason: String? = nil,
    ) {
        self.state = state
        self.skipStateUpdate = skipStateUpdate
        self.visibleIdle = visibleIdle
        self.visibleBlocker = visibleBlocker
        self.visibleWorking = visibleWorking
        self.matchedRuleID = matchedRuleID
        self.fallbackReason = fallbackReason
    }

    /// herdr `DEFAULT_KNOWN_AGENT_IDLE_FALLBACK` — the reason string on the known-agent
    /// no-rule-matched fallback.
    public static let knownAgentIdleFallbackReason = "default_known_agent_idle_fallback"

    /// The fallback verdict for a KNOWN agent whose screen matched no rule: plain idle.
    public static let knownAgentIdleFallback = Self(
        state: .idle,
        fallbackReason: knownAgentIdleFallbackReason,
    )
}
