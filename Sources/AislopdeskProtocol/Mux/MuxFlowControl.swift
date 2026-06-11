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

    /// Bound on the host's per-channel PTY-read queue, in bytes. Sized for LATENCY, not
    /// throughput: every byte enqueued-not-yet-sent here is committed AHEAD of fresh output
    /// (a keystroke echo, the post-flood prompt), so on a slow link the queue bound IS the
    /// in-host head-of-line delay. 64 KiB ≈ 44 ms at the measured ~12 Mbps inter-ISP path
    /// (vs ~175 ms at the old 256 KiB) while still amortizing the pause/resume gate to one
    /// NSCondition signal per ~64 KiB drained. The PTY pause → kernel-buffer → shell
    /// backpressure chain (never-drop) is unchanged — only the trigger point moves.
    /// Host-local only (no protocol interaction) → unilaterally safe to tune via
    /// `AISLOPDESK_MUX_HOST_QUEUE`.
    public static let hostQueueCapacityBytes =
        envInt("AISLOPDESK_MUX_HOST_QUEUE", 64 * 1024, min: 8 * 1024, max: 8 * 1024 * 1024)

    /// Cap on a MERGED host output frame (drain-side coalescing), in bytes. The host drain
    /// concatenates immediately-available FIFO chunks into one `.output` frame up to this
    /// cap, amortizing per-frame costs (seq, two encode copies, actor hops, one send) across
    /// a flood's small kernel-sized chunks. MUST stay ≤ ``initialWindowBytes``/2 so a merged
    /// frame can always make window progress (the credit grant threshold is window/2 — a
    /// frame bigger than that can park the sender against a receiver that never re-grants).
    /// Tunable via `AISLOPDESK_MUX_MERGE_CAP`.
    public static let hostMergeCapBytes =
        envInt("AISLOPDESK_MUX_MERGE_CAP", 32 * 1024, min: 4 * 1024, max: 128 * 1024)

    /// Max number of LIVE logical channels (panes) one physical connection may hold open at once
    /// (R6 #6). A hostile/buggy peer can otherwise spam distinct `channelOpen` ids and make the host
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
