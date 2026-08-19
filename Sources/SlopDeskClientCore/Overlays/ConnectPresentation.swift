// ConnectPresentation — the Connect-to-Host form's one non-obvious rule.
//
// The form is a FORM on both platforms, so it takes the platform's own modal on both: an AppKit sheet on
// the Mac (``SlopDeskMacUI/MacConnectFormController``), a SwiftUI `.sheet` on the phone (``ConnectHostView``).
// Neither owns a connection model — ``AppConnection`` already holds the editable fields, the parse and
// the `connect()` lifecycle — so what is left to share is one question, asked when a connect completes:
// does this dismiss the card?

import SlopDeskWorkspaceCore

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
