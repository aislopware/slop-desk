import Foundation
import SlopDeskVideoProtocol

// PURE host-window feed snapshot logic (docs/45 host-windows rail). No AppKit, no CoreGraphics —
// the videohostd glue enumerates `CGWindowListCopyWindowInfo` into ``WindowFeedSourceWindow``s and
// everything from there (inclusion, flags, caps, ordering) is deterministic and headless-tested,
// exactly the `SystemDialogDetector` split.

/// One raw host window as the enumeration glue sees it — the CGWindowList-shaped input record.
/// Order in the array is the enumeration's z-order (front-to-back); the builder preserves it.
public struct WindowFeedSourceWindow: Equatable, Sendable {
    public var windowID: UInt32
    /// `kCGWindowOwnerName` ("" when absent) — the inclusion-policy + section key.
    public var ownerName: String
    /// The owning app's bundle identifier ("" when the process has none) — icon cache key.
    public var bundleID: String
    /// `kCGWindowLayer` — only layer 0 (normal app windows) is listable.
    public var layer: Int
    /// `kCGWindowIsOnscreen` — false ⇒ minimized / other Space / hidden app.
    public var isOnScreen: Bool
    /// `kCGWindowName` (needs Screen Recording TCC, which the daemon already holds; "" when absent).
    public var title: String
    /// Window size in points (CG bounds).
    public var widthPt: Int
    public var heightPt: Int
    /// Ordinal of the display whose bounds best contain the window (0 when unknown/single-display).
    public var displayIndex: UInt8
    /// `NSRunningApplication.isHidden` for the owning app (best-effort; false when unknown).
    public var isAppHidden: Bool
    /// Whether the owning app is `NSWorkspace.frontmostApplication`.
    public var isFrontmostApp: Bool
    /// `AXMinimized` (best-effort, budgeted — Phase 5; false when not probed).
    public var isMinimized: Bool
    /// Whether the AX probe has seen this window in its app's `kAXWindows` list (best-effort,
    /// budgeted; false when not probed). Off-screen windows need this evidence to be listed — see
    /// ``WindowFeedSnapshotBuilder/records(from:)``.
    public var isAXListed: Bool

    public init(
        windowID: UInt32,
        ownerName: String,
        bundleID: String,
        layer: Int,
        isOnScreen: Bool,
        title: String,
        widthPt: Int,
        heightPt: Int,
        displayIndex: UInt8 = 0,
        isAppHidden: Bool = false,
        isFrontmostApp: Bool = false,
        isMinimized: Bool = false,
        isAXListed: Bool = false,
    ) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.title = title
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.displayIndex = displayIndex
        self.isAppHidden = isAppHidden
        self.isFrontmostApp = isFrontmostApp
        self.isMinimized = isMinimized
        self.isAXListed = isAXListed
    }
}

/// Which host windows appear in the picker AND the feed — the ONE inclusion policy, extracted from
/// the picker's `pickerSummary` so the two surfaces can never drift (docs/45 §6).
public enum WindowFeedInclusionPolicy {
    /// System apps whose windows are never useful to stream (docs/31): desktop chrome, indicators.
    /// "Cua Driver" is the cua automation agent's transparent full-display cursor overlay — a real
    /// on-screen layer-0 window with nothing visible in it (user report 2026-07-12).
    public static let excludedSystemApps: Set<String> = [
        "", "Window Server", "Control Center", "Dock", "Notification Center", "Spotlight", "Wallpaper",
        "Cua Driver",
    ]

    /// Phantom utility windows that survive the off-screen AX-evidence gate because their app
    /// genuinely lists them in `kAXWindows` yet they never render: Finder's App Store `asverify`
    /// receipt-verification window (user report 2026-07-12). Keyed (ownerName → titles) to stay
    /// surgical — real windows of the same app are untouched.
    static let junkTitlesByOwner: [String: Set<String>] = ["Finder": ["asverify"]]

    /// Windows under this size (points) are tiny indicators/popups, not streamable app windows.
    public static let minDimensionPt = 80

    /// The shared picker/feed verdict for one window.
    public static func includes(ownerName: String, title: String = "", widthPt: Int, heightPt: Int) -> Bool {
        !excludedSystemApps.contains(ownerName)
            && junkTitlesByOwner[ownerName]?.contains(title) != true
            && widthPt >= minDimensionPt && heightPt >= minDimensionPt
    }
}

/// Maps raw enumeration windows to the wire ``HostWindowRecord``s of one snapshot: inclusion
/// filter, wire-cap string truncation, flag assembly, the single `focusedWindow` bit, and the
/// 64-record cap — z-order preserved.
public enum WindowFeedSnapshotBuilder {
    /// Post-filter record cap (typical desktops are < 40; revisit only on evidence — docs/45 §5).
    public static let maxRecords = 64
    /// Wire caps for the two identity strings (the title cap lives on the codec —
    /// ``VideoControlMessage/feedTitleMaxBytes`` — because it is part of the packing contract).
    public static let bundleIDMaxBytes = 128
    public static let appNameMaxBytes = 64

    public static func records(from windows: [WindowFeedSourceWindow]) -> [HostWindowRecord] {
        var out: [HostWindowRecord] = []
        // Exactly ONE record carries `focusedWindow`: the frontmost app's first on-screen window in
        // z-order (CGWindowList lists front-to-back, so the first hit IS the focused one).
        var focusedAssigned = false
        for w in windows {
            guard w.layer == 0,
                  WindowFeedInclusionPolicy.includes(
                      ownerName: w.ownerName, title: w.title, widthPt: w.widthPt, heightPt: w.heightPt,
                  )
            else { continue }
            // Off-screen windows need AX EVIDENCE to be listed (user report 2026-07-11: the rail
            // drowned in `.optionAll` phantoms — Chrome tab caches, panel services, `loginwindow`,
            // 16 of 27 records). A REAL off-screen window (minimized, other Space, hidden app) shows
            // up in its app's `kAXWindows`; phantom caches never do. Alpha/sharing-state were dead
            // ends (all 1.0/1). Cold cost: a real off-screen window may hide for the probe's first
            // few budgeted ticks (≤3 pids/s, 3 s TTL) before appearing — junk-free beats instant.
            guard w.isOnScreen || w.isMinimized || w.isAXListed else { continue }
            var flags: HostWindowFlags = []
            if w.isOnScreen { flags.insert(.onScreen) }
            if w.isMinimized { flags.insert(.minimized) }
            if w.isAppHidden { flags.insert(.appHidden) }
            if w.isFrontmostApp { flags.insert(.frontmostApp) }
            if w.isFrontmostApp, w.isOnScreen, !focusedAssigned {
                flags.insert(.focusedWindow)
                focusedAssigned = true
            }
            out.append(HostWindowRecord(
                windowID: w.windowID,
                widthPt: UInt16(clamping: w.widthPt),
                heightPt: UInt16(clamping: w.heightPt),
                flags: flags,
                displayIndex: w.displayIndex,
                bundleID: truncatedUTF8(w.bundleID, maxBytes: bundleIDMaxBytes),
                appName: truncatedUTF8(w.ownerName, maxBytes: appNameMaxBytes),
                title: truncatedUTF8(w.title, maxBytes: VideoControlMessage.feedTitleMaxBytes),
            ))
            if out.count >= maxRecords { break }
        }
        return out
    }

    /// Truncates to at most `maxBytes` of UTF-8 WITHOUT splitting a grapheme (dropping whole
    /// `Character`s from the end) — a split scalar would decode to a replacement char client-side.
    /// Also bounds the worst-case record size so the greedy chunk packer always progresses.
    static func truncatedUTF8(_ string: String, maxBytes: Int) -> String {
        var result = string
        while result.utf8.count > maxBytes { result.removeLast() }
        return result
    }
}
