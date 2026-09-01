// TerminalSurfaceDriver — everything about driving a terminal surface that is not a view.
//
// `PlatformView.swift` states the rule this file obeys: the `PlatformView` alias "IS NOT A
// COMPATIBILITY SHIM AND MUST NOT GROW INTO ONE… Each platform's canvas is written against its OWN
// framework". So the shared half of the renderer is NOT a shared view superclass with `#if` around
// every method spelling — it is this, a driver that owns the handle and the model binding and knows
// nothing about `NSView` or `UIView`. The two platform views own one and forward their events into
// it, and the only thing they share is a type, not a framework.
//
// What lives here is what is genuinely identical on both: the handle's lifetime, the feed and the
// two drains that must follow it, the geometry the layout pass reports, the theme, and the four
// capability conformances (`TerminalSurface`, `TerminalSurfaceActions`, `TerminalViewportSnapshotting`,
// `TerminalSelectionControl`) — every one of which is a question answered by a door and has no view
// in it at all.
//
// ⚠️ MAIN THREAD, EVERY CALL, for `TerminalRendererSurface`'s reasons: the engine is `!Send`/`!Sync`
// and carries no lock, the `CAMetalLayer` is main-thread-affine, and so are the Core Text faces.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import QuartzCore
import SlopDeskClientCore
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore

/// The framework-neutral half of the terminal renderer.
@MainActor
final class TerminalSurfaceDriver: @MainActor TerminalSurface {
    /// The live surface, or `nil` on a machine that refused one (no Metal device) and after teardown.
    private var surface: TerminalRendererSurface?

    /// The pane this draws, held weakly: the model outlives a view remount and the view must not
    /// keep a torn-down pane alive.
    private weak var model: TerminalViewModel?

    /// Bytes to send back to the host. Set by ``bind(to:)`` to the model's own `sendInput`, which is
    /// where the sync-input tap and the disconnected-drop already live.
    var onWrite: ((Data) -> Void)?

    /// Asks the platform view to present. The display link belongs to the view — AppKit and UIKit
    /// spell it differently and `NSView.displayLink(target:selector:)` needs a view to hang off —
    /// so the driver requests a frame and the view decides when it lands.
    var onNeedsPresent: (() -> Void)?

    /// Presents a clipboard-write confirmation and calls back with the verdict. The sheet is the
    /// platform's, so the view supplies it; a view that supplies none makes ``ClipboardAccess/ask``
    /// behave as deny, which is the safe direction.
    var onConfirmClipboardWrite: ((String, @escaping (Bool) -> Void) -> Void)?

    /// Presents a paste-protection sheet and calls back with the verdict. The sheet is the
    /// platform's, so the view supplies it; a view that supplies none drops the paste, which is the
    /// safe direction — an unanswerable question is not consent.
    var onConfirmPaste: ((PasteSafetyAnalyzer.PasteDangers, @escaping (Bool) -> Void) -> Void)?

    /// Asks the view to choose a file and hand back its bytes, for **Paste File Base64-Encoded…**.
    /// `nil` bytes mean the user cancelled or the file could not be read. A view that supplies no
    /// picker makes that item a no-op rather than a wrong paste.
    var onPickFileToPaste: ((@escaping (Data?) -> Void) -> Void)?

    /// Called after a menu verb changed the command prompt's text, so the band that draws it redraws.
    ///
    /// Separate from ``onNeedsPresent`` on purpose: that one fires on every frame the GRID changed,
    /// and the band is not on the grid — hanging a redraw off it would repaint the prompt once per
    /// frame of a `yes` flood for text that did not move.
    var onPromptEdited: (() -> Void)?

    /// The grid the last layout produced, so a redundant layout costs no wire traffic.
    private var lastGrid: (cols: UInt16, rows: UInt16)?

    /// Whether the replay's leftovers have been thrown away yet — see ``bind(to:)``.
    private var hasDiscardedReplay = false

    /// The pending scrollback-compression step, or `nil` when none is armed — see
    /// ``scheduleCompression(after:)``.
    private var compression: Task<Void, Never>?

    /// Opens a surface, or answers `nil` when this machine cannot draw one.
    ///
    /// The refusal is latched by ``TerminalRendererSurface`` rather than retried: a machine with no
    /// Metal device does not acquire one a frame later, and a view that kept asking would ask every
    /// frame forever.
    init?(font: TerminalFontSpec, scale: Double, size: CGSize) {
        guard let opened = TerminalRendererSurface(font: font, scale: scale, size: size) else {
            return nil
        }
        surface = opened
    }

    /// The `CAMetalLayer` the view hosts, borrowed at +0.
    ///
    /// ⚠️ The layer's drawable source is the handle. A view still holding it after ``close()`` is
    /// holding a layer whose source is gone, which is why ``close()`` is ordered by the view's
    /// detach and not left to `deinit`.
    var layer: CALayer? { surface?.layer }

    /// Whether a live handle backs this driver.
    var isLive: Bool { surface?.isLive ?? false }

    // MARK: - Binding

    /// Binds the driver to a pane and takes its replay.
    ///
    /// ⚠️ **The replay's leftovers are drained and THROWN AWAY here, and that is load-bearing.**
    /// `attachSurface` re-feeds the retained output ring so a rebuilt surface repaints, and those
    /// bytes are old: a replayed `CSI 6n` makes this fresh engine compose a cursor-position reply
    /// that, forwarded, would type `^[[3;7R` at whatever prompt is live now; a replayed OSC 52 under
    /// an `allow` policy would silently overwrite the pasteboard on every remount. Discarding is
    /// deterministic rather than racy because `attachSurface` replays synchronously — by the time it
    /// returns, everything the replay pushed is in the sink and nothing else is.
    ///
    /// The live drain is wired only afterwards, so there is no window in which a replay's reply can
    /// reach the host.
    func bind(to model: TerminalViewModel) {
        self.model = model
        onWrite = { [weak model] bytes in model?.sendInput(bytes) }
        model.attachSurface(self)
        discardReplayLeftovers()
        followSettings()
    }

    /// Follows ``TerminalConfigBroadcaster`` for the life of this driver, applying on every publish.
    ///
    /// ⚠️ **The generation is the whole dependency, deliberately.** It bumps on every publish even
    /// when nothing moved (`PreferenceRules`' comment says so), and reading the individual fields
    /// inside the tracking block would follow them one by one for no gain — the apply re-reads all of
    /// them anyway. Arming performs the first apply synchronously, which is why `bind` no longer
    /// pushes anything itself: the arm IS the initial push.
    private func followSettings() {
        ObservationFollow.arm(self) { _ in
            TerminalConfigBroadcaster.shared.generation
        } apply: { driver, _ in
            driver.applySettings()
        }
    }

    /// Drops the replay's pty replies and clipboard writes without acting on either.
    private func discardReplayLeftovers() {
        guard let surface, !hasDiscardedReplay else { return }
        hasDiscardedReplay = true
        _ = surface.takePtyReplies()
        _ = surface.takeClipboardWrites()
    }

    /// Unbinds and frees the handle, in that order.
    ///
    /// Idempotent, because the view calls it from `detachSurface()` and from its own teardown and
    /// neither knows whether the other ran.
    func close() {
        if surface != nil { model?.detachSurface(self) }
        onWrite = nil
        // Before the handle goes: a step that woke after the close would call a freed surface, and
        // the `surface` guard inside it is only half the answer — the task also holds the pane.
        compression?.cancel()
        compression = nil
        surface?.close()
        surface = nil
    }

    // MARK: - TerminalSurface

    func feed(_ bytes: Data) {
        surface?.feed(bytes)
        drain()
        armCompression()
        onNeedsPresent?()
    }

    /// The batch path: every chunk written, then ONE drain and one present.
    ///
    /// The drain is per-batch rather than per-chunk because a device-status reply is owed to the
    /// far side once the whole batch has been parsed, not once each wire chunk has — and a backlog
    /// of N chunks would otherwise cost N crossings to hear the same silence.
    func feedBatch(_ chunks: ArraySlice<Data>) {
        guard let surface else { return }
        for chunk in chunks {
            surface.feed(chunk)
        }
        drain()
        armCompression()
        onNeedsPresent?()
    }

    // MARK: - Idle scrollback compression

    /// Arms one compression pass, unless one is already pending.
    ///
    /// ⚠️ **Armed once per QUIET period, not once per feed.** A flood re-entering this every chunk
    /// would rebuild the timer thousands of times a second and never let it fire; leaving the
    /// pending one alone costs one engine call every quarter second, which then finds the scrollback
    /// still moving and postpones itself. Deciding that on this side would need a copy of the
    /// engine's activity token, and there is exactly one — see `slopdesk_vterm::compression`.
    private func armCompression() {
        guard compression == nil else { return }
        scheduleCompression(after: TerminalRendererSurface.compressionIdleDelay)
    }

    /// Sleeps `delay`, takes one bounded compression step, and re-arms at whatever it asked for.
    ///
    /// The whole policy lives on the Rust side: this holds a delay it was given and a task it can
    /// cancel. A `nil` step means the pass is finished, so nothing is re-armed and the next feed is
    /// what starts the next one.
    private func scheduleCompression(after delay: Duration) {
        compression?.cancel()
        compression = Task { [weak self] in
            // Weak across the sleep — a parked compression timer must not extend a closed pane.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            compression = nil
            guard let next = surface?.compressStep() else { return }
            scheduleCompression(after: next)
        }
    }

    func setSize(cols: UInt16, rows: UInt16) {
        // The grid is derived from LAYOUT, not pushed: `setGeometry` measures the view and answers
        // the grid that fits, because the surface knows the cell metrics it drew with and a caller's
        // copy can be a frame stale. A pushed size would be the caller telling the renderer
        // something the renderer already knows better.
        model?.sendResize(cols: cols, rows: rows)
    }

    func handleInput(_ bytes: Data) {
        onWrite?(bytes)
    }

    // MARK: - Feeding, drawing, geometry

    /// Everything the far side pushed during a feed, delivered to whoever owns it.
    ///
    /// ⚠️ **Not optional.** The pty replies are what makes this a terminal that answers when spoken
    /// to; a pane that never drains is one where vim's truecolour probe and tmux's cursor query
    /// block or guess wrong. See `docs/68` §4.1.
    private func drain() {
        guard let surface else { return }
        let replies = surface.takePtyReplies()
        if !replies.isEmpty {
            onWrite?(replies)
        }
        for write in surface.takeClipboardWrites() {
            apply(write)
        }
    }

    /// Runs one clipboard write a program asked for through the user's policy.
    ///
    /// ⚠️ All three arms are this side's — `libghostty-vt` reports every write and enforces nothing.
    /// ``ClipboardWritePolicy/decide(access:text:)`` is the door that cannot be called without
    /// deciding what `deny` means, which is why it is used here rather than the two-arm primitive.
    /// Only ``TerminalClipboardTarget/standard`` is actuated: Apple has no selection clipboard, so a
    /// write aimed at one has no destination to land in and pretending otherwise would put a
    /// program's text somewhere the user cannot see it.
    private func apply(_ write: TerminalClipboardWrite) {
        guard write.target == .standard else { return }
        switch ClipboardWritePolicy.decide(access: SettingsKey.clipboardWrite, text: write.text) {
        case .write:
            _ = ClientPasteboard.shared.write(write.text)
        case .confirm:
            guard let onConfirmClipboardWrite else { return }
            onConfirmClipboardWrite(write.text) { approved in
                guard approved else { return }
                _ = ClientPasteboard.shared.write(write.text)
            }
        case .drop:
            break
        }
    }

    /// Draws one frame. Called from the view's display link.
    func present() {
        surface?.draw()
    }

    /// Re-measures after a layout pass and mirrors the settled grid to the host.
    ///
    /// ⚠️ **The pty drain runs here too**, because a resize can emit an in-band size report and that
    /// report is a reply the far side is waiting on exactly like a `CSI 6n`.
    func setGeometry(size: CGSize, scale: CGFloat) {
        guard let surface, size.width > 0, size.height > 0 else { return }
        guard let grid = surface.setGeometry(size: size, scale: scale) else { return }
        settle(grid)
    }

    /// What a re-measure owes once the surface has answered its new grid, wherever the re-measure
    /// came from — a layout pass or a font change.
    ///
    /// ⚠️ **The pty drain runs here**, because a resize can emit an in-band size report and that
    /// report is a reply the far side is waiting on exactly like a `CSI 6n`. Answers whether the grid
    /// actually moved, so a caller with its OWN reason to repaint can tell that reason apart from
    /// this one.
    @discardableResult
    private func settle(_ grid: (cols: UInt16, rows: UInt16)) -> Bool {
        drainPtyReplies()
        // `if let` rather than comparing the optionals: a tuple is not `Equatable`, so `==` reaches
        // the arity-2 overload only once both sides are unwrapped.
        if let lastGrid, lastGrid == grid { return false }
        lastGrid = grid
        setSize(cols: grid.cols, rows: grid.rows)
        onNeedsPresent?()
        return true
    }

    /// Hands the far side whatever the engine queued for it.
    ///
    /// Split out of ``settle(_:)`` because a re-measure that does NOT settle still owes this: the
    /// engine answers in band, and a reply held back is a far side waiting forever.
    private func drainPtyReplies() {
        guard let replies = surface?.takePtyReplies(), !replies.isEmpty else { return }
        onWrite?(replies)
    }

    /// Pushes the pane's workspace focus and the blink clock's phase.
    /// ⚠️ Drains afterwards because focus is not only the painter's: a program that set DEC mode
    /// 1004 is owed a `CSI I`/`CSI O` report on the edge, and the engine composes it into the same
    /// queue a device-status reply lands in. The edge itself is detected on the Rust side, so
    /// pushing the same focus twice costs nothing.
    func setFocus(_ focused: Bool, blinkVisible: Bool) {
        surface?.setFocus(focused, blinkVisible: blinkVisible)
        drainPtyReplies()
        onNeedsPresent?()
    }

    /// Pushes the theme's three colours.
    func setTheme(foreground: UInt32, background: UInt32, selection: UInt32) {
        surface?.setTheme(foreground: foreground, background: background, selection: selection)
        onNeedsPresent?()
    }

    /// Rebuilds the face stack at a new family and size, and settles the grid that came out of it.
    ///
    /// The present is unconditional rather than `settle`'s: a font change invalidates every glyph in
    /// the atlas whether or not the grid moved, and a family swap at the same metrics is exactly the
    /// case where it does not move.
    ///
    /// ⚠️ **Before the first layout there is no grid to settle.** `bind` applies the settings
    /// synchronously, which is earlier than the view's first `layout` — the surface would answer the
    /// grid of its PLACEHOLDER size and `settle` would mirror that made-up geometry to the host as a
    /// resize. The grid comes from layout, so a pre-layout font change only rebuilds the faces and
    /// waits: ``setGeometry(size:scale:)`` mirrors it a moment later with the real one.
    func setFont(_ font: TerminalFontSpec) {
        guard let surface, !font.family.isEmpty, font.pointSize > 0 else { return }
        guard let grid = surface.setFont(font) else { return }
        if lastGrid != nil {
            settle(grid)
        } else {
            drainPtyReplies()
        }
        onNeedsPresent?()
    }

    /// Re-reads every process-wide terminal setting and pushes it. Called on bind and on each
    /// ``TerminalConfigBroadcaster`` generation.
    ///
    /// ⚠️ **This is the whole live-reload path.** The deleted fork re-parsed a config STRING and
    /// re-applied itself; the renderer that replaced it has typed doors, so "the settings changed"
    /// has to be spelled as the calls below. A setting that grows a door and is not added here is a
    /// setting the user can only change by reopening the pane.
    func applySettings() {
        let broadcaster = TerminalConfigBroadcaster.shared
        setFont(broadcaster.font)
        if let words = broadcaster.themeWords {
            setTheme(
                foreground: words.foreground,
                background: words.background,
                selection: words.selection,
            )
            // An EMPTY palette is a statement, not a gap: it means the source of these colours named
            // no ANSI ladder — the config file states two colours and no more — so all sixteen slots
            // stay at the engine's own rather than being cleared to nothing.
            if !words.palette.isEmpty { surface?.setPalette(words.palette) }
            onNeedsPresent?()
        }
        // The furniture's design rides the same generation as the cells' colours, because it is the
        // same theme: `TerminalChromeAppearance` reads the glass palette the words above came from,
        // and installing one without the other is how a divider ends up in the previous profile's
        // edge tone.
        surface?.setChromeStyle(TerminalChromeAppearance.current)
        applyOptionAsAlt()
        surface?.setScrollback(lines: broadcaster.scrollbackLines)
        surface?.setCursorStyle(broadcaster.cursorStyle)
        surface?.setCursorBlink(broadcaster.cursorBlink)
        surface?.setCursorColor(broadcaster.cursorColor)
        surface?.setCursorTextColor(broadcaster.cursorTextColor)
        surface?.setCursorOpacity(broadcaster.cursorOpacity)
        // Read HERE rather than carried on the broadcaster, which is the line every control knob
        // falls on: the store publishes what it had to RESOLVE, and a plain toggle resolves to
        // itself. `copy-on-select` and its neighbours are read the same way, where they are used.
        surface?.setTrimTrailing(SettingsKey.trimTrailingSpacesOnCopyEnabled)
        surface?.setImages(SettingsKey.terminalImagesEnabled)
        onNeedsPresent?()
    }

    /// Pushes where the pointer is, in surface points, or that it has left.
    ///
    /// A present is owed because hover is a DRAWN state now: the wash is in the renderer's own pass,
    /// so a move that changed which block is under the pointer changes the next frame and nothing
    /// else would ask for it. Owed only when it CHANGED, which is what the door answers — a pointer
    /// gliding inside one block arrives once per sample and would otherwise buy a full render each
    /// time for a picture that is already up.
    func setHover(_ point: CGPoint?) {
        guard surface?.setHover(point) == true else { return }
        onNeedsPresent?()
    }

    /// Pushes what an input method is composing, presenting only when the picture would change.
    ///
    /// The composition never reaches the engine — see the door. Passing `""` clears it, which is
    /// what an input method committing or cancelling reports.
    func setMarkedText(_ text: String, cursorBytes: Int) {
        guard surface?.setMarkedText(text, cursorBytes: cursorBytes) == true else { return }
        onNeedsPresent?()
    }

    /// The caret's cell in view points, for an input method's candidate window.
    func caretRect() -> CGRect? { surface?.caretRect() }

    /// Re-reads `macos-option-as-alt` and pushes it.
    func applyOptionAsAlt() {
        surface?.setOptionAsAlt(SettingsKey.optionAsAlt.surfaceCode)
    }

    /// Scrolls the viewport, then tells the model the viewport moved so the scroll-to-bottom
    /// affordance and the copy-mode badge stay honest.
    func scroll(_ request: TerminalRendererSurface.ScrollRequest) {
        surface?.scroll(request)
        model?.noteViewportScroll(atBottom: surface?.modes().isViewportAtBottom ?? true)
        onNeedsPresent?()
    }

    /// The same, for a continuous gesture measured in POINTS.
    ///
    /// A positive delta reveals OLDER output. Apart from ``scroll(_:)`` because the block list's
    /// chrome is measured in pixels and is spent BEFORE the scrollback: quantising a flick to rows
    /// first would skip past the headers it is scrolling through. What the chrome cannot absorb
    /// spills into the engine as whole rows, so the far end of the gesture is the same scroll the
    /// row door performs.
    func scrollPoints(_ delta: Double) {
        surface?.scrollPoints(delta)
        // BOTH ends have to be at the bottom. A flick the block list absorbed on its own leaves the
        // engine's viewport untouched — still at the last row — while the reader is looking at
        // older output, and asking only the engine would hide the jump-to-bottom affordance exactly
        // when it is wanted.
        let engineAtBottom = surface?.modes().isViewportAtBottom ?? true
        let chromeAtBottom = surface?.blockScroll()?.following ?? true
        model?.noteViewportScroll(atBottom: engineAtBottom && chromeAtBottom)
        onNeedsPresent?()
    }

    /// Every block the last draw placed, for the chrome that decorates them.
    func blocks() -> [TerminalRendererSurface.Block] { surface?.blocks() ?? [] }

    /// Hands the surface one command-block record, so a scrolled-back header can print its outcome.
    func noteBlock(ordinal: UInt32, command: String, exitCode: Int32?, duration: UInt32?) {
        surface?.noteBlock(ordinal: ordinal, command: command, exitCode: exitCode, duration: duration)
    }

    /// Drops those records when the shell behind this pane died and a fresh one replaced it.
    func forgetBlocks() { surface?.forgetBlocks() }

    /// Where the block list sits, for a scrollbar.
    func blockScroll() -> TerminalRendererSurface.BlockScroll? { surface?.blockScroll() }

    /// The block under a point, or `nil`.
    func block(at point: CGPoint) -> Int? { surface?.block(at: point) }

    /// The block under a point as a MENU target — the join key plus its two state bits — or `nil`.
    func blockTarget(at point: CGPoint) -> TerminalRendererSurface.BlockTarget? {
        surface?.blockTarget(at: point)
    }

    /// Folds or unfolds the block wearing `ordinal`, answering the state it left behind.
    ///
    /// ⚠️ Ordinal-keyed rather than positional because a menu outlives the layout it was built over —
    /// see ``TerminalRendererSurface/toggleBlock(ordinal:)``.
    @discardableResult
    func toggleBlock(ordinal: UInt32) -> Bool {
        let collapsed = surface?.toggleBlock(ordinal: ordinal) ?? false
        onNeedsPresent?()
        return collapsed
    }

    /// Folds or unfolds one block, answering the state it left behind.
    @discardableResult
    func toggleBlock(_ index: Int) -> Bool {
        let collapsed = surface?.toggleBlock(index) ?? false
        onNeedsPresent?()
        return collapsed
    }

    /// Folds one block to a stated state.
    func setBlock(_ index: Int, collapsed: Bool) {
        surface?.setBlock(index, collapsed: collapsed)
        onNeedsPresent?()
    }

    /// Unfolds every block.
    func expandAllBlocks() {
        surface?.expandAllBlocks()
        onNeedsPresent?()
    }

    /// One block's prompt rows as rendered — what a header prints.
    func blockText(_ index: Int) -> String { surface?.blockText(index) ?? "" }

    /// The OSC 8 URI a cell carries, or `nil`. An AUTHORED link, which wins over a detected one.
    func hyperlink(column: Int, row: Int) -> String? { surface?.hyperlink(column: column, row: row) }

    /// The link under a point in view POINTS — the AUTHORED one first, the detected one after.
    ///
    /// ## Why the authored one wins
    ///
    /// A cell can carry both: a program may wrap `OSC 8` around text that also LOOKS like a path,
    /// and `gcc` emitting `file:///…#L12` over the words `src/main.c:12` is the ordinary case rather
    /// than a contrived one. The program said what it meant; a detector guessing a different span
    /// over the top of it opens something else (`docs/68` §5.5).
    ///
    /// **Link detection's setting does not gate the authored path**, deliberately. "Auto-Detect Link
    /// Schemes" is a rule about GUESSING — how eagerly to read a URL out of ordinary text — and a
    /// program that emitted `OSC 8` did not guess. Turning detection off silences the heuristic, not
    /// the terminal's own hyperlink protocol.
    ///
    /// `slop` is how far off a target a touch may land, in points; a pointer passes zero.
    func link(at point: CGPoint, cwd: String?, slop: CGFloat = 0) -> DetectedLink? {
        guard let metrics = cellMetrics() else { return nil }
        if let authored = authoredLink(at: point, metrics: metrics) { return authored }
        guard SettingsKey.linkDetectionEnabled else { return nil }
        let links = TerminalLinkDetector.detect(
            rows: viewportTextRows(), cwd: cwd, schemes: SettingsKey.linkSchemePolicy,
        )
        return TerminalLinkHitTest.link(
            in: links, metrics: metrics, pointX: point.x, pointY: point.y, slop: slop,
        )
    }

    /// The `OSC 8` run under a point — the whole run that shares its URI, already classified.
    ///
    /// The engine flags the link per CELL and shares one URI across the run, so the extent is a
    /// question about where the URI changes rather than about the point. `authoredLinkRuns()` asks
    /// it once for the whole viewport, in Rust, and the same answer feeds Hint Mode: an outward
    /// walk spelled here would be that decision written a second time, in the language `docs/68`
    /// §10 keeps it out of.
    ///
    /// The span matters because a menu names what it will open and an underline has to end
    /// somewhere. A one-cell answer would title the menu after a character.
    private func authoredLink(at point: CGPoint, metrics: TerminalCellMetrics) -> DetectedLink? {
        guard let cell = TerminalLinkHitTest.cell(metrics: metrics, pointX: point.x, pointY: point.y)
        else {
            return nil
        }
        return authoredLinkRuns().first { run in
            run.row == cell.row && run.colStart <= cell.column && cell.column < run.colEnd
        }
    }

    // MARK: - Input

    /// Encodes one key press and sends what it produced. Answers whether anything was sent, which
    /// the view reads as "handled".
    @discardableResult
    func sendKey(
        keyCode: UInt16,
        action: UInt8,
        mods: UInt16,
        consumedMods: UInt16,
        text: String,
        composing: Bool,
    ) -> Bool {
        guard let surface else { return false }
        // `controls.shift-arrow-select`: ⇧+arrow steers the SELECTION rather than reaching the
        // program — but only while there is one to steer. The engine refuses to invent a selection
        // from the cursor (`slopdesk-vterm`'s `adjust_selection` says why), and that refusal is the
        // fall-through: with nothing selected the press encodes as the escape the program expects,
        // so a TUI that binds ⇧→ keeps it. A release is excluded and a repeat is not — holding ⇧→
        // extends by one cell per repeat, the way a text field does.
        if action != 1, SettingsKey.shiftArrowSelectEnabled,
           let edge = TerminalBindingAction.Edge.shiftArrow(keyCode: keyCode, mods: mods),
           performBindingAction(TerminalBindingAction.adjustSelection(edge).wire)
        {
            return true
        }
        let bytes = surface.encodeKey(
            keyCode: keyCode, action: action, mods: mods,
            consumedMods: consumedMods, text: text, composing: composing,
        )
        guard !bytes.isEmpty else { return false }
        // `selection-clear-on-typing`: a selection is a reading of the screen, and typing moves the
        // screen out from under it. Gated on bytes actually being produced, so a bare modifier press
        // — which encodes to nothing — does not clear what the user is about to copy.
        if SettingsKey.clearSelectionOnTypingEnabled, hasSelection() {
            clearSelection()
        }
        onWrite?(bytes)
        return true
    }

    /// Encodes one pointer event. Answers `false` when the far side is not tracking the mouse, which
    /// the view reads as "this gesture is mine" and answers with a selection instead.
    ///
    /// `mouse-reporting = false` makes every event answer `false` without asking the engine: the
    /// setting's whole meaning is "programs do not get the mouse", and the honest place to enforce it
    /// is the one call that would hand a program an event. Refusing here rather than at each caller
    /// is also what makes the setting cover the wheel, the drag and the hover in one line instead of
    /// six.
    @discardableResult
    func sendMouse(action: UInt8, button: UInt8, mods: UInt16, at point: CGPoint) -> Bool {
        guard let surface, SettingsKey.allowMouseCaptureEnabled else { return false }
        let bytes = surface.encodeMouse(action: action, button: button, mods: mods, at: point)
        guard !bytes.isEmpty else { return false }
        onWrite?(bytes)
        return true
    }

    /// `controls.click-to-move`: a click on the shell's own prompt line moves its cursor there.
    /// Answers whether anything was sent.
    ///
    /// Two gates, and they are different questions asked of different owners. THIS side asks whether
    /// the shell is at an editable prompt — ``isPromptZone``, the same reading ⌘Z uses, which is
    /// OSC 133 plus a live connection — because a click into the middle of `less` is not an edit and
    /// arrows would page it. The ENGINE asks whether the click is mechanically answerable at all
    /// (primary screen, no mouse-reporting program, the cursor's own row) and how far it is in
    /// GLYPHS. Neither could answer the other's question without holding a copy of the other's state.
    @discardableResult
    func clickToMove(at point: CGPoint) -> Bool {
        guard SettingsKey.clickToMoveEnabled, isPromptZone,
              let metrics = cellMetrics(),
              let cell = TerminalLinkHitTest.cell(metrics: metrics, pointX: point.x, pointY: point.y),
              let bytes = surface?.clickToMove(column: cell.column, row: cell.row)
        else {
            return false
        }
        onWrite?(bytes)
        return true
    }

    /// ⌘Z / ⌘⇧Z / ⌘Y at an editable shell prompt — the ONE ⌘ chord that is terminal input rather than
    /// an app shortcut. Answers whether it was consumed.
    ///
    /// The rule is ``PromptEditPolicy`` (the readline undo byte itself, and why redo is recognised and
    /// deliberately unanswered); the platform's job is only to say which chord was pressed. Both
    /// shells call THIS, so the Mac and the phone cannot drift on which prompts accept an undo.
    func takesPromptEdit(undo: Bool, redo: Bool) -> Bool {
        guard SettingsKey.undoAtPromptEnabled, undo || redo else { return false }
        guard let bytes = PromptEditPolicy.bytes(forUndo: undo, redo: redo, inPromptZone: isPromptZone)
        else { return false }
        onWrite?(Data(bytes))
        return true
    }

    /// The four mode flags, read together.
    func modes() -> TerminalRendererSurface.Modes {
        surface?.modes() ?? TerminalRendererSurface.Modes(
            isAlternateScreen: false, isMouseTracking: false,
            isViewportAtBottom: true, wantsBracketedPaste: false,
        )
    }

    // MARK: - Selection gestures

    @discardableResult
    func selectPress(at point: CGPoint, timeMs: Double, repeatIntervalMs: Double, repeatDistance: Double) -> Bool {
        let changed = surface?.selectPress(
            at: point, timeMs: timeMs,
            repeatIntervalMs: repeatIntervalMs, repeatDistance: repeatDistance,
        ) ?? false
        if changed { onNeedsPresent?() }
        return changed
    }

    @discardableResult
    func selectDrag(to point: CGPoint, rectangle: Bool) -> Bool {
        let changed = surface?.selectDrag(to: point, rectangle: rectangle) ?? false
        if changed { onNeedsPresent?() }
        return changed
    }

    func selectRelease(at point: CGPoint) {
        surface?.selectRelease(at: point)
        // `copy-on-select`: the X11 habit, and the release is the only moment it can fire — a copy per
        // drag step would put a partial selection on the board dozens of times per gesture. It writes
        // through the same receipt path as ⌘C, so the `COPIED` chip does not distinguish them.
        if SettingsKey.copyOnSelectEnabled, let text = selectionText(.plain), !text.isEmpty {
            copyToPasteboard(text)
        }
        onNeedsPresent?()
    }

    /// Puts `text` on the pasteboard and records the receipt the `COPIED · N` chip renders.
    ///
    /// Every copy this driver makes goes through here rather than touching the board directly: the
    /// receipt is the user's only confirmation that a copy landed, and a path that skipped it would be
    /// a copy the app denies having made.
    @discardableResult
    private func copyToPasteboard(_ text: String) -> Bool {
        guard ClientPasteboard.shared.write(text) else { return false }
        model?.noteClipboardCopy(text)
        return true
    }

    /// Which way a live drag wants the viewport to move, asked once per display tick.
    var autoscrollDirection: TerminalRendererSurface.AutoscrollDirection {
        surface?.autoscrollDirection ?? .none
    }

    @discardableResult
    func autoscrollTick(at point: CGPoint, rectangle: Bool) -> Bool {
        let changed = surface?.autoscrollTick(at: point, rectangle: rectangle) ?? false
        if changed { onNeedsPresent?() }
        return changed
    }

    /// The selection as text in one of the three formats, or `nil` when nothing is selected.
    func selectionText(_ format: TerminalRendererSurface.CopyFormat = .plain) -> String? {
        surface?.selectionText(format)
    }
}

// MARK: - Menu items

extension TerminalSurfaceDriver {
    /// Runs one context-menu / responder item.
    ///
    /// The single dispatcher both platforms route through — the Mac's `copy:`/`cut:`/`selectAll:`
    /// responder selectors, the phone's ⌘C/⌘X/⌘A through ``TerminalViewModel/onRequestMenuItem``,
    /// and either one's long-press menu. Answers whether it ran, which a responder reads as
    /// "handled" and a menu reads as "keep the item enabled".
    ///
    /// ## The paste family, and where each half of it lives
    ///
    /// A paste is three decisions and this method makes none of them itself:
    ///
    /// 1. **Which text.** The clipboard, or the surface's own selection for `pasteSelection` (the
    ///    X11 middle-click), or a file's bytes for `pasteFileBase64` — the picker is the view's.
    /// 2. **What shape.** `PasteTransform` base64s or shell-quotes it, and `shellEscaped` is itself
    ///    a face over the Rust `ShellQuoting` the `cd` a jump emits is quoted by.
    /// 3. **What framing.** ``TerminalRendererSurface/encodePaste(_:bracketed:)`` — the ENGINE's,
    ///    because the scrub, the newline rewrite and the end-marker strip are all rules about how
    ///    the far side's parser behaves.
    ///
    /// Between 2 and 3 sits ``PastePrecheck``, which is why the paste cannot simply be spelled as a
    /// binding action: a dangerous payload has to stop and ask, and a fire-and-forget verb has
    /// nowhere to put the question.
    ///
    /// The items this deliberately does NOT run are the ones that are not the surface's:
    /// `splitRight`, `splitDown` and `find` are the pane's, and the model already carries a sink for
    /// each (`onContextMenuSplit`, `onRequestFind`). Running them here would put the workspace's
    /// verbs inside the renderer.
    @discardableResult
    func run(_ item: TerminalContextMenu.Item) -> Bool {
        switch item {
        case .copy:
            if let text = promptSelection(cutting: false) {
                copyToPasteboard(text)
                return true
            }
            return copySelection()
        case .cut:
            if let text = promptSelection(cutting: true) {
                copyToPasteboard(text)
                onPromptEdited?()
                return true
            }
            // A terminal has no editable buffer THIS side, so a cut is a copy plus the DEL bytes the
            // remote line editor would need to erase the run — and only where those bytes can erase
            // it faithfully. ``CutSelectionPolicy`` owns that ladder, including why the alternate
            // screen is refused before the prompt zone is even asked about.
            let cut = CutSelectionPolicy.action(
                hasSelection: hasSelection(),
                isAlternateScreen: modes().isAlternateScreen,
                isPromptZone: isPromptZone,
            )
            guard cut != .none else { return false }
            let selection = selectionText(.plain) ?? ""
            guard copySelection() else { return false }
            // The DEL bytes are for a remote line editor holding the text. While the app's editor
            // owns the line the shell holds nothing, so they would erase whatever the PREVIOUS line
            // left — a cut over a grid selection degrades to a copy, the safe direction of the two.
            guard cut == .copyAndDelete, !(model?.commandPromptArmed ?? false) else { return true }
            // The geometry the policy asks about, answered by the one thing that holds both the
            // selection and the cursor. It reads the last DRAWN frame, so a cut fired between a
            // programmatic selection and the next present sees the older geometry and refuses —
            // which deletes nothing and degrades to a copy, the safe direction of the two.
            let deletes = CutSelectionPolicy.deleteCount(
                selection: selection,
                selectionEndsAtCursor: surface?.selectionEndsAtCursor() ?? false,
            )
            if deletes > 0 {
                onWrite?(Data(repeating: 0x7F, count: deletes))
            }
            return true
        case .selectAll:
            let selected = surface?.selection(.all) ?? false
            if selected { onNeedsPresent?() }
            return selected
        case .clear:
            let cleared = surface?.selection(.clear) ?? false
            onNeedsPresent?()
            return cleared
        case .copyOutput:
            // The latest block's output is the MODEL's to fetch (request type 15), not the grid's —
            // the surface has no idea which rows were one command. The reply is asynchronous and may
            // be empty (a block whose output the host no longer holds), which is a silent no-op
            // rather than an empty copy: `true` here means the request went out.
            guard let model, let index = model.blocks.latest?.index else { return false }
            model.copyBlockOutput(index: index) { [weak self] text in
                guard let text, !text.isEmpty else { return }
                self?.copyToPasteboard(text)
            }
            return true
        case .paste:
            return paste(ClientPasteboard.text(), bracketing: .askTheProgram)
        case .pasteBracketed:
            return paste(ClientPasteboard.text(), bracketing: .force)
        case .pasteAsKeystrokes:
            // As if typed: no brackets, so the engine rewrites newlines as carriage returns and the
            // shell acts on each line exactly as it would on a real Return.
            return paste(ClientPasteboard.text(), bracketing: .suppress)
        case .pasteSelection:
            return paste(selectionText(.plain), bracketing: .askTheProgram)
        case .pasteEscaped:
            return paste(
                ClientPasteboard.text().map(PasteTransform.shellEscaped),
                bracketing: .askTheProgram,
            )
        case .pasteFileBase64:
            guard let onPickFileToPaste else { return false }
            onPickFileToPaste { [weak self] bytes in
                guard let bytes else { return }
                _ = self?.paste(
                    PasteTransform.base64(ofFileBytes: bytes),
                    bracketing: .askTheProgram,
                )
            }
            return true
        case .splitRight,
             .splitDown,
             .find:
            return false
        }
    }

    /// The block under `point` and the right-click snapshot for it, or `nil` when no block is there.
    ///
    /// The one place the two halves meet: the SURFACE knows where the pointer landed, whether that
    /// block can fold and whether it is folded; the MODEL knows whether it joined a host record, whether
    /// that command finished and whether it is starred; the pane knows the transport and the lock. Both
    /// shells ask this rather than assembling seven bits each, so their menus cannot come to disagree.
    func blockMenu(at point: CGPoint) -> (ordinal: UInt32, context: TerminalContextMenu.BlockContext)? {
        guard let target = blockTarget(at: point) else { return nil }
        let record = block(target.ordinal)
        return (target.ordinal, TerminalContextMenu.BlockContext(
            joined: record != nil,
            complete: record?.complete ?? false,
            foldable: target.foldable,
            collapsed: target.collapsed,
            bookmarked: record.map { model?.blocks.isBookmarked($0.index) ?? false } ?? false,
            paneConnected: model?.connectionStatus.isLive ?? false,
            readOnly: model?.isReadOnly ?? false,
        ))
    }

    /// Runs a BLOCK item against the block wearing `ordinal` — the one dispatcher both shells share,
    /// exactly as ``run(_:)`` is for the pane-global items and ``LinkActionActuator`` is for a link.
    ///
    /// ⚠️ **This pane's model, never the store's active-pane convenience.** A right-click on macOS does
    /// not necessarily focus the pane it lands in, so ``WorkspaceStore/copyBlockOutputInActivePane(index:onResult:)``
    /// and its re-run sibling would copy from — or type into — a DIFFERENT pane than the one the user
    /// aimed at. Those stay for the keyboard and palette callers that genuinely mean "the focused pane".
    ///
    /// ⚠️ **Re-Run writes to the pty**, so the read-only lock has to reach it. It is refused twice on
    /// purpose: the menu greys the row (``TerminalContextMenu/isEnabled(_:context:)-block``) and
    /// ``TerminalViewModel/sendInput(_:)`` drops the bytes at the single outbound seam. The seam is the
    /// enforcement; the grey is the affordance agreeing with it.
    ///
    /// `false` means nothing was done — an ordinal no block wears, an empty command, or a verb whose
    /// precondition went away between the menu opening and the click.
    @discardableResult
    func run(_ item: TerminalContextMenu.BlockItem, ordinal: UInt32) -> Bool {
        switch item {
        case .collapse:
            // Ordinal-keyed: the fold vector is positional and the list re-segments while a menu is
            // open, so the layout index is resolved on the far side at THIS moment, not at build time.
            return toggleBlock(ordinal: ordinal)
        case .copyCommand:
            guard let block = block(ordinal), !block.commandText.isEmpty else { return false }
            return copyToPasteboard(block.commandText)
        case .copyOutput:
            // ``run(_:)``'s `.copyOutput` reason, aimed: the output is the MODEL's to fetch (request
            // type 15) and the reply is asynchronous and may be empty, which copies nothing rather
            // than clearing the pasteboard. `true` means the request went out.
            guard let model, let block = block(ordinal) else { return false }
            model.copyBlockOutput(index: block.index) { [weak self] text in
                guard let text, !text.isEmpty else { return }
                _ = self?.copyToPasteboard(text)
            }
            return true
        case .reRun:
            guard let model, let block = block(ordinal) else { return false }
            return model.reRunCommand(block.commandText)
        case .bookmark:
            guard let model, let block = block(ordinal) else { return false }
            model.blocks.toggleBookmark(index: block.index)
            return true
        }
    }

    /// The pane's record for the block wearing `ordinal`, or `nil` when it joined none.
    private func block(_ ordinal: UInt32) -> CommandBlock? {
        model?.blocks.block(promptOrdinal: ordinal)
    }

    /// Copies the selection, honouring `selection-clear-on-copy`. `false` when nothing is selected.
    ///
    /// The user's own gesture IS the consent, which is why this takes the two-arm primitive rather
    /// than the `clipboard-write` setting: that setting gates what a remote PROGRAM may do, and
    /// applying it to a ⌘C would gate the user against themselves.
    private func copySelection() -> Bool {
        guard let text = selectionText(.plain), !text.isEmpty else { return false }
        guard case .write = ClipboardWritePolicy.decide(confirmRequested: false, text: text) else {
            return false
        }
        guard copyToPasteboard(text) else { return false }
        if SettingsKey.clearSelectionOnCopyEnabled {
            clearSelection()
        }
        return true
    }

    /// Whether the terminal is at an EDITABLE shell prompt, as the MODEL derives it — the one
    /// derivation both prompt-gated features and both shells read. No surface ⇒ no prompt.
    var isPromptZone: Bool { model?.isAtEditablePrompt ?? false }

    /// Whether a paste item overrides the program's own bracketed-paste mode.
    ///
    /// Three cases rather than a `Bool` because the third is not a value but a QUESTION, and
    /// spelling it as `bracketed: surface.modes().wantsBracketedPaste` at each call site is how one
    /// of them ends up reading a stale mode.
    enum PasteBracketing {
        /// Ordinary Paste — whatever the foreground program asked for with `?2004h`.
        case askTheProgram
        /// **Bracketed Paste** — framed even if the program never advertised it.
        case force
        /// **Paste as Keystrokes** — never framed, so the payload arrives as if typed.
        case suppress
    }

    /// The command editor's selection for a copy or a cut, or `nil` when this verb is the grid's.
    ///
    /// ⚠️ THE GRID WINS WHEN IT HAS A SELECTION, and that ordering is the whole rule: the two are
    /// DIFFERENT selections — one is a reading of the screen, the other is a range in a line being
    /// typed — and a reader who just dragged over scrollback meant that text. The editor answers only
    /// when the grid has none, so a ⌘C is never stolen; without the test, arming the prompt would
    /// silently change what the oldest verb in the app copies.
    private func promptSelection(cutting: Bool) -> String? {
        guard let model, model.commandPromptArmed, !hasSelection() else { return nil }
        return cutting ? model.commandPrompt.cut() : model.commandPrompt.copy()
    }

    /// Runs one paste end to end: protection, then framing, then the pty.
    ///
    /// Answers whether the paste STARTED, not whether it landed — a payload that trips the
    /// protection sheet returns `true` and completes when the user approves. That is the honest
    /// answer for a menu item's `validate`: the item did something.
    ///
    /// `nil` or empty text answers `false`, which is what makes Paste inert on an empty clipboard
    /// rather than sending a bare bracket pair.
    @discardableResult
    private func paste(_ text: String?, bracketing: PasteBracketing) -> Bool {
        guard let text, !text.isEmpty, let surface else { return false }
        // ⚠️ THE ONE FUNNEL ALL SIX PASTE VERBS REACH, which is why the editor is asked here and not
        // at each of them: `paste`, `pasteBracketed`, `pasteAsKeystrokes`, `pasteSelection`,
        // `pasteEscaped` and `pasteFileBase64` differ only in the text and the framing by the time
        // they arrive. While the app's editor owns the line, all six are TEXT INTO THE EDITOR — the
        // text transforms (escaping, base64) already happened above, and the framing distinctions
        // collapse because bracketing is a wire concern and nothing is reaching the wire.
        //
        // Ahead of the protection precheck deliberately. All four dangers are about what a SHELL does
        // with a payload on arrival, and nothing arrives: the text lands in a buffer the user can
        // read, edit and delete before any of it is run, which is a stronger protection than the
        // sheet.
        if let model, model.commandPromptArmed {
            model.commandPrompt.paste(text)
            onPromptEdited?()
            return true
        }
        let modes = surface.modes()
        switch PastePrecheck.decide(
            clipboard: text,
            protectionOn: SettingsKey.pasteProtectionEnabled,
            isAlternateScreen: modes.isAlternateScreen,
            bracketedSafe: SettingsKey.pasteBracketedSafeEnabled,
            // The live DECSET, from the engine that parsed it — see ``TerminalRendererSurface/Modes``.
            // Under `force` the paste IS bracketed whatever the program said, so the skip rule holds
            // by construction rather than by the program's cooperation.
            programAdvertisedBracketed: bracketing == .force || modes.wantsBracketedPaste,
        ) {
        case .pasteDirect:
            send(text, bracketing: bracketing, modes: modes)
        case let .confirm(dangers):
            guard let onConfirmPaste else { return false }
            onConfirmPaste(dangers) { [weak self] approved in
                guard approved else { return }
                // Re-read the modes: the sheet is modal for the USER, not for the far side, and a
                // program can turn `?2004h` on or off while it is up.
                guard let self, let surface = self.surface else { return }
                send(text, bracketing: bracketing, modes: surface.modes())
            }
        }
        return true
    }

    /// Frames `text` through the engine and puts it on the pty.
    private func send(_ text: String, bracketing: PasteBracketing, modes: TerminalRendererSurface.Modes) {
        let bracketed =
            switch bracketing {
            case .askTheProgram: modes.wantsBracketedPaste
            case .force: true
            case .suppress: false
            }
        guard let bytes = surface?.encodePaste(text, bracketed: bracketed) else { return }
        onWrite?(bytes)
    }
}

// MARK: - TerminalSurfaceActions

extension TerminalSurfaceDriver: @MainActor TerminalSurfaceActions {
    func hasSelection() -> Bool {
        surface?.selection(.ask) ?? false
    }

    func readSelection() -> String? {
        surface?.selectionText(.plain)
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        let ran = surface?.bindingAction(action) ?? false
        if ran { onNeedsPresent?() }
        return ran
    }

    /// ⚠️ A GESTURE read — it walks the whole retained scrollback. Cross-tab search and the block
    /// extractor call it; the display link must not.
    func scrollbackLines() -> [TerminalScrollbackLine] {
        surface?.logicalLines() ?? []
    }

    func find(_ query: String, caseSensitive: Bool, wholeWord: Bool, isRegex: Bool) -> Int {
        let count = surface?.find(query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex) ?? 0
        // The search paints the highlight and may have scrolled to the first hit, and neither is on
        // the display link's own path — the same reason `performBindingAction` asks for a present.
        onNeedsPresent?()
        return count
    }

    func findPosition() -> (current: Int, total: Int)? {
        surface?.findPosition()
    }
}

// MARK: - TerminalViewportSnapshotting

extension TerminalSurfaceDriver: @MainActor TerminalViewportSnapshotting {
    func viewportTextRows() -> [String] {
        surface?.viewportRows() ?? []
    }

    func cellMetrics() -> TerminalCellMetrics? {
        surface?.cellMetrics()
    }

    func authoredLinkSpans() -> [TerminalLinkSpan] {
        surface?.hyperlinkSpans() ?? []
    }

    func authoredLinkRuns() -> [DetectedLink] {
        surface?.hyperlinkRuns() ?? []
    }
}

// MARK: - TerminalSelectionControl

extension TerminalSurfaceDriver: @MainActor TerminalSelectionControl {
    func viewportInfo() -> TerminalViewportInfo? {
        surface?.viewportInfo()
    }

    @discardableResult
    func setSelection(anchor: TerminalScreenPoint, head: TerminalScreenPoint, rectangle: Bool) -> Bool {
        let accepted = surface?.setSelection(anchor: anchor, head: head, rectangle: rectangle) ?? false
        if accepted { onNeedsPresent?() }
        return accepted
    }

    func clearSelection() {
        surface?.selection(.clear)
        onNeedsPresent?()
    }

    func readScreenRow(_ row: Int) -> String? {
        surface?.screenRow(row)
    }

    func lineRange(_ screenRow: Int) -> ClosedRange<Int>? {
        surface?.lineRange(screenRow)
    }
}
