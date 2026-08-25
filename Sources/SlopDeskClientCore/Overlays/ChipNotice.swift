// ChipNotice — the value behind every transient window-level cue, as a face over
// `slopdesk_workspace::chip_notice`.
//
// Split out of `InstrumentChip` when the client's presentation logic left the view target (docs/56).
// The wording, the truncation and the dwell are decided away from any renderer so they stay
// unit-pinnable without drawing anything, and so the phone and the Mac say the same sentence in their
// own chip.
//
// The truncation and the spoken form cross TOGETHER, in one call: the spoken form is built from the
// CUT detail, and two crossings would let the chip draw a clipped sentence while the screen reader
// spoke the whole one — the same notice disagreeing with itself.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

/// One transient `label · detail` notice: `label` names the event in SENTENCE CASE ("Tab closed", "Reply
/// sent"), `detail` carries the actionable answer ("⇧⌘T reopens", the target pane's title) and is the
/// dominant half. `epoch` is the dwell-timer identity (a rapid successor RETARGETS the mounted chip — the
/// text hard-cuts and the dwell restarts, never a re-entrance animation).
///
/// ⚠️ Sentence case is load-bearing, not a preference: this chip joined the floating family's paper
/// surface (``SlatePaperCapsule``) and that family's voice is the system's neutral semantics in sentence
/// case — the caps register belongs to the GLASS, which this no longer stands on. A caps label here would
/// be the instrument voice on paper, which is the pairing the form cards already rejected.
public struct ChipNotice: Equatable, Sendable {
    public let label: String
    /// The chord this notice is offering, if any — "⇧⌘T", "⌘K". Drawn as a KEYCAP, not as text (see
    /// ``NoticeKeycap``), so the notice reads `Tab closed ⇧⌘T reopens`: a sentence with a pressable object
    /// in it. `nil` for a notice that offers nothing to press, which is most of them — and ABSENT rather
    /// than empty, which is what stops the separator being left hanging.
    public let keycap: String?
    /// The detail as the chip may draw it: cut at construction so the fixed-size capsule can never
    /// outgrow its window.
    public let detail: String
    public let epoch: Int
    /// How long the chip dwells before expiring — per notice, because an undo affordance ("⇧⌘T reopens")
    /// needs more reading time than a pure confirmation.
    public let dwell: Duration
    /// The full one-string form for accessibility + tests (mirrors `CopyReceipt.label`).
    ///
    /// The keycap rejoins the sentence here as PLAIN TEXT, in the reading order it is drawn in, because
    /// VoiceOver has no keycap: `Tab closed · ⇧⌘T reopens`. The separator sits where the eye's separator
    /// sits — before the answer — so the spoken and the drawn form say the same thing in the same order.
    public let accessibilityText: String

    public init(label: String, keycap: String? = nil, detail: String, epoch: Int, dwell: Duration) {
        var arena = WsStrings()
        // The door's own order — label, keycap, detail.
        let spans = [arena.span(label), arena.span(keycap), arena.span(detail)]
        assert(spans.count == Int(SLOPDESK_WS_CHIP_NOTICE_SPANS))
        let blob = spans.withUnsafeBufferPointer { lentSpans in
            arena.bytes.withUnsafeBufferPointer { lent in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_chip_notice(
                        lent.baseAddress, lent.count,
                        lentSpans.baseAddress, lentSpans.count,
                        out, cap,
                    ))
                }
            }
        }
        let runs = wsRuns(blob, count: 2)
        self.label = label
        self.keycap = keycap
        self.detail = runs[0]
        accessibilityText = runs[1]
        self.epoch = epoch
        self.dwell = dwell
    }
}
