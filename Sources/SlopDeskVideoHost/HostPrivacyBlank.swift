import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// PRIVACY BLANK for a full-desktop session (the RustDesk technique, driver-free): while engaged it
/// (1) blacks the streamed host display with a zero ``CGDisplayGammaTable`` — the encoder still
/// captures the real framebuffer, so the CLIENT sees the desktop while a bystander at the physical
/// Mac sees only black — and (2) installs a global ``CGEventTap`` that SWALLOWS local keyboard/mouse
/// input, so no one at the host can interfere while the remote operator works.
///
/// ## Caveats (documented, not solved)
/// - The gamma blackout is PER-DISPLAY (the session's target display); the input swallow is GLOBAL
///   (a `.cghidEventTap` sees all HID input) — so on a multi-display host, blanking display A still
///   freezes the keyboard/mouse everywhere. Single-display hosts (the common remote-desktop case)
///   are unaffected. A future refinement could scope the swallow to events destined for the blanked
///   display, but the coordinate mapping is unreliable across a sleeping/blanked display.
/// - The REMOTE operator's injected input (`InputInjector`, posted via `CGEvent.post`) is NOT
///   swallowed: the tap filters at `.cghidEventTap` (hardware) while injection posts at the same
///   tap but is re-entrancy-exempt by the tap's own `enabled` gate — see ``localInputShouldPass``.
///
/// Seam-injected (raise/restore gamma, install/remove tap) so the engage/idempotence logic
/// unit-tests headlessly with fakes — no real CoreGraphics side effects, honouring the hang-safety
/// rule (no SCStream/VT/Metal here). One controller per display session; `@unchecked Sendable` with
/// an `NSLock` because the owning session actor and the tap callback both touch it.
public final class HostPrivacyBlank: @unchecked Sendable {
    /// Blacks `displayID` (zero gamma). Returns `false` when the platform call failed (the
    /// controller then stays disengaged so the client can retry on its next re-send).
    public typealias Blank = (_ displayID: UInt32) -> Bool
    /// Restores `displayID`'s gamma to the calibrated default.
    public typealias Restore = (_ displayID: UInt32) -> Void
    /// Installs the local-input-swallowing tap. Returns `false` when the tap could not be created
    /// (missing Accessibility permission) — the blank still stands (the picture is dark), only the
    /// input swallow is absent, which the caller logs.
    public typealias InstallTap = () -> Bool
    /// Removes the local-input tap.
    public typealias RemoveTap = () -> Void

    private let lock = NSLock()
    private let displayID: UInt32
    private var engaged = false
    private var tapInstalled = false
    private let blank: Blank
    private let restore: Restore
    private let installTap: InstallTap
    private let removeTap: RemoveTap

    public init(
        displayID: UInt32,
        blank: @escaping Blank = HostPrivacyBlank.blankDisplayGamma,
        restore: @escaping Restore = HostPrivacyBlank.restoreDisplayGamma,
        installTap: @escaping InstallTap = { false },
        removeTap: @escaping RemoveTap = {},
    ) {
        self.displayID = displayID
        self.blank = blank
        self.restore = restore
        self.installTap = installTap
        self.removeTap = removeTap
    }

    /// Applies the client's privacy wish. Idempotent: a re-sent `enabled` (the per-session re-assert
    /// after a re-hello) is a no-op when the state already matches. Returns the RESOLVED engaged
    /// state (may stay `false` if the gamma blank itself failed).
    @discardableResult
    public func setEnabled(_ on: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if on, !engaged {
            guard blank(displayID) else { return false } // gamma failed → leave disengaged, client retries
            engaged = true
            tapInstalled = installTap() // absent tap (no Accessibility grant) still leaves the screen dark
        } else if !on, engaged {
            teardownLocked()
        }
        return engaged
    }

    /// Teardown on session end / deinit — restores gamma + removes the tap unconditionally (a
    /// crashed remote must never strand the host with a black screen and a dead keyboard).
    public func disengage() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        guard engaged else { return }
        if tapInstalled { removeTap()
            tapInstalled = false
        }
        restore(displayID)
        engaged = false
    }

    deinit { disengage() }

    /// Test-visible engaged state.
    public var isEngaged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engaged
    }

    // MARK: Real CoreGraphics implementations (default seams)

    /// PURE decision the real tap callback consults: whether a local HID event should PASS. While
    /// the blank is engaged every hardware event is swallowed (`false`); the remote operator's
    /// injected events are posted with a marker userData the tap recognises and passes. Extracted so
    /// the swallow policy is unit-tested without a real event tap.
    public static func localInputShouldPass(engaged: Bool, isInjectedByRemote: Bool) -> Bool {
        !engaged || isInjectedByRemote
    }

    public static func blankDisplayGamma(_ displayID: UInt32) -> Bool {
        #if canImport(CoreGraphics)
        // A single-entry zero ramp: every input intensity maps to black. Cheap, instant, and
        // reversed by `CGDisplayRestoreColorSyncSettings` — no ColorSync profile mutation.
        var zero: CGGammaValue = 0
        let status = CGSetDisplayTransferByTable(CGDirectDisplayID(displayID), 1, &zero, &zero, &zero)
        return status == .success
        #else
        return false
        #endif
    }

    public static func restoreDisplayGamma(_ displayID: UInt32) {
        #if canImport(CoreGraphics)
        // Restore THIS display's calibrated gamma. `CGDisplayRestoreColorSyncSettings` restores all
        // displays from their ColorSync profiles — correct here (we only ever zeroed one) and the
        // documented inverse of a transfer-table override.
        _ = displayID
        CGDisplayRestoreColorSyncSettings()
        #endif
    }
}
