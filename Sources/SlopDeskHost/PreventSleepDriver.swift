import Foundation

// MARK: - The prevent-sleep DRIVER (cross-platform, testable)

/// The minimal sink the prevent-sleep driver drives: set the desired held state of a system-sleep assertion.
/// The macOS glue (``PreventSleepAssertion``) is the production conformer; a unit test supplies a fake so the
/// driver's apply-ordering is exercised WITHOUT ever instantiating a real `IOPMAssertion` (the
/// code-reviewed-only / hang-safety posture for power-management resources). Cross-platform so the driver
/// itself unit-tests on the headless macOS `swift test` host even though the real assertion is macOS-only.
public protocol PreventSleepAsserting: AnyObject, Sendable {
    /// Drives the assertion to `desired`, returning the resulting held state. Idempotent.
    @discardableResult
    func setAsserted(_ desired: Bool) -> Bool
}

/// Aggregates each pane's agent `.working` transition into a set and drives a STRICTLY BALANCED system-sleep
/// assertion via ``PreventSleepPolicy`` (assert on the first working pane, release when none remain).
/// `slopdesk-hostd` registers ``note(paneId:working:)`` on the existing P1 agent-status fan-out
/// (``HostServer/observeAgentStatusForPreventSleep(_:)``), which calls its observers OUTSIDE its own lock and
/// from MULTIPLE threads — the foreground-poll thread (normal status transitions) AND the mux receive loop's
/// teardown fan (`fanAgentTeardown` from a tab close / child exit / link drop / ctl kill).
///
/// The driver therefore guards BOTH the working-pane set AND the assertion apply under ONE lock, so the state
/// pushed to the asserter always reflects the latest set: two interleaved `note()` calls can never apply
/// `setAsserted` in an order that disagrees with the final set. Were the apply done OUTSIDE the lock (pane "a"
/// finishing on thread A while pane "b" finishes on thread B), A could compute `anyWorking=true` (b still in
/// the set), release the lock, let B remove the last pane and apply `false`, then apply its stale `true` —
/// leaving the assertion HELD with an empty set: a leaked `kIOPMAssertionTypePreventUserIdleSystemSleep` that
/// keeps the Mac awake until the next clean transition (it does NOT self-heal). That is the exact balance
/// directive the `EnableSecureEventInput` lesson mirrors. ``PreventSleepAssertion`` has its OWN internal lock
/// and never re-enters the driver, so holding this lock across `setAsserted` cannot deadlock.
/// `@unchecked Sendable`: all mutable state is lock-guarded.
public final class PreventSleepDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var workingPanes: Set<String> = []
    private let asserter: PreventSleepAsserting
    private let enabled: Bool

    public init(enabled: Bool, asserter: PreventSleepAsserting) {
        self.enabled = enabled
        self.asserter = asserter
    }

    /// Records a pane's `.working` transition and applies the resulting assertion state — the set mutation AND
    /// the apply happen UNDER THE LOCK so a concurrent `note()` can never compute its `anyWorking` against a
    /// different set than the one it applies (the apply-outside-lock leak above).
    public func note(paneId: String, working: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if working { workingPanes.insert(paneId) } else { workingPanes.remove(paneId) }
        let anyWorking = !workingPanes.isEmpty
        asserter.setAsserted(PreventSleepPolicy.shouldAssert(anyAgentWorking: anyWorking, enabled: enabled))
    }
}
