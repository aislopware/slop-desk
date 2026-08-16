import CSlopDeskFFI
import Foundation

/// The temporal layer over the pure engine: the working→idle confirmation hold, the publish-worthiness
/// gate, and the steady visible-blocker re-publish heartbeat.
///
/// Every rule is `rust/slopdesk-agent::hold` (docs/55) — including the counters, which ARE the rule:
/// three confirming reads, or the 700 ms cap, release a hold. This is a handle over that state, so
/// it is a `final class` where it used to be a `struct`. Nothing copied it (the one owner is
/// `PaneScreenScanner`, which resets it by assignment), so reference semantics cost nothing here.
public final class AgentDetectionHold: @unchecked Sendable {
    /// Recheck interval while a working→idle transition is pending.
    public static let pendingIdleRecheck: TimeInterval = slopdesk_agent_hold_constant(0)
    /// Consecutive confirming reads required to publish a plain idle.
    public static let pendingIdleConfirmations = Int(slopdesk_agent_hold_constant(1))
    /// Hard ceiling — publish the idle regardless once this much time has passed.
    public static let pendingIdleCap: TimeInterval = slopdesk_agent_hold_constant(2)
    /// Re-publish a steady visible blocker this often (freshness heartbeat).
    public static let stableVisibleSignalRefresh: TimeInterval = slopdesk_agent_hold_constant(3)
    /// Suppress detection publishes for this long after a new agent appears (splash paint).
    public static let startupGraceWindow: TimeInterval = slopdesk_agent_hold_constant(4)
    /// The scan cadence when no hold is pending (herdr's detection-loop sleep).
    public static let scanInterval: TimeInterval = slopdesk_agent_hold_constant(5)

    private let handle: OpaquePointer

    public init() {
        guard let handle = slopdesk_agent_hold_new() else {
            // A hold is a few counters; a failure here is the allocator being gone, and a detector
            // with no hold would flap every pane rather than fail quietly.
            preconditionFailure("slopdesk_agent_hold_new returned null")
        }
        self.handle = handle
    }

    deinit { slopdesk_agent_hold_free(handle) }

    /// True while EITHER idle hold is pending (callers tighten the recheck cadence).
    public var isHoldingIdle: Bool {
        slopdesk_agent_hold_is_holding_idle(handle)
    }

    /// herdr `should_hold_working_to_idle`: engages only on working → PLAIN idle (a VISIBLE
    /// idle — real prompt chrome — bypasses the hold); 3 consecutive confirmations release,
    /// the 700 ms cap force-releases.
    public func shouldHoldWorkingToIdle(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        now: TimeInterval,
    ) -> Bool {
        withHoldPair(previous, next) { from, to in
            slopdesk_agent_hold_working_to_idle(
                handle, from, to, agentChanged, processExited, now,
            )
        }
    }

    /// The BLOCKED→idle sibling — **ours, not herdr's**, and deliberately stricter than the
    /// working→idle hold above.
    ///
    /// A pane leaving a block is the single most consequential screen edge there is: it clears the
    /// mark, it is herdr's hook-less COMPLETION edge (`AttentionEdge.isCompletion` /
    /// `MuxChannelSession.isCompletionTransition`), so it mints an unread finish across every
    /// client, and it can override an authoritative hook block. One bad read must not buy all of
    /// that. Requiring the same 3 confirmations (or the 700 ms cap) costs at most ~300 ms on a
    /// genuine unblock — and the ONE unblock that has no other announcement, an Esc-cancelled
    /// dialog, already has an instant path of its own (`PaneInputClassifier.containsCancelKeystroke`
    /// → `ClaudeSignal.userInput`), which does not come through here at all.
    ///
    /// ⚠️ Unlike ``shouldHoldWorkingToIdle(previous:next:agentChanged:processExited:now:)``, a
    /// VISIBLE idle does NOT bypass this hold. The visible idle is exactly the false verdict being
    /// guarded against: with the dialog's footer momentarily erased mid-repaint, the highest rule
    /// still matching is `live_prompt_box` — the dialog's own option list carries the `❯` pointer,
    /// and the footer needles that would veto it sit BELOW the last horizontal rule, outside
    /// `prompt_box_body`. So it reports `idle` + `visible_idle`, the one shape strong enough to
    /// clear a hook block (user-reported 2026-08-11, `AskUserQuestion` Tab flap).
    public func shouldHoldBlockedToIdle(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        now: TimeInterval,
    ) -> Bool {
        withHoldPair(previous, next) { from, to in
            slopdesk_agent_hold_blocked_to_idle(
                handle, from, to, agentChanged, processExited, now,
            )
        }
    }

    /// A steady visible blocker re-publishes every 800 ms even without a change.
    public static func stableVisibleSignalRefreshDue(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        lastRefresh: TimeInterval?,
        now: TimeInterval,
    ) -> Bool {
        withHoldPair(previous, next) { from, to in
            slopdesk_agent_hold_refresh_due(from, to, lastRefresh ?? 0, lastRefresh != nil, now)
        }
    }

    /// Whether a verdict differs enough from the last published one to be worth announcing.
    public static func shouldPublish(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        refreshDue: Bool,
    ) -> Bool {
        withHoldPair(previous, next) { from, to in
            slopdesk_agent_hold_should_publish(from, to, agentChanged, processExited, refreshDue)
        }
    }

    /// The whole temporal decision: hold → no publish; else the publish gate.
    ///
    /// Both holds are consulted on EVERY decision inside the crate, never short-circuited: each
    /// clears its own pending state when its transition does not apply, so a pane that walks
    /// working → idle → blocked → idle leaves no stale counter behind.
    public func decide(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        lastRefresh: TimeInterval?,
        now: TimeInterval,
    ) -> Bool {
        withHoldPair(previous, next) { from, to in
            slopdesk_agent_hold_decide(
                handle, from, to, agentChanged, processExited,
                lastRefresh ?? 0, lastRefresh != nil, now,
            )
        }
    }
}

/// Lends the two verdicts as C structs for exactly the length of one call — the `withUnsafePointer`
/// scopes ARE the safety contract, so nothing else goes inside them.
private func withHoldPair<T>(
    _ previous: AgentScreenDetection,
    _ next: AgentScreenDetection,
    _ body: (UnsafePointer<SlopDeskAgentDetection>, UnsafePointer<SlopDeskAgentDetection>) -> T,
) -> T {
    var from = previous.ffiDetection
    var to = next.ffiDetection
    return withUnsafePointer(to: &from) { fromPointer in
        withUnsafePointer(to: &to) { toPointer in
            body(fromPointer, toPointer)
        }
    }
}
