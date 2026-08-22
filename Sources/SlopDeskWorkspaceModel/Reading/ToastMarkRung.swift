// ToastMarkRung — which status rung a notification card's mark is drawn in.
//
// WHAT a card says is `SlopDeskClientCore/Overlays/ToastPresentation.swift`, which asks
// `slopdesk_ws_notify_toast_headline` and decides which cards speak in full. Only the RUNG
// descended, and only because `SlopDeskSlate` resolves it (`Slate.Native.toastMarkInk(for:)`) — the
// design floor may name the ladder without naming the notification reading above it.

/// Which status rung a card's mark is drawn in. Named, not coloured: the ink ladder is the drawing
/// half's, and this layer must not own a `Color`.
public enum ToastMarkRung: Sendable, Equatable {
    /// It ended well — green.
    case ok
    /// It is waiting on a human — AMBER, not the accent. The rail already fixed this mapping
    /// (`StatusDot`: green finish, amber question, red failure), so an agent waiting on a human is
    /// the same colour here as on its own sidebar row; and every FOUNDRY seed sets `info == accent`,
    /// so the accent would have rendered "needs input" in the same cyan as a routine notice.
    case warn
    /// It ended badly — red.
    case err
    /// A routine notice, drawn in the reading ink's secondary rung. NEUTRAL on purpose: cyan on
    /// every OSC notice was chrome pretending to be signal.
    case neutral
}
