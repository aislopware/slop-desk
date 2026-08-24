// ConnectPresentation — the near-side FACE of `slopdesk_workspace::connect_form`.
//
// The form is a FORM on both platforms, so it takes the platform's own modal on both: an AppKit sheet on
// the Mac (``SlopDeskMacUI/MacConnectFormController``), a SwiftUI `.sheet` on the phone (``ConnectHostView``).
// Neither owns a connection model — ``AppConnection`` already holds the editable fields, the parse and
// the `connect()` lifecycle — so what crossed is the words, and one question asked when a connect
// completes: does this dismiss the card?
//
// ⚠️ THE THREE PORT PROMPTS STAY HERE, and that is deliberate. They are `ConnectionTarget.default`'s own
// numbers rendered as text. Both halves once prompted `9000` / `9001` / `9002` against a default of
// `7420` / `9000` / `9001` — one slot off, so an emptied Port field advertised the MEDIA port as the
// terminal one, and the two halves AGREED, which is how a duplicated literal hides a bug. Deriving them
// from the default is what makes a prompt unable to outlive the value it quotes; a door for them would
// put the number back in a second place and re-open exactly that door.

import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The Connect-to-Host form's words and prompts, spelled once for both shells.
///
/// Nothing here is a view: a label is a string, and which string goes on which field is the form's
/// meaning rather than either platform's drawing (docs/56 §3).
public enum ConnectForm {
    /// The card's title.
    public static var title: String { words[0] }
    /// The headline pair — the machine, then its terminal-mux port.
    public static var hostLabel: String { words[1] }
    public static var portLabel: String { words[2] }
    /// The host prompt shows BOTH spellings a reader might reach for, a name and an address, because
    /// the field takes either and an example of one reads as a rule against the other.
    public static var hostPrompt: String { words[3] }
    /// The folded disclosure over the two video ports.
    public static var videoPortsLabel: String { words[4] }
    public static var mediaPortLabel: String { words[5] }
    public static var cursorPortLabel: String { words[6] }
    /// The confirming action. Cancel is the platform's own word on both halves (a `keyEquivalent` on the
    /// Mac, ``SlateCardFooter``'s role on the phone), so it is NOT respelled — on either side.
    public static var connectAction: String { words[7] }

    /// The three port prompts, quoted from ``ConnectionTarget/default`` rather than typed. A prompt is
    /// an example of the value the field wants, so it is the default itself or it is misinformation.
    public static let portPrompt = String(ConnectionTarget.default.port)
    public static let mediaPortPrompt = String(ConnectionTarget.default.mediaPort)
    public static let cursorPortPrompt = String(ConnectionTarget.default.cursorPort)

    /// Every word in ONE crossing, once per process — the card is raised often enough that a crossing
    /// per label per raise would be eight for a form that never changes.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_connect_form_words(out, cap)) },
        count: 8,
    )
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
        if case .failed = status { return slopdesk_ws_connect_form_closes_after(true) }
        return slopdesk_ws_connect_form_closes_after(false)
    }
}
