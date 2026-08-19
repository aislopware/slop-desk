// ChipNotice — the value behind every transient window-level cue.
//
// Split out of `InstrumentChip` when the client's presentation logic left the view target (docs/56).
// The wording, the truncation and the dwell are decided here so they stay unit-pinnable without
// rendering anything, and so the phone and the Mac say the same sentence in their own chip.

import Foundation

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
    /// Longest `detail` kept verbatim — a longer one is middle-agnostic tail-clipped at construction
    /// (deterministic, testable data-layer truncation) so the fixed-size chip can never outgrow the window.
    package static let detailCap = 48

    public let label: String
    /// The chord this notice is offering, if any — "⇧⌘T", "⌘K". Drawn as a KEYCAP, not as text (see
    /// ``NoticeKeycap``), so the notice reads `Tab closed ⇧⌘T reopens`: a sentence with a pressable object
    /// in it. `nil` for a notice that offers nothing to press, which is most of them.
    public let keycap: String?
    public let detail: String
    public let epoch: Int
    /// How long the chip dwells before expiring — per notice, because an undo affordance ("⇧⌘T reopens")
    /// needs more reading time than a pure confirmation.
    public let dwell: Duration

    public init(label: String, keycap: String? = nil, detail: String, epoch: Int, dwell: Duration) {
        self.label = label
        self.keycap = keycap
        self.detail = detail.count > Self.detailCap
            ? String(detail.prefix(Self.detailCap - 1)) + "…"
            : detail
        self.epoch = epoch
        self.dwell = dwell
    }

    /// The full one-string form for accessibility + tests (mirrors `CopyReceipt.label`).
    ///
    /// The keycap rejoins the sentence here as PLAIN TEXT, in the reading order it is drawn in, because
    /// VoiceOver has no keycap: `Tab closed · ⇧⌘T reopens`. The separator sits where the eye's separator
    /// sits — before the answer — so the spoken and the drawn form say the same thing in the same order.
    public var accessibilityText: String {
        let answer = [keycap, detail.isEmpty ? nil : detail].compactMap(\.self).joined(separator: " ")
        return answer.isEmpty ? label : label + " · " + answer
    }
}
