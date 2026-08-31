// TerminalPromptBand — what the command prompt LOOKS like, and the ONE implementation of it.
//
// The near side of `docs/68` §5.4. `CommandPrompt` holds the text, the caret, the selection, the
// colours-by-role and the candidates; this file turns those into pixels and decides none of them.
//
// ## Why it is a namespace and not a view
//
// The band exists twice — `MacTerminalPromptView` is an `NSView`, `PhoneTerminalPromptView` a
// `UIView` — and that is the only thing about it that has to. Everything else is arithmetic over the
// editor's bytes and glyphs drawn through Core Text, which ships identically on both platforms, so
// the two views are shells: a `draw(_:)` that hands its `CGContext` down here, a fitting height, and
// the framework's own invalidation. A second copy of the wrapping, the UTF-8→UTF-16 conversion or
// the accessory row's precedence would be two answers to one question — the one-implementation rule
// failing in the place it is most expensive, because the two only disagree under a composition,
// which is exactly where a terminal is judged.
//
// ⚠️ NO `AppKit` AND NO `UIKit` IN THIS FILE. `SlateNativeColor` is the design system's own platform
// pair and `CTFont` is Core Text's, so the whole band draws with neither framework named. An import
// added here does not warn — it fails whichever target does not have it, which on the phone is a
// build nobody runs on this machine until `just check-ios`.
//
// ## Why it draws itself instead of being a text view
//
// An `NSTextView`/`UITextView` is a second line editor. It would carry its own storage, its own undo
// manager and its own caret, and the moment both existed one of them would be the truth. So the text
// here is DRAWN from the editor's bytes on every frame and stored nowhere.
//
// ## The island
//
// Inside the terminal island the palette is `Slate.Native.Terminal.*` and nothing else: no card, no
// shadow, no second material (`one-island`'s law 2 — separation inside the island is a LINE). The
// prompt is the bottom band of the same sheet the grid is on, marked off by one hairline, and the
// TEXT colours are the terminal's own ANSI ladder rather than a second palette invented here, so a
// `--flag` at the prompt is the colour a `--flag` in the scrollback already is.

import CoreGraphics
import CoreText
import Foundation
import SlopDeskSlate
import SlopDeskWorkspaceCore

/// Every decision the prompt band makes about where things go and what they look like.
@MainActor
enum TerminalPromptBand {
    /// At most this many candidates are drawn. A completion list that fills the pane has stopped
    /// being a hint about the next word and started being a file browser.
    static let candidateLimit = 6

    /// The band's own padding, matched to the grid's own inset so the prompt's first glyph sits in
    /// the same column as a cell's.
    static let inset = CGSize(width: 8, height: 6)

    /// How many UTF-16 units the leading `❯ ` / `  ` mark spends. Every document line carries one, so
    /// every offset into a drawn line is shifted by it.
    static let markWidth = 2

    /// The font and the two numbers every layout here is in terms of.
    ///
    /// `CTFont` rather than an `NSFont`/`UIFont` pair, and that is what makes the band one
    /// implementation: Core Text takes a `CTFont` on either platform and both frameworks' font types
    /// are toll-free bridged to it, so nothing downstream has to know which OS asked.
    struct Metrics {
        /// The terminal's own face at its own size.
        let font: CTFont
        /// The baseline's distance from the row's top.
        let ascent: CGFloat
        /// One row, ascent + descent + leading.
        let lineHeight: CGFloat

        /// The terminal's own face at its own size — the band and the grid must not be two typefaces.
        ///
        /// `@MainActor` because the broadcaster it reads is: the font is one process-wide setting and
        /// the only readers are draws, which are already on the main thread.
        ///
        /// The fallback is Core Text's own fixed-pitch UI font rather than either framework's
        /// `monospacedSystemFont`, which is the same face by a different door and keeps this file
        /// free of both.
        @MainActor
        static var current: Self {
            let size = TerminalConfigBroadcaster.shared.fontSize
            let points = size > 0 ? size : 12
            let family = TerminalConfigBroadcaster.shared.fontFamily
            let font = CTFontCreateWithNameAndOptions(
                family as CFString, points, nil, .preventAutoActivation,
            )
            // A name Core Text does not know answers the system face rather than nil, so the family
            // is checked rather than the pointer: a prompt in the UI font beside a grid in the
            // terminal's own is the one way this can look wrong and still run.
            let resolved = (CTFontCopyFamilyName(font) as String) == family
                ? font
                : CTFontCreateUIFontForLanguage(.userFixedPitch, points, nil) ?? font
            let ascent = CTFontGetAscent(resolved)
            // `terminal.line-height` stretches the band's rows exactly as it stretches the grid's,
            // because the band draws the shell's own prompt line and the two sit against each other:
            // a grid at 1.3 beside a band at 1.0 reads as the prompt having its own, tighter
            // typography. The GAIN goes below the baseline rather than around it — the band's rows
            // are stacked from the top and its ascent is what places the first one, so centring here
            // would push the first row's text off its own inset.
            let natural = ascent + CTFontGetDescent(resolved) + CTFontGetLeading(resolved)
            return Self(
                font: resolved,
                ascent: ascent,
                lineHeight: natural * CGFloat(TerminalConfigBroadcaster.shared.lineHeight),
            )
        }
    }

    // MARK: - Layout

    /// How many rows the document occupies.
    static func documentRows(_ prompt: CommandPrompt) -> Int { wrap(prompt.text).count }

    /// How many rows the accessory under it occupies.
    static func accessoryRows(_ prompt: CommandPrompt) -> Int {
        if prompt.isSearching { return 1 }
        if !prompt.candidates.isEmpty { return min(prompt.candidates.count, candidateLimit) }
        return openLabel(prompt.unterminated) == nil ? 0 : 1
    }

    /// How tall the band wants to be for what the editor currently holds.
    static func height(_ prompt: CommandPrompt, metrics: Metrics) -> CGFloat {
        let rows = documentRows(prompt) + accessoryRows(prompt)
        return CGFloat(rows) * metrics.lineHeight + inset.height * 2
    }

    /// The caret's baseline point in the band's own coordinates, or `nil` when no line claims it.
    ///
    /// ⚠️ THE OWNERSHIP TEST IS `lowerBound ... upperBound`, INCLUSIVE AT BOTH ENDS, and the closed
    /// upper end is the whole of it: a caret sitting immediately before a `\n` is at the upper bound
    /// of its line and inside no line's half-open range, so a `contains` test draws it nowhere. The
    /// two ends can never both claim it — a line is `start..<offset` and the next starts at
    /// `offset + 1`, so consecutive bounds are never equal — and the first line to claim it wins.
    static func caretOrigin(_ prompt: CommandPrompt, metrics: Metrics, from top: CGFloat) -> CGPoint? {
        let text = prompt.text
        let caret = prompt.cursor
        var y = top
        for (index, line) in wrap(text).enumerated() {
            guard caret >= line.lowerBound, caret <= line.upperBound else {
                y += metrics.lineHeight
                continue
            }
            let ct = ctLine(prompt, for: line, in: text, metrics: metrics, isFirst: index == 0)
            let body = slice(text, line) ?? ""
            let x = inset.width + offset(ct, at: caret - line.lowerBound, in: body)
            return CGPoint(x: x, y: y + metrics.ascent)
        }
        return nil
    }

    /// The caret's rectangle in the band's own coordinates — where an input method's candidate
    /// window hangs while the editor owns the line.
    ///
    /// The renderer view answers the same question with the GRID's caret cell, which is the right
    /// answer only while the shell owns the line. With the band up the caret is here, and a candidate
    /// list hanging off a cell the user is not typing into is the most visible way a Telex session
    /// can look broken.
    static func caretRect(_ prompt: CommandPrompt, metrics: Metrics) -> CGRect? {
        guard let origin = caretOrigin(prompt, metrics: metrics, from: inset.height) else { return nil }
        return CGRect(
            x: origin.x, y: origin.y - metrics.ascent, width: 2, height: metrics.lineHeight,
        )
    }

    // MARK: - Drawing

    /// The whole band, into a context whose y grows DOWNWARD — which both `NSView.isFlipped` and
    /// every `UIView` already give.
    static func draw(
        _ prompt: CommandPrompt,
        composition: (text: String, selection: NSRange)?,
        metrics: Metrics,
        in bounds: CGRect,
        into context: CGContext,
    ) {
        context.setFillColor(Slate.Native.Terminal.face.cgColor)
        context.fill(bounds)
        context.setFillColor(Slate.Native.Terminal.edge.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))

        var y = inset.height
        y = drawDocument(prompt, composition: composition, metrics: metrics, at: y, into: context)
        drawAccessory(prompt, metrics: metrics, at: y, into: context)
    }

    /// The editor's own line(s), with the selection under them and the caret over them.
    private static func drawDocument(
        _ prompt: CommandPrompt,
        composition: (text: String, selection: NSRange)?,
        metrics: Metrics,
        at top: CGFloat,
        into context: CGContext,
    ) -> CGFloat {
        let text = prompt.text
        var y = top
        for (index, line) in wrap(text).enumerated() {
            let ct = ctLine(prompt, for: line, in: text, metrics: metrics, isFirst: index == 0)
            let origin = CGPoint(x: inset.width, y: y + metrics.ascent)
            drawSelection(prompt, ct, line: line, origin: origin, metrics: metrics, into: context)
            draw(ct, at: origin, into: context)
            y += metrics.lineHeight
        }
        // The caret LAST and once, over whichever line owns it — ``caretOrigin(_:metrics:from:)``
        // finds that line by the same walk, so the caret and the IME's candidate window cannot land
        // on two different rows.
        if let caret = caretOrigin(prompt, metrics: metrics, from: top) {
            drawCaret(composition, metrics: metrics, at: caret, into: context)
        }
        return y
    }

    /// What goes UNDER the line: a running ⌃R, the candidate list, or the reason Enter did not run.
    ///
    /// One of the three at most, and in that order. They are alternatives rather than a stack because
    /// each answers the same question — what is the prompt waiting for — and two answers at once is
    /// the shape a status bar takes when nobody decided.
    private static func drawAccessory(
        _ prompt: CommandPrompt,
        metrics: Metrics,
        at top: CGFloat,
        into context: CGContext,
    ) {
        if prompt.isSearching {
            // ⚠️ THE HIT, not just the query. Pixel verification caught this: the row printed
            // `(reverse-i-search)`clip'` and stopped, so a search UI showed a query and never a
            // result. The buffer stays untouched while ⌃R runs — that is the point, cancelling must
            // leave the draft alone — which makes this row the only place the match can appear, and
            // it is the shape bash and zsh both print.
            drawRow(
                searchRow(query: prompt.searchQuery, hit: prompt.searchHit),
                ink: prompt.searchHasHit ? Slate.Native.Terminal.ink2 : Slate.Native.Terminal.err,
                metrics: metrics,
                at: top,
                into: context,
            )
            return
        }
        let candidates = prompt.candidates.prefix(candidateLimit)
        guard candidates.isEmpty else {
            for (index, candidate) in candidates.enumerated() {
                let selected = index == prompt.selectedCandidate
                drawRow(
                    candidate.detail.map { "\(candidate.text)    \($0)" } ?? candidate.text,
                    ink: selected ? Slate.Native.Terminal.accent : Slate.Native.Terminal.ink2,
                    metrics: metrics,
                    at: top + CGFloat(index) * metrics.lineHeight,
                    into: context,
                )
            }
            return
        }
        guard let open = openLabel(prompt.unterminated) else { return }
        drawRow(open, ink: Slate.Native.Terminal.ink2, metrics: metrics, at: top, into: context)
    }

    /// One plain line of accessory text.
    private static func drawRow(
        _ text: String,
        ink: SlateNativeColor,
        metrics: Metrics,
        at top: CGFloat,
        into context: CGContext,
    ) {
        let line = CTLineCreateWithAttributedString(
            attributed(text, metrics: metrics, ink: ink),
        )
        draw(line, at: CGPoint(x: inset.width, y: top + metrics.ascent), into: context)
    }

    /// Draws a `CTLine` with the flip already undone, so the glyphs are not upside down.
    private static func draw(_ line: CTLine, at origin: CGPoint, into context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The selection fill for whatever part of it falls on this line.
    private static func drawSelection(
        _ prompt: CommandPrompt,
        _ line: CTLine,
        line range: Range<Int>,
        origin: CGPoint,
        metrics: Metrics,
        into context: CGContext,
    ) {
        guard let selection = prompt.selection, let visible = intersect(selection, range) else { return }
        let body = slice(prompt.text, range) ?? ""
        let start = offset(line, at: visible.lowerBound - range.lowerBound, in: body)
        let end = offset(line, at: visible.upperBound - range.lowerBound, in: body)
        context.setFillColor(Slate.Native.Terminal.accent.withAlphaComponent(0.30).cgColor)
        context.fill(CGRect(
            x: origin.x + start,
            y: origin.y - metrics.ascent,
            width: max(end - start, 1),
            height: metrics.lineHeight,
        ))
    }

    /// The caret, and the composition run when one is in flight. `origin` is the text baseline.
    private static func drawCaret(
        _ composition: (text: String, selection: NSRange)?,
        metrics: Metrics,
        at origin: CGPoint,
        into context: CGContext,
    ) {
        if let marked = composition {
            drawComposition(marked, metrics: metrics, at: origin, into: context)
            return
        }
        context.setFillColor(Slate.Native.Terminal.accent.cgColor)
        context.fill(CGRect(x: origin.x, y: origin.y - metrics.ascent, width: 2, height: metrics.lineHeight))
    }

    /// The input method's preedit, underlined at the caret — NOT in the editor's buffer.
    private static func drawComposition(
        _ marked: (text: String, selection: NSRange),
        metrics: Metrics,
        at origin: CGPoint,
        into context: CGContext,
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): metrics.font,
            .init(kCTForegroundColorAttributeName as String): Slate.Native.Terminal.ink.cgColor,
            .init(kCTUnderlineStyleAttributeName as String): CTUnderlineStyle.single.rawValue,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: marked.text, attributes: attributes),
        )
        draw(line, at: origin, into: context)
        // ⚠️ NO MARK ON THIS LINE, so `offset(_:at:in:)` — which adds one — is the wrong helper. The
        // preedit is drawn on its own, starting at the caret, and both input systems already report
        // the selection in UTF-16, which is the unit Core Text wants: no conversion either.
        let caret = CTLineGetOffsetForStringIndex(
            line, CFIndex(min(marked.selection.location, marked.text.utf16.count)), nil,
        )
        context.setFillColor(Slate.Native.Terminal.accent.cgColor)
        context.fill(CGRect(
            x: origin.x + caret, y: origin.y - metrics.ascent, width: 2, height: metrics.lineHeight,
        ))
    }

    // MARK: - Text

    /// One run of text in one colour, as Core Text's own attributes.
    ///
    /// `kCTFontAttributeName` and `kCTForegroundColorAttributeName` rather than `.font` and
    /// `.foregroundColor`: the AppKit spellings take an `NSFont`/`NSColor` and the UIKit ones a
    /// `UIFont`/`UIColor`, which is exactly the fork this file exists to not have.
    private static func attributed(
        _ text: String, metrics: Metrics, ink: SlateNativeColor,
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): metrics.font,
            .init(kCTForegroundColorAttributeName as String): ink.cgColor,
        ])
    }

    /// The `CTLine` for one logical line, coloured by the editor's own spans.
    ///
    /// The first line carries the prompt MARK — one glyph saying whether Enter would run what is
    /// there. Green when the document is closed, dim when something is still open: the same fact the
    /// accessory row spells out, in the place the eye is already looking.
    private static func ctLine(
        _ prompt: CommandPrompt,
        for range: Range<Int>,
        in text: String,
        metrics: Metrics,
        isFirst: Bool,
    ) -> CTLine {
        let attributed = NSMutableAttributedString()
        if isFirst {
            attributed.append(Self.attributed(
                "❯ ",
                metrics: metrics,
                ink: prompt.wouldRun ? Slate.Native.Terminal.ok : Slate.Native.Terminal.ink2,
            ))
        } else {
            attributed.append(Self.attributed("  ", metrics: metrics, ink: Slate.Native.Terminal.ink2))
        }
        for (run, kind) in runs(prompt.spans, over: range, in: text) {
            attributed.append(Self.attributed(run, metrics: metrics, ink: ink(kind)))
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    /// The document's logical lines, as byte ranges into the text.
    ///
    /// Logical only: the band grows downward instead of soft-wrapping, because a command line that
    /// wrapped would move every following row on each keystroke — and the editor already knows what a
    /// line is, so inventing a second answer here would be the one that drifts.
    static func wrap(_ text: String) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        for (offset, byte) in text.utf8.enumerated() where byte == 0x0A {
            lines.append(start..<offset)
            start = offset + 1
        }
        lines.append(start..<text.utf8.count)
        return lines
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
    static func intersect(_ a: Range<Int>, _ b: Range<Int>) -> Range<Int>? {
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    /// The substring one byte range names, or `nil` when it does not land on character boundaries —
    /// which a span from a newer build could, and which must not crash a draw.
    static func slice(_ text: String, _ range: Range<Int>) -> String? {
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
    static func offset(_ line: CTLine, at byte: Int, in lineText: String) -> CGFloat {
        CTLineGetOffsetForStringIndex(line, CFIndex(markWidth + utf16Offset(lineText, utf8: byte)), nil)
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

    /// The ink for one role, taken from the terminal's OWN ANSI ladder so a word at the prompt is the
    /// colour that word already is in the scrollback.
    ///
    /// Falls back to the glass ink when the ladder is empty — the config file states two colours and
    /// no more, which is the reading `ResolvedTerminalTheme(preferences:)` produces.
    static func ink(_ kind: PromptToken) -> SlateNativeColor {
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
        return SlateNativeColor(slateHex: palette[slot])
    }
}
