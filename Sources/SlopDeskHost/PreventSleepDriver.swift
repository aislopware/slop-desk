import CSlopDeskFFI
import Foundation

/// hostd's "keep the Mac awake while an agent is working" driver — a face over
/// `slopdesk-ffi`'s `power` doors.
///
/// ## What is left here
/// The lock, and nothing else. Rust owns the working-pane set (`slopdesk_agent::sleep::PreventSleep`),
/// the opt-in rule, and the `IOPMAssertion` itself (`slopdesk-apple-power`) — and it owns them
/// TOGETHER, behind one door, which is the point of the port. The Swift version kept the set and the
/// assertion as two objects and asked every caller to hold a lock across both; the failure that
/// slips past a reviewer is one thread applying a verdict computed against a set another thread has
/// already changed, leaving the assertion held over an empty set. That does not self-heal, and it
/// keeps the Mac awake until the daemon dies. Behind the door the update and the apply are one
/// statement.
///
/// The lock stays because the door carries the handle convention of `docs/55` §4 — no two calls on
/// one handle may overlap — and `slopdesk-hostd` registers ``note(paneId:working:)`` on the agent-status
/// fan-out (``HostServer/observeAgentStatusForPreventSleep(_:)``), which calls its observers from
/// MULTIPLE threads: the foreground-poll thread on a normal transition, and the mux receive loop's
/// teardown fan on a tab close, child exit, link drop or ctl kill.
///
/// The other two handle obligations are met the usual way: exactly one `free` per `new` (in
/// `deinit`, which also RELEASES a still-held assertion — the teardown guarantee), and nothing
/// allocated on one side and freed on the other.
///
/// `@unchecked Sendable`: the handle is only ever touched under the lock.
public final class PreventSleepDriver: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: OpaquePointer

    /// - Parameter enabled: the `SLOPDESK_AGENT_PREVENT_SLEEP` opt-in, read once at launch. There is
    ///   no live config reload; a host restart is the reload.
    public init(enabled: Bool) {
        // Rust returns null only if the allocation failed, and it aborts on allocation failure
        // before it could — so this is unreachable rather than unhandled.
        guard let handle = slopdesk_prevent_sleep_new(enabled) else {
            preconditionFailure("slopdesk_prevent_sleep_new returned null")
        }
        self.handle = handle
    }

    deinit {
        slopdesk_prevent_sleep_free(handle)
    }

    /// Records a pane's `.working` transition and drives the assertion to the resulting state.
    public func note(paneId: String, working: Bool) {
        let pane = Array(paneId.utf8)
        lock.lock()
        // The door answers the state it reached; nothing here needs it, and `isAsserted` is the
        // question a caller that does would ask.
        pane.withUnsafeBufferPointer { bytes in
            _ = slopdesk_prevent_sleep_note(handle, bytes.baseAddress, bytes.count, working)
        }
        lock.unlock()
    }

    /// Whether the assertion is held right now. Diagnostic; the driver never asks itself.
    public var isAsserted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return slopdesk_prevent_sleep_is_held(handle)
    }
}
