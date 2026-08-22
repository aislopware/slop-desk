// ConnectPresentation — the Connect-to-Host form's one non-obvious rule, and its whole vocabulary.
//
// The form is a FORM on both platforms, so it takes the platform's own modal on both: an AppKit sheet on
// the Mac (``SlopDeskMacUI/MacConnectFormController``), a SwiftUI `.sheet` on the phone (``ConnectHostView``).
// Neither owns a connection model — ``AppConnection`` already holds the editable fields, the parse and
// the `connect()` lifecycle — so what is left to share is one question, asked when a connect completes:
// does this dismiss the card?
//
// ⚠️ AND THE WORDS. Every label, prompt and button title on this card was spelled TWICE, character for
// character, with the two files' comments explaining the same layout decision in the same words. A
// user-facing string spelled once per shell is a translation bug that has already happened: the day one
// half is reworded, the two platforms ship different copy for the same field and nothing catches it.
// ``ConnectForm`` is the single spelling; the shells bind controls to it and say nothing themselves.
//
// ⚠️ AND THE PORT PROMPTS WERE WRONG — on BOTH halves, identically, which is how a duplicated literal
// hides a bug: the two agreed, so the disagreement with the actual default was invisible. The fields
// prompted `9000` / `9001` / `9002` while ``ConnectionTarget/default`` is `7420` / `9000` / `9001` — the
// three prompts were one slot off, so an emptied Port field advertised the MEDIA port as the terminal
// one. They are derived from the default target now, so the prompt cannot outlive the value it quotes.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The Connect-to-Host form's words and prompts, spelled once for both shells.
///
/// Nothing here is a view: a label is a string, and which string goes on which field is the form's
/// meaning rather than either platform's drawing (docs/56 §3).
public enum ConnectForm {
    /// The card's title.
    public static let title = "Connect to Host"
    /// The headline pair — the machine, then its terminal-mux port.
    public static let hostLabel = "Host"
    public static let portLabel = "Port"
    /// The host prompt shows BOTH spellings a reader might reach for, a name and an address, because
    /// the field takes either and an example of one reads as a rule against the other.
    public static let hostPrompt = "host.local or 10.0.0.7"
    /// The folded disclosure over the two video ports.
    public static let videoPortsLabel = "Video ports"
    public static let mediaPortLabel = "Media port"
    public static let cursorPortLabel = "Cursor port"
    /// The confirming action. Cancel is the platform's own word on both halves (a `keyEquivalent` on the
    /// Mac, ``SlateCardFooter``'s role on the phone), so it is NOT respelled here.
    public static let connectAction = "Connect"

    /// The three port prompts, quoted from ``ConnectionTarget/default`` rather than typed. A prompt is
    /// an example of the value the field wants, so it is the default itself or it is misinformation.
    public static let portPrompt = String(ConnectionTarget.default.port)
    public static let mediaPortPrompt = String(ConnectionTarget.default.mediaPort)
    public static let cursorPortPrompt = String(ConnectionTarget.default.cursorPort)
}

/// The Connect-to-Host form's shared decision.
public enum ConnectPresentation {
    /// Whether a `connect()` completion should dismiss the card — every terminal status except `.failed`
    /// does. A failed connect leaves the card up with the reason inline: dropping the card and leaving
    /// the reason reachable only through the status pill's tooltip is a silent failure.
    ///
    /// A live `.connecting`/`.reconnecting` never reaches here — `connect()` has already resolved by the
    /// time this is asked.
    public static func shouldCloseAfterConnect(status: ConnectionStatus) -> Bool {
        if case .failed = status { return false }
        return true
    }
}
