// MacTerminalPromptView — what the command prompt LOOKS like on macOS.
//
// The near side of `docs/68` §5.4. `CommandPrompt` holds the text, the caret, the selection, the
// colours-by-role and the candidates; this file turns those into pixels and does not decide any of
// them. There is no key handling here at all: `MacTerminalRendererView` stays the first responder
// for the pane and routes into the editor (see its `editsPrompt(_:)`), so the focus region, the
// secure-input balance and the whole `ownsKeyboard` gate are untouched by this view existing.
//
// ## Why it draws itself instead of being an NSTextView
//
// An `NSTextView` is a second line editor. It would carry its own storage, its own undo manager and
// its own caret, and the moment both existed one of them would be the truth — that is the
// one-implementation rule failing in the most expensive place, because the two only disagree under
// a composition or a paste, which is where a terminal is judged. So the text here is DRAWN from the
// editor's bytes on every frame and stored nowhere.
//
// ## The island
//
// Inside the terminal island the palette is `Slate.Native.Terminal.*` and nothing else: no card, no
// shadow, no second material (`one-island`'s law 2 — separation inside the island is a LINE). The
// prompt is the bottom band of the same sheet the grid is on, marked off by one hairline, and the
// TEXT colours are the terminal's own ANSI ladder rather than a second palette invented here, so a
// `--flag` at the prompt is the colour a `--flag` in the scrollback already is.
//
// ⚠️ THE WHOLE FILE IS FENCED, exactly as `MacTerminalRendererView` is. `SlopDeskTerminal` builds for
// the phone too, and an unguarded `import AppKit` there is not a warning — it fails the iOS target
// outright with "unable to resolve module dependency", which is a build nobody runs on this machine
// until `just check-ios`. The band's iOS twin is a separate view, not this one under a shim.

#if canImport(AppKit)
import AppKit
import CoreText
import SlopDeskSlate
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

    /// At most this many candidates are drawn. A completion list that fills the pane has stopped
    /// being a hint about the next word and started being a file browser.
    private static let candidateLimit = 6

    /// The band's own padding, matched to the grid's own inset so the prompt's first glyph sits in
    /// the same column as a cell's.
    private static let inset = CGSize(width: 8, height: 6)

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

    /// AppKit's own top-down coordinates, which is the order the lines are laid out in.
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
        let metrics = Metrics.current
        let rows = documentRows(metrics: metrics) + accessoryRows()
        return CGFloat(rows) * metrics.lineHeight + Self.inset.height * 2
    }

    // MARK: - Drawing

    override func draw(_: NSRect) {
        guard armed() else { return }
        let metrics = Metrics.current
        Slate.Native.Terminal.face.setFill()
        bounds.fill()
        Slate.Native.Terminal.edge.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        var y = Self.inset.height
        y = drawDocument(metrics: metrics, at: y)
        drawAccessory(metrics: metrics, at: y)
    }

    /// The editor's own line(s), with the selection under them and the caret over them.
    private func drawDocument(metrics: Metrics, at top: CGFloat) -> CGFloat {
        let text = prompt.text
        let lines = Self.wrap(text)
        var y = top
        for (index, line) in lines.enumerated() {
            let ctLine = ctLine(for: line, in: text, metrics: metrics, isFirst: index == 0)
            let origin = CGPoint(x: Self.inset.width, y: y + metrics.ascent)
            drawSelection(ctLine, line: line, origin: origin, metrics: metrics)
            draw(ctLine, at: origin)
            y += metrics.lineHeight
        }
        // The caret LAST and once, over whichever line owns it — ``caretOrigin(metrics:)`` finds that
        // line by the same walk, so the caret and the IME's candidate window cannot land on two
        // different rows.
        if let caret = caretOrigin(metrics: metrics, from: top) {
            drawCaret(at: caret, metrics: metrics)
        }
        return y
    }

    /// What goes UNDER the line: a running ⌃R, the candidate list, or the reason Enter did not run.
    ///
    /// One of the three at most, and in that order. They are alternatives rather than a stack because
    /// each answers the same question — what is the prompt waiting for — and two answers at once is
    /// the shape a status bar takes when nobody decided.
    private func drawAccessory(metrics: Metrics, at top: CGFloat) {
        if prompt.isSearching {
            // ⚠️ THE HIT, not just the query. Pixel verification caught this: the row printed
            // `(reverse-i-search)`clip'` and stopped, so a search UI showed a query and never a
            // result. The buffer stays untouched while ⌃R runs — that is the point, cancelling must
            // leave the draft alone — which makes this row the only place the match can appear, and
            // it is the shape bash and zsh both print.
            drawRow(
                Self.searchRow(query: prompt.searchQuery, hit: prompt.searchHit),
                ink: prompt.searchHasHit ? Slate.Native.Terminal.ink2 : Slate.Native.Terminal.err,
                metrics: metrics,
                at: top,
            )
            return
        }
        let candidates = prompt.candidates.prefix(Self.candidateLimit)
        guard candidates.isEmpty else {
            for (index, candidate) in candidates.enumerated() {
                let selected = index == prompt.selectedCandidate
                drawRow(
                    candidate.detail.map { "\(candidate.text)    \($0)" } ?? candidate.text,
                    ink: selected ? Slate.Native.Terminal.accent : Slate.Native.Terminal.ink2,
                    metrics: metrics,
                    at: top + CGFloat(index) * metrics.lineHeight,
                )
            }
            return
        }
        guard let open = Self.openLabel(prompt.unterminated) else { return }
        drawRow(open, ink: Slate.Native.Terminal.ink2, metrics: metrics, at: top)
    }

    /// The `(reverse-i-search)` row's whole text.
    ///
    /// ⚠️ THE HIT IS PART OF IT, and it was not until pixel verification looked at the band: the row
    /// printed the query alone, which is a search that never shows a result. The buffer is left
    /// untouched while ⌃R runs — cancelling has to give the draft back exactly — so this row is the
    /// only place the match can appear, and `` `query': hit`` is the shape bash and zsh both print.
    ///
    /// A pure function so the finding is pinned by a test rather than by another render.
    static func searchRow(query: String, hit: String?) -> String {
        "(reverse-i-search)`\(query)'" + (hit.map { ": \($0)" } ?? "  (no match)")
    }

    /// One plain line of accessory text.
    private func drawRow(_ text: String, ink: NSColor, metrics: Metrics, at top: CGFloat) {
        let attributed = NSAttributedString(
            string: text, attributes: [.font: metrics.font, .foregroundColor: ink],
        )
        draw(
            CTLineCreateWithAttributedString(attributed),
            at: CGPoint(x: Self.inset.width, y: top + metrics.ascent),
        )
    }

    /// Draws a `CTLine` with the flip already undone, so the glyphs are not upside down.
    private func draw(_ line: CTLine, at origin: CGPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The selection fill for whatever part of it falls on this line.
    private func drawSelection(_ line: CTLine, line range: Range<Int>, origin: CGPoint, metrics: Metrics) {
        guard let selection = prompt.selection,
              let visible = Self.intersect(selection, range)
        else {
            return
        }
        let body = Self.slice(prompt.text, range) ?? ""
        let start = Self.offset(line, at: visible.lowerBound - range.lowerBound, in: body)
        let end = Self.offset(line, at: visible.upperBound - range.lowerBound, in: body)
        Slate.Native.Terminal.accent.withAlphaComponent(0.30).setFill()
        NSRect(
            x: origin.x + start,
            y: origin.y - metrics.ascent,
            width: max(end - start, 1),
            height: metrics.lineHeight,
        ).fill()
    }

    /// The caret, and the composition run when one is in flight. `origin` is the text baseline.
    private func drawCaret(at origin: CGPoint, metrics: Metrics) {
        if let marked = composition() {
            drawComposition(marked, metrics: metrics, at: origin)
            return
        }
        Slate.Native.Terminal.accent.setFill()
        NSRect(x: origin.x, y: origin.y - metrics.ascent, width: 2, height: metrics.lineHeight).fill()
    }

    /// The caret's baseline point in this view's own coordinates, or `nil` when the band is not up.
    ///
    /// ⚠️ THE OWNERSHIP TEST IS `lowerBound ... upperBound`, INCLUSIVE AT BOTH ENDS, and the closed
    /// upper end is the whole of it: a caret sitting immediately before a `\n` is at the upper bound
    /// of its line and inside no line's half-open range, so a `contains` test draws it nowhere. The
    /// two ends can never both claim it — a line is `start..<offset` and the next starts at
    /// `offset + 1`, so consecutive bounds are never equal — and the first line to claim it wins.
    private func caretOrigin(metrics: Metrics, from top: CGFloat) -> CGPoint? {
        let text = prompt.text
        let caret = prompt.cursor
        var y = top
        for (index, line) in Self.wrap(text).enumerated() {
            guard caret >= line.lowerBound, caret <= line.upperBound else {
                y += metrics.lineHeight
                continue
            }
            let ct = ctLine(for: line, in: text, metrics: metrics, isFirst: index == 0)
            let body = Self.slice(text, line) ?? ""
            let x = Self.inset.width + Self.offset(ct, at: caret - line.lowerBound, in: body)
            return CGPoint(x: x, y: y + metrics.ascent)
        }
        return nil
    }

    /// The caret's rectangle in this view's own coordinates — where an input method's candidate
    /// window hangs while the editor owns the line.
    ///
    /// The renderer view answers `firstRect(forCharacterRange:)` with the GRID's caret cell, which is
    /// the right answer only while the shell owns the line. With the band up the caret is here, and a
    /// candidate list hanging off a cell the user is not typing into is the most visible way a Telex
    /// session can look broken.
    var caretRect: NSRect? {
        guard armed() else { return nil }
        let metrics = Metrics.current
        guard let origin = caretOrigin(metrics: metrics, from: Self.inset.height) else { return nil }
        return NSRect(
            x: origin.x, y: origin.y - metrics.ascent, width: 2, height: metrics.lineHeight,
        )
    }

    /// The input method's preedit, underlined at the caret — NOT in the editor's buffer.
    private func drawComposition(
        _ marked: (text: String, selection: NSRange),
        metrics: Metrics,
        at origin: CGPoint,
    ) {
        let attributed = NSAttributedString(string: marked.text, attributes: [
            .font: metrics.font,
            .foregroundColor: Slate.Native.Terminal.ink,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        draw(line, at: origin)
        // ⚠️ NO MARK ON THIS LINE, so `offset(_:at:in:)` — which adds one — is the wrong helper. The
        // preedit is drawn on its own, starting at the caret, and AppKit already reports its
        // selection in UTF-16, which is the unit Core Text wants: no conversion either.
        let caret = CTLineGetOffsetForStringIndex(
            line, CFIndex(min(marked.selection.location, marked.text.utf16.count)), nil,
        )
        Slate.Native.Terminal.accent.setFill()
        NSRect(x: origin.x + caret, y: origin.y - metrics.ascent, width: 2, height: metrics.lineHeight).fill()
    }

    // MARK: - Text

    /// The `CTLine` for one logical line, coloured by the editor's own spans.
    ///
    /// The first line carries the prompt MARK — one glyph saying whether Enter would run what is
    /// there. Green when the document is closed, dim when something is still open: the same fact the
    /// accessory row spells out, in the place the eye is already looking.
    private func ctLine(for range: Range<Int>, in text: String, metrics: Metrics, isFirst: Bool) -> CTLine {
        let attributed = NSMutableAttributedString()
        if isFirst {
            attributed.append(NSAttributedString(string: "❯ ", attributes: [
                .font: metrics.font,
                .foregroundColor: prompt.wouldRun ? Slate.Native.Terminal.ok : Slate.Native.Terminal.ink2,
            ]))
        } else {
            attributed.append(NSAttributedString(
                string: "  ", attributes: [.font: metrics.font, .foregroundColor: Slate.Native.Terminal.ink2],
            ))
        }
        for (run, kind) in Self.runs(prompt.spans, over: range, in: text) {
            attributed.append(NSAttributedString(string: run, attributes: [
                .font: metrics.font,
                .foregroundColor: Self.ink(kind),
            ]))
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    /// The document's logical lines, as byte ranges into the text.
    ///
    /// Logical only: the band grows downward instead of soft-wrapping, because a command line that
    /// wrapped would move every following row on each keystroke — and the editor already knows what a
    /// line is, so inventing a second answer here would be the one that drifts.
    private static func wrap(_ text: String) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        for (offset, byte) in text.utf8.enumerated() where byte == 0x0A {
            lines.append(start..<offset)
            start = offset + 1
        }
        lines.append(start..<text.utf8.count)
        return lines
    }

    /// How many rows the document occupies.
    private func documentRows(metrics _: Metrics) -> Int { Self.wrap(prompt.text).count }

    /// How many rows the accessory occupies.
    private func accessoryRows() -> Int {
        if prompt.isSearching { return 1 }
        if !prompt.candidates.isEmpty { return min(prompt.candidates.count, Self.candidateLimit) }
        return Self.openLabel(prompt.unterminated) == nil ? 0 : 1
    }

    /// The spans falling inside one line, as `(text, kind)` pairs covering it end to end.
    ///
    /// Every byte is emitted exactly once: a byte no span claims is ``PromptToken/argument``, the
    /// neutral colour, so an unlexed tail (a paste mid-word) paints plainly rather than vanishing.
    static func runs(
        _ spans: [PromptSpan],
        over line: Range<Int>,
        in text: String,
    ) -> [(String, PromptToken)] {
        var out: [(String, PromptToken)] = []
        var cursor = line.lowerBound
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard let visible = intersect(span.start..<span.end, line), visible.lowerBound >= cursor else { continue }
            if visible.lowerBound > cursor, let gap = slice(text, cursor..<visible.lowerBound) {
                out.append((gap, .argument))
            }
            if let body = slice(text, visible) { out.append((body, span.kind)) }
            cursor = visible.upperBound
        }
        if cursor < line.upperBound, let tail = slice(text, cursor..<line.upperBound) {
            out.append((tail, .argument))
        }
        return out
    }

    /// The overlap of two byte ranges, or `nil` when they do not meet.
    private static func intersect(_ a: Range<Int>, _ b: Range<Int>) -> Range<Int>? {
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    /// The substring one byte range names, or `nil` when it does not land on character boundaries —
    /// which a span from a newer build could, and which must not crash a draw.
    private static func slice(_ text: String, _ range: Range<Int>) -> String? {
        let utf8 = text.utf8
        guard range.lowerBound >= 0, range.upperBound <= utf8.count else { return nil }
        let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let end = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        return String(utf8[start..<end])
    }

    /// The UTF-16 offset one UTF-8 offset names — the other direction, and the one every position the
    /// editor reports has to go through.
    ///
    /// ⚠️ THE EDITOR COUNTS BYTES AND CORE TEXT COUNTS UTF-16 UNITS, and they agree only on ASCII. A
    /// `ế` is three bytes and one unit, so a caret handed straight to
    /// `CTLineGetOffsetForStringIndex` drifts two units right per Vietnamese letter before it —
    /// which, Telex being the composition this whole path exists for (`docs/68` §5.1), is what a
    /// first day of use looks like.
    static func utf16Offset(_ text: String, utf8 byte: Int) -> Int {
        let bytes = text.utf8
        guard byte > 0 else { return 0 }
        guard byte < bytes.count else { return text.utf16.count }
        return bytes.index(bytes.startIndex, offsetBy: byte).utf16Offset(in: text)
    }

    /// The x offset of one byte position inside a drawn DOCUMENT line, prompt mark included.
    ///
    /// `lineText` is that line's own text without the mark, which is what the byte offset is relative
    /// to; the mark's two units are added after the conversion, never before.
    private static func offset(_ line: CTLine, at byte: Int, in lineText: String) -> CGFloat {
        CTLineGetOffsetForStringIndex(line, CFIndex(markWidth + utf16Offset(lineText, utf8: byte)), nil)
    }

    /// How many UTF-16 units the leading `❯ ` / `  ` mark spends. Every document line carries one, so
    /// every offset into a drawn line is shifted by it.
    private static let markWidth = 2

    /// The ink for one role, taken from the terminal's OWN ANSI ladder so a word at the prompt is the
    /// colour that word already is in the scrollback.
    ///
    /// Falls back to the glass ink when the ladder is empty — the config file states two colours and
    /// no more, which is the reading `ResolvedTerminalTheme(preferences:)` produces.
    static func ink(_ kind: PromptToken) -> NSColor {
        let slot: Int
        switch kind {
        case .commandName: slot = 10 // bright green
        case .flag: slot = 11 // bright yellow
        case .path: slot = 14 // bright cyan
        case .quoted: slot = 3 // yellow
        case .variable: slot = 12 // bright blue
        case .operator,
             .redirection: slot = 13 // bright magenta
        case .comment: return Slate.Native.Terminal.ink2
        case .argument: return Slate.Native.Terminal.ink
        }
        guard let palette = TerminalConfigBroadcaster.shared.themeWords?.palette, slot < palette.count else {
            return Slate.Native.Terminal.ink
        }
        return NSColor(slateHex: palette[slot])
    }

    /// What is holding the document open, phrased as the thing to close.
    ///
    /// `nil` for a closed document, which is the common case and draws no row at all.
    static func openLabel(_ open: PromptOpen) -> String? {
        switch open {
        case .nothing: nil
        case .singleQuote: "unclosed '"
        case .doubleQuote: "unclosed \""
        case .backslash: "line continues"
        case .substitution: "unclosed $("
        case .backtick: "unclosed `"
        case .variable: "unclosed ${"
        case .group: "unclosed ("
        }
    }

    /// The font and the three numbers every layout here is in terms of.
    struct Metrics {
        let font: NSFont
        let ascent: CGFloat
        let lineHeight: CGFloat

        /// The terminal's own face at its own size — the band and the grid must not be two typefaces.
        ///
        /// `@MainActor` because the broadcaster it reads is: the font is one process-wide setting and
        /// the only readers are draws, which are already on the main thread.
        @MainActor
        static var current: Self {
            let size = TerminalConfigBroadcaster.shared.fontSize
            let points = size > 0 ? size : NSFont.systemFontSize
            let font = NSFont(name: TerminalConfigBroadcaster.shared.fontFamily, size: points)
                ?? NSFont.monospacedSystemFont(ofSize: points, weight: .regular)
            return Self(font: font, ascent: font.ascender, lineHeight: font.ascender - font.descender + font.leading)
        }
    }
}
#endif
