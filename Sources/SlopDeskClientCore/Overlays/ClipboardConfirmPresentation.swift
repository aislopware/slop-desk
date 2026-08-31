// ClipboardConfirmPresentation — what a clipboard confirmation ASKS, resolved once for both halves.
//
// Three questions share one shape and one surface: an UNSAFE PASTE (⌘V / a middle-click of a payload
// `slopdesk_terminal::paste` flagged), an OSC-52 clipboard READ (`clipboard-read = ask`) and an OSC-52
// clipboard WRITE (`clipboard-write = ask`). Each arrives through the terminal surface's pull-only
// drain as an approve/deny decision the RENDERER owes an answer to, and each is only ever a USER's answer — on the Mac through
// `SlopDeskMacUI/PasteProtectionSheet`'s `NSAlert`, on the phone through `ClipboardConfirmCard`.
//
// ⚠️ NOTHING HERE IS A SENTENCE OF ITS OWN, AND NOTHING HERE IS A DECISION EITHER. Every word comes
// from `slopdesk_terminal::paste` (docs/55): the heading, the affirmative button, the reason an OSC-52
// ask prints where a paste prints bullets, one bullet per flagged danger in the mask's own bit order,
// the defused (caret-notated, length-capped) preview — and the SHAPE, which used to be decided here:
// bullets OR the reason (never both), the preview only where there is one, and the AppKit join for the
// renderer whose dialog takes a single string. A renderer that spelled its own would be a second guard
// saying something slightly different, and a fifth danger would reach the user as a blank bullet.
//
// It crosses in ONE call. It used to be six — a heading door, a button door, a reason door, a danger
// count, a bullet-at-index and a preview — which is `5 + n` crossings to draw one dialog and six
// chances to take the heading of one ask beside the bullets of another. This type is what a renderer
// asks; `slopdesk_paste_confirmation` is what answers.

import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// One clipboard confirmation, as either renderer needs it — a value, so the whole dialog is pinnable
/// without presenting anything.
public struct ClipboardConfirmPresentation: Equatable, Sendable {
    /// The bullet a danger list is set with, in ONE place: the crate's join reads it and so does the
    /// phone's row, so the two lists cannot come to look like different lists.
    public static let bullet = "•"

    /// The caption over the defused payload. The one word on this surface that is not a danger
    /// sentence — it names a REGION — so each renderer sets it in its own register (a line of body
    /// text on the Mac, a caps micro-label on the phone).
    public static let previewCaption = "Clipboard preview"

    /// Which of the three questions this is. Kept so a renderer can differ by ask without re-deriving
    /// which one it is from the wording.
    public let ask: PasteSafetyAnalyzer.Ask
    /// The question, as the dialog's heading.
    public let title: String
    /// The affirmative button — it names the ACTION rather than saying "OK".
    public let affirmative: String
    /// One line per flagged danger, in the mask's own bit order. EMPTY for every OSC-52 ask, which
    /// carries no payload to classify.
    public let dangers: [String]
    /// What stands in for the bullets when the mask flagged nothing — the ask's own reason. EMPTY
    /// whenever ``dangers`` is non-empty, so a renderer draws exactly one of the two and never both.
    public let reason: String
    /// The payload as the confirmation may show it: length-capped, with every control character in caret
    /// notation, so the escape being warned about cannot run inside the warning. EMPTY where there is
    /// nothing to show.
    public let preview: String
    /// The whole body as ONE string, for the renderer whose dialog takes one — an `NSAlert`'s
    /// `informativeText`. A renderer that lays the parts out (the phone draws the bullets as rows and the
    /// preview on its own plate) reads ``dangers`` / ``reason`` / ``preview`` directly and never this.
    public let informativeText: String

    public init(
        ask: PasteSafetyAnalyzer.Ask,
        title: String,
        affirmative: String,
        dangers: [String],
        reason: String,
        preview: String,
        informativeText: String,
    ) {
        self.ask = ask
        self.title = title
        self.affirmative = affirmative
        self.dangers = dangers
        self.reason = reason
        self.preview = preview
        self.informativeText = informativeText
    }

    /// Resolve the confirmation for `ask` over `preview` and the dangers `preview` tripped.
    public static func reading(
        ask: PasteSafetyAnalyzer.Ask,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
    ) -> Self {
        var bytes = Array(preview.utf8)
        let mask = UInt32(truncatingIfNeeded: dangers.rawValue)
        let blob = bytes.withUnsafeMutableBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_paste_confirmation(
                    ask.rawValue, mask, lent.baseAddress, lent.count, out, cap,
                ))
            }
        }
        let head = 4
        // The bullet COUNT leads the delivery so the reader knows how many runs follow the fixed
        // five; a short delivery is a layout disagreement and loses the whole dialog rather than
        // drawing a heading with someone else's bullets under it.
        guard blob.count >= head else {
            return Self(
                ask: ask, title: "", affirmative: "", dangers: [], reason: "", preview: "",
                informativeText: "",
            )
        }
        let bulletCount = (0..<4).reduce(0) { $0 << 8 | Int(blob[$1]) }
        let fixed = Int(SLOPDESK_PASTE_CONFIRMATION_FIXED_RUNS)
        let runs = wsRuns(Array(blob.dropFirst(head)), count: fixed + bulletCount)
        return Self(
            ask: ask,
            title: runs[0],
            affirmative: runs[1],
            dangers: Array(runs.dropFirst(fixed)),
            reason: runs[2],
            preview: runs[3],
            informativeText: runs[4],
        )
    }
}
