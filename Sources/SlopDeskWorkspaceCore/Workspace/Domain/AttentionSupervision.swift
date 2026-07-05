import Foundation
import SlopDeskAgentDetect

// MARK: - AttentionEdge (the pure "should this status change raise an attention notification" policy)

/// The PURE decision policy for the P3 supervision cockpit: given a pane's PREVIOUS and CURRENT
/// rolled-up ``ClaudeStatus``, decide whether the transition is an ATTENTION EDGE worth a desktop
/// notification — i.e. the pane just entered a state that needs the human (``ClaudeStatus/needsPermission``
/// — it is blocked on you) or just finished (``ClaudeStatus/done``).
///
/// Split out from the store + the platform notifier so the edge rule is unit-tested with NO SwiftUI,
/// NO `UNUserNotificationCenter`, NO `LivePaneSession` — exactly as ``CommandNotificationPolicy`` and
/// ``BackgroundCompletionPolicy`` are. `#if`-unguarded so it compiles + tests on every platform.
///
/// The rule is deliberately EDGE-triggered, not level-triggered: a notification fires only on the
/// genuine transition INTO `needsPermission`/`done` from a DIFFERENT state. A flap that re-enters the
/// same attention state without first leaving it (the `prev == current` case) never re-fires — the
/// store's coalescing map (`lastNotifiedStatus`) makes "different" mean "different from the last state
/// we notified for", so `done → working → done` only notifies on the FIRST `done`.
public enum AttentionEdge {
    /// Whether the `prev → current` transition is an attention edge worth a notification.
    ///
    /// True iff `current` is `.needsPermission` or `.done` AND it differs from `prev` (a real entry
    /// into the attention state, not a repeat of the state we are already in). `.idle` / `.working` /
    /// `.none` are never notify-worthy targets (working is in-flight; idle/none recede).
    public static func shouldNotify(prev: ClaudeStatus, current: ClaudeStatus) -> Bool {
        guard prev != current else { return false }
        switch current {
        case .needsPermission,
             .done: return true
        case .none,
             .idle,
             .working: return false
        }
    }

    /// Whether `status` is an ATTENTION state — the level predicate the ring / tab-glow read (a pure
    /// function of the CURRENT status; no history). `needsPermission` (blocked, the most urgent) and
    /// `done` (finished, waiting to be seen) draw the attention chrome; everything else is quiet.
    public static func isAttention(_ status: ClaudeStatus) -> Bool {
        switch status {
        case .needsPermission,
             .done: true
        case .none,
             .idle,
             .working: false
        }
    }
}

// MARK: - AttentionJump (the pure jump-to-unread selection)

/// The PURE selection policy for ⌘⇧U "Jump to Pane Needing Attention": over a canonical-order list of
/// pane ids and a status lookup, pick the OLDEST pane that needs attention — `needsPermission` first
/// (ALL blocked panes before ANY done pane), then `done`, each bucket in traversal order (the first /
/// top-most in the list is the "oldest"). `nil` when no pane needs attention.
///
/// Split from the store so the ordering rule (blocked-before-done, oldest-first) is unit-tested without
/// a `WorkspaceStore` — the store passes `tree.allPaneIDs()` (session → tab → pre-order DFS) and its
/// `agentStatus(for:)` closure.
public enum AttentionJump {
    /// The oldest pane needing attention in `panes` (canonical order), or `nil` if none.
    ///
    /// Priority: a `.needsPermission` pane ALWAYS wins over a `.done` pane regardless of position
    /// (blocked is the most urgent — get unblocked first); within a bucket the FIRST pane in `panes`
    /// (the oldest in traversal order) wins. A single pass keeps the two candidates.
    public static func oldestPane(
        in panes: some Sequence<PaneID>,
        status: (PaneID) -> ClaudeStatus,
    ) -> PaneID? {
        var firstBlocked: PaneID?
        var firstDone: PaneID?
        for id in panes {
            switch status(id) {
            case .needsPermission:
                if firstBlocked == nil { firstBlocked = id }
            case .done:
                if firstDone == nil { firstDone = id }
            case .none,
                 .idle,
                 .working:
                continue
            }
        }
        return firstBlocked ?? firstDone
    }
}
