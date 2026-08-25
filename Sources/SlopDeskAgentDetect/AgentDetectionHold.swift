import CSlopDeskFFI
import Foundation

/// The six timings of the temporal layer, as `rust/slopdesk-agent::hold` spells them.
///
/// ## This is a NAME for six numbers, not a machine
/// The machine that uses them — the working→idle confirmation hold, the publish-worthiness gate, the
/// steady visible-blocker heartbeat — is `rust/slopdesk-agent::panescan`, and the only thing that
/// drives it is ``PaneScreenScanner`` over the `slopdesk_pane_scan_*` doors. What used to be here
/// was a Swift handle re-deciding *when* to call each of those rules, one tick at a time; that
/// sequencing is the crate's now, so the handle is gone.
///
/// What survives is the reason the constants were ever public: a test that asserts a scanner tightened
/// its cadence has to name the interval it tightened to, and a number typed a second time in Swift is
/// exactly the drift `make lint-invariants` exists to catch. They are read through the door, so there
/// is still only one copy.
public enum AgentDetectionHold {
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
}
