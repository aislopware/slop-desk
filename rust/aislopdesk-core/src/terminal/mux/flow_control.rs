//! Shared constants for TCP-mux per-channel credit flow control (always on) — a port of
//! Swift `AislopdeskProtocol.MuxFlowControl`.
//!
//! The numbers here are deliberately in ONE place so both ends agree without negotiation:
//! a sender's initial [`FlowCreditPolicy`](super::FlowCreditPolicy) window, a receiver's
//! [`ReceiveWindowAccountant`](super::ReceiveWindowAccountant) window, and the host's
//! [`BoundedQueuePolicy`](super::BoundedQueuePolicy) capacity are all sized from here.
//!
//! In the Swift host these are env-tunable (`AISLOPDESK_MUX_*`). This port pins the shipped
//! defaults as compile-time constants (the unset-env values) and exposes pure resolvers
//! ([`resolve_initial_window_bytes`] etc.) plus `*_from_env` wrappers, so the math stays
//! deterministic and testable while a host that wants the env seam can still opt in. The
//! `⚠️ MUST be set identically in BOTH processes` caveat from the Swift source applies to
//! any host using the env seam.

/// Initial per-channel send/receive window, in bytes (64 KiB).
///
/// Sized for LATENCY now that
/// credit is granted at CONSUMPTION: the window bounds both client RAM per flooding pane
/// and the echo head-of-line delay. Still far above what an interactive pane ever has
/// outstanding, so flow control stays invisible on the common path.
pub const DEFAULT_INITIAL_WINDOW_BYTES: usize = 64 * 1024;
/// Lower bound for [`resolve_initial_window_bytes`] (16 KiB).
pub const MIN_INITIAL_WINDOW_BYTES: usize = 16 * 1024;
/// Upper bound for [`resolve_initial_window_bytes`] (16 MiB).
pub const MAX_INITIAL_WINDOW_BYTES: usize = 16 * 1024 * 1024;

/// Bound on the host's per-channel PTY-read queue, in bytes (64 KiB).
///
/// Sized for LATENCY:
/// every byte enqueued-not-yet-sent is committed ahead of fresh output, so the queue bound
/// IS the in-host head-of-line delay. Host-local only (no protocol interaction).
pub const DEFAULT_HOST_QUEUE_CAPACITY_BYTES: usize = 64 * 1024;
/// Lower bound for [`resolve_host_queue_capacity_bytes`] (8 KiB).
pub const MIN_HOST_QUEUE_CAPACITY_BYTES: usize = 8 * 1024;
/// Upper bound for [`resolve_host_queue_capacity_bytes`] (8 MiB).
pub const MAX_HOST_QUEUE_CAPACITY_BYTES: usize = 8 * 1024 * 1024;

/// Cap on a MERGED host output frame (drain-side coalescing), in bytes (32 KiB).
///
/// The host
/// drain concatenates immediately-available FIFO chunks into one `.output` frame up to this
/// cap, amortizing per-frame costs across a flood's small kernel-sized chunks. The
/// EFFECTIVE bound is [`max_output_frame_payload_bytes`], which cross-clamps this against
/// the window — the raw value alone is NOT a safe frame bound.
pub const DEFAULT_HOST_MERGE_CAP_BYTES: usize = 32 * 1024;
/// Lower bound for [`resolve_host_merge_cap_bytes`] (4 KiB).
pub const MIN_HOST_MERGE_CAP_BYTES: usize = 4 * 1024;
/// Upper bound for [`resolve_host_merge_cap_bytes`] (128 KiB).
pub const MAX_HOST_MERGE_CAP_BYTES: usize = 128 * 1024;

/// Max number of LIVE logical channels (panes) one physical connection may hold open at
/// once.
///
/// A hostile/buggy peer can otherwise spam distinct `channelOpen` ids and make the
/// host fork a shell per id without bound. 256 is far above any real multi-pane session.
pub const MAX_CHANNELS_PER_CONNECTION: usize = 256;

/// Margin subtracted from `window / 2` when sizing a frame payload cap: ≥ the 13-byte
/// `.output` header (4 length + 1 type + 8 seq), with headroom for future header growth.
/// Closes the dead-zone where a payload cap at exactly `window / 2` produced a frame WIRE
/// size just over `window / 2` (the night-review wedge: a 32 KiB payload + 13 header bytes
/// = 32781 > 32768).
const FRAME_OVERHEAD_MARGIN: usize = 16;

/// Hard cap on `.input` (paste) frame payloads (16 KiB),
///
/// cross-clamped against the window's
/// half-window grant threshold so a low `initial_window` can never reintroduce the
/// frame ≥ window/2 dead zone on the input direction.
///
/// See the progress invariant in the
/// Swift source.
#[must_use]
pub fn max_data_message_payload_bytes(initial_window_bytes: usize) -> usize {
    (16 * 1024).min((initial_window_bytes / 2).saturating_sub(FRAME_OVERHEAD_MARGIN))
}

/// The PROVABLY-SAFE payload cap for host `.output` frames — the single place the credit
/// progress invariant is enforced.
///
/// In PAYLOAD bytes but accounting the frame overhead:
/// `window / 2` minus a margin, cross-clamped against `host_merge_cap_bytes` so env-tuning
/// either knob can never produce a deadlocking combination.
#[must_use]
pub fn max_output_frame_payload_bytes(
    host_merge_cap_bytes: usize,
    initial_window_bytes: usize,
) -> usize {
    host_merge_cap_bytes.min((initial_window_bytes / 2).saturating_sub(FRAME_OVERHEAD_MARGIN))
}

/// Parses a decimal byte count and accepts it only within `[lo, hi]`; otherwise (absent,
/// unparseable, or out of range) returns `fallback`. Mirrors the Swift `envInt` discipline
/// (a typo can never produce a degenerate window/queue). Parses as `i64` so a leading-minus
/// value is rejected by the bound check exactly as Swift's `Int(s)` path does.
fn resolve_bounded(raw: Option<&str>, fallback: usize, lo: usize, hi: usize) -> usize {
    match raw.and_then(|s| s.parse::<i64>().ok()) {
        Some(v) if v >= lo as i64 && v <= hi as i64 => v as usize,
        _ => fallback,
    }
}

/// Resolves the initial per-channel window from an optional env string (`AISLOPDESK_MUX_WINDOW`).
#[must_use]
pub fn resolve_initial_window_bytes(raw: Option<&str>) -> usize {
    resolve_bounded(
        raw,
        DEFAULT_INITIAL_WINDOW_BYTES,
        MIN_INITIAL_WINDOW_BYTES,
        MAX_INITIAL_WINDOW_BYTES,
    )
}

/// Resolves the host PTY-read queue capacity (`AISLOPDESK_MUX_HOST_QUEUE`).
#[must_use]
pub fn resolve_host_queue_capacity_bytes(raw: Option<&str>) -> usize {
    resolve_bounded(
        raw,
        DEFAULT_HOST_QUEUE_CAPACITY_BYTES,
        MIN_HOST_QUEUE_CAPACITY_BYTES,
        MAX_HOST_QUEUE_CAPACITY_BYTES,
    )
}

/// Resolves the host output-merge cap (`AISLOPDESK_MUX_MERGE_CAP`).
#[must_use]
pub fn resolve_host_merge_cap_bytes(raw: Option<&str>) -> usize {
    resolve_bounded(
        raw,
        DEFAULT_HOST_MERGE_CAP_BYTES,
        MIN_HOST_MERGE_CAP_BYTES,
        MAX_HOST_MERGE_CAP_BYTES,
    )
}

/// Reads `AISLOPDESK_MUX_WINDOW` from the process environment (host opt-in seam).
#[must_use]
pub fn initial_window_bytes_from_env() -> usize {
    resolve_initial_window_bytes(std::env::var("AISLOPDESK_MUX_WINDOW").ok().as_deref())
}

/// Reads `AISLOPDESK_MUX_HOST_QUEUE` from the process environment (host opt-in seam).
#[must_use]
pub fn host_queue_capacity_bytes_from_env() -> usize {
    resolve_host_queue_capacity_bytes(std::env::var("AISLOPDESK_MUX_HOST_QUEUE").ok().as_deref())
}

/// Reads `AISLOPDESK_MUX_MERGE_CAP` from the process environment (host opt-in seam).
#[must_use]
pub fn host_merge_cap_bytes_from_env() -> usize {
    resolve_host_merge_cap_bytes(std::env::var("AISLOPDESK_MUX_MERGE_CAP").ok().as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_swift_shipped_values() {
        assert_eq!(DEFAULT_INITIAL_WINDOW_BYTES, 65_536);
        assert_eq!(DEFAULT_HOST_QUEUE_CAPACITY_BYTES, 65_536);
        assert_eq!(DEFAULT_HOST_MERGE_CAP_BYTES, 32_768);
        assert_eq!(MAX_CHANNELS_PER_CONNECTION, 256);
    }

    #[test]
    fn resolver_clamps_out_of_range_and_unparseable_to_fallback() {
        assert_eq!(
            resolve_initial_window_bytes(None),
            DEFAULT_INITIAL_WINDOW_BYTES
        );
        assert_eq!(
            resolve_initial_window_bytes(Some("nope")),
            DEFAULT_INITIAL_WINDOW_BYTES
        );
        assert_eq!(
            resolve_initial_window_bytes(Some("-5")),
            DEFAULT_INITIAL_WINDOW_BYTES
        );
        assert_eq!(
            resolve_initial_window_bytes(Some("1024")),
            DEFAULT_INITIAL_WINDOW_BYTES,
            "below the 16 KiB floor → fallback"
        );
        assert_eq!(
            resolve_initial_window_bytes(Some("99999999")),
            DEFAULT_INITIAL_WINDOW_BYTES,
            "above the 16 MiB ceiling → fallback"
        );
    }

    #[test]
    fn resolver_accepts_in_range_value() {
        assert_eq!(resolve_initial_window_bytes(Some("131072")), 131_072);
        assert_eq!(resolve_host_queue_capacity_bytes(Some("16384")), 16_384);
        assert_eq!(resolve_host_merge_cap_bytes(Some("65536")), 65_536);
    }

    /// The credit progress invariant: a host `.output` frame's WIRE size must stay
    /// ≤ window/2, or a sender can park permanently. Assert the default cap (payload +
    /// 13-byte header) stays under window/2 — the dead-zone the margin closes.
    #[test]
    fn output_frame_cap_respects_half_window_progress_invariant() {
        let window = DEFAULT_INITIAL_WINDOW_BYTES;
        let cap = max_output_frame_payload_bytes(DEFAULT_HOST_MERGE_CAP_BYTES, window);
        let wire = cap + 13; // 4 length + 1 type + 8 seq = max .output header
        assert!(
            wire <= window / 2,
            "max .output wire frame ({wire}) must be ≤ window/2 ({})",
            window / 2
        );
    }

    /// Cross-clamping must hold even at the smallest legal window: neither payload cap may
    /// reach window/2 (which would deadlock the credit loop).
    #[test]
    fn payload_caps_cross_clamp_at_minimum_window() {
        let window = MIN_INITIAL_WINDOW_BYTES;
        assert!(max_data_message_payload_bytes(window) < window / 2);
        assert!(max_output_frame_payload_bytes(DEFAULT_HOST_MERGE_CAP_BYTES, window) < window / 2);
    }
}
