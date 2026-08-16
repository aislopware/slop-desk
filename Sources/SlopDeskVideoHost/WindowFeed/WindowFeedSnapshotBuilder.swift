import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskVideoProtocol

// The Swift face of `rust/slopdesk-video`'s `window_feed_host`, reached through the door of the
// same name. No AppKit, no CoreGraphics — the videohostd glue enumerates
// `CGWindowListCopyWindowInfo` into ``WindowFeedSourceWindow``s and everything from there
// (inclusion, flags, caps, ordering) is the crate's, exactly the `SystemDialogDetector` split.

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
    /// `AXMinimized` (best-effort, budgeted probe; false when not probed).
    public var isMinimized: Bool
    /// Whether the AX probe has seen this window in its app's `kAXWindows` list (best-effort,
    /// budgeted; false when not probed). Off-screen windows need this evidence to be listed — see
    /// `window_feed_host.rs`'s `snapshot_records`.
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

    /// This window flattened for the boundary, its three strings appended to `arena`.
    func row(into arena: inout Data) -> SlopDeskFeedSource {
        var row = SlopDeskFeedSource()
        row.window_id = windowID
        row.owner = Self.intern(ownerName, into: &arena)
        row.bundle = Self.intern(bundleID, into: &arena)
        row.title = Self.intern(title, into: &arena)
        row.layer = Int32(clamping: layer)
        row.width_pt = Int32(clamping: widthPt)
        row.height_pt = Int32(clamping: heightPt)
        row.display_index = displayIndex
        row.is_on_screen = isOnScreen
        row.is_app_hidden = isAppHidden
        row.is_frontmost_app = isFrontmostApp
        row.is_minimized = isMinimized
        row.is_ax_listed = isAXListed
        return row
    }

    /// Appends one string's UTF-8 and answers the span naming it — ``ArenaText/intern(_:into:)``
    /// wearing this door's C struct, which is the only part of it that is about this door.
    private static func intern(_ value: String, into arena: inout Data) -> SlopDeskByteSpan {
        let span = ArenaText.intern(value, into: &arena)
        return SlopDeskByteSpan(offset: span.offset, length: span.length)
    }
}

/// Which host windows appear in the picker AND the feed — the ONE inclusion policy, so the two
/// surfaces can never drift (docs/45 §6). The excluded apps and the minimum dimension are the
/// crate's; see `window_feed_host.rs` for why a transparent full-display overlay has to be excluded
/// by NAME rather than by any visual heuristic.
public enum WindowFeedInclusionPolicy {
    /// Windows under this size (points) are tiny indicators/popups, not streamable app windows.
    public static var minDimensionPt: Int { Int(slopdesk_feed_constants().min_dimension_pt) }

    /// The shared picker/feed verdict for one window.
    public static func includes(ownerName: String, title: String = "", widthPt: Int, heightPt: Int) -> Bool {
        let owner = Array(ownerName.utf8)
        let name = Array(title.utf8)
        return owner.withUnsafeBufferPointer { ownerBytes in
            name.withUnsafeBufferPointer { titleBytes in
                slopdesk_feed_includes(
                    ownerBytes.baseAddress, ownerBytes.count,
                    titleBytes.baseAddress, titleBytes.count,
                    Int32(clamping: widthPt), Int32(clamping: heightPt),
                )
            }
        }
    }
}

/// Maps raw enumeration windows to the wire ``HostWindowRecord``s of one snapshot: inclusion
/// filter, wire-cap string truncation, flag assembly, the single `focusedWindow` bit, and the
/// record cap — z-order preserved. All of it `window_feed_host.rs`'s.
public enum WindowFeedSnapshotBuilder {
    /// The builder's fixed numbers, from the door, so neither language writes them down twice.
    private static let law = slopdesk_feed_constants()
    /// Post-filter record cap (typical desktops are < 40; revisit only on evidence — docs/45 §5).
    public static var maxRecords: Int { law.max_records }
    /// Wire caps for the two identity strings (the title cap lives on the codec —
    /// ``VideoControlMessage/feedTitleMaxBytes`` — because it is part of the packing contract).
    public static var bundleIDMaxBytes: Int { law.bundle_id_max_bytes }
    public static var appNameMaxBytes: Int { law.app_name_max_bytes }

    /// The snapshot for one enumeration. Two calls: the first reports the shape, the second fills
    /// the buffers it named — the build is pure, so recomputing costs a pass over at most `maxRecords`
    /// rows, and nothing has to hold an answer nobody asked for.
    public static func records(from windows: [WindowFeedSourceWindow]) -> [HostWindowRecord] {
        var arena = Data()
        let sources = windows.map { window in window.row(into: &arena) }
        return sources.withUnsafeBufferPointer { input in
            arena.withUnsafeBytes { pool -> [HostWindowRecord] in
                let shape = slopdesk_feed_snapshot(
                    input.baseAddress, input.count, pool.baseAddress, pool.count, nil, 0, nil, 0,
                )
                let room = shape.count
                guard room > 0 else { return [] }
                var rows = [SlopDeskControlRecord](repeating: SlopDeskControlRecord(), count: room)
                var built = Data(count: shape.arena_len)
                let filled = rows.withUnsafeMutableBufferPointer { out in
                    built.withUnsafeMutableBytes { outPool in
                        slopdesk_feed_snapshot(
                            input.baseAddress, input.count, pool.baseAddress, pool.count,
                            out.baseAddress, out.count, outPool.baseAddress, outPool.count,
                        )
                    }
                }
                guard filled.count == shape.count else { return [] }
                return rows.map { row in HostWindowRecord.of(row, arena: built) }
            }
        }
    }
}
