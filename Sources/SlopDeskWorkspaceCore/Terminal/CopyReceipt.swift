// CopyReceipt — the pure "what just landed on the clipboard" summary behind every transient copy
// confirmation (the pane chip + the window-level chip). A copy is the highest-frequency invisible action
// in a terminal, so the confirmation must answer the one real doubt — "did I get the whole thing?" —
// in a glance: a LINE count for a multi-line grab (where the selection may extend past the viewport),
// a CHAR count for a single-line grab (where truncation is the failure mode).
//
// Pure value type: counting + label formatting live here (not in a view) so the wording is pinned by
// unit tests and the pane mount / window mount can never drift. The label speaks the instrument voice's
// caps register ("COPIED · 1,204 CHARS") — the view renders it in `Slate.Typeface.instrument`.

import Foundation

/// One clipboard-copy receipt: the counts of what was written, plus a monotonically-increasing `epoch`
/// so a rapid re-copy reads as a NEW receipt (the chip's dwell timer restarts and the label hard-cuts
/// to the new count — retarget, never a re-entrance animation).
public struct CopyReceipt: Equatable, Sendable {
    /// Grapheme-cluster count of the copied text — what a user would call "characters".
    public let charCount: Int
    /// Logical line count: newline-separated segments, with a single trailing newline NOT counted as an
    /// extra empty line (a shell line copy `"foo\n"` is one line, not two).
    public let lineCount: Int
    /// Bumped per copy by the owner (pane model / overlay coordinator) — identity for the dwell timer.
    public let epoch: Int

    public init(text: String, epoch: Int) {
        charCount = text.count
        var segments = text.split(separator: "\n", omittingEmptySubsequences: false)
        if segments.count > 1, segments.last?.isEmpty == true { segments.removeLast() }
        lineCount = segments.count
        self.epoch = epoch
    }

    /// The count half of the label: `"18 LINES"` for a multi-line copy (the whole-block doubt),
    /// `"1,204 CHARS"` / `"1 CHAR"` for a single line (the truncation doubt). Never "1 LINE" — a
    /// single-line copy always speaks chars, the more informative number.
    public var detail: String {
        if lineCount > 1 { return "\(Self.grouped(lineCount)) LINES" }
        return "\(Self.grouped(charCount)) \(charCount == 1 ? "CHAR" : "CHARS")"
    }

    /// The full caps label (`"COPIED · 1,204 CHARS"`) — one string for accessibility + tests; the chip
    /// renders the two halves in separate text tones (label secondary, count primary).
    public var label: String { "COPIED · " + detail }

    /// Deterministic thousands grouping (`1204` → `"1,204"`) — locale-independent so the instrument
    /// voice reads identically on every machine and the label pins don't drift with system settings.
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        guard digits.count > 3 else { return String(digits) }
        var out: [Character] = []
        for (i, d) in digits.enumerated() {
            if i > 0, (digits.count - i).isMultiple(of: 3) { out.append(",") }
            out.append(d)
        }
        return String(out)
    }
}
