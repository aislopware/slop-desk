import CoreGraphics
import Foundation
import SlopDeskProtocol

/// The seam between the byte pipeline and a terminal renderer.
///
/// PATH 1 streams raw VT bytes from the host PTY to the client; **how** those bytes
/// become pixels is hidden behind this protocol. The production renderer is
/// **libghostty** (see `DECISIONS.md`): a
/// `GhosttySurface` conforming to `TerminalSurface` lives in the GUI app target
/// (WF-5), where it owns a `ghostty_surface_t` in a Metal view. The headless core
/// here never links libghostty.
///
/// ``HeadlessTerminalSurface`` is the in-package conformer used by tests and the
/// headless `slopdesk-client` CLI.
///
/// ### Concurrency
/// libghostty's `feed_data`/`refresh`/`draw` are main-thread-only ([18 C]), so the
/// real renderer will be `@MainActor`. This protocol does not impose an isolation;
/// conformers state their own. `onWrite` fires when the surface produces bytes to
/// send back to the host (encoded keystrokes), which the client wraps in `input`.
public protocol TerminalSurface: AnyObject {
    /// Feeds inbound PTY/VT bytes (an `output` payload) into the renderer.
    func feed(_ bytes: Data)

    /// Feeds a BATCH of output payloads, flushing the renderer ONCE at the end.
    ///
    /// The batch-drain ingest path uses this so a backlog of N wire chunks costs one
    /// render flush instead of N. The default implementation simply feeds each chunk
    /// (per-chunk flush — correct, just unbatched); renderers with a separate
    /// write/flush split (GhosttySurface) override it to write all chunks and
    /// refresh/present once. Must be fully synchronous (doc-18-§C: no suspension
    /// between writes and the flush).
    func feedBatch(_ chunks: ArraySlice<Data>)

    /// Sets the terminal grid size; mirrored to the host via `resize`.
    func setSize(cols: UInt16, rows: UInt16)

    /// Handles user input already encoded as terminal bytes (e.g. from a test or a
    /// headless driver). The real GUI surface routes keys through
    /// `ghostty_surface_key` and emits bytes via ``onWrite``.
    func handleInput(_ bytes: Data)

    /// Called when the surface has bytes to send back to the host (keystrokes the
    /// renderer encoded). The client encodes these as ``WireMessage/input(_:)``.
    var onWrite: ((Data) -> Void)? { get set }
}

public extension TerminalSurface {
    /// Default: feed each chunk individually (per-chunk flush). Renderers with a
    /// write/flush split override for one flush per batch.
    func feedBatch(_ chunks: ArraySlice<Data>) {
        for chunk in chunks {
            feed(chunk)
        }
    }
}

// MARK: - TerminalSurfaceActions (the W14 editor-action capability seam)

/// The OPTIONAL capability seam (docs/42 W14) the right-click context menu and the ⌘F find bar drive: a
/// renderer that wraps a real terminal (``GhosttySurface``) exposes selection state + named keybinding
/// actions + scrollback search through these, so the SwiftUI find bar / `NSMenu` route through the SEAM
/// instead of importing libghostty. Headless conformers (tests, the CLI) DO NOT conform — the GUI probes
/// with `as? TerminalSurfaceActions` and degrades gracefully (a no-selection, no-search surface), exactly
/// like ``FeedBackpressuring``. None of these are exercised in a test (the real surface hangs without a
/// window server — the hang-safety rule); they are compiled + code-reviewed, and their PURE inputs
/// (``TerminalSearchController`` over a text mirror) carry the unit tests.
public protocol TerminalSurfaceActions: AnyObject {
    /// Whether the surface currently holds a text selection (gates Copy in the context menu).
    func hasSelection() -> Bool

    /// The current selection as text, or `nil` (drives "copy" + the find-from-selection seed).
    func readSelection() -> String?

    /// Fires a named libghostty keybinding action (`copy_to_clipboard` / `paste_from_clipboard` /
    /// `select_all` / `clear_screen` / `jump_to_prompt:-1` / `start_search:<needle>` …). Returns whether it
    /// ran. The single lever the menu + find bar + jump-to-prompt all route through.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool

    /// A flat, line-oriented text mirror of the visible scrollback (newest screen + retained scrollback),
    /// for the client-side ``TerminalSearchController`` fallback when libghostty's in-surface search result
    /// callbacks are not plumbed through the C `action_cb`. One entry per line, no trailing newline.
    func scrollbackTextLines() -> [String]

    /// The live grid COLUMN count, used to map an unwrapped LOGICAL scrollback line index (the index into
    /// ``scrollbackTextLines()``, whose soft-wrapped rows are collapsed) to the PHYSICAL grid row
    /// libghostty's `scroll_to_row:` addresses. `0` ⇒ unknown (headless / pre-layout), in which case the
    /// caller treats the mapping as the identity (no wrap compensation). A protocol requirement with a
    /// default so existing conformers (tests, the CLI) need not implement it — only the libghostty surface does.
    func scrollbackGridColumns() -> Int
}

public extension TerminalSurfaceActions {
    /// Default: grid width unknown (headless / preview conformers) ⇒ no wrap compensation.
    func scrollbackGridColumns() -> Int { 0 }
}

// MARK: - TerminalViewportSnapshotting (the E10 WI-2 overlay-geometry capability seam)

/// The VISIBLE-grid geometry of a live terminal surface, in **points** (not pixels), used by the E10
/// link-underline (WI-5) and Hint Mode (WI-9) overlays to map a detected `(row, colStart ..< colEnd)`
/// span (``TerminalLinkDetector``'s display-cell columns) straight to a `CGRect` in the view's
/// coordinate space.
///
/// Every field is in POINTS in the embedding view's top-left-origin coordinate space (the same
/// convention the surface's `sendMousePos` already uses): `originX`/`originY` is the viewport's
/// top-left, `cellWidth`/`cellHeight` the per-cell advance (a fullwidth/East-Asian-wide glyph occupies
/// two cells), and `cols`/`rows` the visible grid. `Sendable` so an overlay can snapshot the geometry
/// across the `@MainActor` boundary without retaining the surface; `Equatable` so a view can skip a
/// redraw when nothing moved.
public struct TerminalCellMetrics: Sendable, Equatable {
    /// Per-cell advance width in points.
    public var cellWidth: CGFloat
    /// Per-cell line height in points.
    public var cellHeight: CGFloat
    /// Visible viewport columns (NOT the retained scrollback).
    public var cols: Int
    /// Visible viewport rows (NOT the retained scrollback).
    public var rows: Int
    /// Viewport top-left X in the view's coordinate space (points).
    public var originX: CGFloat
    /// Viewport top-left Y in the view's coordinate space (points).
    public var originY: CGFloat

    public init(
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        cols: Int,
        rows: Int,
        originX: CGFloat = 0,
        originY: CGFloat = 0,
    ) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.cols = cols
        self.rows = rows
        self.originX = originX
        self.originY = originY
    }

    /// Maps a detector `(row, colStart ..< colEnd)` cell span to its rect in the view's coordinate
    /// space. The SINGLE source of truth the underline + hint-label overlays both reuse, so the
    /// geometry can never drift between them.
    ///
    /// Plain separate `*` then `+` (NEVER `addingProduct`/`fma`, per CLAUDE.md §2 — this is view
    /// geometry, not the codec/controller cluster, but the habit is kept):
    /// `x = originX + cellWidth*colStart`, `width = cellWidth*(colEnd − colStart)`. `colEnd` is
    /// exclusive (matching ``TerminalLinkDetector``).
    public func rect(row: Int, colStart: Int, colEnd: Int) -> CGRect {
        let x = originX + cellWidth * CGFloat(colStart)
        let y = originY + cellHeight * CGFloat(row)
        let width = cellWidth * CGFloat(colEnd - colStart)
        return CGRect(x: x, y: y, width: width, height: cellHeight)
    }

    /// The ``rect(row:colStart:colEnd:)`` for a span CLAMPED to the visible grid, or `nil` when the span
    /// starts at or beyond the last visible column (`colStart >= cols`) — so a decoration is NEVER drawn
    /// off-screen-right. `colEnd` is clamped to ``cols`` (a span that runs past the grid edge is trimmed to
    /// the edge). The E10 overlays (WI-5 underline, WI-9 hint labels) map every span through THIS, not the
    /// raw ``rect`` — defence in depth for the per-grid-row viewport read (FINDING 3): even if a span's
    /// `colStart` lands past the grid width (e.g. a long line whose own `colStart` would otherwise overshoot)
    /// it is skipped rather than painted in the void. A degenerate clamp (`colEnd <= colStart` after
    /// clamping) also returns `nil`.
    public func clampedRect(row: Int, colStart: Int, colEnd: Int) -> CGRect? {
        guard cols > 0, colStart >= 0, colStart < cols else { return nil }
        let clampedEnd = min(colEnd, cols)
        guard clampedEnd > colStart else { return nil }
        return rect(row: row, colStart: colStart, colEnd: clampedEnd)
    }
}

/// The OPTIONAL capability seam (mirrors ``TerminalSurfaceActions``) that exposes the visible
/// viewport's text + geometry so the E10 overlays render at the exact cell.
///
/// Like ``TerminalSurfaceActions`` this is a SEPARATE protocol the GUI probes with
/// `as? TerminalViewportSnapshotting`: the libghostty-backed `GhosttySurface` conforms (app target),
/// while headless conformers (tests, the CLI ``HeadlessTerminalSurface``) and the
/// `BuildStatusPlaceholderView` placeholder DO NOT — so `cellMetrics()` is absent and the overlays
/// simply do not render. That is the HONEST ceiling: an absent underline, never a wrong one (no faked
/// overlay over a placeholder). Not exercised by a test (the real surface hangs without a window server
/// — the hang-safety rule); the pure geometry it feeds is unit-tested via ``TerminalCellMetrics`` +
/// ``TerminalLinkDetector``.
public protocol TerminalViewportSnapshotting: AnyObject {
    /// The VISIBLE viewport rows top→bottom (NOT the retained scrollback — that is
    /// ``TerminalSurfaceActions/scrollbackTextLines()``). One entry per visible row, no trailing
    /// newline; the returned index is the `row` the overlays feed back through ``TerminalCellMetrics``.
    func viewportTextRows() -> [String]

    /// The live cell geometry, or `nil` when there is no live surface (headless / placeholder) — in
    /// which case the overlays do not render.
    func cellMetrics() -> TerminalCellMetrics?
}

/// Backpressure seam for renderers whose ``TerminalSurface/feed(_:)`` is an
/// ASYNCHRONOUS enqueue (GhosttySurface's per-surface serial feed queue, docs/31 #5).
///
/// A SEPARATE `Sendable` protocol (not a `TerminalSurface` requirement with a default):
/// the ingest pump must `await` this from the main actor, and awaiting a nonisolated
/// async member on a non-Sendable `any TerminalSurface` existential is a Swift 6
/// sending violation. Synchronous renderers (headless, tests) simply don't conform —
/// the pump's `as?` probe skips them with zero overhead change.
public protocol FeedBackpressuring: Sendable {
    /// Parks until the renderer can absorb more feed work — i.e. its queued-but-
    /// unparsed backlog is below a high-water mark. The ingest pump awaits this before
    /// each pass so wire flow control (credit-at-consumption) stays coupled to actual
    /// parse progress; without it a flood turns the feed queue into an unbounded
    /// buffer. Must always resolve in bounded time.
    func feedBackpressure() async
}
