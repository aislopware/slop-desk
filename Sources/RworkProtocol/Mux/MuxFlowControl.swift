import Foundation

/// Shared constants + the pure send-side decider for TCP-mux S2 per-channel credit flow
/// control (sub-gated by `RWORK_TCP_MUX_FLOW`).
///
/// The numbers here are deliberately in ONE place so both ends agree without negotiation
/// (the gate is the contract — same discipline as `RWORK_TCP_MUX`): a sender's initial
/// ``FlowCreditPolicy`` window, a receiver's ``ReceiveWindowAccountant`` window, and the
/// host's ``BoundedQueuePolicy`` capacity are all sized from ``MuxFlowControl``.
public enum MuxFlowControl {
    /// Initial per-channel send/receive window, in bytes. 256 KiB — the yamux default
    /// (`initialStreamWindow`), and in the same ballpark as a healthy SSH channel window.
    ///
    /// Sizing rationale: large enough that a normal interactive pane (keystrokes, a screenful
    /// of `vt` output — kilobytes) NEVER touches the window, so flow control is invisible on
    /// the common path; small enough that a flood (`yes | head -c 50M`) can only put ~256 KiB
    /// in flight per channel before it MUST wait for the receiver to drain + grant, so one
    /// flooding pane cannot monopolise the shared socket and starve a sibling pane's
    /// keystrokes (the HOL/starvation problem this stage exists to solve).
    public static let initialWindowBytes = 256 * 1024

    /// Bound on the host's per-channel PTY-read queue, in bytes. Matched to the send window so
    /// the host buffers at most ~one window beyond what is in flight before it PAUSES the PTY
    /// read — the real fix for the flood (backpressure to the producer, not buffer-the-world).
    public static let hostQueueCapacityBytes = 256 * 1024

    /// The `RWORK_TCP_MUX_FLOW` sub-gate value from `env` (ON iff `"1"`/`"true"`/`"yes"`/`"on"`,
    /// case-insensitive). Default OFF — an unset var leaves the mux on the S1 infinite-window
    /// path (byte-identical to today: the sender never blocks, a received `windowAdjust` is a
    /// benign no-op, the host queue is unbounded). Read ONCE at the mux construction site,
    /// alongside `RWORK_TCP_MUX`.
    ///
    /// ⚠️ BOTH ENDS MUST MATCH (FIX #4). There is NO on-wire negotiation — the gate IS the contract,
    /// exactly like `RWORK_TCP_MUX`. A MISMATCH FAILS CLOSED INTO A SILENT HANG: if the SENDER has
    /// flow ON but the RECEIVER OFF, the receiver never emits a `windowAdjust`, so the sender's
    /// 256 KiB window drains once and then the channel PARKS PERMANENTLY (every subsequent send on
    /// that pane freezes). The symptom — "a pane works for ~one screenful then goes dead" — is hard
    /// to diagnose, so set `RWORK_TCP_MUX_FLOW` IDENTICALLY on the host daemon and every client, or
    /// leave it unset on both. (Set it alongside `RWORK_TCP_MUX`, which carries the same both-ends
    /// requirement.)
    public static func flowEnabledFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env["RWORK_TCP_MUX_FLOW"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }
}
