// CopyReceipt — the "what just landed on the clipboard" summary behind every transient copy
// confirmation (the pane chip + the window-level chip), as a face over
// `slopdesk_terminal::copy_receipt`.
//
// A copy is the highest-frequency invisible action in a terminal, so the confirmation must answer the
// one real doubt — "did I get the whole thing?" — in a glance: a LINE count for a multi-line grab
// (where the selection may extend past the viewport), a CHAR count for a single-line grab (where
// truncation is the failure mode). Which number, how it is grouped, and the sentence it sits in are
// all the crate's; counting and wording crossed together because they are one answer, and a chip
// holding a count from one grab beside a sentence from the next is exactly what two doors would
// allow.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

/// One clipboard-copy receipt: the counts of what was written, plus a monotonically-increasing `epoch`
/// so a rapid re-copy reads as a NEW receipt (the chip's dwell timer restarts and the label hard-cuts
/// to the new count — retarget, never a re-entrance animation).
/// `Hashable` over the same fields it is `Equatable` over — the AppKit chip keys its dwell on the
/// WHOLE receipt (a hand-off between the two owners can carry the same epoch), and an identity a view
/// compares has to be one it can also box.
public struct CopyReceipt: Hashable, Sendable {
    /// Grapheme-cluster count of the copied text — what a user would call "characters".
    public let charCount: Int
    /// Logical line count: newline-separated segments, with a single trailing newline NOT counted as an
    /// extra empty line (a shell line copy `"foo\n"` is one line, not two).
    public let lineCount: Int
    /// Bumped per copy by the owner (pane model / overlay coordinator) — identity for the dwell timer.
    public let epoch: Int
    /// The count half of the label: `"18 lines"` for a multi-line copy (the whole-block doubt),
    /// `"1,204 characters"` / `"1 character"` for a single line (the truncation doubt).
    public let detail: String
    /// The full label (`"Copied · 1,204 characters"`) — one string for accessibility + tests; the chip
    /// renders the two halves at separate weights (label quiet, count semibold).
    public let label: String

    /// How long the chip dwells before expiring — long enough to read a short count at a glance, short
    /// enough that the pane is ornament-free again before the next thought.
    ///
    /// It is a CONSTANT rather than per-receipt, unlike `ChipNotice.dwell`, because every copy says the
    /// same shape of thing; a notice may be offering an undo chord, which needs more reading time. It
    /// lives on the value rather than on either chip so the two renderers cannot hold the receipt for
    /// two different lengths of time. A DURATION and not a number of characters, so it is the one
    /// field here with nothing to decide and no reason to cross.
    public static let dwell: Duration = .seconds(1.5)

    public init(text: String, epoch: Int) {
        var bytes = Array(text.utf8)
        let blob = bytes.withUnsafeMutableBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_copy_receipt(lent.baseAddress, lent.count, out, cap))
            }
        }
        let head = Int(SLOPDESK_COPY_RECEIPT_HEAD_BYTES)
        // The door never answers nothing — an empty copy still has a receipt — so a short delivery is
        // a layout disagreement, and zeroes beside empty words say so rather than half-reporting.
        let number = { (at: Int) -> Int in
            guard blob.count >= head else { return 0 }
            return (0..<4).reduce(0) { $0 << 8 | Int(blob[at + $1]) }
        }
        charCount = number(0)
        lineCount = number(4)
        let runs = wsRuns(blob.count >= head ? Array(blob.dropFirst(head)) : [], count: 2)
        detail = runs[0]
        label = runs[1]
        self.epoch = epoch
    }
}
