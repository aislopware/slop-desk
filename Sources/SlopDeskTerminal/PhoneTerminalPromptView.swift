// PhoneTerminalPromptView — the command prompt's band, as a `UIView`.
//
// The Mac's twin, and deliberately its mirror image line for line: `TerminalPromptBand` decides
// everything the band looks like, and this file is the handful of UIKit facts that cannot be shared.
// A `UIView` is already top-down, so there is no flip to declare.
//
// The pane's one responder is `TerminalInputHostView`, which routes into the editor before the
// encoder (see its `editsPrompt(_:)`). This view takes touches and never the keyboard — it is not a
// responder candidate at all, so the focus region the tab owns is untouched by it handling a tap.
//
// ## The tap ladder is the Mac's click ladder
//
// One tap places the caret or picks a candidate row, two select a word, three the line, and a pan
// drags a selection out from where it started — the same four gestures `MacTerminalPromptView`
// spells in `clickCount`, mapped through the same `PromptGranularity(clickCount:)` so the two shells
// cannot come apart about what a double means. Three recognisers rather than raw `touchesBegan`
// because UIKit's arbitration between them is what a hand-rolled version would reimplement badly —
// the same reason `PhoneTerminalRendererView` gives for its own three.

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

    /// Asks for the pane's focus. The REQUEST only — which view holds first responder is
    /// ``PaneFocusCoordinator``'s, driven off the store's active pane, exactly as
    /// `PhoneTerminalRendererView.handleTap` says.
    private let focusPane: () -> Void

    /// Tells the pane the editor moved, so the band repaints and the host's shell is asked about any
    /// word the edit left unruled. The renderer's own `promptDidChange`.
    private let promptEdited: () -> Void

    /// The last height ``fittingHeight`` answered, so a re-layout is asked for only when it changed.
    private var lastHeight: CGFloat = 0

    /// Where the pan that is running began, in document bytes. `nil` between pans, and set only for
    /// a pan that began in the DOCUMENT — one that began on a candidate row selects nothing.
    private var dragAnchor: Int?

    init(
        prompt: CommandPrompt,
        armed: @escaping () -> Bool,
        composition: @escaping () -> (text: String, selection: NSRange)?,
        focusPane: @escaping () -> Void,
        promptEdited: @escaping () -> Void,
    ) {
        self.prompt = prompt
        self.armed = armed
        self.composition = composition
        self.focusPane = focusPane
        self.promptEdited = promptEdited
        super.init(frame: .zero)
        // ⚠️ NOT OPAQUE AND REDRAWN ON RESIZE. A `UIView` keeps its old bitmap through a bounds change
        // by default, which on a rotate or a split leaves the hairline and the caret stretched — the
        // one visual difference between the platforms if it is left out, because AppKit redraws.
        contentMode = .redraw
        backgroundColor = .clear
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: Pointer

    /// The tap ladder and the drag — see this file's header for why they are recognisers.
    private func installGestures() {
        // Built longest-first so each can be made to yield to the one above it: a single tap that
        // fired before the double had a chance would place a caret and dismiss the word the second
        // tap was asking for.
        var longer: UITapGestureRecognizer?
        for taps in [3, 2, 1] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.numberOfTapsRequired = taps
            if let longer { tap.require(toFail: longer) }
            addGestureRecognizer(tap)
            longer = tap
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    /// A tap: focus the pane, then place the caret, select a unit, or pick a candidate row.
    ///
    /// ⚠️ **Refused outright while an input method is composing** — the marked run lives at the caret
    /// and is not in the document, so moving the caret out from under it would strand it. The rule is
    /// ``TerminalPromptBand/hit(_:metrics:at:)``'s and holds on both shells.
    @objc
    private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard armed(), composition() == nil else { return }
        focusPane()
        let point = gesture.location(in: self)
        switch TerminalPromptBand.hit(prompt, metrics: TerminalPromptBand.Metrics.current, at: point) {
        case let .text(byte):
            let granularity = PromptGranularity(clickCount: gesture.numberOfTapsRequired)
            prompt.pointerSelect(anchor: byte, head: byte, granularity: granularity)
            promptEdited()
        case let .candidate(index):
            // Picking and ACCEPTING are one gesture, as on the Mac: a tap on a row is the user
            // saying "that one", and which accept it is comes from the flag the state already
            // carries — a ⌃R row goes onto the line without running, a completion row is applied.
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

    /// A pan drags a caret-granularity selection out from wherever it began.
    ///
    /// Caret and not the tap ladder's unit: a pan carries no tap count, so there is nothing to read a
    /// word or a line from, and guessing one would make a finger drag select more than it crossed.
    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard armed(), composition() == nil else { return }
        let metrics = TerminalPromptBand.Metrics.current
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            focusPane()
            guard case let .text(byte) = TerminalPromptBand.hit(prompt, metrics: metrics, at: point) else {
                dragAnchor = nil
                return
            }
            dragAnchor = byte
            prompt.pointerSelect(anchor: byte, head: byte, granularity: .caret)
            promptEdited()
        case .changed:
            guard let dragAnchor else { return }
            let head = TerminalPromptBand.byteOffset(prompt, metrics: metrics, at: point)
            prompt.pointerSelect(anchor: dragAnchor, head: head, granularity: .caret)
            promptEdited()
        default:
            dragAnchor = nil
        }
    }

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
        return TerminalPromptBand.caretRect(
            prompt, composition: composition(), metrics: TerminalPromptBand.Metrics.current,
        )
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
