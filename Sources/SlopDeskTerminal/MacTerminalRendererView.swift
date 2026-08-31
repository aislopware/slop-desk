// MacTerminalRendererView — the AppKit half of the terminal surface.
//
// `docs/68` §10's reframing, restated where it applies: MOST OF THIS SWIFT IS EVENT PLUMBING, AND
// EVENT PLUMBING STAYS SWIFT. An `NSView` that receives `keyDown` and forwards it is the same view
// before and after the fork's deletion; what changed is the C ABI it forwards INTO. So this file is
// AppKit and nothing else — every decision it appears to make is `TerminalSurfaceDriver`'s, and
// every number it appears to know is a door's.
//
// ⚠️ THE LAYER IS BORROWED AT +0. `driver.layer` is owned by the Rust handle, not by this view, so
// `detachSurface()` must take it out of the hierarchy BEFORE `driver.close()` frees the handle
// underneath it. Removing the view from its superview is not enough and never was.

#if canImport(AppKit)
import AppKit
import CSlopDeskFFI
import SlopDeskClientCore
import SlopDeskWorkspaceCore

/// The layer-hosting `NSView` the Mac canvas mounts for a terminal pane.
@MainActor
final class MacTerminalRendererView: NSView {
    /// The framework-neutral half. Everything this view does to the terminal goes through it.
    private let driver: TerminalSurfaceDriver

    /// The pane, for the wiring a view owns rather than a driver: focus requests, the canvas pan,
    /// the keybinding interceptor.
    private weak var model: TerminalViewModel?

    /// The display link, started on the first mount and stopped on detach.
    private var displayLink: CADisplayLink?

    /// Whether a present is owed. The driver requests one per feed; the link consumes at most one
    /// per frame, so a burst of chunks costs one draw rather than one each.
    private var needsPresent = false

    /// The tracking area for hover, rebuilt on every bounds change because an `NSTrackingArea` is
    /// fixed to the rect it was made with.
    private var tracking: NSTrackingArea?

    /// Whether a selection drag is live, so `mouseDragged` knows which of the two gestures it is in.
    private var isSelecting = false

    /// Where the pointer last was in view points, for the autoscroll tick — which runs on the
    /// display link, when there is no event to read a position from.
    private var lastPointerPoint: CGPoint = .zero

    /// Whether the live drag is rectangular (⌥ held at press).
    private var isRectangularDrag = false

    /// Whether the live right-button press was handled HERE — intercepted as a paste, taken by ⌃, or
    /// passed to `super` for the menu — and so never reached a mouse-reporting program. Read by
    /// `rightMouseUp`, which must not send a release for a press the program never saw.
    private var suppressedRightButtonPress = false

    /// ``suppressedRightButtonPress``'s middle-button twin, for the selection paste.
    private var suppressedMiddleButtonPress = false

    /// The link the open context menu was built over, stashed at build time so the item that fires
    /// acts on the span under the CLICK rather than under wherever the pointer has since moved.
    private var pendingMenuLink: DetectedLink?

    /// Whether this pane holds the workspace focus, as the last push said.
    ///
    /// Mirrored here rather than asked of the model because the model has no such property to ask —
    /// focus arrives as a PUSH (``setPaneFocused(_:)``, the responder chain), and the one thing that
    /// reads it back is the focus-follows-mouse short-circuit, which fires on every pointer motion and
    /// would thrash the workspace focus without it.
    private var isPaneFocused: Bool

    /// Builds a view for a pane, or `nil` when this machine cannot open a surface.
    init?(model: TerminalViewModel, isFocused: Bool) {
        guard let driver = TerminalSurfaceDriver(
            family: TerminalConfigBroadcaster.shared.fontFamily,
            pointSize: TerminalConfigBroadcaster.shared.fontSize,
            scale: Double(NSScreen.main?.backingScaleFactor ?? 2),
            size: CGSize(width: 640, height: 400),
        ) else {
            return nil
        }
        self.driver = driver
        self.model = model
        isPaneFocused = isFocused
        super.init(frame: .zero)

        wantsLayer = true
        // The layer the handle owns, hosted rather than created: a view that made its own would be
        // a second layer the renderer does not draw into.
        if let hosted = driver.layer {
            layer = hosted
        }

        driver.onNeedsPresent = { [weak self] in self?.needsPresent = true }
        driver.onConfirmClipboardWrite = { [weak self] text, decide in
            self?.confirm(.clipboardWrite, preview: text, dangers: [], decide)
        }
        driver.onConfirmPaste = { [weak self] dangers, decide in
            self?.confirm(.unsafePaste, preview: "", dangers: dangers, decide)
        }
        driver.onPickFileToPaste = { [weak self] deliver in
            self?.pickFileToPaste(deliver)
        }
        driver.bind(to: model)
        pushFocus(isFocused)
    }

    /// The ONE writer of ``isPaneFocused``, so the mirror and the surface can never disagree.
    private func pushFocus(_ focused: Bool) {
        isPaneFocused = focused
        driver.setFocus(focused, blinkVisible: true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("MacTerminalRendererView is built in code, never from a nib")
    }

    // MARK: - Geometry

    /// Top-left origin, because that is the coordinate space every pointer door documents and the
    /// space the overlays lay out in. Flipping here rather than converting per event is what keeps
    /// the conversion from being written eleven times.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        driver.setGeometry(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
        rebuildTrackingArea()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            startDisplayLink()
            driver.setGeometry(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
        }
    }

    private func rebuildTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    // MARK: - The display link

    private func startDisplayLink() {
        guard displayLink == nil, let window else { return }
        let link = window.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One frame: run any live autoscroll, then present if anything asked.
    ///
    /// The autoscroll runs HERE rather than on a timer because it is a per-frame question — "does
    /// this drag still want the viewport to move" — and a timer would answer it at a cadence
    /// unrelated to the one the user sees.
    @objc
    private func tick() {
        if isSelecting, driver.autoscrollDirection != .none {
            driver.autoscrollTick(at: lastPointerPoint, rectangle: isRectangularDrag)
        }
        guard needsPresent else { return }
        needsPresent = false
        driver.present()
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        pushFocus(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        pushFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // `mouse-hide-while-typing`, and the whole of it. The deleted fork's comment implied the
        // engine decided and delegated the hide back; it did not — the decision IS "hide on
        // keyDown", which AppKit spells in one call (docs/DECISIONS.md). Read live off the setting
        // rather than cached, so a Settings toggle takes effect on the very next keystroke, and
        // done BEFORE the interceptor so a swallowed chord still hides the pointer: the person
        // typed either way, which is the only thing this reacts to.
        if SettingsKey.mouseHideWhileTypingEnabled {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        // The rebindable chord table first: a ⌘D the user mapped to a split is not a keystroke the
        // terminal should see, and the interceptor is the shared engine that decides which is which.
        if let interceptor = model?.keyInterceptor, let chord = Self.chord(from: event),
           case .swallow = interceptor.intercept(chord)
        {
            return
        }
        // Copy mode is modal: while it is on, every press steers the selection instead of reaching
        // the shell. The model owns the machine; the view only recognises that it is running.
        if model?.takesModalKeys == true {
            model?.handleCopyModeKey(TerminalViewModel.makeCopyModeKey(event: event))
            return
        }
        if takesPromptEdit(event) { return }
        send(event, action: event.isARepeat ? 2 : 0)
    }

    /// ⌘Z at an editable shell prompt, which is the ONE ⌘ combination that is terminal input rather
    /// than an app shortcut.
    ///
    /// The decision is the driver's (``TerminalSurfaceDriver/takesPromptEdit(undo:redo:)``) and the
    /// rule under it is ``PromptEditPolicy``'s — the same one the phone's `takesPromptUndo` calls. All
    /// this side does is read which chord an `NSEvent` is: ⌃ and ⌥ are refused because those are other
    /// line-edit chords, and the letter is read off `charactersIgnoringModifiers` so the chord is
    /// layout-aware.
    private func takesPromptEdit(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return false
        }
        let base = (event.charactersIgnoringModifiers ?? "").lowercased()
        let shift = flags.contains(.shift)
        return driver.takesPromptEdit(
            undo: base == "z" && !shift,
            redo: (base == "z" && shift) || base == "y",
        )
    }

    override func keyUp(with event: NSEvent) {
        send(event, action: 1)
    }

    /// Encodes one press through the engine and sends what it produced.
    private func send(_ event: NSEvent, action: UInt8) {
        _ = driver.sendKey(
            keyCode: event.keyCode,
            action: action,
            mods: Self.mods(event.modifierFlags),
            // Nothing is consumed on this path: `consumedMods` describes modifiers an IME already
            // used to produce the text, and an IME commit arrives through `insertText`, not here.
            consumedMods: 0,
            text: event.characters ?? "",
            composing: false,
        )
    }

    /// The engine's `mods` word for an AppKit flag set.
    ///
    /// ⚠️ Every bit comes from `slopdesk_term_mods` and none is written here — the layout is
    /// `libghostty-vt`'s and a copy of it in Swift would drift silently. The SIDE flags read the raw
    /// device-dependent bits, which is the only place AppKit says which Option was held.
    static func mods(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        let raw = flags.rawValue
        return slopdesk_term_mods(
            flags.contains(.shift),
            flags.contains(.option),
            flags.contains(.control),
            flags.contains(.command),
            flags.contains(.capsLock),
            flags.contains(.numericPad),
            raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0,
            raw & UInt(NX_DEVICERALTKEYMASK) != 0,
            raw & UInt(NX_DEVICERCTLKEYMASK) != 0,
            raw & UInt(NX_DEVICERCMDKEYMASK) != 0,
        )
    }

    /// The chord the interceptor table is keyed by, or `nil` for a press that names none.
    ///
    /// `KeyChordNormalizer`'s, not this file's — the same normalization the workspace's own key
    /// dispatcher runs, so a chord the user bound in one place is the chord recognised in the other.
    /// It covers the NAMED keys (Tab, Return, Space) as well as the printable ones, which the hand
    /// -rolled version here did not: a bound ⌃⇧Space used to reach the shell instead of being
    /// swallowed. It also rejects what must not be a chord — a bare Escape normalizes to `nil`
    /// precisely so it always reaches a TUI.
    private static func chord(from event: NSEvent) -> KeyChord? {
        KeyChordNormalizer.chord(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifierFlags: KeyChordNormalizer.Modifiers(
                shift: event.modifierFlags.contains(.shift),
                control: event.modifierFlags.contains(.control),
                option: event.modifierFlags.contains(.option),
                command: event.modifierFlags.contains(.command),
            ),
        )
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        // The click focuses the pane FIRST. This view is the deepest in the pane, so it wins the
        // hit-test and no ancestor's focus handler ever sees the click — a pane that started a
        // selection without taking focus is the bug this line is.
        model?.onRequestFocus?()
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        lastPointerPoint = point
        // A mouse-reporting program owns the click; only when it declines does the selection start.
        guard !driver.sendMouse(action: 0, button: 0, mods: Self.mods(event.modifierFlags), at: point) else {
            return
        }
        isSelecting = true
        isRectangularDrag = event.modifierFlags.contains(.option)
        driver.selectPress(
            at: point,
            timeMs: event.timestamp * 1000,
            repeatIntervalMs: NSEvent.doubleClickInterval * 1000,
            // The slop a click ladder allows, in points. AppKit publishes no constant for it, so it
            // is the door's parameter rather than a number this side invents a meaning for.
            repeatDistance: 3,
        )
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPointerPoint = point
        if isSelecting {
            driver.selectDrag(to: point, rectangle: isRectangularDrag)
        } else {
            _ = driver.sendMouse(action: 2, button: 0, mods: Self.mods(event.modifierFlags), at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPointerPoint = point
        if isSelecting {
            isSelecting = false
            driver.selectRelease(at: point)
        } else {
            _ = driver.sendMouse(action: 1, button: 0, mods: Self.mods(event.modifierFlags), at: point)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        // The MODAL POINTER SHIELD: an `NSTrackingArea` is rect-based and keeps firing under a
        // palette composited over it, so hover traffic would reach a mouse-reporting TUI through the
        // card. Clicks already obey the occlusion via ordinary hit-testing; this makes hover match.
        guard !TerminalPointerShield.isActive() else { return }
        requestFocusFollowsMouseIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        lastPointerPoint = point
        _ = driver.sendMouse(action: 2, button: 255, mods: Self.mods(event.modifierFlags), at: point)
    }

    /// The pointer arriving is the other half of "Mouse-over-to-focus": a pane the pointer enters and
    /// then rests in produces no `mouseMoved` at all, so entry has to claim the focus itself.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !TerminalPointerShield.isActive() else { return }
        requestFocusFollowsMouseIfNeeded()
    }

    /// The pointer LEAVING is reported to the program as an out-of-bounds position, which is how a
    /// mouse-reporting TUI learns its hover highlight should drop. `(-1, -1)` is deliberately outside
    /// every cell rather than clamped to `(0, 0)`, which would read as a hover over the first one.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // A held button keeps delivering positions past the edge, and those are a live drag rather
        // than a departure — reporting "left the viewport" mid-drag would end the program's own
        // selection while the user is still making it.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        _ = driver.sendMouse(
            action: 2, button: 255, mods: Self.mods(event.modifierFlags), at: CGPoint(x: -1, y: -1),
        )
    }

    /// Claims the workspace focus for a hover, when the setting says a hover may.
    ///
    /// The decision — including why "already focused" is load-bearing rather than an optimisation — is
    /// ``FocusFollowsMousePolicy``'s; the setting is read LIVE so a Settings toggle takes effect on the
    /// next hover rather than the next mount.
    private func requestFocusFollowsMouseIfNeeded() {
        guard FocusFollowsMousePolicy.shouldRequestFocus(
            focusFollowsMouse: SettingsKey.focusFollowsMouseEnabled,
            isAlreadyFocused: isPaneFocused,
        ) else { return }
        model?.onRequestFocus?()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Cleared at the top of the press, not only when the matching release consumes it: a press
        // that ends inside menu tracking never sees its `rightMouseUp` at all, and a flag left
        // standing would eat the NEXT release — one belonging to a program that is by then tracking.
        suppressedRightButtonPress = false
        let point = convert(event.locationInWindow, from: nil)
        // ⌃-right is the macOS spelling of a secondary click and always means the MENU, whatever
        // `right-click-action` says — the modifier is the user overriding their own default, so it
        // must not be intercepted as a paste. Flagged so `rightMouseUp` knows the press it is
        // balancing never reached the program.
        if event.modifierFlags.contains(.control) {
            suppressedRightButtonPress = true
            super.rightMouseDown(with: event)
            return
        }
        // The selection is read BEFORE the click is forwarded, so it is the genuine pre-click one.
        switch RightClickPolicy.outcome(
            action: SettingsKey.rightClickAction,
            hasSelection: driver.hasSelection(),
            mouseCaptured: driver.modes().isMouseTracking,
        ) {
        case .forward:
            guard !driver.sendMouse(action: 0, button: 1, mods: Self.mods(event.modifierFlags), at: point) else {
                return
            }
            // The engine declined it after all — a pointer nobody is reporting. The menu is where a
            // right-click that reaches no program belongs.
            suppressedRightButtonPress = true
            super.rightMouseDown(with: event)
        case .paste:
            // The whole point of taking the click: a right-click paste goes through the SAME
            // four-danger pre-check ⌘V does, which a dispatch inside the engine could never reach.
            suppressedRightButtonPress = true
            driver.run(.paste)
        case .copy:
            suppressedRightButtonPress = true
            driver.run(.copy)
        case .menu:
            suppressedRightButtonPress = true
            super.rightMouseDown(with: event)
        case .ignore:
            suppressedRightButtonPress = true
        }
    }

    /// Balances a press the program never saw. Without this a program that IS tracking sees a release
    /// with no press for every intercepted click and, in the worst case, treats the button as stuck.
    override func rightMouseUp(with event: NSEvent) {
        if suppressedRightButtonPress {
            suppressedRightButtonPress = false
            super.rightMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard !driver.sendMouse(action: 1, button: 1, mods: Self.mods(event.modifierFlags), at: point) else {
            return
        }
        super.rightMouseUp(with: event)
    }

    /// Middle-click pastes the SELECTION, the X11 convention — and only when no program is tracking
    /// the mouse, since a middle button is an ordinary button to a program that asked for one.
    override func otherMouseDown(with event: NSEvent) {
        suppressedMiddleButtonPress = false
        let point = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        guard !driver.sendMouse(action: 0, button: 2, mods: Self.mods(event.modifierFlags), at: point) else {
            return
        }
        suppressedMiddleButtonPress = true
        driver.run(.pasteSelection)
    }

    /// ``otherMouseDown``'s balance, for its reason.
    ///
    /// The button check mirrors the press's: only button 2 is ever forwarded there, so reporting a
    /// release for a 4th or 5th button would be exactly the unpaired report the flag exists to prevent.
    override func otherMouseUp(with event: NSEvent) {
        if suppressedMiddleButtonPress {
            suppressedMiddleButtonPress = false
            return
        }
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard !driver.sendMouse(action: 1, button: 2, mods: Self.mods(event.modifierFlags), at: point) else {
            return
        }
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌥-scroll is the deliberate canvas-pan escape hatch; a plain scroll always goes to this
        // pane's own scrollback, because scroll follows the POINTER rather than focus.
        if event.modifierFlags.contains(.option) {
            model?.onCanvasScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // A full-screen program that asked for mouse reports gets the wheel as a report; only when
        // it declines does the viewport move, which is what makes scrolling inside vim work.
        guard !driver.sendMouse(action: 2, button: 4, mods: Self.mods(event.modifierFlags), at: point) else {
            return
        }
        // `mouse-scroll-multiplier` scales the DELTA, before rounding: scaling the rows instead would
        // quantise every wheel notch to at least one row and turn a 0.4 multiplier into no change at
        // all. Multiplied here rather than in the driver because it is a WHEEL number — the phone
        // scrolls with a finger and has no notch to scale.
        let rows = Int32((event.scrollingDeltaY * SettingsKey.scrollMultiplierValue).rounded())
        guard rows != 0 else { return }
        driver.scroll(.rows(rows))
    }

    /// The I-beam over the terminal, which is what says the text can be selected.
    ///
    /// A cursor RECT rather than a `cursorUpdate:`, because AppKit re-establishes rects on its own
    /// after every scroll and resize; a manual `set()` has to be re-run at each and is silently wrong
    /// in between.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - The context menu

    /// The right-click menu: the link items for the span under the click, then the standard set.
    ///
    /// Everything about WHICH items exist, in what order, with what words and which of them are
    /// enabled is ``TerminalContextMenu``'s — this builds `NSMenuItem`s over that answer and routes
    /// each one back through ``TerminalSurfaceDriver/run(_:)``.
    ///
    /// ⚠️ `autoenablesItems` is turned OFF, and that is not a style choice. `NSMenu` defaults it ON,
    /// which RE-VALIDATES every item at display time and enables any whose target responds to the
    /// action selector — all of them here — clobbering the per-item enablement that was just computed.
    override func menu(for event: NSEvent) -> NSMenu? {
        let context = TerminalContextMenu.Context(
            hasSelection: driver.hasSelection(),
            clipboardHasText: !(ClientPasteboard.text()?.isEmpty ?? true),
            paneConnected: model?.connectionStatus.isLive ?? false,
            hasCommandOutput: model?.blocks.latest?.complete ?? false,
        )
        let menu = NSMenu()
        menu.autoenablesItems = false

        pendingMenuLink = detectedLink(at: convert(event.locationInWindow, from: nil))
        if let link = pendingMenuLink {
            for item in TerminalContextMenu.linkItems(for: link.kind) {
                menu.addItem(entry(
                    title: item.title(for: link.kind), symbol: item.symbol, tag: item.rawValue,
                    action: #selector(linkMenuAction(_:)), enabled: true,
                ))
            }
            menu.addItem(.separator())
        }

        for item in TerminalContextMenu.items {
            if item.separatorBefore { menu.addItem(.separator()) }
            menu.addItem(entry(
                title: item.title, symbol: item.symbol, tag: item.rawValue,
                action: #selector(contextMenuAction(_:)),
                enabled: TerminalContextMenu.isEnabled(item, context: context),
            ))
            // The "Paste as…" submenu sits directly below Paste, which is the one place its variants
            // appear — they are deliberately absent from the top-level list.
            if item == .paste {
                menu.addItem(pasteAsItem(context: context))
            }
        }
        return menu
    }

    /// One menu row, tagged with the raw item id its action reads back.
    private func entry(
        title: String, symbol: String, tag: String, action: Selector, enabled: Bool,
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = tag
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        return item
    }

    /// The "Paste as…" parent and its four variants, each dispatching like a top-level item.
    private func pasteAsItem(context: TerminalContextMenu.Context) -> NSMenuItem {
        let title = TerminalContextMenu.pasteAsSubmenuTitle
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false // The parent menu's reason, for the same clobbering.
        for item in TerminalContextMenu.pasteAsItems {
            if item.separatorBefore { submenu.addItem(.separator()) }
            submenu.addItem(entry(
                title: item.title, symbol: item.symbol, tag: item.rawValue,
                action: #selector(contextMenuAction(_:)),
                enabled: TerminalContextMenu.isEnabled(item, context: context),
            ))
        }
        parent.submenu = submenu
        return parent
    }

    /// The detected link under a point in view coordinates, or `nil` when the point is over none.
    ///
    /// The hit-test is ``TerminalLinkHitTest``'s and the detection is ``TerminalLinkDetector``'s — the
    /// same pair the ⌘-hover overlay and the phone's long-press run, over the same viewport rows.
    /// `slop: 0` because a pointer lands where it is aimed; the phone passes its touch slop instead.
    private func detectedLink(at point: CGPoint) -> DetectedLink? {
        guard SettingsKey.linkDetectionEnabled, let metrics = driver.cellMetrics() else { return nil }
        let links = TerminalLinkDetector.detect(
            rows: driver.viewportTextRows(),
            cwd: model?.linkCwd,
            schemes: SettingsKey.linkSchemePolicy,
        )
        return TerminalLinkHitTest.link(in: links, metrics: metrics, pointX: point.x, pointY: point.y)
    }

    /// Runs a standard menu item: the surface's own through the driver, the WORKSPACE's through the
    /// pane's callbacks — the split and find verbs are the canvas's, and running them in the renderer
    /// would put the workspace's vocabulary inside the terminal.
    @objc
    private func contextMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = TerminalContextMenu.Item(rawValue: raw) else { return }
        switch item {
        case .splitRight: model?.onContextMenuSplit?(true)
        case .splitDown: model?.onContextMenuSplit?(false)
        case .find: model?.onRequestFind?()
        default: driver.run(item)
        }
    }

    /// Runs a link item against the span the menu was built over, through the one shared actuator.
    @objc
    private func linkMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = TerminalContextMenu.LinkItem(rawValue: raw),
              let link = pendingMenuLink else { return }
        LinkActionActuator.actuate(LinkActionPolicy.action(for: item, link: link), model: model)
    }

    // MARK: - The clipboard-write sheet

    /// Presents the "a program wants to set your clipboard" confirmation.
    ///
    /// Only reached on ``ClipboardAccess/ask``; ``ClipboardAccess/deny`` never gets here and
    /// ``ClipboardAccess/allow`` never asks. A window-less view drops the write, which is the safe
    /// direction: an unanswerable question is not consent.
    private func confirm(
        _ ask: PasteSafetyAnalyzer.Ask,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
        _ decide: @escaping (Bool) -> Void,
    ) {
        PasteProtectionSheet.present(
            ask: ask, preview: preview, dangers: dangers, in: window, completion: decide,
        )
    }

    /// Chooses a file for **Paste File Base64-Encoded…** and hands back its bytes.
    ///
    /// `nil` for a cancel or an unreadable file — the driver pastes nothing rather than pasting the
    /// empty base64 of a file it could not open.
    private func pickFileToPaste(_ deliver: @escaping (Data?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a file to paste, base64-encoded."
        guard let window else {
            deliver(panel.runModal() == .OK ? panel.url.flatMap { try? Data(contentsOf: $0) } : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            deliver(response == .OK ? panel.url.flatMap { try? Data(contentsOf: $0) } : nil)
        }
    }
}

// MARK: - TerminalSurfaceHosting

extension MacTerminalRendererView: @MainActor TerminalMenuItemRunning {
    @discardableResult
    func run(_ item: TerminalContextMenu.Item) -> Bool {
        driver.run(item)
    }

    /// Re-arms the present keep-alive after a resize settles — see ``TerminalViewModel/onResizeSettled``.
    /// One frame is enough here where the fork needed a burst: the drain is synchronous, so the
    /// reflow bytes are on the grid before this view is asked to draw them.
    func requestPresentBurst() {
        needsPresent = true
    }
}

extension MacTerminalRendererView: @MainActor TerminalSurfaceHosting {
    var surfaceView: PlatformView { self }

    func setPaneFocused(_ isFocused: Bool) {
        pushFocus(isFocused)
        if isFocused, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
    }

    /// ⚠️ The ORDER is the whole point — see this file's header. The layer leaves the hierarchy
    /// before the handle that owns it is freed.
    func detachSurface() {
        stopDisplayLink()
        if let tracking {
            removeTrackingArea(tracking)
            self.tracking = nil
        }
        layer = nil
        wantsLayer = false
        driver.close()
    }
}
#endif
