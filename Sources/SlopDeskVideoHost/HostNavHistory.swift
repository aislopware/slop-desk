#if os(macOS)
import CSlopDeskFFI
import Foundation

/// Reads the frontmost target's LIVE canGoBack/canGoForward for the `SwipeNavStatusMessage.navFlags`
/// push (doc 20 §9.6): the swipe-nav chip must not promise a navigation the browser cannot perform,
/// because Back greyed out means ⌘[ is a no-op and the chip would animate a page turn that never
/// happened.
///
/// Everything below the call is `slopdesk-ffi`'s `nav_history`, which is where the two strategies,
/// the walk bounds, the per-window currency rule and the cache live now. The file this replaced
/// carried a standing note that no unit test could reach it — every reading is blocking
/// out-of-process AX IPC against a live browser — and what rode along under that note was four
/// rules that never needed a browser to be true. They are thirteen tests in
/// `slopdesk_video::nav_history` now.
///
/// EVERY call blocks on IPC, bounded by the crate's own per-message cap and scan deadline. Call off
/// the main actor only, and never from unit tests: this is process-external state, the same rule as
/// `SCStream` and VideoToolbox.
///
/// ⚠️ **GUI-ONLY + TCC:** needs the Accessibility grant. Without it every read answers nil, and nil
/// ships `historyKnown=false` — the client FAILS OPEN to the pre-gate behaviour.
public final class HostNavHistory: @unchecked Sendable {
    private let handle: OpaquePointer?

    public init() {
        handle = slopdesk_nav_history_new()
    }

    deinit {
        slopdesk_nav_history_free(handle)
    }

    /// The current Back/Forward availability for `pid`, or nil when unknown (fail open).
    ///
    /// `rescanUnknown` lets the slow heartbeat retry a pid whose last scan found no pair, while the
    /// fast change-poll skips it — without it a browser with no windows costs a full walk four
    /// times a second forever. `verifyWindow` is that same beat's permission to spend one extra
    /// round trip confirming a toolbar pair still belongs to the focused window; between forced
    /// beats an intra-app window switch can serve the old window's flags for up to about two
    /// seconds, which is cosmetic because the FIRE path is ungated.
    public func read(pid: pid_t, rescanUnknown: Bool, verifyWindow: Bool) -> NavHistoryFlags? {
        var flags = SlopDeskNavFlags()
        guard slopdesk_nav_history_read(handle, pid, rescanUnknown, verifyWindow, &flags) else {
            return nil
        }
        return NavHistoryFlags(canGoBack: flags.can_go_back, canGoForward: flags.can_go_forward)
    }
}
#endif
