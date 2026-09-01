// MacTerminalPromptView — the command prompt's band, as an `NSView`.
//
// A SHELL. Everything about what the band looks like is `TerminalPromptBand`, which draws through
// Core Text into a `CGContext` and names neither framework; this file is the twelve AppKit facts
// that cannot be shared — the flip, the responder refusal, the intrinsic size and the invalidation.
// `PhoneTerminalPromptView` is the same shell over UIKit, and the two are as short as they are
// because nothing else was allowed into them.
//
// There is no key handling here at all: `MacTerminalRendererView` stays the first responder for the
// pane and routes into the editor (see its `editsPrompt(_:)`), so the focus region, the secure-input
// balance and the whole `ownsKeyboard` gate are untouched by this view existing.
//
// ## Being the hit view is not being the first responder
//
// The band DOES take the mouse — clicking places the caret, dragging selects, a double-click takes a
// word, a triple-click the line, and a click on a candidate row picks it. It still refuses the
// keyboard: `acceptsFirstResponder` is `false`, so AppKit cannot make this view the responder no
// matter where the pointer lands, and the pane's one responder stays the renderer. The two are
// different mechanisms, and the band decision (`docs/decisions` vol-14) rules only on the second.
//
// ⚠️ This REVERSES the `hitTest(_:) -> nil` this file shipped with. That was not a product decision;
// it arrived with the mount as a way of not thinking about focus, and the cost was a text editor
// nobody could click into. `focusPane` is what replaces it and is load-bearing: the click has to
// give the pane the keyboard before it does anything else, which is what the discarded hit test used
// to do by accident.
//
// ⚠️ THE WHOLE FILE IS FENCED, exactly as `MacTerminalRendererView` is. `SlopDeskTerminal` builds for
// the phone too, and an unguarded `import AppKit` there is not a warning — it fails the iOS target
// outright with "unable to resolve module dependency", which is a build nobody runs on this machine
// until `just check-ios`.

#if canImport(AppKit)
import AppKit
import SlopDeskWorkspaceCore

/// The bottom band of a terminal pane: the editor's line, and whatever is under it.
@MainActor
final class MacTerminalPromptView: NSView {
    /// The pane's editor. Read on every draw; never written here.
    private let prompt: CommandPrompt

    /// What an input method is composing over the line, asked of the renderer view that owns the
    /// composition. A closure rather than a stored pair so this view can never hold a preedit the
    /// input context has already withdrawn.
    private let composition: () -> (text: String, selection: NSRange)?

    /// Whether the editor currently owns the keyboard — the band is hidden outright when it does not,
    /// because a prompt drawn under a running `htop` is a claim about the keyboard that is false.
    private let armed: () -> Bool

    /// Gives the pane the keyboard. Called FIRST on every press, before any hit arithmetic, because
    /// a click that placed a caret without focusing the pane would leave the user typing into
    /// whatever had the responder before.
    private let focusPane: () -> Void

    /// Tells the pane the editor moved, so the band repaints and the host's shell is asked about any
    /// word the click's edit left unruled. The renderer's own `promptDidChange`.
    private let promptEdited: () -> Void

    /// The pane's context menu, so a right-click over the band opens the same one the grid does.
    /// Without it, taking the mouse would take the menu away with it.
    private let paneMenu: (NSEvent) -> NSMenu?

    /// The last height ``fittingHeight`` answered, so a re-layout is asked for only when it changed.
    private var lastHeight: CGFloat = 0

    /// Where the press that started the current drag landed, and at what unit it selects.
    ///
    /// `nil` between drags, and set only for a press that landed in the DOCUMENT: a press on a
    /// candidate row starts nothing, so dragging off it cannot turn a row pick into a text
    /// selection anchored at a byte the user never pointed at.
    private var drag: (anchor: Int, granularity: PromptGranularity)?

    init(
        prompt: CommandPrompt,
        armed: @escaping () -> Bool,
        composition: @escaping () -> (text: String, selection: NSRange)?,
        focusPane: @escaping () -> Void,
        promptEdited: @escaping () -> Void,
        paneMenu: @escaping (NSEvent) -> NSMenu?,
    ) {
        self.prompt = prompt
        self.armed = armed
        self.composition = composition
        self.focusPane = focusPane
        self.promptEdited = promptEdited
        self.paneMenu = paneMenu
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// AppKit's own top-down coordinates, which is the order the lines are laid out in — and the
    /// order `TerminalPromptBand` draws in, because every `UIView` has them for free.
    override var isFlipped: Bool { true }

    /// The band never takes the keyboard: the renderer view is the pane's one responder, and a second
    /// one would divide the focus region the tab owns (see the `focus-region` rule).
    override var acceptsFirstResponder: Bool { false }

    /// Re-reads the editor and re-lays out if the band's height changed.
    func refresh() {
        needsDisplay = true
        let height = fittingHeight
        guard height != lastHeight else { return }
        lastHeight = height
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        // The I-beam covers the DOCUMENT rows, and a row was just added or taken away.
        window?.invalidateCursorRects(for: self)
    }

    /// The I-beam over the document rows, and the arrow everywhere else.
    ///
    /// The band's own affordance: the accessory rows are a list to click at, not text to place a
    /// caret in, so they keep the arrow and the difference says which is which before the click.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard armed() else { return }
        let metrics = TerminalPromptBand.Metrics.current
        let rows = CGFloat(TerminalPromptBand.documentRows(prompt))
        addCursorRect(
            NSRect(
                x: 0,
                y: TerminalPromptBand.inset.height,
                width: bounds.width,
                height: rows * metrics.lineHeight,
            ),
            cursor: .iBeam,
        )
    }

    /// The pane's menu, not one of this view's own — see ``paneMenu``.
    override func menu(for event: NSEvent) -> NSMenu? { paneMenu(event) }

    // MARK: Pointer

    /// A press: focus the pane, then place the caret, select a unit, or pick a candidate row.
    ///
    /// The unit comes from `clickCount`, which is AppKit's whole contribution to the question — what
    /// a word or a line IS belongs to Rust, so a double-click here and ⌥⇧→ at the keyboard cannot
    /// come apart.
    ///
    /// ⚠️ **Refused outright while an input method is composing.** The marked run sits at the caret
    /// and is not in the document; moving the caret out from under it would strand it, and
    /// committing it from here would mean this view reaching into the renderer's input context. See
    /// ``TerminalPromptBand/hit(_:metrics:at:)``, where the rule is stated for both shells.
    override func mouseDown(with event: NSEvent) {
        guard armed(), composition() == nil else { return }
        focusPane()
        drag = nil
        let point = convert(event.locationInWindow, from: nil)
        switch TerminalPromptBand.hit(prompt, metrics: TerminalPromptBand.Metrics.current, at: point) {
        case let .text(byte):
            let granularity = PromptGranularity(clickCount: event.clickCount)
            drag = (byte, granularity)
            prompt.pointerSelect(anchor: byte, head: byte, granularity: granularity)
            promptEdited()
        case let .candidate(index):
            // Picking and ACCEPTING are one gesture here where they are two keys — a click on a row
            // is the user saying "that one", and a click that only highlighted would leave them
            // reaching for Enter with the pointer already on the answer. Which accept it is comes
            // from the flag the state record already carries: a ⌃R row goes onto the line without
            // running, a completion row is applied over the range it declared.
            guard prompt.selectCandidate(index) else { return }
            if prompt.isSearching {
                prompt.acceptSearch()
            } else {
                prompt.acceptCompletion()
            }
            promptEdited()
        case .inert:
            break
        }
    }

    /// A drag extends from the press's own anchor, at the press's own unit — so dragging after a
    /// double-click keeps selecting whole words, the way every text view does.
    override func mouseDragged(with event: NSEvent) {
        guard let drag, armed(), composition() == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let head = TerminalPromptBand.byteOffset(
            prompt, metrics: TerminalPromptBand.Metrics.current, at: point,
        )
        prompt.pointerSelect(anchor: drag.anchor, head: head, granularity: drag.granularity)
        promptEdited()
    }

    override func mouseUp(with _: NSEvent) {
        drag = nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight)
    }

    /// How tall the band wants to be for what the editor currently holds.
    ///
    /// Zero when the editor is not armed, which is what makes the band DISAPPEAR rather than sit
    /// empty under a full-screen program.
    var fittingHeight: CGFloat {
        guard armed() else { return 0 }
        return TerminalPromptBand.height(prompt, metrics: TerminalPromptBand.Metrics.current)
    }

    /// The caret's rectangle in this view's own coordinates — where an input method's candidate
    /// window hangs while the editor owns the line.
    var caretRect: NSRect? {
        guard armed() else { return nil }
        return TerminalPromptBand.caretRect(
            prompt, composition: composition(), metrics: TerminalPromptBand.Metrics.current,
        )
    }

    override func draw(_: NSRect) {
        guard armed(), let context = NSGraphicsContext.current?.cgContext else { return }
        TerminalPromptBand.draw(
            prompt,
            composition: composition(),
            metrics: TerminalPromptBand.Metrics.current,
            in: bounds,
            into: context,
        )
    }
}
#endif
