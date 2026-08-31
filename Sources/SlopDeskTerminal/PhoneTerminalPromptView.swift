// PhoneTerminalPromptView — the command prompt's band, as a `UIView`.
//
// The Mac's twin, and deliberately its mirror image line for line: `TerminalPromptBand` decides
// everything the band looks like, and this file is the handful of UIKit facts that cannot be shared.
// It is shorter than `MacTerminalPromptView` by exactly two overrides — a `UIView` is already
// top-down, so there is no flip to declare, and `isUserInteractionEnabled = false` says in one
// property what `hitTest(_:)` and `acceptsFirstResponder` say in two over there.
//
// The pane's one responder is `TerminalInputHostView`, which routes into the editor before the
// encoder (see its `editsPrompt(_:)`). This view takes no touches and no keys.

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import SlopDeskWorkspaceCore
import UIKit

/// The bottom band of a terminal pane: the editor's line, and whatever is under it.
@MainActor
final class PhoneTerminalPromptView: UIView {
    /// The pane's editor. Read on every draw; never written here.
    private let prompt: CommandPrompt

    /// What the input method is composing over the line, asked of the responder that owns the
    /// composition. A closure rather than a stored pair so this view can never hold a preedit
    /// `UITextInput` has already withdrawn.
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
        // The band is pixels and nothing else: every touch inside it belongs to the pane, exactly as
        // the Mac's `hitTest(_:)` decides.
        isUserInteractionEnabled = false
        // ⚠️ NOT OPAQUE AND REDRAWN ON RESIZE. A `UIView` keeps its old bitmap through a bounds change
        // by default, which on a rotate or a split leaves the hairline and the caret stretched — the
        // one visual difference between the platforms if it is left out, because AppKit redraws.
        contentMode = .redraw
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Re-reads the editor and re-lays out if the band's height changed.
    func refresh() {
        setNeedsDisplay()
        let height = fittingHeight
        guard height != lastHeight else { return }
        lastHeight = height
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fittingHeight)
    }

    /// How tall the band wants to be for what the editor currently holds.
    ///
    /// Zero when the editor is not armed, which is what makes the band DISAPPEAR rather than sit
    /// empty under a full-screen program.
    var fittingHeight: CGFloat {
        guard armed() else { return 0 }
        return TerminalPromptBand.height(prompt, metrics: TerminalPromptBand.Metrics.current)
    }

    /// The caret's rectangle in this view's own coordinates — where the input method's candidate bar
    /// points while the editor owns the line.
    var caretRect: CGRect? {
        guard armed() else { return nil }
        return TerminalPromptBand.caretRect(prompt, metrics: TerminalPromptBand.Metrics.current)
    }

    override func draw(_: CGRect) {
        guard armed(), let context = UIGraphicsGetCurrentContext() else { return }
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
