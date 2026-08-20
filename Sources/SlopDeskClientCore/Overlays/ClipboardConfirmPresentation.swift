// ClipboardConfirmPresentation — what a clipboard confirmation ASKS, resolved once for both halves.
//
// Three questions share one shape and one surface: an UNSAFE PASTE (⌘V / a middle-click of a payload
// `slopdesk_terminal::paste` flagged), an OSC-52 clipboard READ (`clipboard-read = ask`) and an OSC-52
// clipboard WRITE (`clipboard-write = ask`). Each arrives at the libghostty embedder as an approve/deny
// decision the EMBEDDER owes an answer to, and each is only ever a USER's answer — on the Mac through
// `SlopDeskMacUI/PasteProtectionSheet`'s `NSAlert`, on the phone through `ClipboardConfirmCard`.
//
// ⚠️ NOTHING HERE IS A SENTENCE OF ITS OWN. Every word comes from ``PasteSafetyAnalyzer`` and therefore
// from `slopdesk_terminal::paste` (docs/55): the heading, the affirmative button, the reason an OSC-52 ask
// prints where a paste prints bullets, one bullet per flagged danger in the mask's own bit order, and the
// defused (caret-notated, length-capped) preview. A renderer that spelled its own would be a second guard
// saying something slightly different, and a fifth danger would reach the user as a blank bullet.
//
// What this type adds is the SHAPE the two renderers would otherwise each decide for themselves: bullets
// OR the ask's reason (never both — an OSC-52 ask has no payload to classify, so the REQUEST is the
// reason), the preview only where there is one, and — for the one renderer that needs a single string
// rather than a layout — the AppKit join, so `informativeText` is composed here and not beside an
// `NSAlert`.
//
// It lives HERE rather than in the domain for the reason docs/56 §2 gives: `PasteSafetyAnalyzer` owns
// whether a payload is dangerous and what that danger is CALLED; what a dialog is shaped like is what a
// UI asks that answer for.

import SlopDeskWorkspaceCore

/// One clipboard confirmation, as either renderer needs it — PURE, so the whole dialog is pinnable
/// without presenting anything.
public struct ClipboardConfirmPresentation: Equatable, Sendable {
    /// The bullet a danger list is set with, in ONE place: the AppKit join below reads it and so does the
    /// phone's row, so the two lists cannot come to look like different lists.
    public static let bullet = "•"

    /// The caption over the defused payload. The one word on this surface that is not a `paste` sentence
    /// — it names a REGION rather than describing a danger — so it is spelled once here and each renderer
    /// sets it in its own register (a line of body text on the Mac, a caps micro-label on the phone).
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

    public init(
        ask: PasteSafetyAnalyzer.Ask,
        title: String,
        affirmative: String,
        dangers: [String],
        reason: String,
        preview: String,
    ) {
        self.ask = ask
        self.title = title
        self.affirmative = affirmative
        self.dangers = dangers
        self.reason = reason
        self.preview = preview
    }

    /// Resolve the confirmation for `ask` over `preview` and the dangers `preview` tripped.
    ///
    /// The bullets-or-reason branch is the whole decision: a paste that reached a confirmation reached it
    /// because the mask flagged something, so it lists what; an OSC-52 ask has an empty mask by
    /// construction, so it prints why the REQUEST is being questioned instead. A renderer asking this
    /// cannot get that branch subtly different from the other renderer's.
    public static func reading(
        ask: PasteSafetyAnalyzer.Ask,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
    ) -> Self {
        let described = PasteSafetyAnalyzer.descriptions(for: dangers)
        return Self(
            ask: ask,
            title: ask.title,
            affirmative: ask.affirmative,
            dangers: described,
            reason: described.isEmpty ? ask.reason : "",
            preview: PasteSafetyAnalyzer.preview(of: preview),
        )
    }

    /// The whole body as ONE string, for the renderer whose dialog takes one — an `NSAlert`'s
    /// `informativeText`. A renderer that lays the parts out (the phone draws the bullets as rows and the
    /// preview on its own plate) reads ``dangers`` / ``reason`` / ``preview`` directly and never this.
    public var informativeText: String {
        var sections: [String] = []
        if !dangers.isEmpty {
            sections.append(dangers.map { "\(Self.bullet)  \($0)" }.joined(separator: "\n"))
        } else if !reason.isEmpty {
            sections.append(reason)
        }
        if !preview.isEmpty {
            sections.append("\(Self.previewCaption):\n\(preview)")
        }
        return sections.joined(separator: "\n\n")
    }
}
