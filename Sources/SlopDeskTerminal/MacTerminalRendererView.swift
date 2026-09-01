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

    /// The BLOCK the open context menu was built over, and the snapshot its rows were greyed by.
    ///
    /// ⚠️ An ORDINAL, never the layout position it was hit-tested at: a menu stays open for seconds and
    /// output arriving meanwhile re-segments the list, so a stashed index would fold or copy a block the
    /// user never clicked. The verbs resolve the ordinal again when they fire.
    private var pendingMenuBlock: (ordinal: UInt32, context: TerminalContextMenu.BlockContext)?

    /// What the input method is composing, or `nil` when it is not.
    ///
    /// Held here rather than asked of the surface because `NSTextInputClient` asks for it back —
    /// ``markedRange()`` and ``attributedSubstring(forProposedRange:actualRange:)`` are questions
    /// about the string AppKit last handed over, in the UTF-16 offsets AppKit speaks. The surface
    /// holds the same text measured in CELLS, which is a different question and cannot answer this.
    private var markedText: String?

    /// Where the composition's own caret sits inside ``markedText``, as AppKit reported it.
    private var markedSelection = NSRange(location: 0, length: 0)

    /// Text an input method committed during the press being handled, or `nil` outside one.
    ///
    /// ⚠️ `nil` and `[]` mean different things. `insertText` also arrives from a menu equivalent and
    /// from `⌘V` on some layouts, long after any `keyDown` — the accumulator being `nil` is what says
    /// "no press is being composed", so that text is sent straight through instead of being stashed
    /// for a press that will never read it.
    private var committed: [String]?

    /// TRUE only for the span of one `interpretKeyEvents` call the command prompt asked for.
    ///
    /// ⚠️ THE ONE FLAG THAT REDIRECTS `NSTextInputClient`. AppKit answers a press by calling BACK
    /// into this view — ``insertText(_:replacementRange:)``, ``setMarkedText(_:selectedRange:replacementRange:)``,
    /// ``doCommand(by:)`` — and those callbacks cannot be told who asked. Without this the same
    /// commit would reach the shell as a keystroke whether the editor owned the line or not.
    ///
    /// Set and cleared around the call rather than tracked as a mode, because `insertText` ALSO
    /// arrives outside a press (a menu equivalent, the character palette) and that text belongs
    /// wherever the keyboard currently points, which is the same question ``commandPromptArmed``
    /// answers on its own.
    private var editingPrompt = false

    /// The key codes whose PRESS the engine was actually given, waiting for their release.
    ///
    /// ⚠️ A POSITIVE SET, and it has to be. The obvious spelling is the negative one — record what the
    /// app SWALLOWED and forward every other release — and it was wrong the moment the Edit menu
    /// gained working key equivalents: AppKit resolves ⌘C against the main menu before the responder
    /// chain, so ``keyDown(with:)`` is never called for it and nothing can be recorded there, while
    /// the RELEASE is delivered to the first responder as normal. A negative set therefore forwards a
    /// ⌘C release for a press the shell never saw, which under the kitty protocol is a reported event
    /// about a key that was never down. Asking "did the engine see the press" instead is answerable at
    /// the one place a press can reach the engine, so a route nobody thought of defaults to silence.
    ///
    /// A set rather than a flag because presses overlap: holding ⌥ and typing is several keys down at
    /// once, and each one's release has to be matched against its own press. Bounded by the number of
    /// keys a person can physically hold, and a key whose release is never delivered (the window lost
    /// focus mid-press) costs one `UInt16` until the same key is pressed again.
    private var pressedKeys: Set<UInt16> = []

    /// The band the command prompt draws in, once the leaf has asked for it.
    private var promptBand: MacTerminalPromptView?

    /// What ``TerminalViewModel/commandPromptArmed`` last answered, so the band is told when it flips.
    private var lastPromptArmed = false

    /// Called after every edit the command prompt took, so the view that draws it can redraw.
    ///
    /// A closure rather than a reference to the prompt view: this file names no sibling view, and the
    /// leaf that mounts both is already where the other five callback pairs are wired
    /// (`TerminalPaneWiring`). `nil` in a headless build, which is also the build with no prompt view.
    var promptDidChange: (() -> Void)?

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
            font: TerminalConfigBroadcaster.shared.font,
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

        driver.onNeedsPresent = { [weak self] in
            self?.needsPresent = true
            self?.notePromptArming()
        }
        driver.onPromptEdited = { [weak self] in self?.promptDidChange?() }
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
        // A composition belongs to the responder that started it. Left standing it would draw over a
        // pane the user has moved away from, and the input context would deliver its commit to
        // whatever took the keyboard next.
        inputContext?.discardMarkedText()
        clearMarkedText()
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
        // The app's own command-line editor, when it owns the line. Above the input method because a
        // press it refuses must still compose, and below copy mode because copy mode is modal.
        if editsPrompt(event) { return }
        if takesPromptEdit(event) { return }
        let action: UInt8 = event.isARepeat ? 2 : 0
        guard belongsToInputMethod(event) else {
            send(event, action: action, composing: false)
            return
        }
        compose(event, action: action)
    }

    /// One press, offered to the input method first.
    ///
    /// ⚠️ THE ORDER IS THE WHOLE OF IME SUPPORT, and it is `interpretKeyEvents` that establishes it:
    /// AppKit hands the press to the input context, which answers by calling BACK into this view —
    /// ``insertText(_:replacementRange:)`` for a commit, ``setMarkedText(_:selectedRange:replacementRange:)``
    /// for a composition still in flight, ``doCommand(by:)`` for anything it recognises as an editing
    /// verb. Only a press that produced none of those is encoded as a keystroke.
    ///
    /// Telex is the case this exists for, and `docs/68` §5.1 item 8 is why it is on the critical
    /// path: `Tieengs` is seven presses that compose one `Tiếng`, and a view that encoded each press
    /// itself sends all seven to the shell.
    ///
    /// A press the composition CONSUMED — ⎋ cancelling a half-typed syllable — reaches
    /// ``send(_:action:composing:)`` flagged composing, which the engine reports and encodes to
    /// nothing. Dropping it here instead would be the same picture with the key event never seen.
    private func compose(_ event: NSEvent, action: UInt8) {
        let wasComposing = markedText != nil
        committed = []
        interpretKeyEvents([event])
        let commits = committed ?? []
        committed = nil
        guard commits.isEmpty else {
            // The input method finished. Each commit is TEXT: the keyCode that produced it is the
            // last of a sequence and encodes nothing on its own, so the engine is handed the text
            // with the modifiers the layout already spent marked consumed.
            let mods = Self.mods(event.modifierFlags)
            // The one press that reaches the engine WITHOUT going through
            // ``send(_:action:composing:)``, so it records itself. Its release is owed exactly like
            // any other's — the commit is text, but the key was still physically down.
            pressedKeys.insert(event.keyCode)
            for text in commits {
                _ = driver.sendKey(
                    keyCode: event.keyCode, action: action, mods: mods,
                    consumedMods: Self.consumedMods(event), text: text, composing: false,
                )
            }
            return
        }
        send(event, action: action, composing: wasComposing || markedText != nil)
    }

    /// Whether this press belongs to the input method at all.
    ///
    /// Everything does EXCEPT an Option the user has given to Alt. `macos-option-as-alt` is a promise
    /// that ⌥→ reaches the program as `ESC [1;3C` rather than composing anything, and a press handed
    /// to `interpretKeyEvents` under that setting comes back as the layout's composed character with
    /// the Option already spent — the meta prefix the setting exists to produce, gone.
    ///
    /// The test is on the SETTING, not on the modifier, which is what keeps a US-International dead
    /// key composing: with `macos-option-as-alt` off, ⌥e then e is still `é`.
    private func belongsToInputMethod(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option) else { return true }
        let raw = event.modifierFlags.rawValue
        switch SettingsKey.optionAsAlt {
        case .off: return true
        case .both: return false
        case .left: return raw & UInt(NX_DEVICELALTKEYMASK) == 0
        case .right: return raw & UInt(NX_DEVICERALTKEYMASK) == 0
        }
    }

    /// Which modifiers macOS SPENT producing this press's text.
    ///
    /// Only Option can be spent in a way the engine must not re-encode: a layout that turns ⌥e into
    /// a dead key has used the Option on the character, and reporting it unconsumed would ALSO
    /// prefix the result with `ESC`. AppKit answers by difference — `characters` is the layout's
    /// output WITH the modifiers applied and `charactersIgnoringModifiers` without, so a press where
    /// the two differ is one where the modifier reached the layout.
    ///
    /// Zero for every other press, including ⇧: an engine that saw Shift consumed would stop
    /// reporting it, and the kitty protocol reports it.
    private static func consumedMods(_ event: NSEvent) -> UInt16 {
        guard event.modifierFlags.contains(.option),
              event.characters != event.charactersIgnoringModifiers
        else {
            return 0
        }
        return slopdesk_term_mods(false, true, false, false, false, false, false, false, false, false)
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
        // A release is forwarded ONLY for a press the engine was given. Under the kitty protocol a
        // release is its own reported event, so an unmatched one tells a program that a key it never
        // saw pressed has just come up.
        //
        // ⚠️ KEYED ON THE PRESS, NOT ON `commandPromptArmed`, and the difference is every state flip
        // between the two halves of one keystroke. Enter submits, the command starts, the prompt
        // disarms — and a release matched against the CURRENT arming would be forwarded for a press
        // the shell never saw. The other direction is the same fault mirrored: a forwarded ⌃C's press
        // reached the shell, so its release must too, and an arming test would swallow it.
        guard pressedKeys.remove(event.keyCode) != nil else { return }
        send(event, action: 1, composing: false)
    }

    // MARK: - The command prompt

    /// The editor's turn at the press — `true` when it took it and nothing should reach the shell.
    ///
    /// ⚠️ THIS IS WHERE THE KEYBOARD CHANGES HANDS, and the ladder position is the whole design: the
    /// rebindable chord table and copy mode both outrank it (a bound ⌘D is a split, and copy mode is
    /// modal), and it outranks the input method, because a press the editor refuses must still be
    /// composable. `docs/68` §5.4.
    ///
    /// Three branches, in the order a shell would answer them:
    ///
    /// 1. **A `⌃` letter the editor may not have** — `⌃C`, `⌃D` on an empty line, `⌃Z`, `⌃L`. The rule
    ///    is Rust's (``PromptControlAction``); this side only reads which letter the press is.
    /// 2. **`⌃R`** — the one editor chord AppKit's key-binding table does not name, so it is
    ///    recognised here rather than waited for in ``doCommand(by:)``.
    /// 3. **⌘Z / ⇧⌘Z / ⌘Y** — the editor's own history. AppKit's key-binding table does not name them
    ///    either (undo is a menu item everywhere else in the app, and this view is not in the menu's
    ///    responder chain for it), so they are read here.
    /// 4. **Everything else** — handed to `interpretKeyEvents`, which is what turns ⌥← into
    ///    `moveWordLeft:` and a Telex sequence into one commit. The callbacks land in this file with
    ///    ``editingPrompt`` set, which is what redirects them.
    private func editsPrompt(_ event: NSEvent) -> Bool {
        guard let model, model.commandPromptArmed else { return false }
        let prompt = model.commandPrompt
        let flags = event.modifierFlags
        if flags.contains(.control), !flags.contains(.command),
           let letter = (event.charactersIgnoringModifiers ?? "").first
        {
            if letter == "r" || letter == "R" {
                searchPrompt(prompt, again: prompt.isSearching)
                return true
            }
            switch PromptControlAction.of(letter: letter, bufferEmpty: prompt.text.isEmpty) {
            // The two forwarding branches record nothing HERE either — ``send(_:action:composing:)``
            // does it for them, which is the point of asking the question at the engine's door.
            case .editor: break
            case .forward:
                send(event, action: event.isARepeat ? 2 : 0, composing: false)
                return true
            case .forwardAndClear:
                prompt.clear()
                send(event, action: event.isARepeat ? 2 : 0, composing: false)
                promptDidChange?()
                return true
            }
        }
        if let step = Self.promptUndoStep(event) {
            _ = step == .undo ? prompt.undo() : prompt.redo()
            promptDidChange?()
            return true
        }
        editingPrompt = true
        interpretKeyEvents([event])
        editingPrompt = false
        promptDidChange?()
        return true
    }

    /// Which way through the editor's history a press asks to go, if it asks at all.
    ///
    /// ⚠️ NOT GATED ON `controls.undo-at-prompt`, and the two are not the same key doing the same
    /// thing. That setting decides whether ⌘Z **emits the readline undo byte** to a shell holding the
    /// line (``TerminalSurfaceDriver/takesPromptEdit(undo:redo:)``, which this branch shadows while
    /// armed). Here the app's own editor holds the line, no byte is going anywhere, and ⌘Z is the same
    /// undo it is in every other text field — a setting about talking to readline cannot switch it off.
    ///
    /// The chord is read exactly as ``takesPromptEdit(_:)`` reads it: ⌃ and ⌥ refused because those are
    /// other line-edit chords, and the letter off `charactersIgnoringModifiers` so it survives a
    /// non-QWERTY layout.
    private static func promptUndoStep(_ event: NSEvent) -> PromptUndoStep? {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return nil
        }
        let base = (event.charactersIgnoringModifiers ?? "").lowercased()
        let shift = flags.contains(.shift)
        if base == "z" { return shift ? .redo : .undo }
        // ⌘Y ignores ⇧, exactly as ``takesPromptEdit(_:)`` reads it. Two spellings of the same chord
        // disagreeing about one modifier is the kind of drift nobody finds by using the app.
        return base == "y" ? .redo : nil
    }

    private enum PromptUndoStep { case undo, redo }

    /// Tells the band when the editor takes the keyboard, or gives it back.
    ///
    /// ⚠️ NOTHING ELSE REDRAWS ON AN ARMING EDGE, and every edge is caused by the far side rather than
    /// by a key: the shell's `OSC 133` prompt marks, a program entering the alternate screen, a pane
    /// losing its connection. Enter is the visible one — the command runs, the prompt disarms, and a
    /// band that redrew only on keystrokes would keep the submitted line on screen with a height to
    /// match until the next one. Driven off the present callback because that is what already fires
    /// when the far side changed anything.
    private func notePromptArming() {
        let armed = model?.commandPromptArmed ?? false
        guard armed != lastPromptArmed else { return }
        lastPromptArmed = armed
        promptDidChange?()
    }

    /// Whether text arriving through `NSTextInputClient` belongs to the editor.
    ///
    /// Two conditions rather than one because the callbacks arrive from two places: ``editingPrompt``
    /// is set around the `interpretKeyEvents` this file makes, and covers a press whose arming was
    /// already checked; ``TerminalViewModel/commandPromptArmed`` covers everything AppKit delivers on
    /// its own, with no press behind it.
    private var promptOwnsText: Bool {
        editingPrompt || model?.commandPromptArmed == true
    }

    /// ⌃R: open a reverse search, or step it to the next older hit.
    private func searchPrompt(_ prompt: CommandPrompt, again: Bool) {
        if again { _ = prompt.searchAgain() } else { prompt.beginSearch() }
        promptDidChange?()
    }

    /// One AppKit editing verb, applied to the editor.
    ///
    /// ⚠️ EVERY CHORD IN THIS FILE IS APPKIT'S, NOT OURS. `⌥←`, `⌃A`, `⇧⌘→`, `fn⌫` and the rest are
    /// already named by the standard key-binding table, and a press arrives here having been through
    /// it — so this maps SELECTORS, never keys, and inherits every layout and every user's
    /// `DefaultKeyBinding.dict` for free. That is also `docs/68` §10's rule read literally: a motion
    /// crosses as a case, never as a key.
    ///
    /// An unrecognised selector is DROPPED rather than passed to `super`. `NSResponder`'s default is
    /// `noResponder`, which beeps, and there is no second reading of an editing verb at a prompt.
    private func applyPromptCommand(_ selector: Selector, to prompt: CommandPrompt) {
        // Scrollback FIRST, because it is not the editor's at all. PageUp at a prompt reads what
        // already scrolled past, in this app as in every other terminal — and these selectors would
        // otherwise fall through to the `default:` and be dropped, which is the one way the editor
        // could take a terminal feature away by existing.
        if let scroll = Self.promptScroll(selector) {
            driver.scroll(scroll)
            return
        }
        // ↑/↓ move the ⌃R PANEL while one is up, before they can mean history or a line. The panel
        // is a list on screen and the arrows are what moves a list; the history walk they otherwise
        // do is the same store read a different way, so leaving them on it would offer two ways
        // through one set of commands at once.
        if prompt.isSearching, Self.promptWalksHistory(selector) {
            _ = selector == #selector(NSResponder.moveUp(_:)) ? prompt.searchBack() : prompt.searchAgain()
            return
        }
        if Self.promptWalksHistory(selector), walkPromptHistory(prompt, selector: selector) { return }
        if let motion = Self.promptMotion(selector) {
            let extends = Self.promptExtendsSelection(selector)
            // A forward motion at the end of the line takes the autosuggestion instead of walking
            // past it — fish's rule, where the accept belongs to the input FUNCTION rather than to
            // one key, so `→`, `End`, `⌃F`, `⌘→` and whatever the user bound in
            // `DefaultKeyBinding.dict` all inherit it. Which motions claim the ghost is Rust's
            // answer, not a list here. Never while extending: ⇧→ is a selection gesture.
            if !extends, prompt.acceptSuggestion(over: motion) { return }
            if extends { prompt.extend(motion) } else { prompt.move(motion) }
            return
        }
        if let motion = Self.promptDeletion(selector) {
            // A running ⌃R edits its QUERY, not the document: the searched line is never put into the
            // buffer while the search runs (`prompt/mod.rs` says why), so there is nothing there for a
            // ⌫ to take back.
            if prompt.isSearching, motion == .grapheme(.backward) {
                prompt.searchBackspace()
            } else {
                prompt.delete(motion)
            }
            return
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submitPrompt(prompt)
        case #selector(NSResponder.insertLineBreak(_:)): prompt.insertNewline()
        case #selector(NSResponder.insertTab(_:)): completePrompt(forward: true)
        case #selector(NSResponder.insertBacktab(_:)): completePrompt(forward: false)
        case #selector(NSResponder.cancelOperation(_:)): cancelPrompt(prompt)
        case #selector(NSResponder.selectAll(_:)): prompt.selectAll()
        case #selector(NSResponder.yank(_:)): pastePrompt(prompt)
        default: break
        }
    }

    /// Return: run what the editor holds, or add a line when the document is still open.
    ///
    /// A live candidate list claims the key first — that is what every completion UI does, and the
    /// alternative is running a command the user was still choosing the last word of.
    private func submitPrompt(_ prompt: CommandPrompt) {
        // ⚠️ THE SEARCH FIRST, and it has to be: a ⌃R panel's rows ARE `candidates`, so the
        // completion branch would fire on them, insert the row and leave the session open behind a
        // panel that had just answered. `acceptSearch` is the same insertion plus the close.
        if prompt.isSearching {
            _ = prompt.acceptSearch()
            return
        }
        if !prompt.candidates.isEmpty {
            prompt.acceptCompletion()
            return
        }
        model?.submitCommandPrompt()
    }

    /// Tab: ask for candidates, then step through them.
    ///
    /// The rule itself — first Tab completes, later Tabs move the highlight, and the shell's own
    /// answer merges in when it lands — lives on the model, because the phone leaf presses the same
    /// key. What is left here is the AppKit half: the selector arrives, and the band is told to
    /// redraw when the asynchronous half of the answer lands after this has returned.
    private func completePrompt(forward: Bool) {
        model?.completeCommandPrompt(forward: forward) { [weak self] in self?.promptDidChange?() }
    }

    /// Escape: undo the most recent thing that is up, innermost first.
    ///
    /// Never clears the TEXT. A key that can throw away a half-typed command by being pressed one
    /// time too many is the wrong key for the job — `⌃C` is the one that abandons a line, and it does
    /// it by telling the shell so.
    private func cancelPrompt(_ prompt: CommandPrompt) {
        if prompt.isSearching {
            prompt.cancelSearch()
            return
        }
        prompt.dismissCompletion()
    }

    /// ⌃Y, and the paste half of ⌘V once the editor owns the line.
    private func pastePrompt(_ prompt: CommandPrompt) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        prompt.paste(text)
    }

    /// The VIEWPORT scroll an AppKit selector names, or `nil` when it names none.
    ///
    /// These are the keys that were never about the line: PageUp/PageDown and Home/End-of-document
    /// read the SCROLLBACK, which the editor does not own and has no opinion about. Kept apart from
    /// ``promptMotion(_:)`` because that table answers a caret question and this one does not — note
    /// that ⌘↑ (`moveToBeginningOfDocument:`) is the EDITOR's, since on a multi-line command the
    /// document in question is the one being typed.
    ///
    /// Negative pages reveal OLDER output, which is the direction ``TerminalRendererSurface/ScrollRequest``
    /// reads negative.
    private static func promptScroll(_ selector: Selector) -> TerminalRendererSurface.ScrollRequest? {
        switch selector {
        case #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.pageUpAndModifySelection(_:)),
             #selector(NSResponder.scrollPageUp(_:)):
            .pages(-1)
        case #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.pageDownAndModifySelection(_:)),
             #selector(NSResponder.scrollPageDown(_:)):
            .pages(1)
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)): .top
        case #selector(NSResponder.scrollToEndOfDocument(_:)): .bottom
        case #selector(NSResponder.scrollLineUp(_:)): .rows(-1)
        case #selector(NSResponder.scrollLineDown(_:)): .rows(1)
        default: nil
        }
    }

    /// Whether the selector is a bare ↑ / ↓ — the two keys that mean two things at a prompt.
    ///
    /// The `…AndModifySelection:` twins are NOT here: a shift-arrow is unambiguously a selection
    /// gesture, and a history walk that also selected something would be nonsense.
    private static func promptWalksHistory(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:))
    }

    /// ↑ / ↓ where they mean HISTORY rather than a line, and `true` when they did.
    ///
    /// The rule is the one every shell with a multi-line editor converged on: ↑ walks back only from
    /// the FIRST line and ↓ walks forward only from the LAST, so inside a `for … done` the arrows
    /// navigate the thing being edited, and at either edge they leave it. On a one-line document both
    /// edges are the same line, which is why an ordinary prompt behaves exactly like `readline`.
    ///
    /// The edge is counted here rather than asked of a door because both halves are already on this
    /// side — the text and the caret's byte offset — and a door would answer a question this can only
    /// get wrong by disagreeing with the string it was handed.
    private func walkPromptHistory(_ prompt: CommandPrompt, selector: Selector) -> Bool {
        let text = prompt.text
        let caret = text.utf8.index(text.utf8.startIndex, offsetBy: min(prompt.cursor, text.utf8.count))
        let before = text.utf8[..<caret]
        if selector == #selector(NSResponder.moveUp(_:)) {
            guard !before.contains(0x0A) else { return false }
            return prompt.historyPrevious()
        }
        guard !text.utf8[caret...].contains(0x0A) else { return false }
        return prompt.historyNext()
    }

    /// The caret motion an AppKit selector names, or `nil` when it names none.
    ///
    /// Each selector appears once with its `…AndModifySelection:` twin, because the two differ only
    /// in whether the anchor moves — which is ``promptExtendsSelection(_:)``'s question, asked of the
    /// same selector rather than encoded twice here.
    private static func promptMotion(_ selector: Selector) -> PromptMotion? {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)),
             #selector(NSResponder.moveLeftAndModifySelection(_:)):
            .grapheme(.backward)
        case #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveRightAndModifySelection(_:)):
            .grapheme(.forward)
        case #selector(NSResponder.moveUp(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)):
            .line(.backward)
        case #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.moveDownAndModifySelection(_:)):
            .line(.forward)
        case #selector(NSResponder.moveWordLeft(_:)),
             #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
             #selector(NSResponder.moveWordBackward(_:)),
             #selector(NSResponder.moveWordBackwardAndModifySelection(_:)):
            .word(.backward)
        case #selector(NSResponder.moveWordRight(_:)),
             #selector(NSResponder.moveWordRightAndModifySelection(_:)),
             #selector(NSResponder.moveWordForward(_:)),
             #selector(NSResponder.moveWordForwardAndModifySelection(_:)):
            .word(.forward)
        case #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
             #selector(NSResponder.moveToLeftEndOfLine(_:)),
             #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)):
            .lineEdge(.backward)
        case #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
             #selector(NSResponder.moveToRightEndOfLine(_:)),
             #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)):
            .lineEdge(.forward)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)),
             #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)):
            .documentEdge(.backward)
        case #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)):
            .documentEdge(.forward)
        default: nil
        }
    }

    /// Whether the selector is one of the `…AndModifySelection:` family.
    ///
    /// Asked by NAME rather than listed, because AppKit's convention is total: every motion has
    /// exactly one such twin and the suffix is what tells them apart. A hand-kept list would go stale
    /// the first time a selector was added to ``promptMotion(_:)`` and its twin was not.
    private static func promptExtendsSelection(_ selector: Selector) -> Bool {
        NSStringFromSelector(selector).hasSuffix("AndModifySelection:")
    }

    /// The deletion granularity an AppKit selector names, or `nil`.
    ///
    /// ⌫ with a selection deletes the selection, and that is the editor's own rule
    /// (`slopdesk_terminal::prompt`) rather than a case here — the granularity is what crosses.
    private static func promptDeletion(_ selector: Selector) -> PromptMotion? {
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)):
            .grapheme(.backward)
        case #selector(NSResponder.deleteForward(_:)): .grapheme(.forward)
        case #selector(NSResponder.deleteWordBackward(_:)): .word(.backward)
        case #selector(NSResponder.deleteWordForward(_:)): .word(.forward)
        case #selector(NSResponder.deleteToBeginningOfLine(_:)): .lineEdge(.backward)
        case #selector(NSResponder.deleteToEndOfLine(_:)): .lineEdge(.forward)
        default: nil
        }
    }

    /// Encodes one press through the engine and sends what it produced.
    ///
    /// `composing` is the engine's own flag for "an input method is mid-composition": the press is
    /// REPORTED — the kitty protocol says so — and encodes to no bytes.
    private func send(_ event: NSEvent, action: UInt8, composing: Bool) {
        // Every press that reaches the engine passes here, which is what makes ``pressedKeys`` an
        // answer rather than a guess. Action 1 is the release itself, already removed by its caller.
        if action != 1 { pressedKeys.insert(event.keyCode) }
        _ = driver.sendKey(
            keyCode: event.keyCode,
            action: action,
            mods: Self.mods(event.modifierFlags),
            consumedMods: Self.consumedMods(event),
            text: event.characters ?? "",
            composing: composing,
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

    /// Every editing verb AppKit recognises, refused.
    ///
    /// ⌃A is `moveToBeginningOfLine:` to AppKit and `\u{01}` to a shell, and there is no third
    /// reading: this view has no document for the verb to act on. Refusing without calling `super`
    /// is also what stops the system beep — `NSResponder`'s default is `noResponder`, which beeps —
    /// and leaves ``compose(_:action:)``'s accumulator empty so the press is encoded as a keystroke.
    ///
    /// ⚠️ IN THE CLASS BODY, NOT THE `NSTextInputClient` EXTENSION IT BELONGS TO BY SUBJECT.
    /// `NSResponder` declares this too, so the implementation OVERRIDES rather than merely conforms —
    /// and Swift does not allow `override` in an extension. Split by that language rule alone.
    ///
    /// With the command prompt armed the verb finally HAS a document to act on, and this is the door
    /// every editing chord arrives through — see ``applyPromptCommand(_:to:)``.
    override func doCommand(by selector: Selector) {
        guard editingPrompt, let prompt = model?.commandPrompt else { return }
        applyPromptCommand(selector, to: prompt)
    }

    /// What an input method is composing over the editor's line, and where its own caret sits inside
    /// it — the pair the prompt view draws as an underlined preedit run at the caret.
    ///
    /// `nil` when nothing is being composed. The text is NOT in the editor's buffer: a composition is
    /// not an edit until it commits, and putting it there would give the undo stack a step per
    /// keystroke of a syllable the user has not finished spelling.
    var markedComposition: (text: String, selection: NSRange)? {
        guard let markedText else { return nil }
        return (markedText, markedSelection)
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
        // `controls.shift-click` is the one thing that takes the click BACK off such a program: with
        // it on, ⇧ means "this drag is mine", which is how a selection is made over a full-screen
        // TUI at all. The setting stores four values and is read as two — ``MouseShiftCapture``'s own
        // rule, not a comparison here. The half that is NOT actuated is the program's ability to
        // override the bypass (DEC mode 1029): the engine exposes no reading of it, so `always` and
        // `enabled` behave alike, as do `never` and `disabled`.
        let shiftSelects = event.modifierFlags.contains(.shift) && SettingsKey.allowShiftClick.extendsSelection
        if !shiftSelects,
           driver.sendMouse(action: 0, button: 0, mods: Self.mods(event.modifierFlags), at: point)
        {
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
            // `controls.click-to-move`, and the RELEASE is the only honest moment for it: a press
            // that turns into a drag is a selection, and moving the shell's cursor at the press
            // would have fired for the first pixel of every one of them. A gesture that selected
            // nothing is the CLICK this answers.
            if !driver.hasSelection() {
                driver.clickToMove(at: point)
            }
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
        // The block wash and the program's own hover are two different readers of one move, and both
        // get it: a mouse-reporting TUI runs on the alternate screen, where there are no blocks to
        // wash, so the two never light at once.
        driver.setHover(point)
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
        driver.setHover(nil)
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
        // POINTS, not rows: the block list's chrome is spent before the scrollback, and rounding to
        // rows first would flick past a header instead of through it. `mouse-scroll-multiplier`
        // scales the DELTA rather than the rows, so a 0.4 multiplier stays a 0.4 multiplier instead
        // of quantising every notch up to a whole row. Multiplied here rather than in the driver
        // because it is a WHEEL number — the phone scrolls with a finger and has no notch to scale.
        //
        // Only a PRECISE delta is already points. A notched wheel reports LINES, and handing those
        // to a points door would move a whole notch by three points — near-invisible. A line is a
        // row, so the cell height is the conversion, and `cellMetrics` answers it in points.
        //
        // Un-negated, unlike `.rows(_:)`: a positive `scrollingDeltaY` is the content moving DOWN,
        // which reveals what is above it — older output — and that is the direction this door reads
        // positive. `scrollPoints` spills whatever the chrome cannot absorb into the engine with the
        // sign already carried through, so one flick keeps one direction across the seam.
        let lineHeight = event.hasPreciseScrollingDeltas ? 1 : Double(driver.cellMetrics()?.cellHeight ?? 0)
        let travelled = Double(event.scrollingDeltaY) * lineHeight * SettingsKey.scrollMultiplierValue
        guard travelled != 0 else { return }
        driver.scrollPoints(travelled)
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

    /// The right-click menu: the link items for the span under the click, the items for the BLOCK it
    /// landed in, then the standard set.
    ///
    /// Everything about WHICH items exist, in what order, with what words and which of them are
    /// enabled is ``TerminalContextMenu``'s — this builds `NSMenuItem`s over that answer and routes
    /// each one back through ``TerminalSurfaceDriver/run(_:)`` or its block sibling.
    ///
    /// Most specific first: a link is a span the pointer is ON, a block is the region it is IN, and the
    /// standard set is the pane's. Both prepended sections are absent for a click that found neither,
    /// which is most clicks — so the standard items keep their usual place under the pointer.
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
        let point = convert(event.locationInWindow, from: nil)

        pendingMenuLink = detectedLink(at: point)
        if let link = pendingMenuLink {
            for item in TerminalContextMenu.linkItems(for: link.kind) {
                menu.addItem(entry(
                    title: item.title(for: link.kind), symbol: item.symbol, tag: item.rawValue,
                    action: #selector(linkMenuAction(_:)), enabled: true,
                ))
            }
            menu.addItem(.separator())
        }

        // The ORDINAL is stashed, never the layout position: this menu outlives the layout it was
        // built over — output arriving while it is open re-segments the list — and the ordinal is the
        // one key that survives that. `nil` = the click found no block, so no section is drawn.
        pendingMenuBlock = driver.blockMenu(at: point)
        if let block = pendingMenuBlock {
            for item in TerminalContextMenu.blockItems {
                if item.separatorBefore { menu.addItem(.separator()) }
                menu.addItem(entry(
                    title: item.title(for: block.context), symbol: item.symbol(for: block.context),
                    tag: item.rawValue, action: #selector(blockMenuAction(_:)),
                    enabled: TerminalContextMenu.isEnabled(item, context: block.context),
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

    /// The link under a point in view coordinates, or `nil` when the point is over none.
    ///
    /// ``TerminalSurfaceDriver/link(at:cwd:slop:)``'s — the same door the phone's long-press runs, so
    /// an `OSC 8` hyperlink and a detected path are ranked the same way on both. `slop: 0` because a
    /// pointer lands where it is aimed; the phone passes its touch slop instead.
    private func detectedLink(at point: CGPoint) -> DetectedLink? {
        driver.link(at: point, cwd: model?.linkCwd)
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

    // MARK: - The standard editing verbs

    /// ⌘C / ⌘X / ⌘V / ⌘A, which reach this view as RESPONDER SELECTORS and nothing else.
    ///
    /// ⚠️ THEY WERE DEAD IN THE TERMINAL UNTIL THIS EXISTED, and the reason is worth keeping written
    /// down because nothing about the tree looked wrong. `WorkspaceCommands` builds the Edit menu with
    /// `cut:`/`copy:`/`paste:`/`selectAll:` as key equivalents — it has to, since this process has no
    /// MainMenu.nib and even an `NSTextField` gets its ⌘V from that menu. AppKit resolves a key
    /// equivalent against the RESPONDER CHAIN, before any application key monitor sees the event, so
    /// the workspace dispatcher could never have caught them either. This view is the pane's first
    /// responder and implemented none of the four, so the chain ran out and the four oldest chords on
    /// the platform did nothing in the one pane the app exists for.
    ///
    /// Each is one line because the DECISIONS are all already made elsewhere: ``TerminalSurfaceDriver``
    /// `run(_:)` is the single dispatcher the long-press menu, the right-click paste and the phone's
    /// ``TerminalViewModel/onRequestMenuItem`` seam already share, and it is what knows that a copy
    /// while the editor is armed is the editor's only when the grid has no selection, that a paste
    /// while armed is text into the editor, and that a cut over a grid selection degrades to a copy.
    @objc
    private func copy(_: Any?) { driver.run(.copy) }

    @objc
    private func cut(_: Any?) { driver.run(.cut) }

    @objc
    private func paste(_: Any?) { driver.run(.paste) }

    /// ⌘A. The one of the four whose ANSWER changes with the arming, rather than only its side
    /// effects: "everything" means the line being typed while the editor holds it and the whole
    /// scrollback otherwise, and the driver's `.selectAll` only knows about the grid.
    /// `override` because this one — unlike the other three — is `NSResponder`'s already
    /// (`NSStandardKeyBindingResponding`), which is also why `doCommand(by:)` can route it.
    override func selectAll(_: Any?) {
        if let prompt = model?.commandPrompt, model?.commandPromptArmed == true {
            prompt.selectAll()
            promptDidChange?()
            return
        }
        driver.run(.selectAll)
    }

    /// Runs a block item against the block the menu was built over, through the one shared dispatcher.
    ///
    /// The ORDINAL is what was stashed, so the verb resolves the block again at THIS moment — output
    /// that arrived while the menu was open cannot make a fold land on the wrong one.
    @objc
    private func blockMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = TerminalContextMenu.BlockItem(rawValue: raw),
              let ordinal = pendingMenuBlock?.ordinal else { return }
        driver.run(item, ordinal: ordinal)
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

// MARK: - NSTextInputClient

/// The composition half of the keyboard, which is the only reason this view is a text client.
///
/// It is deliberately NOT a text VIEW: there is no document here to navigate, no attributed storage
/// to substring, and no character index a point resolves to — the grid answers all three and the
/// engine owns the grid. So the questions that would need a document are answered with the honest
/// empty value, and the four that a composition genuinely needs are answered for real: what is
/// marked, where it is, where to hang the candidate window, and what was committed.
///
/// `docs/68` §10's rule holds throughout — every number here is AppKit's or a door's, and none is
/// invented on this side. The caret's cell comes from `slopdesk_term_surface_caret_rect`, the cell
/// width of a composition is measured behind `slopdesk_term_surface_set_marked_text`, and this file
/// converts UTF-16 offsets to UTF-8 ones because that is what AppKit speaks and what C takes.
extension MacTerminalRendererView: @MainActor NSTextInputClient {
    /// The input method committed. During a press this is stashed for ``compose(_:action:)``;
    /// outside one — a menu equivalent, a character-palette insertion — it goes straight through.
    func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = Self.plainText(string)
        clearMarkedText()
        guard !text.isEmpty else { return }
        // The editor owns the line, so the text is the DOCUMENT's — or the ⌃R query's, which is the
        // one place typing does not touch the document at all.
        //
        // ``promptOwnsText`` rather than ``editingPrompt`` alone, because this callback ALSO arrives
        // outside a press: an emoji from the character palette, a menu equivalent, an accessibility
        // insertion. Those belong wherever the keyboard currently points, and while the band is up
        // that is the band — a palette emoji landing in the shell's invisible readline instead is
        // exactly the divergence the one-implementation rule exists to prevent.
        if promptOwnsText, let prompt = model?.commandPrompt {
            if prompt.isSearching { prompt.searchType(text) } else { prompt.insert(text) }
            promptDidChange?()
            return
        }
        if committed != nil {
            committed?.append(text)
            return
        }
        // The one press-shaped call that deliberately does NOT record into ``pressedKeys``: there is
        // no physical key behind it (`keyCode: 0` is a placeholder, not a position) and therefore no
        // release will ever arrive to match. Recording it would leave a keycode standing until some
        // unrelated key with the same code was released, and that release would be forwarded twice.
        _ = driver.sendKey(
            keyCode: 0, action: 0, mods: 0, consumedMods: 0, text: text, composing: false,
        )
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        let text = Self.plainText(string)
        guard !text.isEmpty else {
            clearMarkedText()
            return
        }
        markedText = text
        markedSelection = selectedRange
        // A composition over the EDITOR's line is drawn by the prompt view, which reads
        // ``markedComposition`` — so the grid, which is not where the line is, must not also draw it.
        // Two preedit runs on screen at once is what handing this to the surface would look like.
        if promptOwnsText {
            promptDidChange?()
            return
        }
        // AppKit counts in UTF-16 and the door takes UTF-8. `String.Index(utf16Offset:in:)` lands on
        // `endIndex` for an offset past the end, which is the same "caret after everything" the door
        // falls back to — so an out-of-range report is handled once, here, rather than twice.
        let caret = String.Index(utf16Offset: selectedRange.location, in: text)
        driver.setMarkedText(text, cursorBytes: text[..<caret].utf8.count)
    }

    func unmarkText() {
        clearMarkedText()
    }

    func hasMarkedText() -> Bool { markedText != nil }

    /// The marked range in AppKit's UTF-16 offsets, or `NSNotFound` for no composition.
    ///
    /// From zero, because a terminal's composition is not inside a document: there is nothing before
    /// it for an offset to be relative to.
    func markedRange() -> NSRange {
        guard let markedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    /// The composition's own selection, which is the only selection a text client here has.
    ///
    /// Deliberately NOT the terminal's text selection: that one is a reading of the SCREEN, it lives
    /// in grid coordinates, and handing it over as a document range would invite an input method to
    /// replace it.
    func selectedRange() -> NSRange {
        markedText == nil ? NSRange(location: NSNotFound, length: 0) : markedSelection
    }

    /// Where the candidate window hangs: the caret's cell, converted to screen coordinates.
    ///
    /// The rect is asked of the surface rather than derived from the grid here, because with blocks
    /// a row's y is the LAYOUT's answer and not `row × cellHeight` — a scrolled-back cursor under a
    /// stack of headers is exactly where the two disagree. An empty rect at the pointer is the
    /// honest fallback for a cursor that is not on screen; AppKit places the window itself.
    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        // While the editor owns the line the caret is in the BAND, not on the grid, and the band is a
        // sibling view — so the rect is converted from ITS coordinates. A candidate list hanging off
        // the grid's stale cursor cell while the letters appear a band's height below is the most
        // visible way a Telex session can look broken.
        if let band = promptBand, let caret = band.caretRect {
            return window.convertToScreen(band.convert(caret, to: nil))
        }
        guard let cell = driver.caretRect() else { return .zero }
        return window.convertToScreen(convert(cell, to: nil))
    }

    /// No document, so no substring. An input method that asks gets nothing rather than a guess at
    /// what the grid says — reconstructing a row here would hand back text the engine has since
    /// scrolled away.
    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    /// None. The composition is drawn by the renderer in the terminal's own colours, so an attribute
    /// accepted here would be one AppKit expects to see honoured and nothing would honour it.
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// No document means no index. `NSNotFound` is the documented "not in my text" answer, and it is
    /// the true one: a point over this view is over a CELL, which the pointer doors already resolve.
    func characterIndex(for _: NSPoint) -> Int { NSNotFound }

    /// Drops the composition on both sides, so the mirror and the surface can never disagree.
    ///
    /// The band is told too, because it draws the preedit itself when the editor owns the line and
    /// nothing else would tell it the run just went away. Cancelling a Telex composition — Escape, a
    /// click elsewhere — leaves no keystroke and no frame behind it, so the underlined letters would
    /// stay on screen until something unrelated happened to repaint.
    private func clearMarkedText() {
        guard markedText != nil else { return }
        markedText = nil
        markedSelection = NSRange(location: 0, length: 0)
        driver.setMarkedText("", cursorBytes: 0)
        promptDidChange?()
    }

    /// The plain text inside whatever `NSTextInputClient` handed over.
    ///
    /// AppKit passes either an `NSString` or an `NSAttributedString` and does not say which; the
    /// attributes it carries are the input method's own underline styling, which the renderer draws
    /// itself. Anything else is a client contract violation and reads as nothing.
    private static func plainText(_ string: Any) -> String {
        switch string {
        case let text as String: text
        case let text as NSAttributedString: text.string
        default: ""
        }
    }
}

// MARK: - Menu validation

extension MacTerminalRendererView: @MainActor NSMenuItemValidation {
    /// Greys out the two Edit-menu verbs that would have nothing to act on.
    ///
    /// The conformance is DECLARED rather than overridden because `NSView` has no
    /// `validateMenuItem(_:)` to override — only `NSMenuItemValidation` declares it, and AppKit asks a
    /// target for it exactly when that target answers the item's action. So `true` is the right
    /// default here: it reaches this method only for an action this view implements, and the two
    /// context-menu actuators below (`contextMenuAction:`, `linkMenuAction:`) build items that were
    /// already unconditionally enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)),
             #selector(cut(_:)):
            // A selection SOMEWHERE — the grid's, or the editor's while it holds the line. Cut is not
            // asked the narrower question ``CutSelectionPolicy`` will ask it (alternate screen, prompt
            // zone, does the selection end at the cursor): a cut that degrades to a copy still did
            // something, and greying it out here would hide a verb that would have worked.
            driver.hasSelection() || model?.commandPrompt.selection != nil
        case #selector(paste(_:)):
            // The SAME reader every paste verb uses, so the item is enabled exactly when the verb
            // would find something — a `canReadObject(forClasses:)` probe would answer for a
            // pasteboard shape `ClientPasteboard` does not read.
            ClientPasteboard.text()?.isEmpty == false
        default:
            true
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

    /// The command prompt's band, built on first ask and kept for the pane's life.
    ///
    /// Lazy because the leaf asks for it exactly once, at mount, and building it in `init` would put a
    /// Core Text font lookup on the path of every headless surface that never draws one. The three
    /// closures are how it reads THIS view without holding it: `weak self` throughout, so the band
    /// outliving its renderer draws nothing rather than resurrecting one.
    var promptView: PlatformView? {
        if let promptBand { return promptBand }
        guard let model else { return nil }
        let band = MacTerminalPromptView(
            prompt: model.commandPrompt,
            armed: { [weak self] in self?.model?.commandPromptArmed ?? false },
            composition: { [weak self] in self?.markedComposition },
        )
        promptBand = band
        promptDidChange = { [weak band] in band?.refresh() }
        return band
    }

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
