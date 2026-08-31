import CoreGraphics
import CSlopDeskFFI
import Foundation

/// The seam between the byte pipeline and a terminal renderer.
///
/// PATH 1 streams raw VT bytes from the host PTY to the client; **how** those bytes become pixels is
/// hidden behind this protocol. The production renderer is `Sources/SlopDeskTerminal/`, which drives
/// `slopdesk-vterm` (the `libghostty-vt` engine) and `slopdesk-termrender` (this repo's own layout +
/// paint) through one `slopdesk_term_surface_*` handle — `docs/68`. The headless core here links
/// neither.
///
/// Nothing in this package conforms to it. There was an in-package byte sink here for
/// the headless `slopdesk-client` CLI, and that CLI is `rust/slopdesk-client` now
/// (`docs/63` G.5) — so the last conformer this side is the test target's own
/// `RecordingTerminalPaneSession`, which is a recorder rather than a surface.
///
/// ### Concurrency
/// The engine is `!Send`/`!Sync` and carries no lock, the `CAMetalLayer` it draws into is
/// main-thread-affine, and so are the Core Text faces behind it — so the real renderer is
/// `@MainActor` and a feed from a background queue corrupts the grid rather than tripping an
/// assertion. This protocol does not impose an isolation; conformers state their own. `onWrite` fires
/// when the surface produces bytes to send back to the host (encoded keystrokes), which the client
/// wraps in `input`.
public protocol TerminalSurface: AnyObject {
    /// Feeds inbound PTY/VT bytes (an `output` payload) into the renderer.
    func feed(_ bytes: Data)

    /// Feeds a BATCH of output payloads, flushing the renderer ONCE at the end.
    ///
    /// The batch-drain ingest path uses this so a backlog of N wire chunks costs one
    /// render flush instead of N. The default implementation simply feeds each chunk
    /// (per-chunk flush — correct, just unbatched); renderers with a separate
    /// write/flush split override it to write all chunks and present once. Must be fully
    /// synchronous (doc-18-§C: no suspension between writes and the flush).
    func feedBatch(_ chunks: ArraySlice<Data>)

    /// Sets the terminal grid size; mirrored to the host via `resize`.
    func setSize(cols: UInt16, rows: UInt16)

    /// Handles user input already encoded as terminal bytes (e.g. from a test or a
    /// headless driver). The real GUI surface routes keys through the engine's own encoder
    /// (`slopdesk_term_surface_key`) and emits bytes via ``onWrite``.
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

// MARK: - TerminalSurfaceActions (the editor-action capability seam)

/// The OPTIONAL capability seam (docs/42) the right-click context menu and the ⌘F find bar drive: a
/// renderer that wraps a real terminal exposes selection state + named actions + scrollback search
/// through these, so the find bar / `NSMenu` route through the SEAM instead of naming the engine.
/// Headless conformers (tests, the CLI) DO NOT conform — the GUI probes with
/// `as? TerminalSurfaceActions` and degrades gracefully (a no-selection, no-search surface), exactly
/// like ``FeedBackpressuring``. None of these are exercised in a test (the real surface needs a Metal
/// device — the hang-safety rule); they are compiled + code-reviewed, and their PURE inputs
/// (``TerminalSearchController`` over a text mirror) carry the unit tests.
public protocol TerminalSurfaceActions: AnyObject {
    /// Whether the surface currently holds a text selection (gates Copy in the context menu).
    func hasSelection() -> Bool

    /// The current selection as text, or `nil` (drives "copy" + the find-from-selection seed).
    func readSelection() -> String?

    /// Fires a named action (`scroll_to_bottom` / `jump_to_prompt:-1` / `scroll_page_lines:3` /
    /// `search:<needle>` / `scroll_to_row:<n>` …). Returns whether it ran. The single lever the menu +
    /// find bar + jump-to-prompt + copy-mode scroll all route through.
    ///
    /// ⚠️ THE STRING IS NOT A SWIFT VOCABULARY AND IS NOT PARSED IN SWIFT. Every spelling is written
    /// by Rust — `slopdesk_terminal::surface_action` owns the grammar, and `slopdesk_ws_binding_action`
    /// (behind ``TerminalBindingAction``), `slopdesk_ws_find_bar_wire` and `slopdesk_ws_scroll_action`
    /// are its three doors — and parsed by Rust (`slopdesk_term_surface_binding_action`); this side
    /// only CARRIES it.
    /// That is why a `String` is right here where a typed enum would normally be: an enum would put
    /// the grammar in two languages, and this seam's whole job is that it lives in one. The
    /// unparseable spelling is a `false`, not a crash — which is what a caller built against a newer
    /// producer than its surface reads as.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool

    /// A line-oriented mirror of the whole retained scrollback (oldest retained row → newest), for
    /// ``TerminalSearchController`` and cross-tab search. Soft-wrapped rows are COLLAPSED, so one
    /// entry is one LOGICAL line, no trailing newline — and each entry CARRIES the screen rows it
    /// occupies, so a hit maps to somewhere to scroll without any arithmetic on this side.
    func scrollbackLines() -> [TerminalScrollbackLine]
}

/// One logical scrollback line: its text, and the SCREEN rows it occupies.
///
/// ## Why the rows travel with the text
///
/// A search scans TEXT and reports a line INDEX; `scroll_to_row:` addresses a screen ROW. Those are
/// two different numbers whenever anything soft-wrapped, and the gap used to be closed by a Swift
/// ESTIMATE: sum `max(1, ceil(displayWidth / columns))` over every preceding line. That estimate is
/// a guess at something the engine already knows exactly, and it is wrong in every case the guess
/// cannot see — a grid that was resized while the scrollback stood, a reflow, a line whose wrap
/// point the engine chose differently from a width division. The engine reports each line's real
/// first and last row (`slopdesk_term_surface_logical_lines`), so the estimate is deleted rather
/// than corrected: `ScrollbackWrapMapper`, its FFI door and `slopdesk_terminal::wrap_map` all went
/// with it.
///
/// ``firstRow``/``lastRow`` are inclusive and equal for a line that did not wrap.
public struct TerminalScrollbackLine: Sendable, Equatable {
    /// The line's text, soft-wrap seams already joined, no trailing newline.
    public var text: String
    /// The SCREEN row the line starts on (0 = oldest retained row).
    public var firstRow: Int
    /// The SCREEN row the line ends on — ``firstRow`` unless it soft-wrapped.
    public var lastRow: Int

    public init(text: String, firstRow: Int, lastRow: Int) {
        self.text = text
        self.firstRow = firstRow
        self.lastRow = lastRow
    }
}

public extension [TerminalScrollbackLine] {
    /// Just the text, in order — what a pure matcher scans.
    ///
    /// A matcher has no business holding row numbers it would have to keep in step with its own
    /// index, so the two are separated HERE rather than by a second door: the index into this array
    /// is the index into the receiver, which is what makes ``row(forLine:)`` answerable.
    var text: [String] { map(\.text) }

    /// The screen row logical line `line` starts on, or `nil` for an index this mirror does not hold.
    ///
    /// `nil` rather than a clamp: a stale index means the scrollback moved under the caller, and
    /// scrolling to a row picked by clamping would land somewhere nobody asked to go. The caller
    /// leaves the viewport where it is instead.
    func row(forLine line: Int) -> Int? {
        indices.contains(line) ? self[line].firstRow : nil
    }
}

// MARK: - TerminalViewportSnapshotting (the overlay-geometry capability seam)

/// The VISIBLE-grid geometry of a live terminal surface, in **points** (not pixels), used by the
/// link-underline and Hint Mode overlays to map a detected `(row, colStart ..< colEnd)`
/// span (``TerminalLinkDetector``'s display-cell columns) straight to a `CGRect` in the view's
/// coordinate space.
///
/// Every field is in POINTS in the embedding view's top-left-origin coordinate space (the same
/// convention the surface's pointer forwarding already uses): `originX`/`originY` is the viewport's
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
    /// `colEnd` is exclusive (matching ``TerminalLinkDetector``). The arithmetic is
    /// `slopdesk_terminal::geometry`, which is also what `link_hit`'s own span rect calls: the two
    /// were the drift pair docs/55 §8 recorded and left open, and they are one implementation now.
    public func rect(row: Int, colStart: Int, colEnd: Int) -> CGRect {
        Self.cgRect(slopdesk_grid_rect(
            cellWidth, cellHeight, originX, originY,
            Int64(row), Int64(colStart), Int64(colEnd),
        ))
    }

    /// The ``rect(row:colStart:colEnd:)`` for a span CLAMPED to the visible grid, or `nil` when the span
    /// starts at or beyond the last visible column (`colStart >= cols`) — so a decoration is NEVER drawn
    /// off-screen-right. `colEnd` is clamped to ``cols`` (a span that runs past the grid edge is trimmed to
    /// the edge). The overlays (underline, hint labels) map every span through THIS, not the
    /// raw ``rect`` — defence in depth for the per-grid-row viewport read: even if a span's `colStart`
    /// lands past the grid width (e.g. a long line whose own `colStart` would otherwise overshoot) it is
    /// skipped rather than painted in the void. A degenerate clamp (`colEnd <= colStart` after clamping)
    /// also returns `nil`.
    public func clampedRect(row: Int, colStart: Int, colEnd: Int) -> CGRect? {
        let span = slopdesk_grid_clamped_rect(
            cellWidth, cellHeight, originX, originY, Int64(cols),
            Int64(row), Int64(colStart), Int64(colEnd),
        )
        return span.present ? Self.cgRect(span) : nil
    }

    /// A verdict, read back. `present` is checked by the CALLER before this runs — an absent rect
    /// leaves its four coordinates untouched, and reading them anyway is the one mistake the
    /// value-plus-flag shape exists to make visible rather than plausible.
    private static func cgRect(_ verdict: SlopDeskGridRect) -> CGRect {
        CGRect(x: verdict.x, y: verdict.y, width: verdict.width, height: verdict.height)
    }
}

/// The OPTIONAL capability seam (mirrors ``TerminalSurfaceActions``) that exposes the visible
/// viewport's text + geometry so the overlays render at the exact cell.
///
/// Like ``TerminalSurfaceActions`` this is a SEPARATE protocol the GUI probes with
/// `as? TerminalViewportSnapshotting`: the renderer in `Sources/SlopDeskTerminal/` conforms, while
/// headless conformers (the test target's own) and the `BuildStatusPlaceholderView` placeholder DO
/// NOT — so `cellMetrics()` is absent and the overlays simply do not render. That is the HONEST
/// ceiling: an absent underline, never a wrong one (no faked overlay over a placeholder). Not
/// exercised by a test (the real surface needs a Metal device — the hang-safety rule); the pure
/// geometry it feeds is unit-tested via ``TerminalCellMetrics`` + ``TerminalLinkDetector``.
public protocol TerminalViewportSnapshotting: AnyObject {
    /// The VISIBLE viewport rows top→bottom (NOT the retained scrollback — that is
    /// ``TerminalSurfaceActions/scrollbackLines()``). One entry per visible row, no trailing
    /// newline; the returned index is the `row` the overlays feed back through ``TerminalCellMetrics``.
    func viewportTextRows() -> [String]

    /// The live cell geometry, or `nil` when there is no live surface (headless / placeholder) — in
    /// which case the overlays do not render.
    func cellMetrics() -> TerminalCellMetrics?

    /// Every run of cells the PROGRAM declared as an `OSC 8` hyperlink, in the same row space as
    /// ``viewportTextRows()``.
    ///
    /// Apart from ``viewportTextRows()`` because the two answer different questions and only one of
    /// them is a guess. A detector reads the text and infers a link; this is the program SAYING so,
    /// which is why the underline for it is not gated on `SettingsKey.linkDetectionEnabled` — that
    /// setting governs guessing, and nothing here guessed.
    func authoredLinkSpans() -> [TerminalLinkSpan]
}

/// One run of cells a program declared as an `OSC 8` hyperlink.
///
/// Columns only, and no URI: this is what the UNDERLINE needs, and the underline is drawn for every
/// span at once. The URI is asked for one cell at a time, when a click has to resolve to a target —
/// see ``TerminalSurfaceActions``' hyperlink door.
public struct TerminalLinkSpan: Sendable, Equatable {
    /// The viewport row, zero at the top.
    public var row: Int
    /// The first column the link covers.
    public var colStart: Int
    /// One past the last column it covers.
    public var colEnd: Int

    public init(row: Int, colStart: Int, colEnd: Int) {
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
    }
}

// MARK: - TerminalSelectionControl (the keyboard copy-mode capability seam)

/// A cell position in SCREEN coordinates — `row` 0 is the OLDEST retained scrollback row, which is
/// the space `slopdesk-vterm`'s screen pins address. The copy-mode cursor/anchor live in this space so
/// they stay put while the viewport scrolls under them.
public struct TerminalScreenPoint: Sendable, Equatable {
    /// Grid column (0-based).
    public var col: Int
    /// Absolute screen row (0 = oldest retained scrollback row).
    public var row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

/// One readback of the live surface's viewport/extent/cursor in SCREEN coordinates — the truth the
/// keyboard copy-mode re-reads EVERY keystroke so a client-held cursor can never drift from what the
/// engine actually shows (the anti-jitter rule: never claim a position the engine can contradict).
public struct TerminalViewportInfo: Sendable, Equatable {
    /// The viewport's top row in screen coordinates.
    public var viewportTopRow: Int
    /// Visible viewport rows.
    public var viewportRows: Int
    /// Grid columns.
    public var cols: Int
    /// Total screen rows (retained scrollback + active screen).
    public var totalRows: Int
    /// The TERMINAL cursor (where the shell is typing), in screen coordinates — the copy-mode
    /// entry position (tmux parity: copy-mode starts at the prompt cursor, not the viewport corner).
    public var cursor: TerminalScreenPoint

    public init(
        viewportTopRow: Int,
        viewportRows: Int,
        cols: Int,
        totalRows: Int,
        cursor: TerminalScreenPoint,
    ) {
        self.viewportTopRow = viewportTopRow
        self.viewportRows = viewportRows
        self.cols = cols
        self.totalRows = totalRows
        self.cursor = cursor
    }
}

/// The OPTIONAL capability seam (mirrors ``TerminalSurfaceActions``) that lets the keyboard
/// copy-mode START and steer a selection programmatically — the E17 char-range ceiling lift
/// (DECISIONS.md 2026-07-14). Backed by `slopdesk_term_surface_set_selection` /
/// `_selection_verb` / `_viewport_info`; the selection itself is painted by
/// `slopdesk-termrender` from the engine's own range (never a client-drawn rectangle over a
/// position this side guessed). Headless conformers do not conform; the GUI probes with
/// `as? TerminalSelectionControl` and copy-mode degrades to the pre-lift behavior (scroll-only
/// navigation, mouse-anchored yank). Not exercised by a test (hang-safety rule); the pure
/// cursor/motion state it feeds is unit-tested against a recording mock.
public protocol TerminalSelectionControl: AnyObject {
    /// The live viewport/extent/cursor readback, or `nil` when there is no live surface — in which
    /// case copy-mode runs without a cursor (the honest ceiling, like an absent overlay).
    func viewportInfo() -> TerminalViewportInfo?

    /// Sets the selection from `anchor` to `head` (both inclusive, SCREEN coordinates, either
    /// order — the engine orders internally). `rectangle` selects a block (`⌃V`). Returns whether
    /// the engine accepted the range.
    @discardableResult
    func setSelection(anchor: TerminalScreenPoint, head: TerminalScreenPoint, rectangle: Bool) -> Bool

    /// Clears any selection (leaving visual mode). Safe when nothing is selected.
    func clearSelection()

    /// One SCREEN-coordinate row's text (for word/column motions), or `nil` off-range. The row is
    /// read fresh from the engine — never a cached mirror.
    func readScreenRow(_ row: Int) -> String?

    /// The LOGICAL line containing `screenRow` — the inclusive screen-row range of its soft-wrap
    /// chain (a long line the grid wrapped over several display rows is ONE line; a plain row
    /// returns `row...row`). `nil` off-range / no live surface. Backs the line-oriented copy-mode
    /// ops (`$`/`0`/`^`/`V`/`Y`), which follow the REAL line, not the display row.
    func lineRange(_ screenRow: Int) -> ClosedRange<Int>?
}

/// Backpressure seam for renderers whose ``TerminalSurface/feed(_:)`` is an ASYNCHRONOUS enqueue.
///
/// ⚠️ NOTHING SHIPPING CONFORMS TO THIS ANY MORE, and that is a simplification rather than an
/// oversight. It existed for the fork's embedder, whose `feed` hopped a per-surface serial queue
/// (docs/31 #5) so a flood could pile up unparsed behind it. The renderer that replaced it parses on
/// the main actor INSIDE `feed`, because the engine is `!Send` and holds no lock — so by the time
/// `feed` returns the bytes are already in the grid and there is no backlog to be behind. A
/// non-conformer is not a renderer missing a feature; it is one with nothing to wait for.
///
/// Kept, rather than deleted with its last conformer, because the property that makes it unnecessary
/// is a property of THIS renderer: a future one that parses off the main actor needs it back, and
/// re-deriving why the ingest pump must `await` from the main actor (awaiting a nonisolated async
/// member on a non-`Sendable` `any TerminalSurface` existential is a Swift 6 sending violation, which
/// is why this is a separate `Sendable` protocol and not a defaulted requirement) is the expensive
/// half. The pump's `as?` probe skips a non-conformer at no cost.
public protocol FeedBackpressuring: Sendable {
    /// Parks until the renderer can absorb more feed work — i.e. its queued-but-
    /// unparsed backlog is below a high-water mark. The ingest pump awaits this before
    /// each pass so wire flow control (credit-at-consumption) stays coupled to actual
    /// parse progress; without it a flood turns the feed queue into an unbounded
    /// buffer. Must always resolve in bounded time.
    func feedBackpressure() async
}

// MARK: - What the far side pushed

/// Where a clipboard write is meant to land.
///
/// The three destinations the engine normalises every protocol spelling into. Only ``standard``
/// means anything on Apple platforms — macOS has no selection clipboard and iOS has only the general
/// pasteboard — but the distinction crosses the boundary rather than being collapsed in Rust,
/// because what a destination MEANS is a fact about the system the pane is running on.
public enum TerminalClipboardTarget: UInt8, Sendable, Equatable {
    /// The system clipboard.
    case standard = 0
    /// The selection clipboard, which X11 has and Apple does not.
    case selection = 1
    /// The primary selection clipboard, likewise.
    case primary = 2
}

/// A clipboard write a running program asked for, over OSC 52 or iTerm2's OSC 1337 Copy.
///
/// ⚠️ **Asked for, not applied.** Whether this reaches a pasteboard is ``ClipboardWritePolicy``'s
/// decision, made where the user's `clipboard-write` setting lives. Applying it on arrival would
/// make "Ask" behave as "Allow" — a remote program overwriting the clipboard with no prompt.
///
/// ## Why this is the ONLY push the surface drains
///
/// The engine also sees the bell, the OSC-9/777 notification, the OSC-9;4 progress report, the OSC
/// 0/2 title and the OSC-7 working directory. None of them are read here, because the host already
/// sniffs each one out of the PTY stream and sends it as its own wire message — ``TerminalViewModel``
/// folds them in ``TerminalViewModel/handle(_:)``. That owner is the right one for two reasons the
/// client cannot fix locally: one pane can have several clients attached (`docs/45`), and host-side
/// detection is one verdict they share rather than N that drift; and ``TerminalViewModel/attachSurface(_:)``
/// REPLAYS the retained output ring into a rebuilt surface, so engine-side handlers would re-beep,
/// re-post and re-spin everything that already happened on every remount.
///
/// A clipboard is per-CLIENT, so it is the one push with nowhere else to come from. The replay
/// hazard applies to it too, and the renderer answers it rather than dodging it: the drain runs once
/// after the replay and throws the result away before the live drain is wired.
public struct TerminalClipboardWrite: Sendable, Equatable {
    /// Where the program wants it to land.
    public var target: TerminalClipboardTarget
    /// The text, base64 already undone and multipart chunks already rejoined by the engine.
    public var text: String

    public init(target: TerminalClipboardTarget, text: String) {
        self.target = target
        self.text = text
    }
}
