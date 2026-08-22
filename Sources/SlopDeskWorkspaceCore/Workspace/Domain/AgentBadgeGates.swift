import CSlopDeskFFI
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel

// MARK: - Per-pane agent-badge gating policy (Claude-only)

/// The three "Agent Behaviour" badge toggles, distilled into a pure value the sidebar feeds to
/// ``TabBadgeGating/resolve(agent:completion:isBusy:foregroundProcess:completionFreshness:progress:agentGates:commandGates:)``,
/// which masks the AGENT resolver inputs by source BEFORE the (unchanged) ``TabBadgeResolver`` fuses them.
/// The settings UI (global) and a per-pane override both produce one of these; ``RailRowsBuilder`` resolves
/// the effective gates for a pane (override else global default).
///
/// **Why mask inputs, not the fused badge.** ``TabBadgeResolver/badge(...)`` stays PURE + signal-only
/// — it knows nothing about user preferences. Applying the gates by masking the resolver INPUTS (rather
/// than the single fused ``TabBadgeKind``) keeps the policy at the source: gating the agent's own
/// ``ClaudeStatus/working`` spinner (→ `.idle`) lets a still-busy shell fall through to the quiet
/// ``TabBadgeKind/commandRunning`` marker, since `isBusy` / `progress` are left untouched — the agent badge is
/// silenced without silencing a program's own busy / OSC 9;4 progress indicator.
///
/// **What the agent gates DROP** (their own agent badge family only):
///  - `badgeWhileProcessing == false` → drop the AGENT thinking spinner (status ``ClaudeStatus/working``).
///  - `badgeWhenComplete == false`    → drop the agent ``ClaudeStatus/done`` completed/finished badge.
///  - `badgeWhenAwaitingInput == false` → drop the agent ``ClaudeStatus/needsPermission`` hand.
///
/// **What the gates NEVER drop.** A program's busy / OSC 9;4 progress spinner, a command-exit `.error`, an
/// OSC 9;4;2 progress error, and the privilege badges ``TabBadgeKind/sudo`` / ``TabBadgeKind/caffeinate`` —
/// none of these is opt-out agent chatter, so the agent-badge toggles must not silence them. (The COMMAND-exit
/// completed/error badges have their own opt-out — see ``CommandBadgeGates``.)
public struct AgentBadgeGates: Equatable, Sendable {
    /// Show the AGENT thinking spinner while Claude is processing ("Badge while processing" in Settings). Default OFF
    /// (`progress-state.md` "Claude Code — While Processing (off by default)"). Gates ONLY the agent's own
    /// ``ClaudeStatus/working`` spinner — never a program's busy / OSC 9;4 progress spinner.
    public var badgeWhileProcessing: Bool
    /// Show the ``TabBadgeKind/completed`` checkmark flash + the settled ``TabBadgeKind/finished`` dot when a
    /// command exits 0 / an agent finishes its turn ("Badge when complete" in Settings). Default ON.
    public var badgeWhenComplete: Bool
    /// Show the ``TabBadgeKind/awaitingInput`` hand when a blocked agent / interactive prompt needs a human
    /// ("Badge when awaiting input" in Settings). Default ON.
    public var badgeWhenAwaitingInput: Bool

    public init(
        badgeWhileProcessing: Bool = true,
        badgeWhenComplete: Bool = true,
        badgeWhenAwaitingInput: Bool = true,
    ) {
        self.badgeWhileProcessing = badgeWhileProcessing
        self.badgeWhenComplete = badgeWhenComplete
        self.badgeWhenAwaitingInput = badgeWhenAwaitingInput
    }

    /// All three gates ON — the explicit "show every agent badge" baseline (the seed a per-pane override
    /// toggles from). NOTE: this is NOT the SHIPPED global default — `whileProcessing`
    /// ships OFF (resolved from ``SettingsKey/agentBadgeGates``); `allOn` is the explicit all-on constant.
    ///
    /// Read from `slopdesk-agent::badge`'s own `Gates::ALL_ON` rather than declared here. A `Self()`
    /// would have been a second assertion of the same baseline that no input ever reaches — the
    /// ungated ladder never consults it, so the two could not be caught disagreeing (`docs/55` §8).
    public static let allOn = {
        let gates = slopdesk_agent_badge_gates_default()
        return Self(
            badgeWhileProcessing: gates.agent_while_processing,
            badgeWhenComplete: gates.agent_when_complete,
            badgeWhenAwaitingInput: gates.agent_when_awaiting_input,
        )
    }()

    /// Returns a copy with one gate flipped — the per-pane override the tab context-menu toggle writes.
    public func toggling(_ gate: AgentBadgeGate) -> Self {
        var copy = self
        switch gate {
        case .whileProcessing: copy.badgeWhileProcessing.toggle()
        case .whenComplete: copy.badgeWhenComplete.toggle()
        case .whenAwaitingInput: copy.badgeWhenAwaitingInput.toggle()
        }
        return copy
    }
}

/// Identifies one of the three ``AgentBadgeGates`` toggles — the selector the tab context-menu uses to flip
/// a single per-pane override bit.
public enum AgentBadgeGate: Sendable, CaseIterable {
    case whileProcessing
    case whenComplete
    case whenAwaitingInput
}

// MARK: - Progress cluster: the COMMAND-driven badge gates (Settings → Shell "TAB BADGE")

/// The three "Tab Badge" toggles (`progress-state.md` lines 32-35 — Settings → Shell), DISTINCT from the
/// Claude ``AgentBadgeGates``. They gate the badges a (non-agent) COMMAND produces, so a user controls command
/// vs agent badges independently. All default ON.
///
/// **What the command gates DROP** (their own COMMAND badge family only, masked at the resolver input):
///  - `whenCommandFinishes == false` → drop the `.success`-exit completed/finished badge.
///  - `whenCommandFails == false`    → drop the `.failure`-exit ``TabBadgeKind/error`` (an OSC 9;4;2 program
///    progress error is a SEPARATE signal with no opt-out, so it still surfaces).
///  - `whenCommandAwaitsInput == false` → drop a plain-command awaiting-input hand. The host-side
///    cursor-at-prompt quiescence DETECTOR that would drive that badge is a deferred ceiling (DECISIONS.md);
///    the toggle is wired so the future signal gates without a later code change.
public struct CommandBadgeGates: Equatable, Sendable {
    /// Show the completed/finished badge when a (non-agent) command exits 0 ("When Command Finishes" in Settings).
    public var whenCommandFinishes: Bool
    /// Show the error badge when a (non-agent) command exits non-zero ("When Command Fails" in Settings).
    public var whenCommandFails: Bool
    /// Show the awaiting-input hand when a plain command stops at an interactive prompt ("When Command
    /// Awaits Input" in Settings). The detector is deferred — this toggle is wired for the future signal.
    public var whenCommandAwaitsInput: Bool

    public init(
        whenCommandFinishes: Bool = true,
        whenCommandFails: Bool = true,
        whenCommandAwaitsInput: Bool = true,
    ) {
        self.whenCommandFinishes = whenCommandFinishes
        self.whenCommandFails = whenCommandFails
        self.whenCommandAwaitsInput = whenCommandAwaitsInput
    }

    /// All three command gates ON — the shipped global default (every command badge shows).
    ///
    /// Two of the three come from `slopdesk-agent::badge`'s `Gates::ALL_ON`, for the reason
    /// ``AgentBadgeGates/allOn`` states. `whenCommandAwaitsInput` does NOT, and its absence is
    /// deliberate on the far side rather than an omission here: nothing yet produces that signal, so
    /// `Gates` carries no field for it — a mask over a value that is never set. It is spelled here
    /// because here is the only place it exists.
    public static let allOn = {
        let gates = slopdesk_agent_badge_gates_default()
        return Self(
            whenCommandFinishes: gates.command_when_finishes,
            whenCommandFails: gates.command_when_fails,
            whenCommandAwaitsInput: true,
        )
    }()
}

// MARK: - Source-aware tab-badge gating (the ONE production gating entry point)

/// The ONE production entry point for a row's badge: the signal ladder with the user's toggles
/// applied. Both live in `slopdesk-agent::badge`, which masks each signal by SOURCE before the
/// (unchanged, precedence-pinned) ladder runs — so a silenced agent still lets the program speak,
/// because `isBusy` and the OSC 9;4 mirror are never masked. This forwards; it decides nothing.
public enum TabBadgeGating {
    /// Resolve the gated badge for a pane.
    public static func resolve(
        agent: ClaudeStatus,
        completion: PaneCompletionBadge?,
        isBusy: Bool,
        foregroundProcess: String?,
        completionFreshness: TabBadgeResolver.CompletionFreshness = .settled,
        progress: PaneProgress? = nil,
        unseenAgentDone: Bool = false,
        agentGates: AgentBadgeGates,
        commandGates: CommandBadgeGates,
    ) -> TabBadgeKind? {
        TabBadgeResolver.badge(
            agent: agent,
            completion: completion,
            isBusy: isBusy,
            foregroundProcess: foregroundProcess,
            completionFreshness: completionFreshness,
            progress: progress,
            unseenAgentDone: unseenAgentDone,
            agentGates: agentGates,
            commandGates: commandGates,
        )
    }
}
