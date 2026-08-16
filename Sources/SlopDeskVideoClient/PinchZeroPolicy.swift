import CSlopDeskFFI
import SlopDeskVideoProtocol

/// Where the smart-zoom → ⌘0 translation must NOT fire (doc 05 §8).
///
/// ⌘0 is "actual size / reset zoom" in browsers and most documents — but in some apps the
/// same chord means something else entirely (Xcode: toggle the Navigator), so a two-finger
/// double-tap there would rearrange the IDE instead of resetting zoom. Mirrors the
/// swipe-nav allowlist idea, inverted: smart zoom stays ON everywhere except known-unsafe
/// apps (a deliberate double-tap is far less accident-prone than a scroll-adjacent swipe,
/// so a denylist is the right default — and ⌘=/⌘− stay ungated: they ARE the zoom chords in
/// editors too).
///
/// Matching is by app DISPLAY NAME (`RemoteWindowDescriptor.appName`, the picker's
/// "Xcode"/"Google Chrome" style) — bundle ids never reach the client seam. A DESKTOP pane
/// (or a legacy binding with no recorded app) has an empty name and FAILS OPEN: the pane
/// streams a whole display whose frontmost app the client cannot know.
///
/// A face over `client_gestures`, and the one owner of its handle. A handle is right here for the
/// swipe-nav config's reason: the denylist carries a runtime EXTENSION set, which no fold of
/// scalars holds, and this namespace is process-lifetime and never copied.
public enum PinchZeroPolicy {
    /// The parsed denylist — the built-in names plus `SLOPDESK_PINCH_ZERO_UNSAFE_APPS`
    /// (comma-separated display names), read once. `nonisolated(unsafe)` because it is written by
    /// the first reader and only ever READ afterwards; nothing frees it, and the parse outlives
    /// every caller.
    private nonisolated(unsafe) static let handle: OpaquePointer? = {
        guard let raw = EnvConfig.string("SLOPDESK_PINCH_ZERO_UNSAFE_APPS") else {
            return slopdesk_zoom_reset_policy_parse(nil, 0)
        }
        return Array(raw.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_zoom_reset_policy_parse(bytes.baseAddress, bytes.count)
        }
    }()

    /// Whether a smart-zoom ⌘0 may be sent at a pane bound to `appName`.
    public static func allowsReset(appName: String) -> Bool {
        Array(appName.utf8).withUnsafeBufferPointer { name in
            slopdesk_zoom_reset_allowed(handle, name.baseAddress, name.count)
        }
    }
}
