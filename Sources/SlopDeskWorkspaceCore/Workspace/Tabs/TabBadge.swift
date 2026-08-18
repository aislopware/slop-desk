import CSlopDeskFFI
import SlopDeskAgentDetect

/// The single fused status state a sidebar tab row carries (see
/// `docs/ui-shell/spec/terminal-features__progress-state.md`, "Tab badges reflect the current progress state per tab").
///
/// PURE value type, **no SwiftUI**: HOW each kind renders lives in the view layer
/// (`SlopDeskClientUI` `StatusPresentation` — lifecycle = the trailing ring mark's hue,
/// privilege = a trailing text marker) so this resolver unit-tests headless. There is
/// deliberately **no `.none` case** — the absence of a state is `TabBadgeKind?` `nil`, not a sentinel.
///
/// Each case maps to a state described in `progress-state.md` → "The full badge set".
public enum TabBadgeKind: Equatable, Sendable {
    /// **Running (agent)** — a WORKING code agent (`ClaudeStatus.working`). The "agent is thinking"
    /// state (the accent ring mark in the view layer). Split from a program's
    /// ``commandRunning`` so the sidebar reads "the AGENT is working" distinctly from "a program reports
    /// progress" (herdr's `Working` vs `Unknown` distinction).
    case running
    /// **Running (command)** — an active `OSC 9;4;1`/`3` PROGRESS report with NO agent working: a program
    /// explicitly says "I'm loading". Renders nothing of its own — the running command's text titles
    /// the row. Ranks just below ``running`` and above ``commandBusy``.
    case commandRunning
    /// **Busy (command)** — a plain busy shell (`isBusy`, no OSC 9;4 report): a foreground command is
    /// running, nothing more is known. Renders nothing of its own. Ranks just below
    /// ``commandRunning`` and above the privilege badges.
    case commandBusy
    /// **Completed** — the fresh clean finish (`OSC 133;D` exit 0 / an agent that just finished its
    /// turn), emitted ONLY while the caller reports the completion is still
    /// ``CompletionFreshness/fresh``; once it ``CompletionFreshness/settled`` the same inputs decay to
    /// ``finished``. Both wear the SAME green title ink in the view layer — the split survives for
    /// the freshness machinery and the control backend's badge tokens. Freshness is an INPUT (the store
    /// mirrors a per-pane `completedAt` and compares it to "now"), so this resolver stays clock-free.
    case completed
    /// **Finished** — the "unread output" marker for a command that exited 0 and has settled past the
    /// ``completed`` flash (and for an agent that went done and is still unread). The green title ink
    /// that holds until the tab is viewed (cleared on focus). No timestamp lives here; the settle
    /// decision is the store's.
    case finished
    /// **Error** — the red title ink, static. A command exited non-zero (`OSC 9;4;2` / a `.failure`
    /// completion) or an agent reported an error.
    case error
    /// **Awaiting input** — the amber title ink, static. A code agent is blocked on
    /// approval/input (`ClaudeStatus.needsPermission`) or a plain command is stopped at an
    /// interactive prompt. The most-urgent state — it wins the precedence.
    case awaitingInput
    /// **Caffeinate** — the `∞` trailing marker. A sleep-blocking session (`caffeinate` foreground).
    /// Surfaces only when the shell is otherwise at rest (below the active states).
    case caffeinate
    /// **Sudo** — the `#` trailing marker. A privileged session (`sudo`/`su` foreground). Surfaces
    /// only when the shell is otherwise at rest (below the active states, above ``caffeinate``).
    case sudo

    /// Whether this badge is ATTENTION-class — "finished or waiting on you", the states the
    /// unseen-attention queue (``WorkspaceStore/unseenAttentionPanes``) rolls up. The live activity
    /// markers (``running``/``commandRunning``) and the at-rest privilege badges (``sudo``/``caffeinate``)
    /// are NOT attention: attention means unread, not busy.
    public var needsAttention: Bool {
        slopdesk_agent_badge_needs_attention(ffiByte)
    }

    /// Whether this badge is a BUSY tier — "something is in flight" (a working agent, an OSC 9;4
    /// progress report, or a bare busy shell). The sidebar rows render busy as the trailing ring
    /// mark on the accent/muted inks, the attention kinds as the same ring on the attention hues,
    /// and only the privilege markers occupy the slot.
    /// The disjoint complement of ``needsAttention`` plus the privilege markers.
    public var isBusyTier: Bool {
        slopdesk_agent_badge_is_busy_tier(ffiByte)
    }

    /// The discriminant `slopdesk-agent::badge`'s `TabBadge::ALL` gives this case. Declaration order
    /// is the crossing order, and `scripts/check-supervisor.sh` fails the build if the two lists
    /// ever disagree.
    var ffiByte: UInt8 {
        switch self {
        case .running: 0
        case .commandRunning: 1
        case .commandBusy: 2
        case .completed: 3
        case .finished: 4
        case .error: 5
        case .awaitingInput: 6
        case .caffeinate: 7
        case .sudo: 8
        }
    }

    /// The inverse. An unknown byte — a badge a newer crate names and this build does not — answers
    /// `nil`, which is exactly the all-clear row.
    init?(ffiByte: Int8) {
        switch ffiByte {
        case 0: self = .running
        case 1: self = .commandRunning
        case 2: self = .commandBusy
        case 3: self = .completed
        case 4: self = .finished
        case 5: self = .error
        case 6: self = .awaitingInput
        case 7: self = .caffeinate
        case 8: self = .sudo
        default: return nil
        }
    }
}

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
/// Headless + deterministic: no SwiftUI, no clock, no I/O. The only inputs are the agent verdict, the
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
