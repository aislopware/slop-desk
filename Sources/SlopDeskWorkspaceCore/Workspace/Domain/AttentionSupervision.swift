import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel

// MARK: - PaneFacts (what one status landing on a pane moves)

/// The supervision LADDER for one pane, as `slopdesk-workspace::pane_facts` answers it.
///
/// The three edge questions — is this an attention state, is this transition worth interrupting
/// somebody for, did a hook-less agent just finish — were each their own Swift entry point once, and
/// every writer that reached the store's pane maps had to re-compose them into the answer it
/// actually wanted. That composition is the door now: one call says WHICH of the pane's facts move,
/// and the store applies the verdict without a branch of its own.
///
/// Nothing here reads a clock or learns a pane's identity. A commit takes three statuses; the queue
/// order takes badges and instants and answers POSITIONS in the list it was handed.
public enum PaneFacts {
    /// Which of a pane's facts one committed status change moves, or `nil` when it did not change.
    ///
    /// The fields are applied in declaration order and nothing else is asked. `lastNotified` is the
    /// coalescing MEMORY — the state a notification was last raised for, which is not the previous
    /// status: `done → working → done` re-enters an announced state and stays quiet.
    ///
    /// `quiet` is the host's bookkeeping qualification (today only the `/compact` boundary). It
    /// vetoes rings and nothing else — not the dots, not the stamps, and deliberately not the
    /// re-arm, because leaving the memory latched would swallow the pane's next genuine block.
    public static func commit(
        previous: ClaudeStatus,
        lastNotified: ClaudeStatus,
        status: ClaudeStatus,
        quiet: Bool,
    ) -> SlopDeskWsPaneStatusCommit? {
        let verdict = slopdesk_ws_pane_status_commit(
            previous.ffiByte, lastNotified.ffiByte, status.ffiByte, quiet,
        )
        return verdict.changed ? verdict : nil
    }

    /// What a pane's unread-finish MARKER becomes, given the live counter, what this device recorded
    /// as seen, and whether the pane is on screen.
    public enum Unseen {
        /// Not unread, and nothing to record.
        case clear
        /// Not unread, and RECORD it: a finish you are looking at is a finish you have seen.
        case seenThenClear
        /// Unread — mark it.
        case mark
    }

    /// Decides pane's unread-finish marker. `seen` is `nil` when this device has never recorded one,
    /// which is a different answer from having recorded zero — the first can never match a live
    /// counter, the second is every pane's state before the document arrives.
    public static func unseenDone(epoch: UInt32, seen: UInt32?, isVisible: Bool) -> Unseen {
        switch slopdesk_ws_pane_unseen_done(epoch, seen != nil, seen ?? 0, isVisible) {
        case 1: .seenThenClear
        case 2: .mark
        default: .clear
        }
    }

    /// Whether an unbroken watch of `watched` seconds has earned the finish-marker acknowledge.
    /// Settles once the watch REACHES the window — a window is how long you have to look, not that
    /// plus a tick — and compares NaN-faithfully, per the repo's convention.
    public static func settleDue(watched: TimeInterval, window: TimeInterval) -> Bool {
        slopdesk_ws_pane_settle_due(watched, window)
    }

    /// Reorders `entries` the way the unseen-attention queue is walked: rank first (a waiting
    /// question, then a failure, then an unread finish), then longest-waiting, then the caller's own
    /// traversal order as the tie.
    ///
    /// The tie is load-bearing, which is why the rule answers POSITIONS rather than sorting: the
    /// caller's traversal is session → tab → pre-order DFS, and two panes that entered attention in
    /// the same instant have to come back in it. A dated entry outranks an undated one at the same
    /// rank — age is evidence, and an entry with none cannot claim to have waited longer.
    public static func attentionOrder(_ entries: [UnseenAttentionEntry]) -> [UnseenAttentionEntry] {
        guard entries.count > 1 else { return entries }
        let waiting = entries.map { entry in
            SlopDeskWsWaitingPane(
                badge: entry.badge.ffiByte,
                has_since: entry.since != nil,
                since: entry.since?.timeIntervalSinceReferenceDate ?? 0,
            )
        }
        var order = [UInt32](repeating: 0, count: entries.count)
        let count = waiting.withUnsafeBufferPointer { panes in
            order.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_attention_order(panes.baseAddress, panes.count, out.baseAddress, out.count)
            }
        }
        guard count == entries.count else { return entries }
        return order.compactMap { position in entries.indices.contains(Int(position)) ? entries[Int(position)] : nil }
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
    /// (the oldest in traversal order) wins. The ranking is `slopdesk-agent::attention`, which answers
    /// a POSITION in the list it was handed — the pane identities never leave Swift.
    public static func oldestPane(
        in panes: some Sequence<PaneID>,
        status: (PaneID) -> ClaudeStatus,
    ) -> PaneID? {
        let ordered = Array(panes)
        let statuses = ordered.map { status($0).ffiByte }
        let position = statuses.withUnsafeBufferPointer {
            slopdesk_agent_attention_oldest($0.baseAddress, $0.count)
        }
        guard position >= 0, position < ordered.count else { return nil }
        return ordered[position]
    }
}

// MARK: - AttentionWalk (the pure "step the queue, then pop home" decision — ⌘⇧U's walk)

/// The PURE per-press decision for the ⌘⇧U WALK: given the current queue (the caller passes
/// ``WorkspaceStore/unseenAttentionPanes``'s pane order — rank-then-since), the set of panes this walk
/// has already visited, and the pane the walk should return to on exhaustion, decide whether to step
/// forward or pop home.
///
/// Deliberately NOT built on ``AttentionJump`` — a visited-set walk needs an exclusion `AttentionJump`'s
/// `ClaudeStatus`-only signature cannot express, and the queue itself already carries the badge-gated,
/// since-ordered ranking the walk should honor (the "one shared source" invariant: the menu and the chord
/// read the identical list, never two orderings kept in sync by hand).
///
/// Termination is VISITED-SET exhaustion, not queue emptiness: a still-`.needsPermission` pane re-enters
/// the caller's queue the instant focus leaves it (only the currently-focused leaf is excluded), so the
/// walk must remember every pane it has already stepped onto or it would oscillate between the two most
/// recently departed panes forever.
public enum AttentionWalk {
    /// One press's outcome.
    public enum Step: Equatable {
        /// Step onto `to` — the caller extends its visited-set with it and focuses it.
        case advance(to: PaneID)
        /// The queue's unvisited entries are exhausted (or the walk never started): pop back to `to`, or
        /// no-op silently when `to` is `nil` (never started, or the recorded origin no longer exists).
        case popHome(to: PaneID?)
    }

    /// Decides the outcome of one ⌘⇧U press.
    ///
    /// - `queue`: the CURRENT queue order (already rank-then-since sorted by the caller).
    /// - `visited`: every pane this walk has already stepped onto.
    /// - `origin`: the pane the walk started from, `nil` before the first step.
    /// - `isPaneLive`: whether a pane id still exists in the tree (a closed origin pops to `nil`).
    ///
    /// The rule is `slopdesk-agent::attention`: the visited set crosses as one flag per queue entry
    /// and the answer comes back as a POSITION, so a pane id is never anything but Swift's.
    public static func step(
        queue: [PaneID],
        visited: Set<PaneID>,
        origin: PaneID?,
        isPaneLive: (PaneID) -> Bool,
    ) -> Step {
        let home = origin.flatMap { isPaneLive($0) ? $0 : nil }
        let seen = queue.map { visited.contains($0) }
        let outcome = seen.withUnsafeBufferPointer {
            slopdesk_agent_attention_walk($0.baseAddress, $0.count, home != nil)
        }
        guard outcome >= 0, outcome < queue.count else { return .popHome(to: home) }
        return .advance(to: queue[outcome])
    }
}
