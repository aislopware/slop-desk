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

/// The engine's verdict, in the terms the status machine speaks — decoded from a
/// `ScreenDetection` reply by the scanner, which is the only thing that talks to the engine.
///
/// The ENGINE is `rust/slopdesk-screend` (`docs/52` §4b): the rule ladder, the manifests, the
/// region resolver and both stream trackers live there, so this module has no evaluation input
/// type and no evaluator. It keeps the verdict because the state machine and the temporal hold
/// consume it, and because those are hostd's — the split is that screend owns everything reading
/// the BYTES and hostd owns everything reading the CLOCK.
///
/// The `visible*` flags are true only when the SCREEN literally shows the corresponding chrome (a
/// live prompt box, a live blocker form, a live spinner) — they gate the temporal layer (a visible
/// idle bypasses the working→idle hold; a visible blocker gets the steady re-publish heartbeat).
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
}
