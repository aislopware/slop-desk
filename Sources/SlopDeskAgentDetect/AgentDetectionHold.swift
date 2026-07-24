import Foundation

/// The temporal layer over the pure engine (herdr `src/pane/agent_detection.rs`, ported 1:1):
/// the working→idle confirmation hold, the publish-worthiness gate, and the steady
/// visible-blocker re-publish heartbeat. Pure, injected clock.
public struct AgentDetectionHold: Sendable, Equatable {
    // herdr constants, exact.
    /// Recheck interval while a working→idle transition is pending.
    public static let pendingIdleRecheck: TimeInterval = 0.100
    /// Consecutive confirming reads required to publish a plain idle.
    public static let pendingIdleConfirmations = 3
    /// Hard ceiling — publish the idle regardless once this much time has passed.
    public static let pendingIdleCap: TimeInterval = 0.700
    /// Re-publish a steady visible blocker this often (freshness heartbeat).
    public static let stableVisibleSignalRefresh: TimeInterval = 0.800
    /// Suppress detection publishes for this long after a new agent appears (splash paint).
    public static let startupGraceWindow: TimeInterval = 3.0
    /// The scan cadence when no hold is pending (herdr's detection-loop sleep).
    public static let scanInterval: TimeInterval = 0.300

    /// Pending working→idle confirmation state (herdr `PendingIdleConfirmation`).
    private var pendingIdleStartedAt: TimeInterval?
    private var confirmations = 0

    public init() {}

    /// True while a working→idle hold is pending (callers tighten the recheck cadence).
    public var isHoldingIdle: Bool { pendingIdleStartedAt != nil }

    /// herdr `should_hold_working_to_idle`: engages only on working → PLAIN idle (a VISIBLE
    /// idle — real prompt chrome — bypasses the hold); 3 consecutive confirmations release,
    /// the 700 ms cap force-releases.
    public mutating func shouldHoldWorkingToIdle(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        now: TimeInterval,
    ) -> Bool {
        let transitioning = previous.state == .working && next.state == .idle
            && !next.visibleIdle && !next.visibleBlocker && !agentChanged && !processExited
        guard transitioning else {
            clear()
            return false
        }
        guard let startedAt = pendingIdleStartedAt else {
            pendingIdleStartedAt = now
            confirmations = 0
            return true
        }
        if now - startedAt >= Self.pendingIdleCap {
            clear()
            return false
        }
        confirmations += 1
        if confirmations >= Self.pendingIdleConfirmations {
            clear()
            return false
        }
        return true
    }

    private mutating func clear() {
        pendingIdleStartedAt = nil
        confirmations = 0
    }

    /// herdr `stable_visible_signal_refresh_due`: a steady visible blocker re-publishes
    /// every 800 ms even without a change.
    public static func stableVisibleSignalRefreshDue(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        lastRefresh: TimeInterval?,
        now: TimeInterval,
    ) -> Bool {
        guard next.visibleBlocker, previous.visibleBlocker else { return false }
        guard let lastRefresh else { return true }
        return now - lastRefresh >= stableVisibleSignalRefresh
    }

    /// herdr `should_publish_detection_update`.
    public static func shouldPublish(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        refreshDue: Bool,
    ) -> Bool {
        previous.state != next.state
            || previous.visibleIdle != next.visibleIdle
            || previous.visibleBlocker != next.visibleBlocker
            || previous.visibleWorking != next.visibleWorking
            || agentChanged
            || processExited
            || (refreshDue && next.visibleBlocker && previous.visibleBlocker)
    }

    /// herdr `decide_detection_transition`: hold → no publish; else the publish gate.
    public mutating func decide(
        previous: AgentScreenDetection,
        next: AgentScreenDetection,
        agentChanged: Bool,
        processExited: Bool,
        lastRefresh: TimeInterval?,
        now: TimeInterval,
    ) -> Bool {
        if shouldHoldWorkingToIdle(
            previous: previous,
            next: next,
            agentChanged: agentChanged,
            processExited: processExited,
            now: now,
        ) {
            return false
        }
        let refreshDue = Self.stableVisibleSignalRefreshDue(
            previous: previous,
            next: next,
            lastRefresh: lastRefresh,
            now: now,
        )
        return Self.shouldPublish(
            previous: previous,
            next: next,
            agentChanged: agentChanged,
            processExited: processExited,
            refreshDue: refreshDue,
        )
    }
}
