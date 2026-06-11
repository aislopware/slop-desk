import Foundation

/// Shared constants for TCP-mux per-channel credit flow control (always on).
///
/// The numbers here are deliberately in ONE place so both ends agree without negotiation: a
/// sender's initial ``FlowCreditPolicy`` window, a receiver's ``ReceiveWindowAccountant`` window,
/// and the host's ``BoundedQueuePolicy`` capacity are all sized from ``MuxFlowControl``.
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

    /// Max number of LIVE logical channels (panes) one physical connection may hold open at once
    /// (R6 #6). A hostile/buggy peer can otherwise spam distinct `channelOpen` ids and make the host
    /// `openpty()`+`fork()` a shell per id without bound — a fork-bomb that exhausts fds/processes/RAM.
    /// The host refuses a NEW channel past this cap. 256 is far above any real multi-pane session (a
    /// few dozen panes), so legitimate use never approaches it.
    public static let maxChannelsPerConnection = 256
}
