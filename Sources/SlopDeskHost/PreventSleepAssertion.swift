#if os(macOS)
import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - E13 WI-3 (ES-E13-3): the macOS prevent-sleep assertion glue (code-reviewed only)

/// Holds a SINGLE `IOPMAssertion` (`kIOPMAssertionTypePreventUserIdleSystemSleep`) and drives it to a
/// desired state, STRICTLY BALANCED: it creates the assertion exactly once on a false→true edge and releases
/// it exactly once on a true→false edge; a no-op when already in the desired state. This mirrors the
/// `EnableSecureEventInput` balance lesson — a leaked assertion would keep the Mac awake forever, so every
/// create has its paired release (incl. on `deinit`).
///
/// `slopdesk-hostd` drives this from the agent `.working` aggregate (via ``PreventSleepPolicy``). It is
/// macOS-host-only and **code-reviewed, never instantiated in a test** (the same posture as the SCStream /
/// VideoToolbox glue) — `IOPMAssertion` is a real power-management resource. `@unchecked Sendable` + an
/// internal lock so the driver can call ``setAsserted(_:)`` from the foreground-poll thread without a data
/// race on the held flag / assertion id.
public final class PreventSleepAssertion: PreventSleepAsserting, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID = IOPMAssertionID(0)
    private var held = false
    private let reason: String

    /// - Parameter reason: the human-readable assertion name shown in `pmset -g assertions` (diagnostic only).
    public init(reason: String = "slopdesk: agent working") {
        self.reason = reason
    }

    /// Whether the assertion is currently held (thread-safe read).
    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Drives the assertion to `desired`, returning the resulting held state. Idempotent: creating when
    /// already held, or releasing when already released, is a no-op. A failed create leaves the assertion
    /// un-held (validate-then-default — never marks held on a non-success `IOReturn`).
    @discardableResult
    public func setAsserted(_ desired: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if desired, !held {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id,
            )
            guard result == kIOReturnSuccess else { return false }
            assertionID = id
            held = true
        } else if !desired, held {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            held = false
        }
        return held
    }

    deinit {
        // Final balance: release a still-held assertion so a daemon teardown never leaks it.
        if held { IOPMAssertionRelease(assertionID) }
    }
}
#endif
