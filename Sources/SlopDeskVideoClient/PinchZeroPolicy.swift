import Foundation

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
public enum PinchZeroPolicy {
    /// App display names where ⌘0 is not a zoom reset. Extend at runtime via
    /// `SLOPDESK_PINCH_ZERO_UNSAFE_APPS` (comma-separated display names) without a rebuild.
    public static let unsafeAppNames: Set<String> = ["Xcode"]

    /// Parses the `SLOPDESK_PINCH_ZERO_UNSAFE_APPS` extension list (comma-separated,
    /// whitespace-tolerant) — same shape as `SwipeNavPolicy.extraApps`.
    public static func extraUnsafe(from raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Whether a smart-zoom ⌘0 may be sent at a pane bound to `appName`.
    public static func allowsReset(appName: String, extraUnsafe: Set<String> = []) -> Bool {
        guard !appName.isEmpty else { return true } // desktop pane / legacy binding — fail open
        return !unsafeAppNames.contains(appName) && !extraUnsafe.contains(appName)
    }
}
