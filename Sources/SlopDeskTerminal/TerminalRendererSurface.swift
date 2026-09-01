// TerminalRendererSurface — the Swift half of the terminal surface: a handle, and nothing else.
//
// `docs/68-terminal-surface-in-rust.md` §10 draws the line this file sits on, and the reframing that
// makes the port small is worth repeating here rather than leaving in the document: MOST OF THIS
// SWIFT IS EVENT PLUMBING, AND EVENT PLUMBING STAYS SWIFT. A view that receives `keyDown` and
// forwards it is the same view before and after — what changed is the C ABI it forwards INTO.
//
// So this type owns exactly one thing, a `SlopDeskTerminalSurface *`, and every question anybody
// asks it is answered by `rust/slopdesk-ffi/src/terminal_surface.rs`. There is no grid here, no cell
// arithmetic, no selection state, no glyph, no colour table and no scroll position. Each of those
// lived in the deleted fork's embedder as a Swift copy of something the old libghostty engine also
// held, and each was a place for the two to disagree.
//
// ⚠️ THE HANDLE DIES WITH THIS OBJECT, and `deinit` is the only place it may. That is the
// handle-lifetime rule every `slopdesk-ffi` handle carries, and here it has a second edge: the
// `CAMetalLayer` the view hosts is LENT by the handle at +0 (`slopdesk_term_surface_layer`), so a
// view still holding that layer after `_free` is holding a layer whose drawable source is gone.
// `TerminalRendererView.detachSurface()` is what orders the two, and it is why removing the view
// from its superview is not enough.
//
// ⚠️ MAIN THREAD, EVERY CALL. Not a convention this file chose: `libghostty-vt`'s terminal is
// `!Send`/`!Sync` with no lock upstream, a `CAMetalLayer` is main-thread-affine, and Core Text's
// font objects are the same — so the Rust handle carries no lock at all, because a second thread may
// not have it. `@MainActor` on the class is that obligation in the type system. A feed from a
// background queue would CORRUPT the grid rather than trip an assertion, which is why the ingest
// pump's `feedBatch` is documented synchronous.
//
// Every decode below REPAIRS invalid UTF-8 rather than answering nil, which is why each carries the
// `optional_data_string_conversion` waiver the rest of the tree spells the same way. The bytes come
// from Rust, where each of these answers is already a `&str` — so a replacement character can only
// mean the door and this file disagree about the layout, and a mangled row is a better report of
// that than a viewport that silently collapses to nothing.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import QuartzCore
import SlopDeskArena
import SlopDeskWorkspaceCore

/// A live terminal: one Rust handle, and the calls that reach it.
///
/// Every member is a straight forward into `slopdesk_term_surface_*`. When a member here looks like
/// it is deciding something, it is not — read the door's own doc comment, which carries the
/// argument.
@MainActor
final class TerminalRendererSurface {
    /// The Rust handle, or `nil` when this machine could not open one (no Metal device, pipelines
    /// that will not build) and after ``close()``.
    ///
    /// A refusal does not become true a frame later, so it is latched rather than retried: a `nil`
    /// here is a surface that draws nothing and reports honestly, not one waiting to work.
    private var handle: OpaquePointer?

    /// A reusable answer buffer, so a keystroke's encoded bytes cost no allocation.
    ///
    /// 4 KiB because that is comfortably past every answer on the hot path — an encoded keystroke is
    /// tens of bytes, a mouse report fewer — and the two doors that CAN exceed it (a selection copy,
    /// the viewport rows) go through ``answer(_:)``, which retries at the size the door reported. A
    /// buffer sized for the worst case would be sized for a scrollback copy and held forever.
    private var scratch = [UInt8](repeating: 0, count: 4096)

    /// Opens a surface, or `nil` when this machine cannot draw one.
    init?(family: String, pointSize: Double, lineHeight: Double, scale: Double, size: CGSize) {
        let opened = Array(family.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_term_surface_new(
                bytes.baseAddress, bytes.count,
                pointSize, lineHeight, scale,
                Double(size.width), Double(size.height),
            )
        }
        guard let opened else { return nil }
        handle = opened
    }

    // `isolated` so the handle is reachable at all: it is an `OpaquePointer`, which is not
    // `Sendable`, and a nonisolated `deinit` may not touch one. That is the right isolation
    // regardless — `slopdesk_term_surface_free` tears down a `CAMetalLayer` and Core Text faces,
    // both main-thread-affine, so freeing from whatever thread dropped the last reference would be
    // the bug the compiler is naming rather than a formality it is objecting to.
    isolated deinit {
        // ⚠️ THE ONLY `_free` IN THE TREE, and the reason `close()` is a different door: `deinit`
        // runs when the LAST reference goes, and the view may still be holding the lent layer then.
        // `slopdesk-invariants`' `handle-freed-in-deinit` is the ratchet on this line's location.
        if let handle {
            slopdesk_term_surface_free(handle)
        }
    }

    /// Tears the surface's STATE down early, leaving the handle valid and inert.
    ///
    /// The view calls this from `detachSurface()` because the ORDER matters and a `deinit` cannot
    /// promise one: the layer must leave the view hierarchy before the state that draws into it
    /// dies. It does NOT free the handle — that is `deinit`'s, unconditionally — so a door called on
    /// a closed surface answers its inert value rather than faulting, which is what makes a teardown
    /// that races a runloop turn ordinary instead of a crash.
    ///
    /// Idempotent, on both sides of the boundary.
    func close() {
        guard let handle, isOpen else { return }
        isOpen = false
        slopdesk_term_surface_close(handle)
    }

    /// Whether the surface's state is still live. `false` after ``close()`` and on a machine that
    /// refused one.
    ///
    /// Not `handle != nil`: the handle outlives ``close()`` by design.
    var isLive: Bool { handle != nil && isOpen }

    /// Whether ``close()`` has run. Mirrors the Rust `Option` so a second `close` is free.
    private var isOpen = true

    /// The `CAMetalLayer` to host, borrowed — see this file's header for why it is never released.
    var layer: CALayer? {
        guard let handle, let raw = slopdesk_term_surface_layer(handle) else {
            return nil
        }
        return Unmanaged<CALayer>.fromOpaque(raw).takeUnretainedValue()
    }

    // MARK: - Feeding and drawing

    /// Feeds inbound PTY bytes.
    func feed(_ bytes: Data) {
        guard let handle else { return }
        bytes.withUnsafeBytes { raw in
            slopdesk_term_surface_feed(
                handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count,
            )
        }
    }

    /// Draws one frame. `false` = there was nowhere to draw, which needs no recovery.
    @discardableResult
    func draw() -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_draw(handle)
    }

    /// Re-measures and answers the grid that now fits.
    ///
    /// The pair comes back from the resize rather than being read after it, because the door packs
    /// them into one word for exactly that reason: two reads could straddle a second resize and
    /// mirror the host a grid that never existed.
    func setGeometry(size: CGSize, scale: CGFloat) -> (cols: UInt16, rows: UInt16)? {
        guard let handle else { return nil }
        let packed = slopdesk_term_surface_set_geometry(
            handle,
            Double(size.width), Double(size.height), Double(scale),
        )
        guard packed != 0 else { return nil }
        return (cols: UInt16(packed >> 16), rows: UInt16(packed & 0xFFFF))
    }

    /// Pushes the pane's workspace focus and the blink clock's phase.
    func setFocus(_ focused: Bool, blinkVisible: Bool) {
        guard let handle else { return }
        slopdesk_term_surface_set_focus(handle, focused, blinkVisible)
    }

    /// Pushes the theme's three colours.
    func setTheme(foreground: UInt32, background: UInt32, selection: UInt32) {
        guard let handle else { return }
        slopdesk_term_surface_set_theme(handle, foreground, background, selection)
    }

    /// Pushes the design the block furniture is drawn with.
    ///
    /// One call for the whole record, not one per field: the door refuses to hold a divider colour
    /// beside last frame's gutter thickness, and this face is not the place to invent that state.
    func setChromeStyle(_ style: SlopDeskTerminalChromeStyle) {
        guard let handle else { return }
        slopdesk_term_surface_set_chrome_style(handle, style)
    }

    /// Pushes where the pointer is, in points, or that it has left the surface. Answers whether the
    /// next frame would differ — a move inside one block changes no pixel and is worth no present.
    ///
    /// `false` for a surface with no handle, which is the honest answer and not a fallback: nothing
    /// is going to draw either way.
    func setHover(_ point: CGPoint?) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_set_hover(
            handle, Double(point?.x ?? 0), Double(point?.y ?? 0), point != nil,
        )
    }

    /// Pushes what an input method is composing over the cursor, or clears it with an empty string.
    ///
    /// `cursorBytes` is the composition's own caret as a UTF-8 offset into `text`; the door measures
    /// the cells, because measuring them is the engine's segmentation and not this side's. Answers
    /// whether the next frame would differ — an input method re-reports an unchanged composition on
    /// every arrow key, and presenting on each would be a full render for the same picture.
    func setMarkedText(_ text: String, cursorBytes: Int) -> Bool {
        guard let handle else { return false }
        return Array(text.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_term_surface_set_marked_text(handle, bytes.baseAddress, bytes.count, cursorBytes)
        }
    }

    /// The caret's cell in view POINTS, or `nil` when no cursor is on screen.
    ///
    /// The one caller is an input method asking where to hang its candidate list, which is why it is
    /// the CELL's rect rather than the caret's drawn shape — see the door.
    func caretRect() -> CGRect? {
        guard let handle else { return nil }
        var box = [Double](repeating: 0, count: 4)
        let placed = box.withUnsafeMutableBufferPointer { out in
            slopdesk_term_surface_caret_rect(handle, out.baseAddress)
        }
        guard placed else { return nil }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    }

    /// Pushes the theme's ANSI colours, from index `0`. A prefix — see the door.
    func setPalette(_ entries: [UInt32]) {
        guard let handle, !entries.isEmpty else { return }
        entries.withUnsafeBufferPointer { colours in
            slopdesk_term_surface_set_palette(handle, colours.baseAddress, colours.count)
        }
    }

    /// Rebuilds the face stack at a new family, size and cell-height multiplier, answering the grid
    /// that now fits.
    ///
    /// Answers the pair for ``setGeometry(size:scale:)``'s reason, and the caller owes the same
    /// follow-through: a new cell size is a new grid, and the host is still holding the old one.
    func setFont(family: String, pointSize: Double, lineHeight: Double) -> (cols: UInt16, rows: UInt16)? {
        guard let handle else { return nil }
        let packed = Array(family.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_term_surface_set_font(handle, bytes.baseAddress, bytes.count, pointSize, lineHeight)
        }
        guard packed != 0 else { return nil }
        return (cols: UInt16(packed >> 16), rows: UInt16(packed & 0xFFFF))
    }

    /// The bytes that walk the shell's cursor to a clicked cell, or `nil` for a click the engine
    /// declines. The rule — same row only, glyphs not columns, and what it refuses — is the door's.
    func clickToMove(column: Int, row: Int) -> Data? {
        guard let handle, let column = UInt16(exactly: column), let row = UInt16(exactly: row) else {
            return nil
        }
        let bytes = answer { out, cap in
            slopdesk_term_surface_click_to_move(handle, column, row, out, cap)
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    /// Which absolute or relative scroll a gesture or key asked for.
    enum ScrollRequest {
        /// By a signed number of rows. Negative reveals OLDER output.
        case rows(Int32)
        /// By a signed number of screens.
        case pages(Int32)
        /// To the newest row, where output lands.
        case bottom
        /// To the oldest retained row.
        case top

        /// The door's `(mode, lines)` pair. Kept beside the cases so the two integers are written
        /// once — a caller spelling `0` for rows somewhere else is the drift this enum removes.
        var wire: (mode: UInt8, lines: Int32) {
            switch self {
            case let .rows(delta): (0, delta)
            case let .pages(delta): (1, delta)
            case .bottom: (2, 0)
            case .top: (3, 0)
            }
        }
    }

    /// Scrolls the viewport.
    func scroll(_ request: ScrollRequest) {
        guard let handle else { return }
        let (mode, lines) = request.wire
        slopdesk_term_surface_scroll(handle, mode, lines)
    }

    /// Whether the Option key is Alt: `0` off, `1` both, `2` left, `3` right.
    func setOptionAsAlt(_ value: UInt8) {
        guard let handle else { return }
        slopdesk_term_surface_set_option_as_alt(handle, value)
    }

    // MARK: - Settings

    /// Caps the scrollback at a number of ROWS. Zero or negative keeps none.
    func setScrollback(lines: Int) {
        guard let handle else { return }
        slopdesk_term_surface_set_scrollback(handle, Int64(clamping: lines))
    }

    /// The caret's shape until a program asks for another one.
    ///
    /// A DEFAULT, which is the whole reason a user is allowed to set it: `DECSCUSR` from a running
    /// program still wins, so a bar in the shell coexists with vim's block in insert mode.
    func setCursorStyle(_ style: UInt8) {
        guard let handle else { return }
        slopdesk_term_surface_set_cursor_style(handle, style)
    }

    /// Whether the caret blinks until a program says otherwise: `1` on, `2` off, anything else the
    /// engine's own default.
    func setCursorBlink(_ mode: UInt8) {
        guard let handle else { return }
        slopdesk_term_surface_set_cursor_blink(handle, mode)
    }

    /// The caret's colour until `OSC 12` overrides it. `nil` follows the foreground.
    func setCursorColor(_ rgb: UInt32?) {
        guard let handle else { return }
        slopdesk_term_surface_set_cursor_color(handle, rgb ?? 0, rgb != nil)
    }

    /// How solid the caret is drawn, `0`–`1`. Zero hides it.
    func setCursorOpacity(_ opacity: Double) {
        guard let handle else { return }
        slopdesk_term_surface_set_cursor_opacity(handle, opacity)
    }

    /// Whether inline images (the kitty graphics protocol) are drawn.
    ///
    /// The engine keeps its storage regardless, so this is a live toggle in both directions: turning
    /// it back on redraws what is already on screen rather than waiting for a retransmission.
    func setImages(_ enabled: Bool) {
        guard let handle else { return }
        slopdesk_term_surface_set_images(handle, enabled)
    }

    /// The colour the glyph under a filled caret takes. `nil` keeps the cell's own background.
    func setCursorTextColor(_ rgb: UInt32?) {
        guard let handle else { return }
        slopdesk_term_surface_set_cursor_text_color(handle, rgb ?? 0, rgb != nil)
    }

    /// Whether a copy drops the blanks a terminal padded each short line with.
    func setTrimTrailing(_ trim: Bool) {
        guard let handle else { return }
        slopdesk_term_surface_set_trim_trailing(handle, trim)
    }

    /// Forgets any pointer button the encoder was tracking, for a pointer that left mid-drag.
    func resetPointer() {
        guard let handle else { return }
        slopdesk_term_surface_reset_pointer(handle)
    }

    // MARK: - Input

    /// One key press, encoded. Empty when the press produces no bytes.
    ///
    /// `keyCode` is the platform's hardware position on the Mac and ``TerminalRendererSurface/noKey``
    /// on the phone, where a `UIKey` carries characters instead — the door's own comment is where
    /// that asymmetry is argued.
    func encodeKey(
        keyCode: UInt16,
        action: UInt8,
        mods: UInt16,
        consumedMods: UInt16,
        text: String,
        composing: Bool,
    ) -> Data {
        guard let handle else { return Data() }
        return Data(answer { out, cap in
            Array(text.utf8).withUnsafeBufferPointer { characters in
                slopdesk_term_surface_key(
                    handle,
                    keyCode, action, mods, consumedMods,
                    characters.baseAddress, characters.count,
                    composing, out, cap,
                )
            }
        })
    }

    /// The `keyCode` for a press that names no hardware key — an IME commit, or any iOS press.
    static let noKey: UInt16 = 0xFFFF

    /// One pointer event, encoded, or empty when the far side is not tracking the mouse — which the
    /// caller reads as "this gesture is mine" and answers with a selection instead.
    func encodeMouse(action: UInt8, button: UInt8, mods: UInt16, at point: CGPoint) -> Data {
        guard let handle else { return Data() }
        return Data(answer { out, cap in
            slopdesk_term_surface_mouse(
                handle,
                action, button, mods,
                Double(point.x), Double(point.y),
                out, cap,
            )
        })
    }

    // MARK: - Selection

    /// One pointer press against the selection. `true` when the selection changed.
    @discardableResult
    func selectPress(at point: CGPoint, timeMs: Double, repeatIntervalMs: Double, repeatDistance: Double) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_select_press(
            handle,
            Double(point.x), Double(point.y),
            timeMs, repeatIntervalMs, repeatDistance,
        )
    }

    /// Extends a live selection.
    @discardableResult
    func selectDrag(to point: CGPoint, rectangle: Bool) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_select_drag(
            handle, Double(point.x), Double(point.y), rectangle,
        )
    }

    /// Ends the drag, leaving the selection standing.
    func selectRelease(at point: CGPoint) {
        guard let handle else { return }
        slopdesk_term_surface_select_release(handle, Double(point.x), Double(point.y))
    }

    /// Which way a live drag wants the viewport to move.
    enum AutoscrollDirection: UInt8 {
        /// Nowhere — the pointer is inside the surface.
        case none = 0
        /// Towards older output.
        case up = 1
        /// Towards newer output.
        case down = 2
    }

    /// Which way a live selection drag wants the viewport to move, asked once per display tick.
    var autoscrollDirection: AutoscrollDirection {
        guard let handle else { return .none }
        return AutoscrollDirection(rawValue: slopdesk_term_surface_autoscroll_direction(handle))
            ?? .none
    }

    /// One autoscroll tick with the pointer where it is now.
    @discardableResult
    func autoscrollTick(at point: CGPoint, rectangle: Bool) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_select_autoscroll(
            handle, Double(point.x), Double(point.y), rectangle,
        )
    }

    /// A selection verb that takes no pointer, answering whether anything is selected AFTERWARDS.
    enum SelectionVerb: UInt8 {
        /// Drop the selection.
        case clear = 0
        /// Select the whole scrollback.
        case all = 1
        /// Change nothing and just read.
        case ask = 2
    }

    /// Runs a selection verb and answers whether anything is selected afterwards.
    @discardableResult
    func selection(_ verb: SelectionVerb) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_selection_verb(handle, verb.rawValue)
    }

    /// Whether the selection stops exactly where the cursor stands.
    ///
    /// What a CUT asks before it sends a single `DEL`: cutting from a terminal is not an edit the
    /// terminal can perform, so the delete half is backspaces, and those only remove the selected
    /// text when the cursor sits immediately past it.
    func selectionEndsAtCursor() -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_selection_ends_at_cursor(handle)
    }

    /// How a copied selection is spelled.
    enum CopyFormat: UInt8 {
        /// Just the characters.
        case plain = 0
        /// With the SGR escapes that coloured them.
        case vt = 1
        /// As styled HTML.
        case html = 2
    }

    /// The selection as text, or `nil` when nothing is selected.
    func selectionText(_ format: CopyFormat = .plain) -> String? {
        guard let handle else { return nil }
        let bytes = answer { out, cap in
            slopdesk_term_surface_selection_text(handle, format.rawValue, out, cap)
        }
        // swiftlint:disable:next optional_data_string_conversion
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Readback

    /// The visible rows as text, for the link and hint overlays.
    func viewportRows() -> [String] {
        guard let handle else { return [] }
        let blob = answer { out, cap in
            slopdesk_term_surface_viewport_rows(handle, out, cap)
        }
        return Self.decodeRows(blob)
    }

    /// `[u32 count] count × [u32 length][UTF-8]`, as the door writes it.
    ///
    /// `static` and `internal` rather than a method: the LAYOUT is the only thing worth a test, and a
    /// test that had to open a Metal device to reach it could not run. This is the seam the parse is
    /// asserted through.
    nonisolated static func decodeRows(_ blob: [UInt8]) -> [String] {
        var reader = blob[...]
        guard let count = reader.takeBigEndianUInt32() else { return [] }
        var rows: [String] = []
        rows.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let length = reader.takeBigEndianUInt32(), let run = reader.take(Int(length)) else {
                // A truncated blob answers the rows it DID carry rather than none: the overlays place
                // decorations per row, so a short read costs a missing underline on the tail instead
                // of an empty viewport that reads as a blank terminal.
                return rows
            }
            // swiftlint:disable:next optional_data_string_conversion
            rows.append(String(decoding: run, as: UTF8.self))
        }
        return rows
    }

    /// The live cell geometry in points, or `nil` on a surface that has not laid out.
    func cellMetrics() -> TerminalCellMetrics? {
        guard let handle else { return nil }
        let blob = answer { out, cap in
            slopdesk_term_surface_cell_metrics(handle, out, cap)
        }
        return Self.decodeCellMetrics(blob)
    }

    /// `[f64 w][f64 h][u32 cols][u32 rows][f64 x][f64 y]`, as the door writes it. `static` for
    /// ``decodeRows(_:)``'s reason.
    nonisolated static func decodeCellMetrics(_ blob: [UInt8]) -> TerminalCellMetrics? {
        var reader = blob[...]
        guard let width = reader.takeBigEndianDouble(),
              let height = reader.takeBigEndianDouble(),
              let cols = reader.takeBigEndianUInt32(),
              let rows = reader.takeBigEndianUInt32(),
              let originX = reader.takeBigEndianDouble(),
              let originY = reader.takeBigEndianDouble()
        else {
            return nil
        }
        return TerminalCellMetrics(
            cellWidth: width,
            cellHeight: height,
            cols: Int(cols),
            rows: Int(rows),
            originX: originX,
            originY: originY,
        )
    }

    /// The four mode flags, read together because they are acted on together.
    struct Modes: Equatable {
        /// Whether a full-screen program owns the grid.
        var isAlternateScreen: Bool
        /// Whether the far side asked for mouse reports.
        var isMouseTracking: Bool
        /// Whether the viewport is pinned to the newest row.
        var isViewportAtBottom: Bool
        /// Whether the foreground program asked for DEC bracketed paste (`?2004h`).
        ///
        /// Read from the ENGINE that parsed the DECSET. A second parser watching the same bytes
        /// could only ever agree or be wrong, and being wrong here skips the paste-protection
        /// sheet — `PastePrecheck` takes this as `programAdvertisedBracketed`.
        var wantsBracketedPaste: Bool
    }

    /// The four mode flags in one read. Four separate reads would be four chances to act on a
    /// mixed state — the door's own comment names the failure.
    func modes() -> Modes {
        guard let handle else {
            return Modes(
                isAlternateScreen: false, isMouseTracking: false,
                isViewportAtBottom: true, wantsBracketedPaste: false,
            )
        }
        let bits = slopdesk_term_surface_modes(handle)
        return Modes(
            isAlternateScreen: bits & 1 != 0,
            isMouseTracking: bits & 2 != 0,
            isViewportAtBottom: bits & 4 != 0,
            wantsBracketedPaste: bits & 8 != 0,
        )
    }

    /// The exact bytes a paste of `text` should put on the pty, or `nil` when the surface is closed.
    ///
    /// ⚠️ **Not `Data(text.utf8)` with brackets around it.** The engine scrubs the control bytes a
    /// payload must never carry into a prompt, rewrites newlines as carriage returns when the paste
    /// is not bracketed, and strips any embedded `ESC [ 201 ~` before wrapping — the bracketed-paste
    /// breakout. Framing this side would be a second paste implementation that cannot see the far
    /// side's parser.
    ///
    /// `bracketed` is the caller's: ordinary Paste passes ``Modes/wantsBracketedPaste``, Bracketed
    /// Paste forces `true`, Paste as Keystrokes forces `false`.
    func encodePaste(_ text: String, bracketed: Bool) -> Data? {
        guard let handle, !text.isEmpty else { return nil }
        let bytes = Array(text.utf8)
        let encoded = bytes.withUnsafeBufferPointer { input in
            answer { out, cap in
                slopdesk_term_surface_encode_paste(
                    handle, input.baseAddress, input.count, bracketed, out, cap,
                )
            }
        }
        return encoded.isEmpty ? nil : Data(encoded)
    }

    /// The viewport, the buffer's extent and the cursor, in SCREEN rows — one read.
    ///
    /// One read rather than five because copy-mode acts on all of them together: a cursor read against
    /// one viewport and an extent read against the next describes a grid that never existed. The door
    /// packs them for the reason ``setGeometry(size:scale:)`` packs its pair.
    func viewportInfo() -> TerminalViewportInfo? {
        guard let handle else { return nil }
        let blob = answer { out, cap in
            slopdesk_term_surface_viewport_info(handle, out, cap)
        }
        return Self.decodeViewportInfo(blob)
    }

    /// `[u32 total][u32 top][u32 rows][u32 cols][u32 cursorCol][u32 cursorRow]`, as the door writes it.
    /// `static` for ``decodeRows(_:)``'s reason.
    nonisolated static func decodeViewportInfo(_ blob: [UInt8]) -> TerminalViewportInfo? {
        var reader = blob[...]
        guard let totalRows = reader.takeBigEndianUInt32(),
              let viewportTopRow = reader.takeBigEndianUInt32(),
              let viewportRows = reader.takeBigEndianUInt32(),
              let cols = reader.takeBigEndianUInt32(),
              let cursorCol = reader.takeBigEndianUInt32(),
              let cursorRow = reader.takeBigEndianUInt32()
        else {
            return nil
        }
        return TerminalViewportInfo(
            viewportTopRow: Int(viewportTopRow),
            viewportRows: Int(viewportRows),
            cols: Int(cols),
            totalRows: Int(totalRows),
            cursor: TerminalScreenPoint(col: Int(cursorCol), row: Int(cursorRow)),
        )
    }

    /// Sets the selection between two SCREEN points, in either order. `false` = the engine refused it.
    @discardableResult
    func setSelection(anchor: TerminalScreenPoint, head: TerminalScreenPoint, rectangle: Bool) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_set_selection(
            handle,
            Self.column(anchor.col), Self.row(anchor.row),
            Self.column(head.col), Self.row(head.row),
            rectangle,
        )
    }

    /// One SCREEN row's text, trailing padding trimmed, or `nil` when there is none to answer with.
    ///
    /// ⚠️ A row that is off the buffer's end and a row that exists and is BLANK both answer `nil`, and
    /// the door says so: they are the same answer to "what text is there". The callers are vi word and
    /// column motions, which skip a blank row and stop at the buffer's edge — and the edge is
    /// ``viewportInfo()``'s `totalRows`, which is what a caller that must tell the two apart asks.
    func screenRow(_ row: Int) -> String? {
        guard let handle else { return nil }
        let bytes = answer { out, cap in
            slopdesk_term_surface_screen_row(handle, Self.row(row), out, cap)
        }
        // swiftlint:disable:next optional_data_string_conversion
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// The inclusive SCREEN-row range of the logical line containing `row`, or `nil` off-range.
    func lineRange(_ row: Int) -> ClosedRange<Int>? {
        guard let handle else { return nil }
        let blob = answer { out, cap in
            slopdesk_term_surface_line_range(handle, Self.row(row), out, cap)
        }
        var reader = blob[...]
        guard let first = reader.takeBigEndianUInt32(), let last = reader.takeBigEndianUInt32() else {
            return nil
        }
        return Int(first)...Int(max(first, last))
    }

    /// Every logical line in the buffer with the SCREEN rows it occupies.
    ///
    /// ⚠️ **Never per frame.** This walks the whole retained scrollback and allocates a string per
    /// line; it is a ⌘F / ⇧⌘F snapshot, not a read the display link may take.
    func logicalLines() -> [TerminalScrollbackLine] {
        guard let handle else { return [] }
        let blob = answer { out, cap in
            slopdesk_term_surface_logical_lines(handle, out, cap)
        }
        return Self.decodeLogicalLines(blob)
    }

    /// `[u32 count] count × [u32 first][u32 last][u32 length][UTF-8]`, as the door writes it. `static`
    /// for ``decodeRows(_:)``'s reason — and this one carries three fields per record, which is three
    /// more chances at an off-by-one that only a test can catch.
    nonisolated static func decodeLogicalLines(_ blob: [UInt8]) -> [TerminalScrollbackLine] {
        var reader = blob[...]
        guard let count = reader.takeBigEndianUInt32() else { return [] }
        var lines: [TerminalScrollbackLine] = []
        lines.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let first = reader.takeBigEndianUInt32(),
                  let last = reader.takeBigEndianUInt32(),
                  let length = reader.takeBigEndianUInt32(),
                  let run = reader.take(Int(length))
            else {
                // A truncated blob answers the lines it DID carry, for ``decodeRows(_:)``'s reason: a
                // short read costs a search the buffer's tail, not the whole scrollback.
                return lines
            }
            lines.append(TerminalScrollbackLine(
                // swiftlint:disable:next optional_data_string_conversion
                text: String(decoding: run, as: UTF8.self),
                firstRow: Int(first),
                lastRow: Int(last),
            ))
        }
        return lines
    }

    /// Runs a keybinding action the surface spelled. `false` = it does not know the spelling, which is
    /// a keystroke that does nothing rather than a crash — see ``TerminalBindingAction``.
    @discardableResult
    func bindingAction(_ spelling: String) -> Bool {
        guard let handle else { return false }
        return Array(spelling.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_term_surface_binding_action(
                handle, bytes.baseAddress, bytes.count,
            )
        }
    }

    /// Runs the find bar's query over the whole retained buffer; answers the hit count.
    ///
    /// The one door the `search:` binding action cannot be: it carries the other three mode flags,
    /// and it answers a COUNT where a binding action can only answer whether it ran. See
    /// ``TerminalSurfaceActions/find(_:caseSensitive:wholeWord:isRegex:)``.
    func find(_ query: String, caseSensitive: Bool, wholeWord: Bool, isRegex: Bool) -> Int {
        guard let handle else { return 0 }
        return Array(query.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_term_surface_find(
                handle, bytes.baseAddress, bytes.count,
                caseSensitive, wholeWord, isRegex,
            )
        }
    }

    /// The current hit as the one-based `(current, total)` a find bar prints, or `nil` for none.
    func findPosition() -> (current: Int, total: Int)? {
        guard let handle else { return nil }
        var index = 0
        var total = 0
        guard slopdesk_term_surface_find_position(handle, &index, &total) else { return nil }
        return (index, total)
    }

    /// A Swift `Int` as the door's `u32` row, floored at zero and capped at the widest row there is.
    ///
    /// Clamping rather than refusing: every caller of these doors has already asked the engine for the
    /// extent, so a row outside it is arithmetic that overshot rather than a caller guessing. The
    /// engine answers an out-of-range row with `nil` anyway — clamping just makes the crossing total.
    private static func row(_ value: Int) -> UInt32 {
        UInt32(clamping: value)
    }

    /// A Swift `Int` as the door's `u32` column. ``row(_:)``'s argument, one axis over.
    private static func column(_ value: Int) -> UInt32 {
        UInt32(clamping: value)
    }

    // MARK: - The block list

    /// Where one command block was placed by the last ``draw()``.
    ///
    /// Rects are already in the view's own coordinates: the insets and the list's scroll are folded
    /// in on the Rust side, so a header view is placed at ``header`` without knowing either. A block
    /// with no ``header`` is an ORPHAN — output the segmenter saw before any prompt mark, which is
    /// every pane's first screenful and every pane attached mid-command.
    struct Block: Sendable, Equatable {
        /// The whole block, chrome included.
        let frame: CGRect
        /// Where the header goes, or `nil` for an orphan.
        let header: CGRect?
        /// The rows themselves.
        let body: CGRect
        /// Whether the user folded it.
        let collapsed: Bool
        /// Whether it survived viewport culling — a culled block keeps its view off-screen rather
        /// than making the caller re-derive what the layout already decided.
        let visible: Bool
        /// The frame rows it spans, and how many of them the prompt occupies.
        let rows: Range<Int>
        /// How many of ``rows`` are the prompt.
        let promptRows: Int
    }

    /// Where the block list sits, for a scrollbar.
    ///
    /// ``contentHeight`` exceeds ``viewportHeight`` by exactly the chrome the headers and gaps
    /// added: the GRID is sized from the drawable alone, so a prompt appearing never resizes the
    /// pty. ``following`` is the bottom pin.
    struct BlockScroll: Sendable, Equatable {
        let offset: Double
        let contentHeight: Double
        let viewportHeight: Double
        let following: Bool
    }

    /// Every block the last ``draw()`` placed. The index into this array is the index every other
    /// block call below takes.
    func blocks() -> [Block] {
        guard let handle else { return [] }
        let records = ffiAnswerRecords(SlopDeskTerminalBlock.self) { out, cap in
            slopdesk_term_surface_blocks(handle, out, cap)
        }
        return records.map { record in
            Block(
                frame: CGRect(x: record.x, y: record.y, width: record.width, height: record.height),
                header: record.has_header
                    ? CGRect(
                        x: record.header_x,
                        y: record.header_y,
                        width: record.header_width,
                        height: record.header_height,
                    )
                    : nil,
                body: CGRect(
                    x: record.body_x,
                    y: record.body_y,
                    width: record.body_width,
                    height: record.body_height,
                ),
                collapsed: record.collapsed,
                visible: record.visible,
                rows: Int(record.first_row)..<Int(record.end_row),
                promptRows: Int(record.prompt_rows),
            )
        }
    }

    /// Where the list sits.
    func blockScroll() -> BlockScroll? {
        guard let handle else { return nil }
        let record = slopdesk_term_surface_block_scroll(handle)
        return BlockScroll(
            offset: record.scroll_y,
            contentHeight: record.content_height,
            viewportHeight: record.viewport_height,
            following: record.following,
        )
    }

    /// The block under a point, or `nil`.
    func block(at point: CGPoint) -> Int? {
        guard let handle else { return nil }
        let found = slopdesk_term_surface_block_at_point(handle, point.x, point.y)
        return found < 0 ? nil : Int(found)
    }

    /// Tells the surface what the host said about one command block, so its header can print it.
    ///
    /// Upserted by `ordinal` — the same block arrives running and then finished, and the second has
    /// to replace the first. A zero ordinal is a mid-stream attach the host could not count, and the
    /// surface drops it rather than trying to place it.
    ///
    /// `exitCode` and `duration` stay optional all the way across: a running command has neither,
    /// and flattening that to a sentinel here would make a fresh command look like an instant
    /// success on the far side.
    func noteBlock(ordinal: UInt32, command: String, exitCode: Int32?, duration: UInt32?) {
        guard let handle else { return }
        var command = Array(command.utf8)
        command.withUnsafeMutableBufferPointer { buffer in
            slopdesk_term_surface_note_block(
                handle,
                ordinal,
                buffer.baseAddress,
                buffer.count,
                exitCode != nil,
                exitCode ?? 0,
                duration != nil,
                duration ?? 0,
            )
        }
    }

    /// Forgets every noted block, for a pane whose shell died and came back FRESH.
    ///
    /// The fresh shell re-counts its prompts from one while the surface still holds the dead
    /// session's ordinals, and the join anchors on the newest ordinal it holds — so without this the
    /// first prompt of the new shell would wear the exit code of a command from the old one, and
    /// repeated everyday commands make the join's own text check confirm it rather than reject it.
    func forgetBlocks() {
        guard let handle else { return }
        slopdesk_term_surface_forget_blocks(handle)
    }

    /// Folds one block. An index past the end, or an orphan with no header to click, is ignored.
    func setBlock(_ index: Int, collapsed: Bool) {
        guard let handle else { return }
        slopdesk_term_surface_set_block_collapsed(handle, index, collapsed)
    }

    /// Folds or unfolds one block, answering the state it left behind.
    @discardableResult
    func toggleBlock(_ index: Int) -> Bool {
        guard let handle else { return false }
        return slopdesk_term_surface_toggle_block_collapsed(handle, index)
    }

    /// Unfolds every block.
    func expandAllBlocks() {
        guard let handle else { return }
        slopdesk_term_surface_expand_all_blocks(handle)
    }

    /// The wheel and the trackpad, in POINTS, spending the block chrome before the scrollback.
    ///
    /// A positive delta reveals OLDER output — the same direction ``ScrollRequest/rows(_:)`` spells
    /// negative, because that request counts engine rows and this one counts the gesture. Apart from
    /// it for that reason: a gesture is continuous and the chrome is measured in pixels, so
    /// quantising to rows here would make a flick skip the headers it is scrolling past.
    func scrollPoints(_ delta: Double) {
        guard let handle else { return }
        slopdesk_term_surface_scroll_points(handle, delta)
    }

    /// One block's prompt rows as RENDERED, soft wraps rejoined — what a header prints.
    ///
    /// Not the bare command: OSC 133 `B` does not cross the engine's per-row API, so a shell that
    /// decorates its prompt sends that decoration too. A header wanting the exit code and duration
    /// reads the command-block ring instead.
    func blockText(_ index: Int) -> String {
        guard let handle else { return "" }
        let bytes = answer { out, cap in
            slopdesk_term_surface_block_text(handle, index, out, cap)
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The OSC 8 URI a cell carries, or `nil` when it carries no AUTHORED link.
    ///
    /// Distinct from ``TerminalLinkDetector``'s scan, which finds links in the TEXT. When both name
    /// the same cell the authored one wins: the program said what it meant, and a detector guessing
    /// a different span over the top of it would open the wrong thing.
    func hyperlink(column: Int, row: Int) -> String? {
        guard let handle else { return nil }
        let bytes = answer { out, cap in
            slopdesk_term_surface_hyperlink_at(handle, UInt16(clamping: column), UInt16(clamping: row), out, cap)
        }
        // swiftlint:disable:next optional_data_string_conversion
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// Every authored link on screen, for the overlay that underlines them.
    ///
    /// A LIST rather than ``hyperlink(column:row:)`` per cell, because an overlay draws them all at
    /// once: asking cell by cell would cost `rows × cols` crossings every frame to answer a question
    /// one walk of the frame already knows.
    func hyperlinkSpans() -> [TerminalLinkSpan] {
        guard let handle else { return [] }
        let records = ffiAnswerRecords(SlopDeskTerminalLinkSpan.self) { out, cap in
            slopdesk_term_surface_hyperlink_spans(handle, out, cap)
        }
        return records.map { record in
            TerminalLinkSpan(row: Int(record.row), colStart: Int(record.start), colEnd: Int(record.end))
        }
    }

    // MARK: - What the far side pushed

    /// The bytes the TERMINAL owes the pty, drained.
    ///
    /// ⚠️ **Call this after every ``feed(_:)`` and write what it returns to the host.** It is not
    /// optional. `CSI 6n` asks where the cursor is, `CSI c` what the terminal is, `CSI > q` its
    /// version, `OSC 10/11/4 ?` its colours — the engine composes each answer itself and hands it
    /// over exactly once, here. A pane that never drains is a terminal that never answers, and vim
    /// probing for truecolour or tmux asking for the cursor will block or guess wrong against it.
    ///
    /// Distinct from ``encodeKey(keyCode:action:mods:consumedMods:text:composing:)``'s answer, which
    /// is what the USER typed. Both reach the same pty and neither substitutes for the other.
    ///
    /// Empty on the common day, which is the cheap path the two-attempt convention already gives.
    func takePtyReplies() -> Data {
        guard let handle else { return Data() }
        let bytes = answer { out, cap in
            slopdesk_term_surface_take_pty_replies(handle, out, cap)
        }
        return bytes.isEmpty ? Data() : Data(bytes)
    }

    /// The clipboard writes running programs asked for since the last drain.
    ///
    /// ⚠️ **A write here has NOT been applied.** It is what a program ASKED for; whether it reaches a
    /// pasteboard is ``ClipboardWritePolicy``'s decision, made where the user's `clipboard-write`
    /// setting lives. Writing straight from this would make "Ask" behave as "Allow".
    ///
    /// The ONLY push drained here — see ``TerminalClipboardWrite`` for why the bell, the
    /// notification, the progress report, the title and the cwd all belong to the host's wire
    /// instead. Empty on the common day, which the two-attempt convention answers in one call.
    func takeClipboardWrites() -> [TerminalClipboardWrite] {
        guard let handle else { return [] }
        let blob = answer { out, cap in
            slopdesk_term_surface_take_clipboard_writes(handle, out, cap)
        }
        return Self.decodeClipboardWrites(blob)
    }

    /// `[u16 count] count × [u8 target][u32 length][UTF-8]`, as the door writes it. `static` for
    /// ``decodeLogicalLines(_:)``'s reason: the decode is pure arithmetic over bytes, so a test can
    /// exercise every field without a live surface.
    nonisolated static func decodeClipboardWrites(_ blob: [UInt8]) -> [TerminalClipboardWrite] {
        var reader = blob[...]
        guard let count = reader.takeBigEndianUInt16() else { return [] }
        var writes: [TerminalClipboardWrite] = []
        writes.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let targetCode = reader.takeByte(), let text = reader.takeText() else {
                // A truncated blob answers what it DID carry, for ``decodeLogicalLines(_:)``'s
                // reason: a short read costs one write, not the whole drain.
                return writes
            }
            writes.append(TerminalClipboardWrite(
                // An unknown target is the system clipboard, which is the only one Apple has: a
                // write the caller cannot place is still a write the user asked for, and dropping
                // it would be a silent failure where landing it is at worst the wrong pasteboard on
                // a platform that has exactly one.
                target: TerminalClipboardTarget(rawValue: targetCode) ?? .standard,
                text: text,
            ))
        }
        return writes
    }

    // MARK: - The shim's answer convention

    /// Runs a door that answers `slopdesk-ffi`'s byte count, retrying once at the size it reported.
    ///
    /// The convention (`rust/slopdesk-ffi/Cargo.toml`): `0` is no answer, `n <= cap` means `n` bytes
    /// were written, and `n > cap` means nothing was and `n` is the room needed. Once, never a loop:
    /// every door behind this is PURE, so the second call cannot disagree with the first about how
    /// much room it wants. A loop would be a loop that can only run twice, written as if it could
    /// run forever.
    ///
    /// The grown buffer is KEPT rather than dropped. A pane that copied a screenful once will copy
    /// one again, and re-growing per copy is the allocation the scratch exists to avoid.
    private func answer(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [UInt8] {
        let needed = scratch.withUnsafeMutableBufferPointer { room in
            call(room.baseAddress, room.count)
        }
        guard needed > 0 else { return [] }
        if needed <= scratch.count {
            return Array(scratch[0..<needed])
        }
        scratch = [UInt8](repeating: 0, count: needed)
        let written = scratch.withUnsafeMutableBufferPointer { room in
            call(room.baseAddress, room.count)
        }
        guard written > 0, written <= scratch.count else { return [] }
        return Array(scratch[0..<written])
    }
}

/// Reading the shim's big-endian runs off the front of a slice.
///
/// An extension on the slice rather than a `ByteReader` type: every read here CONSUMES, so the
/// cursor is the slice, and a separate type would be a second thing to keep in step with it. Each
/// answers `nil` on a short buffer and leaves the slice untouched, so a truncated blob stops at the
/// first incomplete field rather than reading past it.
private extension ArraySlice<UInt8> {
    /// Takes `count` bytes, or `nil` when fewer remain.
    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, self.count >= count else { return nil }
        let run = prefix(count)
        self = dropFirst(count)
        return run
    }

    /// Takes a big-endian `u32`.
    mutating func takeBigEndianUInt32() -> UInt32? {
        guard let run = take(4) else { return nil }
        return run.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Takes a big-endian `u16`.
    mutating func takeBigEndianUInt16() -> UInt16? {
        guard let run = take(2) else { return nil }
        return run.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    /// Takes one byte.
    mutating func takeByte() -> UInt8? {
        take(1)?.first
    }

    /// Takes a `u32`-length-prefixed UTF-8 run, which is `slopdesk-ffi`'s `push_text`.
    ///
    /// The length and the bytes travel together everywhere the shim writes a string, so reading them
    /// together is what keeps a caller from advancing past one and not the other.
    mutating func takeText() -> String? {
        guard let length = takeBigEndianUInt32(), let run = take(Int(length)) else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: run, as: UTF8.self)
    }

    /// Takes a big-endian IEEE-754 double, by its BITS.
    ///
    /// Through `bitPattern` rather than any arithmetic: the door wrote `f64::to_be_bytes`, which is
    /// the bit pattern, and reconstructing a double any other way would be a second float format.
    mutating func takeBigEndianDouble() -> Double? {
        guard let run = take(8) else { return nil }
        return Double(bitPattern: run.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }
}
