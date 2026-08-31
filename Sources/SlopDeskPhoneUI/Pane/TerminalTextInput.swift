// TerminalTextInput — the composition half of the phone's keyboard (docs/68 §5.1).
//
// `TerminalInputHostView` conformed to `UIKeyInput` alone until this landed, and that costs exactly
// one thing: an input method had no MARKED text to hand over, so its candidates lived in the
// keyboard's own bar and only the settled string ever reached the pane. Typing Vietnamese or Chinese
// worked — `Tieengs` arrives as one `Tiếng` — but the INLINE preedit, the underlined run under the
// caret that says what is not committed yet, could not be drawn because nothing reported it.
//
// This is the report, and it is deliberately NOT a text view. There is no document here to navigate,
// no attributed storage to substring and no character index a point resolves to: the grid answers all
// three and the engine owns the grid. So the questions that would need a document are answered with
// the honest empty value, and the four a composition genuinely needs are answered for real — what is
// marked, where it is, where to hang the candidate bar, and what was committed.
//
// ## The document is the composition, and nothing else
//
// Every position here is a UTF-16 offset into ``TerminalComposition/text``, which is empty whenever
// nothing is being composed. That is the whole model: an offset is meaningful only while an input
// method is holding a run, and outside one the document is a zero-length string with the caret at its
// only position. `MacTerminalRendererView` says the same thing in `NSTextInputClient`'s vocabulary —
// its `markedRange()` counts from zero "because a terminal's composition is not inside a document".
//
// ⚠️ ``selectedTextRange`` IS NEVER `nil` WHILE THIS VIEW IS FIRST RESPONDER. Several input methods
// refuse to START a composition against a nil selection, and the failure is silent: the keyboard
// works, the candidates appear, and the inline run this file exists to draw never arrives.
//
// ## Who draws it is not decided here
//
// The host REPORTS the composition and `TerminalSurfaceHosting.setComposition(_:selection:)` picks
// the surface — the prompt band while the app's editor owns the line, the grid otherwise. That fork
// lives once per platform rather than once per responder; see the seam.

#if os(iOS)
import SlopDeskWorkspaceCore
import UIKit

// MARK: - The document that is only a composition

/// What an input method is composing, and the whole of this responder's document.
///
/// A value rather than three properties on the view so the offset arithmetic — clamping, ordering,
/// substringing — is one testable thing. `UITextInput` asks for it constantly and out of order, and
/// an offset that walks off either end is answered by UIKit with a crash rather than a complaint.
struct TerminalComposition: Equatable {
    /// The uncommitted run, exactly as the input method reported it.
    var text: String

    /// The composition's own caret inside ``text``, in UTF-16 offsets — the only selection a text
    /// client here has. Deliberately NOT the terminal's text selection: that one is a reading of the
    /// SCREEN, it lives in grid coordinates, and handing it over as a document range would invite an
    /// input method to replace it.
    var selection: NSRange

    /// The document's length, in the units every position here counts in.
    var length: Int { text.utf16.count }

    /// `raw` brought inside the document. UIKit asks for positions it derived itself — a word
    /// boundary past the end, an offset from a position that has since been withdrawn — and expects
    /// an answer rather than a trap.
    func offset(clamping raw: Int) -> Int {
        max(0, min(raw, length))
    }

    /// The text between two offsets, in either order, both clamped.
    func substring(from: Int, to: Int) -> String {
        let lower = offset(clamping: min(from, to))
        let upper = offset(clamping: max(from, to))
        guard lower < upper else { return "" }
        return String(text[
            String.Index(utf16Offset: lower, in: text)..<String.Index(utf16Offset: upper, in: text),
        ])
    }

    /// ``selection`` inside the document, which is what may be handed back as a range.
    ///
    /// An input method reporting a caret past its own run is not a violation worth dropping the
    /// composition over — it happens whenever a candidate shortens the text and the caret report
    /// lags it by one call — so it is answered at the end instead.
    var caret: NSRange {
        let location = offset(clamping: selection.location)
        let end = offset(clamping: location + max(0, selection.length))
        return NSRange(location: location, length: end - location)
    }
}

/// One UTF-16 offset into the composition. A class because `UITextPosition` is one.
final class TerminalTextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
        super.init()
    }
}

/// A span of the composition, normalised so `from <= to` however it was built.
final class TerminalTextRange: UITextRange {
    let from: Int
    let to: Int

    init(from: Int, to: Int) {
        self.from = min(from, to)
        self.to = max(from, to)
        super.init()
    }

    override var start: UITextPosition { TerminalTextPosition(from) }
    override var end: UITextPosition { TerminalTextPosition(to) }
    override var isEmpty: Bool { from == to }
}

// MARK: - The conformance

extension TerminalInputHostView: UITextInput {
    /// The view whose coordinates ``caretRect(for:)`` and ``firstRect(for:)`` are in.
    ///
    /// This one, and the rects are CONVERTED into it rather than the property moving between the band
    /// and the grid: UIKit reads it while placing a candidate bar and while running a floating-cursor
    /// drag, and a text input view that changes identity mid-gesture is a class of bug with no
    /// symptom on this side at all.
    var textInputView: UIView { self }

    // MARK: What is marked

    /// The composition's full span, or `nil` when nothing is marked.
    var markedTextRange: UITextRange? {
        guard let composition else { return nil }
        return TerminalTextRange(from: 0, to: composition.length)
    }

    /// The input method started or revised a composition.
    ///
    /// A MODE refuses it outright: while copy mode or hint mode is armed the pane ANSWERS keys rather
    /// than forwarding them, so there is no line for a preedit to be over and an underlined run drawn
    /// there would be pointing at a buffer the keystrokes are not reaching.
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let text = markedText ?? ""
        guard !text.isEmpty, terminalModel?.takesModalKeys != true else {
            withdrawComposition()
            return
        }
        composition = TerminalComposition(text: text, selection: selectedRange)
        surface?.setComposition(text, selection: selectedRange)
    }

    /// UIKit dropped the composition — a settled candidate, a cancelled syllable, a tap elsewhere.
    ///
    /// No delegate call: UIKit is the one asking, and telling it about a change it just made is how a
    /// text input re-enters its own keyboard.
    func unmarkText() {
        guard composition != nil else { return }
        composition = nil
        surface?.setComposition("", selection: NSRange(location: 0, length: 0))
    }

    /// Drops the composition on BOTH sides when this side is the one dropping it.
    ///
    /// The delegate pair is what ``unmarkText()`` deliberately omits: an input method holding a run
    /// this view withdrew — at a resignation, a commit, a mode arming — keeps its candidates and its
    /// own idea of the caret until it is told the text changed underneath it.
    func withdrawComposition() {
        guard composition != nil else { return }
        inputDelegate?.textWillChange(self)
        composition = nil
        surface?.setComposition("", selection: NSRange(location: 0, length: 0))
        inputDelegate?.textDidChange(self)
    }

    // MARK: The document

    func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalTextRange, let composition else { return nil }
        return composition.substring(from: range.from, to: range.to)
    }

    /// Predictive input and the accessibility inserters reach for this even with every correction
    /// off, so it goes through the ONE commit path rather than editing the composition in place —
    /// which is what a document would do and this is not one.
    func replace(_: UITextRange, withText text: String) {
        insertText(text)
    }

    /// The caret, and never `nil` while this view holds the keyboard — see this file's header.
    var selectedTextRange: UITextRange? {
        get {
            let caret = composition?.caret ?? NSRange(location: 0, length: 0)
            return TerminalTextRange(from: caret.location, to: caret.location + caret.length)
        }
        set {
            guard var held = composition, let range = newValue as? TerminalTextRange else { return }
            held.selection = NSRange(location: range.from, length: range.to - range.from)
            composition = held
        }
    }

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }

    var endOfDocument: UITextPosition { TerminalTextPosition(composition?.length ?? 0) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition
        else { return nil }
        return TerminalTextRange(from: from.offset, to: to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        let held = composition ?? TerminalComposition(text: "", selection: NSRange(location: 0, length: 0))
        let moved = position.offset + offset
        // `nil` for a walk off either end rather than a clamp: UIKit reads it as "there is nothing
        // that way", which is true, and a clamped answer would read as a position that exists.
        guard moved >= 0, moved <= held.length else { return nil }
        return TerminalTextPosition(moved)
    }

    /// A one-dimensional document: left and up are back, right and down are forward.
    func position(
        from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int,
    ) -> UITextPosition? {
        switch direction {
        case .left,
             .up: self.position(from: position, offset: -offset)
        case .right,
             .down: self.position(from: position, offset: offset)
        @unknown default: nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? TerminalTextPosition,
              let other = other as? TerminalTextPosition
        else { return .orderedSame }
        if position.offset < other.offset { return .orderedAscending }
        return position.offset > other.offset ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition
        else { return 0 }
        return to.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? TerminalTextRange else { return nil }
        switch direction {
        case .left,
             .up: return TerminalTextPosition(range.from)
        case .right,
             .down: return TerminalTextPosition(range.to)
        @unknown default: return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TerminalTextPosition,
              let moved = self.position(from: position, in: direction, offset: 1) as? TerminalTextPosition
        else { return nil }
        return TerminalTextRange(from: position.offset, to: moved.offset)
    }

    /// Left to right, and not a guess: the terminal's own grid is laid out that way whatever the
    /// composition holds, so a right-to-left answer here would describe a layout nothing draws.
    func baseWritingDirection(for _: UITextPosition, in _: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    /// Nothing to set it on. The direction is the grid's, and the grid is the engine's.
    func setBaseWritingDirection(_: NSWritingDirection, for _: UITextRange) {}

    // MARK: Where it is on screen

    /// The caret's rectangle, converted out of whichever view owns it — the band while the editor
    /// holds the line, the grid otherwise. `.zero` for a cursor that is not on screen; UIKit places
    /// the candidate bar itself.
    func caretRect(for _: UITextPosition) -> CGRect {
        guard let anchor = surface?.caretAnchor else { return .zero }
        return convert(anchor.rect, from: anchor.view)
    }

    /// Where the candidate bar hangs, which for a run this short is the caret.
    func firstRect(for _: UITextRange) -> CGRect {
        caretRect(for: TerminalTextPosition(0))
    }

    /// None. Selection rects drive the grab handles and the loupe, and the terminal's selection is a
    /// reading of the SCREEN with its own long-press gesture — offering a second set of handles over
    /// the same pixels is two selections the user has to keep apart.
    func selectionRects(for _: UITextRange) -> [UITextSelectionRect] { [] }

    /// No document means no index a point resolves to. A point over this pane is over a CELL, which
    /// the pointer doors already answer, and `TerminalLinkHitTest` is where that mapping lives.
    func closestPosition(to _: CGPoint) -> UITextPosition? { nil }

    func closestPosition(to _: CGPoint, within _: UITextRange) -> UITextPosition? { nil }

    func characterRange(at _: CGPoint) -> UITextRange? { nil }
}
#endif
