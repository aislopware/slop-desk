import Foundation

/// Recognises a two-finger "swipe between pages" flick in the forwarded scroll stream and
/// answers with the history-navigation direction it should be TRANSLATED into (⌘[ / ⌘]).
///
/// WHY A TRANSLATION EXISTS AT ALL: a synthetic phased scroll can NEVER trigger the browser's
/// own swipe-back. Chromium's HistorySwiper needs real `NSTouch` data (trackpad path) or routes
/// into `trackSwipeEventWithOptions:` (Magic-Mouse path), and both reject CGEvent-posted
/// scrolls; Safari behaves the same (probe-verified on macOS 26 across six field variants —
/// phases, ScrollCount, mayBegin, momentum tail, BeginGesture/EndGesture brackets). So the host
/// watches the stream it is already injecting and fires the universal keyboard equivalent
/// instead. See docs/05-input-window-control.md §"Trackpad gestures".
///
/// DECISION POINT IS THE GESTURE END, not mid-stream: a browser can arbitrate scroll-vs-navigate
/// per page (it knows the page is pinned); a remote host cannot. Deciding on the COMPLETED
/// on-glass gesture lets the shape gate out content pans: a navigation flick is short and
/// decisively horizontal, while a horizontal CONTENT pan (spreadsheet, wide code) is longer or
/// drifts vertically. Momentum never participates — the flick's intent is fully expressed by
/// the fingers-on-glass segment, and momentum tails of ordinary pans must not re-arm anything.
///
/// Pure value type: the injector feeds it the (already coalesced) scroll events it posts;
/// coalescing SUMS same-phase deltas and preserves began/ended markers, so the accumulated
/// totals here are identical to the raw gesture's.
public struct SwipeNavRecognizer: Sendable {
    public enum Direction: Equatable, Sendable {
        /// Fingers moved RIGHT (natural scrolling: content follows fingers, revealing the
        /// page to the LEFT) → history BACK — matches the local trackpad convention.
        case back
        /// Fingers moved left → history forward.
        case forward
    }

    /// Minimum accumulated |Σdx| (points) for a flick to count. A deliberate two-finger
    /// navigation flick lands well past this; timid horizontal jitter does not.
    public static let minTravel: Double = 120
    /// Horizontal dominance: |Σdx| must be ≥ this multiple of |Σdy|. Cuts diagonal pans.
    public static let dominance: Double = 3
    /// Maximum began→ended duration (seconds). Content pans run longer; flicks don't.
    public static let maxDuration: TimeInterval = 0.4

    private var tracking = false
    private var startedAt: TimeInterval = 0
    private var sumX: Double = 0
    private var sumY: Double = 0

    public init() {}

    /// Feeds one forwarded scroll event; returns a direction exactly when a completed gesture
    /// qualifies (evaluated on the `ended` marker). `now` is the host arrival clock
    /// (`ProcessInfo.systemUptime`) — wire events carry no timestamps, and arrival time tracks
    /// the gesture closely enough for a 400 ms budget.
    public mutating func ingest(
        dx: Double,
        dy: Double,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        now: TimeInterval,
    ) -> Direction? {
        // Momentum (fingers already lifted) never starts, extends, or finishes a candidate.
        guard momentumPhase == 0 else { return nil }
        switch scrollPhase {
        case 1: // began — a fresh candidate (a real gesture only; wheel notches carry phase 0)
            tracking = continuous
            startedAt = now
            sumX = dx
            sumY = dy
            return nil
        case 2: // changed
            guard tracking else { return nil }
            sumX += dx
            sumY += dy
            return nil
        case 4: // ended — the decision point
            guard tracking else { return nil }
            tracking = false
            sumX += dx
            sumY += dy
            let duration = now - startedAt
            guard duration <= Self.maxDuration,
                  abs(sumX) >= Self.minTravel,
                  abs(sumX) >= Self.dominance * abs(sumY)
            else { return nil }
            return sumX > 0 ? .back : .forward
        case 8: // cancelled — the OS/client abandoned the gesture; never fire from it
            tracking = false
            return nil
        default: // none(0 = wheel notch) / mayBegin(128) / unknown — not part of a candidate
            return nil
        }
    }
}

/// Which HOST apps the swipe translation may drive. ⌘[ / ⌘] is history-back/forward in every
/// mainstream browser and in Finder — but in an editor it is outdent/indent (a TEXT EDIT), so
/// the translation is allow-listed instead of universal: an unknown frontmost app gets the
/// scroll it already received and nothing else.
public enum SwipeNavPolicy {
    /// Bundle ids where ⌘[ / ⌘] means history navigation. Extend at runtime via
    /// `SLOPDESK_SWIPE_NAV_APPS` (comma-separated bundle ids) without a rebuild.
    public static let navigableApps: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.apple.finder",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.kagi.kagimacOS", // Orion
        "app.zen-browser.zen",
    ]

    /// Parses the `SLOPDESK_SWIPE_NAV_APPS` extension list (comma-separated, whitespace-tolerant).
    public static func extraApps(from raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public static func isNavigable(bundleID: String?, extraApps: Set<String> = []) -> Bool {
        guard let bundleID else { return false }
        return navigableApps.contains(bundleID) || extraApps.contains(bundleID)
    }
}
