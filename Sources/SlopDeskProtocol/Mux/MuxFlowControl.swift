import Foundation

/// Shared constants for TCP-mux per-channel credit flow control (always on).
///
/// The numbers here are deliberately in ONE place so both ends agree without negotiation: a
/// sender's initial ``FlowCreditPolicy`` window, a receiver's ``ReceiveWindowAccountant`` window,
/// and the host's ``BoundedQueuePolicy`` capacity are all sized from ``MuxFlowControl``.
public enum MuxFlowControl {
    /// Initial per-channel send/receive window, in bytes. 64 KiB, sized for LATENCY: credit is
    /// granted at CONSUMPTION (the client's render drain), not at demux, so every in-flight byte
    /// is committed ahead of fresh output and the window bounds both client RAM per flooding pane
    /// AND the echo head-of-line delay (~44 ms at the measured ~12 Mbps inter-ISP path — a 256 KiB
    /// window would cost ~175 ms instead). Still far above what an interactive pane ever has
    /// outstanding, so flow control stays invisible on the common path. Throughput ceiling =
    /// window per grant round-trip (~17 Mbps at 30 ms WAN RTT, ~hundreds of Mbps on LAN) — ample
    /// for terminal bytes.
    ///
    /// PROGRESS INVARIANT (credit-at-consumption): every DATA inner frame must satisfy
    /// `frame wire bytes ≤ window/2` — the receiver can only consume (and thus re-grant)
    /// COMPLETE decoded frames, so a frame near the whole window could park its sender
    /// against a receiver whose pending credit never crosses the grant threshold. Enforced
    /// by construction: host output frames ≤ ``hostMergeCapBytes``/`PTYReadLoop.readChunkSize`
    /// (32 KiB), client input frames split at ``maxDataMessagePayloadBytes`` (16 KiB).
    ///
    /// `SLOPDESK_MUX_WINDOW` tunes it — ⚠️ MUST be set identically in BOTH processes
    /// (host + client): the sender's window and the receiver's grant threshold derive from
    /// this constant in their own process; a host-only decrease below the client's
    /// half-window threshold permanently stalls the channel on the first flood.
    public static let initialWindowBytes =
        envInt("SLOPDESK_MUX_WINDOW", 64 * 1024, min: 16 * 1024, max: 16 * 1024 * 1024)

    /// Split cap for client→host `.input` frames (paste). Sending a whole paste as ONE inner
    /// frame (up to 16 MiB) is avoided because the host writes nothing to the PTY until the
    /// WHOLE frame reassembles, and under credit-at-consumption a frame ≥ the window would
    /// deadlock (see the progress invariant above). 16 KiB ≪ window/2 streams a paste progressively
    /// and keeps interleave granularity fine. Splitting a byte stream is transparent to the
    /// PTY (frames carry no semantics; order is preserved by the per-channel send gate).
    /// Cross-clamped against the (env-tunable) window so an `SLOPDESK_MUX_WINDOW` at the
    /// low bound can never reintroduce the frame≥window/2 dead zone on the input direction.
    public static var maxDataMessagePayloadBytes: Int {
        min(16 * 1024, initialWindowBytes / 2 - 16)
    }

    /// Bound on the host's per-channel PTY-read queue, in bytes. Sized for LATENCY, not
    /// throughput: every byte enqueued-not-yet-sent here is committed AHEAD of fresh output
    /// (a keystroke echo, the post-flood prompt), so on a slow link the queue bound IS the
    /// in-host head-of-line delay. 64 KiB ≈ 44 ms at the measured ~12 Mbps inter-ISP path
    /// (vs ~175 ms at a 256 KiB bound) while still amortizing the pause/resume gate to one
    /// NSCondition signal per ~64 KiB drained. The PTY pause → kernel-buffer → shell
    /// backpressure chain (never-drop) is unchanged — only the trigger point moves.
    /// Host-local only (no protocol interaction) → unilaterally safe to tune via
    /// `SLOPDESK_MUX_HOST_QUEUE`.
    public static let hostQueueCapacityBytes =
        envInt("SLOPDESK_MUX_HOST_QUEUE", 64 * 1024, min: 8 * 1024, max: 8 * 1024 * 1024)

    /// The DETACHED-mode replacement for ``hostQueueCapacityBytes``: with no client consuming,
    /// the queue bound is not a latency knob but the "output while away" budget — past it the
    /// PTY pause chain stalls the pane's still-running process (an agent left working would
    /// freeze mid-task at 64 KiB + a kernel buffer). 64 MiB ≈ an aggressive overnight agent's
    /// output, bounded per detached session; `rebindRelay` restores the attached bound (the
    /// backlog ships to the returning client, then normal latency sizing resumes). Host-local
    /// only → unilaterally safe to tune via `SLOPDESK_MUX_DETACHED_QUEUE`.
    public static let detachedHostQueueCapacityBytes =
        envInt("SLOPDESK_MUX_DETACHED_QUEUE", 64 * 1024 * 1024, min: 64 * 1024, max: 1024 * 1024 * 1024)

    /// Cap on a MERGED host output frame (drain-side coalescing), in bytes. The host drain
    /// concatenates immediately-available FIFO chunks into one `.output` frame up to this
    /// cap, amortizing per-frame costs (seq, two encode copies, actor hops, one send) across
    /// a flood's small kernel-sized chunks. Tunable via `SLOPDESK_MUX_MERGE_CAP` — but the
    /// EFFECTIVE bound is ``maxOutputFramePayloadBytes``, which cross-clamps this against
    /// the window (see below); the raw value alone is NOT a safe frame bound.
    public static let hostMergeCapBytes =
        envInt("SLOPDESK_MUX_MERGE_CAP", 32 * 1024, min: 4 * 1024, max: 128 * 1024)

    /// The PROVABLY-SAFE payload cap for host `.output` frames — the single place the
    /// credit progress invariant is enforced.
    ///
    /// Invariant: every windowed inner frame's WIRE size must stay ≤ window/2, or a sender
    /// can park permanently: at a credit park the receiver can only re-grant bytes of
    /// COMPLETE decoded frames, and the partial frame buried in its FrameDecoder is
    /// uncreditable — if that partial prefix alone exceeds the grant threshold (window/2),
    /// `pendingCredit` never crosses it and no windowAdjust is ever emitted. This is a real
    /// trap, not a theoretical one: a 32 KiB PAYLOAD cap puts the max .output frame at
    /// 32 KiB + 13 header bytes = 32781 > 32768, a 13-byte dead zone that permanently wedges
    /// the pane.
    ///
    /// So the cap is in PAYLOAD bytes but accounts the frame overhead: window/2 minus a
    /// 16-byte margin (≥ the 13-byte `.output` header: 4 length + 1 type + 8 seq, with
    /// headroom for future header growth), cross-clamped against ``hostMergeCapBytes`` so
    /// env-tuning either knob can never produce a deadlocking combination.
    public static var maxOutputFramePayloadBytes: Int {
        min(hostMergeCapBytes, initialWindowBytes / 2 - 16)
    }

    /// Max number of LIVE logical channels (panes) one physical connection may hold open at once.
    /// A hostile/buggy peer can otherwise spam distinct `channelOpen` ids and make the host
    /// `openpty()`+`fork()` a shell per id without bound — a fork-bomb that exhausts fds/processes/RAM.
    /// The host refuses a NEW channel past this cap. 256 is far above any real multi-pane session (a
    /// few dozen panes), so legitimate use never approaches it.
    public static let maxChannelsPerConnection = 256

    /// Env-seamed Int with bounds (the video-path `envInt` discipline): out-of-range or
    /// unparseable values fall back to the shipped default, so a typo can never produce a
    /// degenerate window/queue.
    private static func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Int(s), v >= lo, v <= hi
        else { return fallback }
        return v
    }
}
