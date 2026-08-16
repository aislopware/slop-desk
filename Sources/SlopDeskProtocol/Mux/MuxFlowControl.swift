import CSlopDeskFFI

/// Shared constants for TCP-mux per-channel credit flow control (always on).
///
/// The numbers here are deliberately in ONE place so both ends agree without negotiation: a
/// sender's initial ``FlowCreditPolicy`` window, a receiver's ``ReceiveWindowAccountant`` window,
/// and the host's ``BoundedQueuePolicy`` capacity are all sized from ``MuxFlowControl``.
///
/// The values, their bounds and their env seams live in `rust/slopdesk-wire`'s `mux::flow`, which
/// reads each override ONCE. Asking rather than spelling is the whole point: a window typed on both
/// sides of the boundary is the cheapest possible way for the two to disagree, and the disagreement
/// that matters here — a host window below the client's grant threshold — presents as a channel
/// that stalls forever on its first flood, not as a mistake anybody can see.
public enum MuxFlowControl {
    /// Initial per-channel send/receive window, in bytes. 64 KiB, sized for LATENCY: credit is
    /// granted at CONSUMPTION (the client's render drain), not at demux, so every in-flight byte
    /// is committed ahead of fresh output and the window bounds both client RAM per flooding pane
    /// AND the echo head-of-line delay.
    ///
    /// PROGRESS INVARIANT (credit-at-consumption): every DATA inner frame must satisfy
    /// `frame wire bytes ≤ window/2` — the receiver can only consume (and thus re-grant)
    /// COMPLETE decoded frames, so a frame near the whole window could park its sender
    /// against a receiver whose pending credit never crosses the grant threshold. Enforced
    /// by construction at ``maxOutputFramePayloadBytes`` and ``maxDataMessagePayloadBytes``.
    ///
    /// `SLOPDESK_MUX_WINDOW` tunes it — ⚠️ MUST be set identically in BOTH processes.
    public static let initialWindowBytes = Int(slopdesk_mux_flow_constant(0))

    /// Split cap for client→host `.input` frames (paste). Sending a whole paste as ONE inner
    /// frame is avoided because the host writes nothing to the PTY until the WHOLE frame
    /// reassembles, and under credit-at-consumption a frame ≥ the window would deadlock.
    /// Cross-clamped against the (env-tunable) window so a low `SLOPDESK_MUX_WINDOW` can never
    /// reintroduce the frame ≥ window/2 dead zone on the input direction.
    public static var maxDataMessagePayloadBytes: Int { Int(slopdesk_mux_flow_constant(1)) }

    /// Bound on the host's per-channel PTY-read queue, in bytes. Sized for LATENCY, not
    /// throughput: every byte enqueued-not-yet-sent here is committed AHEAD of fresh output,
    /// so on a slow link the queue bound IS the in-host head-of-line delay. The PTY pause →
    /// kernel-buffer → shell backpressure chain (never-drop) is unchanged — only the trigger
    /// point moves. Host-local only → unilaterally safe to tune via `SLOPDESK_MUX_HOST_QUEUE`.
    public static let hostQueueCapacityBytes = Int(slopdesk_mux_flow_constant(2))

    /// The DETACHED-mode replacement for ``hostQueueCapacityBytes``: with no client consuming,
    /// the queue bound is not a latency knob but the "output while away" budget — past it the
    /// PTY pause chain stalls the pane's still-running process. `rebindRelay` restores the
    /// attached bound. Host-local only → tunable via `SLOPDESK_MUX_DETACHED_QUEUE`.
    public static let detachedHostQueueCapacityBytes = Int(slopdesk_mux_flow_constant(3))

    /// Cap on a MERGED host output frame (drain-side coalescing), in bytes. The host drain
    /// concatenates immediately-available FIFO chunks into one `.output` frame up to this cap,
    /// amortizing per-frame costs across a flood's small kernel-sized chunks. Tunable via
    /// `SLOPDESK_MUX_MERGE_CAP` — but the EFFECTIVE bound is ``maxOutputFramePayloadBytes``;
    /// the raw value alone is NOT a safe frame bound.
    public static let hostMergeCapBytes = Int(slopdesk_mux_flow_constant(4))

    /// The PROVABLY-SAFE payload cap for host `.output` frames — the single place the
    /// credit progress invariant is enforced. window/2 minus a 16-byte margin (≥ the 13-byte
    /// `.output` header), cross-clamped against ``hostMergeCapBytes`` so env-tuning either knob
    /// can never produce a deadlocking combination.
    public static var maxOutputFramePayloadBytes: Int { Int(slopdesk_mux_flow_constant(5)) }

    /// Max number of LIVE logical channels (panes) one physical connection may hold open at once.
    /// A hostile/buggy peer can otherwise spam distinct `channelOpen` ids and make the host
    /// `openpty()`+`fork()` a shell per id without bound. The host refuses a NEW channel past this.
    public static let maxChannelsPerConnection = Int(slopdesk_mux_flow_constant(6))
}
