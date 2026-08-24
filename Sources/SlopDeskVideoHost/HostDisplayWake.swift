import CSlopDeskFFI
import Foundation

/// Keeps the HOST's display awake while at least one full-desktop (display-target) session is
/// streaming — a face over `slopdesk-ffi`'s `power` doors.
///
/// A client watching the desktop must never have the picture go dark because the host's
/// display-sleep timer fired mid-session: the stream is not "user activity" as far as the window
/// server is concerned, because nobody is touching that Mac's keyboard.
///
/// ## What is left here
/// The lock and the singleton. Rust owns the refcount (`slopdesk_video::display_wake`) and the
/// `IOPMAssertion` (`slopdesk-apple-power`), behind one door, so the count and the apply cannot
/// interleave — and the count CLAMPS at zero rather than underflowing, which is the failure a
/// double teardown would otherwise turn into a screen that stays lit until the daemon dies.
///
/// Window-target sessions never hold: the desktop stream is the one a person is actively LOOKING at.
/// That choice is this caller's — it acquires or it does not — because which target a session has is
/// the session's own state.
///
/// The three handle obligations of `docs/55` §4 are met here: exactly one `free` per `new` (in
/// `deinit`, which also releases a still-held assertion), no overlapping calls (the `NSLock` — the
/// callers are per-session actors), and nothing allocated on one side and freed on the other.
public final class HostDisplayWake: @unchecked Sendable {
    public static let shared = HostDisplayWake()

    private let lock = NSLock()
    private let handle: OpaquePointer

    init() {
        // Rust returns null only if the allocation failed, and it aborts on allocation failure
        // before it could — so this is unreachable rather than unhandled.
        guard let handle = slopdesk_display_wake_new() else {
            preconditionFailure("slopdesk_display_wake_new returned null")
        }
        self.handle = handle
    }

    deinit {
        slopdesk_display_wake_free(handle)
    }

    /// One more streaming display session. The first holder raises the assertion.
    ///
    /// Both doors answer whether the assertion is now held; nothing here asks. There is deliberately
    /// no `isHolding` accessor to read it back — a face that exposes one exports a door with no
    /// reader, and the count it would report is the far side's to keep.
    public func acquire() {
        lock.lock()
        slopdesk_display_wake_acquire(handle)
        lock.unlock()
    }

    /// One streaming display session ended. Unbalanced calls clamp at zero on the far side.
    public func release() {
        lock.lock()
        slopdesk_display_wake_release(handle)
        lock.unlock()
    }
}
