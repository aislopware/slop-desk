import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Keeps the HOST's display awake while at least one full-desktop (display-target) session is
/// streaming — a client watching the desktop must never have the picture go dark because the host's
/// display-sleep timer fired mid-session (the stream itself does not count as "user activity").
///
/// One process-wide refcount over every streaming display session: the first holder raises ONE
/// `PreventUserIdleDisplaySleep` power assertion, the last release drops it. Window-target sessions
/// never hold (a `.systemDialog` stream is ephemeral and its dialog survives display sleep — the
/// desktop stream is the one a person is actively LOOKING at).
///
/// Thread-safe (`NSLock` — callers are per-session actors). The IOKit calls are seam-injected so
/// the refcount/idempotence logic unit-tests with fakes (no real power assertion side effects in a
/// test run; the hang-safety rule is untouched — no SCStream/VT/Metal here).
public final class HostDisplayWake: @unchecked Sendable {
    /// Raises the assertion; returns an opaque id, or `nil` when the platform call failed (the
    /// coordinator then stays inactive and the NEXT 0→1 acquire retries).
    typealias Raise = () -> UInt32?
    typealias Drop = (UInt32) -> Void

    public static let shared = HostDisplayWake()

    private let lock = NSLock()
    private var holders = 0
    private var assertionID: UInt32?
    private let raise: Raise
    private let drop: Drop

    init(
        raise: @escaping Raise = HostDisplayWake.raiseSystemAssertion,
        drop: @escaping Drop = HostDisplayWake.dropSystemAssertion,
    ) {
        self.raise = raise
        self.drop = drop
    }

    /// One more streaming display session. First holder raises the assertion.
    public func acquire() {
        lock.lock()
        defer { lock.unlock() }
        holders += 1
        guard assertionID == nil else { return }
        assertionID = raise()
    }

    /// One streaming display session ended. Unbalanced calls clamp at zero (validate-then-drop —
    /// a double release must never underflow into "assertion held forever").
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        holders = max(0, holders - 1)
        guard holders == 0, let id = assertionID else { return }
        drop(id)
        assertionID = nil
    }

    /// Test-visible: whether the assertion is currently raised.
    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    private static func raiseSystemAssertion() -> UInt32? {
        #if canImport(IOKit)
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SlopDesk remote desktop session attached" as CFString,
            &id,
        )
        return status == kIOReturnSuccess ? id : nil
        #else
        return nil
        #endif
    }

    private static func dropSystemAssertion(_ id: UInt32) {
        #if canImport(IOKit)
        IOPMAssertionRelease(IOPMAssertionID(id))
        #endif
    }
}
