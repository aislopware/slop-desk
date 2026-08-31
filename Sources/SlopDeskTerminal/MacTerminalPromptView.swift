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

    /// The last height ``fittingHeight`` answered, so a re-layout is asked for only when it changed.
    private var lastHeight: CGFloat = 0

    init(
        prompt: CommandPrompt,
        armed: @escaping () -> Bool,
        composition: @escaping () -> (text: String, selection: NSRange)?,
    ) {
        self.prompt = prompt
        self.armed = armed
        self.composition = composition
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

    /// A click anywhere in the band goes to the pane, not here.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// Re-reads the editor and re-lays out if the band's height changed.
    func refresh() {
        needsDisplay = true
        let height = fittingHeight
        guard height != lastHeight else { return }
        lastHeight = height
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
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
