import CSlopDeskFFI

/// The single fused status state a sidebar tab row carries (see
/// `docs/ui-shell/spec/terminal-features__progress-state.md`, "Tab badges reflect the current progress state per tab").
///
/// PURE value type, **no SwiftUI**: HOW each kind renders lives in the view layer
/// (`SlopDeskSlate` `StatusPresentation` — lifecycle = the trailing ring mark's hue,
/// privilege = a trailing text marker) so this resolver unit-tests headless. There is
/// deliberately **no `.none` case** — the absence of a state is `TabBadgeKind?` `nil`, not a sentinel.
///
/// It sits in the VALUE MODEL rather than beside ``TabBadgeResolver`` (`SlopDeskWorkspaceCore`),
/// which is where it was written. The resolver needs a store's vocabulary — `PaneCompletionBadge`,
/// `PaneProgress`, `AgentBadgeGates` — and cannot descend; the KIND needs only the discriminant, and
/// every reader of it that is not the resolver (``TabBadgeReading``, the design floor's
/// `StatusPresentation`, both navigator rows) reads it as a plain enum. Keeping the two apart is what
/// lets `SlopDeskSlate` name a badge without naming the store.
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
    /// `TabBadgeResolver.CompletionFreshness.fresh`; once it settles the same inputs decay to
    /// ``finished``. Both wear the SAME green title ink in the view layer — the split survives for
    /// the freshness machinery and the control backend's badge tokens. Freshness is an INPUT (the store
    /// mirrors a per-pane `completedAt` and compares it to "now"), so the resolver stays clock-free.
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
    /// unseen-attention queue (`WorkspaceStore.unseenAttentionPanes`) rolls up. The live activity
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
    /// is the crossing order, and `rust/slopdesk-invariants` fails the build if the two lists
    /// ever disagree.
    ///
    /// `package` rather than `internal`: `TabBadgeResolver` is one target up now, and it marshals
    /// this discriminant through `slopdesk_agent_tab_badge` — the door is the ladder's one home, so
    /// the byte has to cross the target boundary the type just crossed.
    package var ffiByte: UInt8 {
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
    package init?(ffiByte: Int8) {
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
