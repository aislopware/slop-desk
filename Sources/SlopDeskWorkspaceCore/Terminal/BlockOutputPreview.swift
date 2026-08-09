import Foundation

// MARK: - BlockOutputPreview (a few lines of a block's output, for the ladder's hover peek)

/// The short excerpt of one command block's output the command ladder shows while the pointer dwells
/// on its tick (user-directed 2026-08-09): a handful of lines plus a count of what was left out.
///
/// WHICH END is the whole design of it. A clean command is read from the TOP — the first lines say
/// what it set out to do. A FAILED one is read from the BOTTOM — the first lines of a failing build
/// are the same banner every build prints, and the message that matters is the last thing said. So
/// the excerpt follows the outcome rather than a fixed rule, and ``fromTail`` records which end it
/// came from so the card can say so out loud (a preview whose provenance is invisible is a preview
/// that can mislead).
///
/// PURE value type + `Sendable` — no clock, no view, no I/O.
public struct BlockOutputPreview: Equatable, Sendable {
    /// The excerpt lines, in reading order (top→bottom as they appeared), already column-truncated.
    public let lines: [String]
    /// How many output lines are NOT in ``lines``. Zero when the whole output fitted.
    public let hiddenCount: Int
    /// True when the excerpt was taken from the END of the output (a failed command) — so the card
    /// says "N lines above" rather than "+N more lines".
    public let fromTail: Bool

    public init(lines: [String], hiddenCount: Int, fromTail: Bool) {
        self.lines = lines
        self.hiddenCount = hiddenCount
        self.fromTail = fromTail
    }

    /// True when there is nothing to show — the command printed nothing (or only blank lines).
    public var isEmpty: Bool { lines.isEmpty }
}

/// Builds a ``BlockOutputPreview`` from a block's VT-stripped plain text (the output of
/// ``BlockOutputSanitizer/plainText(from:)``). PURE + `nonisolated` so it unit-tests headlessly.
public enum BlockOutputPreviewBuilder {
    /// How many output lines the peek card shows. Sized for a card that can hang beside a tick
    /// without covering the pane it belongs to.
    public static let maxLines = 8

    /// The column cap per line. A build log can emit a single 4 000-column line; the card is a fixed
    /// width, so an over-long line is cut here (with an ellipsis) rather than silently clipped by the
    /// layout — the cut is then visible as what it is.
    public static let maxColumns = 96

    /// Tab width used to expand a `\t` before the column cut — a tab inside a fixed-width card
    /// otherwise advances by a value the card has no way to honour.
    public static let tabWidth = 4

    /// The excerpt of `plainText`, taken from the END when `failed` (see ``BlockOutputPreview``).
    /// Blank lines at BOTH ends are dropped first — a command's captured output almost always begins
    /// or ends with the newline that separated it from the prompt, and a preview that opens with an
    /// empty row reads as a bug.
    public nonisolated static func make(
        plainText: String,
        failed: Bool,
        maxLines: Int = maxLines,
        maxColumns: Int = maxColumns,
    ) -> BlockOutputPreview {
        var lines = plainText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
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

    /// Expands tabs, then cuts `line` to `columns` characters, marking the cut with an ellipsis. The
    /// count is CHARACTERS (grapheme clusters), which is what a monospaced card advances by — not
    /// UTF-8 bytes.
    nonisolated static func truncate(_ line: String, to columns: Int) -> String {
        let expanded = line.replacingOccurrences(
            of: "\t", with: String(repeating: " ", count: tabWidth),
        )
        guard columns > 0, expanded.count > columns else { return expanded }
        return String(expanded.prefix(columns)) + "…"
    }
}
