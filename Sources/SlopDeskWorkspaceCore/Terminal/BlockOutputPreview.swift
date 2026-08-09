import Foundation

// MARK: - BlockOutputPreview (a few lines of a block's output, for the ladder's hover peek)

/// The short excerpt of one command block's output the command ladder shows while the pointer dwells
/// on its tick (user-directed 2026-08-09): a handful of lines plus a count of what was left out.
///
/// The lines keep their COLOURS (user-directed 2026-08-09): the excerpt is built from the block's raw
/// captured bytes through ``AnsiStyledParser``, not from stripped text, so a test runner's greens and
/// reds, a compiler's bold error line and a prompt's nerd-font glyphs arrive in the card the way the
/// terminal drew them. Resolving a slot to an actual colour stays with the VIEW — only it knows the
/// profile's palette.
///
/// WHICH END is the other half of the design. A clean command is read from the TOP — the first lines
/// say what it set out to do. A FAILED one is read from the BOTTOM — the first lines of a failing
/// build are the same banner every build prints, and the message that matters is the last thing said.
/// So the excerpt follows the outcome, and ``fromTail`` records which end it came from so the card can
/// say so out loud (a preview whose provenance is invisible is a preview that can mislead).
///
/// PURE value type + `Sendable` — no clock, no view, no I/O.
public struct BlockOutputPreview: Equatable, Sendable {
    /// The excerpt lines in reading order (top→bottom as they appeared), each already column-cut, as
    /// runs of same-styled text.
    public let lines: [[AnsiRun]]
    /// How many output lines are NOT in ``lines``. Zero when the whole output fitted.
    public let hiddenCount: Int
    /// True when the excerpt was taken from the END of the output (a failed command) — so the card
    /// says "N lines above" rather than "+N more lines".
    public let fromTail: Bool

    public init(lines: [[AnsiRun]], hiddenCount: Int, fromTail: Bool) {
        self.lines = lines
        self.hiddenCount = hiddenCount
        self.fromTail = fromTail
    }

    /// True when there is nothing to show — the command printed nothing (or only blank lines).
    public var isEmpty: Bool { lines.isEmpty }

    /// The excerpt as bare text, one string per line — the accessibility reading of the card, and
    /// what a test asserts against when the colours are not what it is pinning.
    public var plainLines: [String] { lines.map { $0.map(\.text).joined() } }
}

/// Builds a ``BlockOutputPreview`` from a block's RAW captured VT bytes (wire type 29's payload).
/// PURE + `nonisolated` so it unit-tests headlessly.
public enum BlockOutputPreviewBuilder {
    /// How many output lines the peek card shows. Sized for a card that can hang beside a tick
    /// without covering the pane it belongs to.
    public static let maxLines = 8

    /// The column cap per line. A build log can emit a single 4 000-column line; the card is a fixed
    /// width, so an over-long line is cut here (with an ellipsis) rather than being laid out in full
    /// and clipped — the cut is then visible as what it is, and the layout is never handed a
    /// pathological string.
    public static let maxColumns = 96

    /// Tab width used to expand a `\t` before the column cut — a tab inside a fixed-width card
    /// otherwise advances by a value the card has no way to honour.
    public static let tabWidth = 4

    /// The excerpt of `rawOutput`, taken from the END when `failed` (see ``BlockOutputPreview``).
    /// Blank lines at BOTH ends are dropped first — a command's captured output almost always begins
    /// or ends with the newline that separated it from the prompt, and a preview that opens with an
    /// empty row reads as a bug.
    public nonisolated static func make(
        rawOutput: Data,
        failed: Bool,
        maxLines: Int = maxLines,
        maxColumns: Int = maxColumns,
    ) -> BlockOutputPreview {
        var lines = AnsiStyledParser.lines(from: rawOutput)
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        guard !lines.isEmpty, maxLines > 0 else {
            return BlockOutputPreview(lines: [], hiddenCount: 0, fromTail: failed)
        }
        let hidden = max(0, lines.count - maxLines)
        let shown = failed ? lines.suffix(maxLines) : lines.prefix(maxLines)
        return BlockOutputPreview(
            lines: shown.map { truncate($0, to: maxColumns) },
            hiddenCount: hidden,
            fromTail: failed,
        )
    }

    /// Whether a parsed line carries no visible text (only whitespace, however it was styled).
    nonisolated static func isBlank(_ line: [AnsiRun]) -> Bool {
        line.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
    }

    /// Expands tabs, then cuts the line to `columns` CHARACTERS across its runs, marking the cut with
    /// an ellipsis carrying the style it cut into. Characters (grapheme clusters), not UTF-8 bytes —
    /// that is what a monospaced card advances by.
    nonisolated static func truncate(_ line: [AnsiRun], to columns: Int) -> [AnsiRun] {
        let expanded = line.map {
            AnsiRun(
                text: $0.text.replacingOccurrences(
                    of: "\t", with: String(repeating: " ", count: tabWidth),
                ),
                style: $0.style,
            )
        }
        guard columns > 0 else { return [] }
        var remaining = columns
        var out: [AnsiRun] = []
        for run in expanded {
            let count = run.text.count
            if count <= remaining {
                out.append(run)
                remaining -= count
                continue
            }
            // This run crosses the cap — keep what fits and mark the cut in its own style.
            if remaining > 0 {
                out.append(AnsiRun(text: String(run.text.prefix(remaining)), style: run.style))
            }
            out.append(AnsiRun(text: "…", style: run.style))
            return out
        }
        return out
    }
}
