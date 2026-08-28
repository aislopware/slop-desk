import CSlopDeskFFI
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel // TabBadgeKind — the KIND descended, the RESOLVER could not

// The badge LADDER lives here and the badge KIND does not, and the split is the store's fault rather
// than a tidying: this resolver's inputs are `PaneCompletionBadge`, `PaneProgress`,
// `AgentBadgeGates` and `CommandBadgeGates`, every one of them `SlopDeskWorkspaceCore`'s, so it
// cannot descend. ``TabBadgeKind`` has no such tie — it is a discriminant — and it descended to
// `SlopDeskWorkspaceModel` so that the design floor can name a badge without naming a store.

/// The PURE fusion policy that collapses the four per-pane badge signals into the single
/// ``TabBadgeKind`` a tab row shows. One badge per row; most-urgent wins.
///
/// **Fixed precedence** (distilled from `progress-state.md` + `parallel-tasks.md`):
///
/// ```
/// awaitingInput  >  error  >  running(agent)  >  AGENT completed/finished  >  commandRunning  >
///   commandBusy  >  sudo  >  caffeinate  >  COMMAND completed/finished  >  nil
/// ```
///
/// A working AGENT (``running``) outranks a program's progress report (``commandRunning``), which
/// outranks the plain busy dot (``commandBusy``) — if a pane is somehow several, the most-informative
/// signal wins. The activity tiers sit above the privilege badges (a running `sudo …` shows activity, not
/// the shield). The AGENT finish sits ABOVE the busy tiers (the agent process itself keeps the shell
/// busy for its whole lifetime — a finished turn must not be shadowed); a COMMAND's clean exit sits
/// BELOW them (a newly-running command supersedes the previous exit).
///
/// Headless + deterministic: no view framework, no clock, no I/O. The only inputs are the agent verdict, the
/// stored completion badge, the busy bit, and the (untrusted) foreground-process string — which is
/// classified by an **allow-set on its lowercased basename**, never `contains`, and defaults to "no
/// privilege badge" for anything unknown / `nil` (validate-then-default; no force-unwrap).
public enum TabBadgeResolver {
    /// Whether a clean completion (`.success` exit / agent `.done`) is still showing its brief success
    /// FLASH or has SETTLED into the persistent unread marker. A pure, clock-free input the resolver
    /// switches the completed/finished branch on — the caller (the store) decides it by comparing an
    /// EPHEMERAL per-pane `completedAt` mirror against "now", so this resolver never reads a clock.
    public enum CompletionFreshness: Sendable, Equatable {
        /// Just completed — render the brief ``TabBadgeKind/completed`` flash.
        case fresh
        /// Settled past the flash — render the persistent ``TabBadgeKind/finished`` unread marker
        /// (held until the tab is viewed). Also the default for a completion with no recorded stamp.
        case settled
    }

    /// Resolve the one badge for a row, by fixed precedence (most-urgent wins).
    ///
    /// - Parameters:
    ///   - agent: the rolled-up `ClaudeStatus` for the pane (`needsPermission` ⇒ awaiting input,
    ///     `working` ⇒ running, `done` ⇒ completed; `idle`/`none` contribute nothing).
    ///   - completion: the stored OSC-133 exit-code badge (`.failure` ⇒ error, `.success` ⇒ completed),
    ///     or `nil` for none.
    ///   - isBusy: the live "command running" bit (`PaneSessionHandle.isShellBusy`) ⇒ running.
    ///   - foregroundProcess: the last foreground-process string the host reported (wire type 26),
    ///     possibly a bare name or a full path; UNTRUSTED. Classified by lowercased basename into
    ///     `sudo`/`caffeinate`, else ignored.
    ///   - completionFreshness: whether a clean completion (`.success` / agent `.done`) is still a
    ///     ``CompletionFreshness/fresh`` FLASH or has ``CompletionFreshness/settled`` into the
    ///     persistent unread marker. Supplied by the store (an ephemeral `completedAt` vs "now"); defaults to
    ///     ``CompletionFreshness/settled`` so an un-stamped completion shows the persistent marker.
    ///   - progress: the live OSC 9;4 ``PaneProgress`` (wire type 32), or `nil` when there is no
    ///     active indicator. ``PaneProgress/error`` resolves to the ``error`` alert (a held-red `9;4;2`,
    ///     ranked with a failed exit); an active ``PaneProgress/indeterminate``/``PaneProgress/determinate``
    ///     resolves to the ``running`` tier — reusing the EXISTING tiers, no new badge kind. Outranks a
    ///     stale completion dot (progress-error sits at the error tier, above completed/finished).
    ///   - unseenAgentDone: the client's UNREAD agent-finish latch (``WorkspaceStore/paneUnseenDone``) —
    ///     true from an agent `.done` edge the user was not watching until the pane is visited. Keeps the
    ///     finished marker alive across the host's own done→idle decay (the host forgets, the client
    ///     remembers until seen — the t3code/herdr unread-completion model).
    ///   - agentGates / commandGates: the user's badge toggles, which silence their OWN family's
    ///     signal and nothing else. Both default to ``AgentBadgeGates/allOn`` / ``CommandBadgeGates/allOn``
    ///     — the signal-only ladder, for a caller with no preferences to apply.
    /// - Returns: the badge to render, or `nil` when the row is all-clear.
    public static func badge(
        agent: ClaudeStatus,
        completion: PaneCompletionBadge?,
        isBusy: Bool,
        foregroundProcess: String?,
        completionFreshness: CompletionFreshness = .settled,
        progress: PaneProgress? = nil,
        unseenAgentDone: Bool = false,
        agentGates: AgentBadgeGates = .allOn,
        commandGates: CommandBadgeGates = .allOn,
    ) -> TabBadgeKind? {
        // The ladder AND the gating are `slopdesk-agent::badge` — every optional input crosses as a
        // value plus its absence sentinel, and the answer comes back the same shape.
        var foreground = Array((foregroundProcess ?? "").utf8)
        let raw = foreground.withUnsafeMutableBufferPointer { name in
            slopdesk_agent_tab_badge(
                agent.ffiByte,
                completion.map { $0 == .failure ? 1 : 0 } ?? -1,
                isBusy,
                name.baseAddress,
                name.count,
                completionFreshness == .fresh,
                progress.map { $0.isRunning ? 0 : 1 } ?? -1,
                unseenAgentDone,
                agentGates.badgeWhileProcessing,
                agentGates.badgeWhenComplete,
                agentGates.badgeWhenAwaitingInput,
                commandGates.whenCommandFinishes,
                commandGates.whenCommandFails,
            )
        }
        return TabBadgeKind(ffiByte: raw)
    }
}
