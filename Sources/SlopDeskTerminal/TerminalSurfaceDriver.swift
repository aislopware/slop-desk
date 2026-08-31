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

    /// The grid the last layout produced, so a redundant layout costs no wire traffic.
    private var lastGrid: (cols: UInt16, rows: UInt16)?

    /// Whether the replay's leftovers have been thrown away yet — see ``bind(to:)``.
    private var hasDiscardedReplay = false

    /// Opens a surface, or answers `nil` when this machine cannot draw one.
    ///
    /// The refusal is latched by ``TerminalRendererSurface`` rather than retried: a machine with no
    /// Metal device does not acquire one a frame later, and a view that kept asking would ask every
    /// frame forever.
    init?(family: String, pointSize: Double, scale: Double, size: CGSize) {
        guard let opened = TerminalRendererSurface(
            family: family, pointSize: pointSize, scale: scale, size: size,
        ) else {
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
        applyOptionAsAlt()
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
        surface?.close()
        surface = nil
    }

    // MARK: - TerminalSurface

    func feed(_ bytes: Data) {
        surface?.feed(bytes)
        drain()
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
        onNeedsPresent?()
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
        let replies = surface.takePtyReplies()
        if !replies.isEmpty {
            onWrite?(replies)
        }
        // `if let` rather than comparing the optionals: a tuple is not `Equatable`, so `==` reaches
        // the arity-2 overload only once both sides are unwrapped.
        if let lastGrid, lastGrid == grid { return }
        lastGrid = grid
        setSize(cols: grid.cols, rows: grid.rows)
        onNeedsPresent?()
    }

    /// Pushes the pane's workspace focus and the blink clock's phase.
    func setFocus(_ focused: Bool, blinkVisible: Bool) {
        surface?.setFocus(focused, blinkVisible: blinkVisible)
        onNeedsPresent?()
    }

    /// Pushes the theme's three colours.
    func setTheme(foreground: UInt32, background: UInt32, selection: UInt32) {
        surface?.setTheme(foreground: foreground, background: background, selection: selection)
        onNeedsPresent?()
    }

    /// Re-reads `macos-option-as-alt` and pushes it. Called on bind and on a settings change.
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
        let bytes = surface.encodeKey(
            keyCode: keyCode, action: action, mods: mods,
            consumedMods: consumedMods, text: text, composing: composing,
        )
        guard !bytes.isEmpty else { return false }
        onWrite?(bytes)
        return true
    }

    /// Encodes one pointer event. Answers `false` when the far side is not tracking the mouse, which
    /// the view reads as "this gesture is mine" and answers with a selection instead.
    @discardableResult
    func sendMouse(action: UInt8, button: UInt8, mods: UInt16, at point: CGPoint) -> Bool {
        guard let surface else { return false }
        let bytes = surface.encodeMouse(action: action, button: button, mods: mods, at: point)
        guard !bytes.isEmpty else { return false }
        onWrite?(bytes)
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
        onNeedsPresent?()
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
        case .copy,
             .cut:
            // Cut is copy at a terminal: there is no editable buffer this side to delete from, and
            // the shell's own kill-line is a keystroke the user can send.
            guard let text = selectionText(.plain), !text.isEmpty else { return false }
            // The user's own gesture IS the consent, which is why this takes the two-arm primitive
            // rather than the `clipboard-write` setting: that setting gates what a remote PROGRAM
            // may do, and applying it to a ⌘C would gate the user against themselves.
            guard case .write = ClipboardWritePolicy.decide(confirmRequested: false, text: text) else {
                return false
            }
            return ClientPasteboard.shared.write(text)
        case .selectAll:
            let selected = surface?.selection(.all) ?? false
            if selected { onNeedsPresent?() }
            return selected
        case .clear:
            let cleared = surface?.selection(.clear) ?? false
            onNeedsPresent?()
            return cleared
        case .copyOutput:
            // The latest block's output is the BLOCK store's to fetch (request type 15), not the
            // grid's — the surface has no idea which rows were one command.
            return false
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

    /// ⚠️ A GESTURE read — it walks the whole retained scrollback. The find bar and the block
    /// extractor call it; the display link must not.
    func scrollbackLines() -> [TerminalScrollbackLine] {
        surface?.logicalLines() ?? []
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
