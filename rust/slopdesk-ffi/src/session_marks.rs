//! What a pane's client session decides, in C.
//!
//! The rules are `slopdesk_clientsession`; what is here is the marshalling.
//!
//! ## The machine crosses by value, in place
//! §4b: the near side reads every field — the two marks it presents and acks, the probe it resolves
//! the resume verdict against, the flag its ticker flushes — so there is nothing to own and nothing
//! to hand back a handle to. The session is four integers and a flag, held by the driver as one
//! `var`, and each entry point takes a pointer to that `var` and steps it where it already lives.
//! No allocation crosses in either direction, and the answer is a verdict byte.
//!
//! ## The bytes never come with it
//! [`slopdesk_pane_session_deliver`] is handed a SEQ, not a payload. Whether the chunk is fed to
//! the surface, appended to the inbox, or dropped and credited is the near side's to do — it
//! already holds the `Data` and the transport that granted its window. A door that took the bytes
//! to answer "have I seen this one" would be crossing a screenful of output to learn one bit.
//!
//! ## The retry ladder is nanoseconds
//! The near side's duration type carries attoseconds. Milliseconds would silently round a schedule
//! configured in fractions of one, so the ladder crosses in nanoseconds, which is exact for every
//! wait it can express and saturates only past a hundred days.

use core::ffi::c_uchar;

use slopdesk_clientsession::backoff::{self, Backoff, DIRECT_RECONNECT_ATTEMPTS, MAX_RECONNECT_ATTEMPTS};
use slopdesk_clientsession::gates::{self, Refusal};
use slopdesk_clientsession::rtt;
use slopdesk_clientsession::seq::{Adoption, Delivery, ResumeOutcome, Session};

use crate::deliver;

/// The client session's marks, whole, as they cross.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskPaneSession {
    /// Highest seq fed to the surface — the dedup high-water bound.
    pub highest_fed: i64,
    /// Highest CONTIGUOUS seq delivered — what is acked and what the next open presents.
    pub highest_contiguous: i64,
    /// The `lastReceivedSeq` the running connection presented.
    pub presented_resume_seq: i64,
    /// The resume verdict: `0` undetermined · `1` a fresh shell · `2` the same shell resumed.
    pub outcome: c_uchar,
    /// Whether a contiguous advance is waiting for the ack ticker.
    pub ack_pending: bool,
}

/// One retry schedule, whole, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPaneBackoff {
    /// The wait before the first retry, in nanoseconds.
    pub initial_ns: u64,
    /// The ceiling, in nanoseconds.
    pub maximum_ns: u64,
    /// What each step multiplies by.
    pub multiplier: f64,
}

/// The session `crossing` stands for.
const fn session_of(crossing: SlopDeskPaneSession) -> Session {
    Session {
        highest_fed: crossing.highest_fed,
        highest_contiguous: crossing.highest_contiguous,
        presented_resume_seq: crossing.presented_resume_seq,
        outcome: ResumeOutcome::from_code(crossing.outcome),
        ack_pending: crossing.ack_pending,
    }
}

/// How `session` crosses back.
const fn crossing_of(session: Session) -> SlopDeskPaneSession {
    SlopDeskPaneSession {
        highest_fed: session.highest_fed,
        highest_contiguous: session.highest_contiguous,
        presented_resume_seq: session.presented_resume_seq,
        outcome: session.outcome.code(),
        ack_pending: session.ack_pending,
    }
}

/// The schedule `crossing` stands for.
const fn backoff_of(crossing: SlopDeskPaneBackoff) -> Backoff {
    Backoff {
        initial_ns: crossing.initial_ns,
        maximum_ns: crossing.maximum_ns,
        multiplier: crossing.multiplier,
    }
}

/// The marks a RESTORED pane starts from: both already at the seq it last rendered, so its first
/// `channelOpen` presents that seq and the host replays only what follows.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_session_seeded(last_seq: i64) -> SlopDeskPaneSession {
    crossing_of(Session::seeded(last_seq))
}

/// Adopts a connection that finished its handshake, stepping `session` in place.
///
/// `presented_resume_seq` is the `lastReceivedSeq` that connection's open carried — read BEFORE
/// this call, because the reset it may perform clears the mark it came from. `resume_from_seq` is
/// the HOST's answer from the open ack, and it is the only correct signal: the near side's
/// "returning client" flag is true on every reconnect, so gating on it would skip the reset exactly
/// when it is needed.
///
/// Answers `0` when the marks were KEPT and `1` when they were CLEARED. `1` leaves the caller one
/// thing to do that this door cannot: zero the wire credit on anything still sitting in its inbox,
/// because the new channel's peer never sent those bytes. The bytes themselves stay — they are the
/// only copy of that output.
///
/// # Safety
/// `session` must be null or point to one writable [`SlopDeskPaneSession`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the machine pointer is the caller's"
)]
pub const unsafe extern "C" fn slopdesk_pane_session_adopt(
    session: *mut SlopDeskPaneSession,
    presented_resume_seq: i64,
    resume_from_seq: i64,
) -> c_uchar {
    if session.is_null() {
        return Adoption::MarksKept.code();
    }
    // SAFETY: non-null and writable for one struct by the caller's obligation above.
    let mut stepped = session_of(unsafe { session.read() });
    let verdict = stepped.adopt(presented_resume_seq, resume_from_seq);
    // SAFETY: as above.
    unsafe { session.write(crossing_of(stepped)) };
    verdict.code()
}

/// Folds one inbound `output` seq, stepping `session` in place.
///
/// Answers `0` for a DUPLICATE — drop the bytes and still credit them, because they crossed the
/// wire and were fully processed by being discarded — and `1` for one that is new.
///
/// # Safety
/// `session` must be null or point to one writable [`SlopDeskPaneSession`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the machine pointer is the caller's"
)]
pub const unsafe extern "C" fn slopdesk_pane_session_deliver(
    session: *mut SlopDeskPaneSession,
    seq: i64,
) -> c_uchar {
    if session.is_null() {
        return Delivery::Duplicate.code();
    }
    // SAFETY: non-null and writable for one struct by the caller's obligation above.
    let mut stepped = session_of(unsafe { session.read() });
    let verdict = stepped.deliver(seq);
    // SAFETY: as above.
    unsafe { session.write(crossing_of(stepped)) };
    verdict.code()
}

/// What the coalescing ticker should ack, stepping `session` in place.
///
/// Answers whether there is anything to send, writing the seq to `seq` only when there is. The
/// pending flag clears eitherway: a flush with nothing delivered has answered the tick, and
/// re-arming it would spin the ticker against a mark that cannot move on its own.
///
/// # Safety
/// `session` must be null or point to one writable [`SlopDeskPaneSession`], and `seq` null or
/// writable for one `int64_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub const unsafe extern "C" fn slopdesk_pane_session_ack(
    session: *mut SlopDeskPaneSession,
    seq: *mut i64,
) -> bool {
    if session.is_null() {
        return false;
    }
    // SAFETY: non-null and writable for one struct by the caller's obligation above.
    let mut stepped = session_of(unsafe { session.read() });
    let answer = stepped.ack();
    // SAFETY: as above.
    unsafe { session.write(crossing_of(stepped)) };
    if let (Some(found), false) = (answer, seq.is_null()) {
        // SAFETY: non-null and writable for one `i64` by the caller's obligation above.
        unsafe { seq.write(found) };
    }
    answer.is_some()
}

/// Re-arms the ack after a send failed, so the next live transport says it instead.
///
/// # Safety
/// `session` must be null or point to one writable [`SlopDeskPaneSession`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the machine pointer is the caller's"
)]
pub const unsafe extern "C" fn slopdesk_pane_session_ack_failed(session: *mut SlopDeskPaneSession) {
    if session.is_null() {
        return;
    }
    // SAFETY: non-null and writable for one struct by the caller's obligation above.
    let mut stepped = session_of(unsafe { session.read() });
    stepped.ack_failed();
    // SAFETY: as above.
    unsafe { session.write(crossing_of(stepped)) };
}

/// The inbound stream ended: drops the resume verdict and nothing else.
///
/// # Safety
/// `session` must be null or point to one writable [`SlopDeskPaneSession`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the machine pointer is the caller's"
)]
pub const unsafe extern "C" fn slopdesk_pane_session_stream_ended(session: *mut SlopDeskPaneSession) {
    if session.is_null() {
        return;
    }
    // SAFETY: non-null and writable for one struct by the caller's obligation above.
    let mut stepped = session_of(unsafe { session.read() });
    stepped.stream_ended();
    // SAFETY: as above.
    unsafe { session.write(crossing_of(stepped)) };
}

/// Folds one pong into the smoothed round trip.
///
/// §4: the previous reading is a value plus a flag, and so is the answer. `false` back means there
/// is nothing to surface and the previous reading stands — which happens only for an echo dated
/// after the instant it arrived at, a thing a monotonic clock cannot produce honestly.
///
/// # Safety
/// `smoothed` must be null or writable for one `double`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the out-slot is the caller's"
)]
pub unsafe extern "C" fn slopdesk_pane_session_rtt(
    now_ms: u64,
    sent_at_ms: u64,
    has_previous: bool,
    previous: f64,
    smoothed: *mut f64,
) -> bool {
    let previous = has_previous.then_some(previous);
    let Some(reading) = rtt::fold(now_ms, sent_at_ms, previous) else {
        return false;
    };
    if !smoothed.is_null() {
        // SAFETY: non-null and writable for one `f64` by the caller's obligation above.
        unsafe { smoothed.write(reading) };
    }
    true
}

/// Why a client refuses to open a channel: `0` it does not · `1` closed · `2` the child exited ·
/// `3` the host closed this pane's channel.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_session_connect_refusal(
    closed: bool,
    child_exited: bool,
    host_closed: bool,
) -> c_uchar {
    match gates::connect_refusal(closed, child_exited, host_closed) {
        Some(refusal) => refusal.code(),
        None => 0,
    }
}

/// What the error thrown for refusal `code` says. `0` back for a code that is not a refusal.
///
/// # Safety
/// `out` must be null or writable for `capacity` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the out-buffer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_pane_session_refusal_reason(
    code: c_uchar,
    out: *mut c_uchar,
    capacity: usize,
) -> usize {
    let reason = Refusal::from_code(code).map_or("", Refusal::reason);
    // SAFETY: `out` is null or writable for `capacity` bytes by the caller's obligation.
    unsafe { deliver(reason.as_bytes(), out, capacity) }
}

/// Whether a freshly-handshaken transport may be ADOPTED, or must be closed and discarded because
/// the client was closed, paused, cancelled, or superseded by a newer connect while it was built.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_session_adopts(
    closed: bool,
    paused: bool,
    cancelled: bool,
    superseded: bool,
) -> bool {
    gates::adopts(closed, paused, cancelled, superseded)
}

/// Whether the end of an inbound stream is announced as a real drop, or is one of the three
/// expected ends — a deliberate close, this driver's own teardown, or the post-exit FIN.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_session_announces_drop(
    closed: bool,
    tearing_down: bool,
    child_exited: bool,
) -> bool {
    gates::announces_drop(closed, tearing_down, child_exited)
}

/// Whether a reconnect campaign may start, or take another turn.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_session_campaign_runs(
    paused: bool,
    closed: bool,
    child_exited: bool,
    host_closed: bool,
) -> bool {
    gates::campaign_runs(paused, closed, child_exited, host_closed)
}

/// The shipped retry schedule: a quarter second, doubling to a two-second ceiling.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_backoff_default() -> SlopDeskPaneBackoff {
    let shipped = Backoff::default();
    SlopDeskPaneBackoff {
        initial_ns: shipped.initial_ns,
        maximum_ns: shipped.maximum_ns,
        multiplier: shipped.multiplier,
    }
}

/// The wait after `current_ns`, capped at the schedule's ceiling.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_backoff_next_after(schedule: SlopDeskPaneBackoff, current_ns: u64) -> u64 {
    backoff_of(schedule).next_after(current_ns)
}

/// The wait BEFORE the `attempt`-th retry, one-indexed — the closed form of the ladder above.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_backoff_delay(schedule: SlopDeskPaneBackoff, attempt: u32) -> u64 {
    backoff_of(schedule).delay_for_attempt(attempt)
}

/// How many attempts one SUPERVISED campaign makes before giving up.
///
/// The single source of truth for the ceiling: the app-global supervisor and the "attempt N of M"
/// copy both read it from here, so a mismatch cannot render an impossible "attempt 25 of 20".
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_backoff_max_attempts() -> u32 {
    MAX_RECONNECT_ATTEMPTS
}

/// How many attempts the DIRECT, awaited reconnect makes before throwing the last error.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_backoff_direct_attempts() -> u32 {
    DIRECT_RECONNECT_ATTEMPTS
}

/// Whether a supervised campaign has run out of attempts, asked after the counter advances.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_backoff_exhausted(attempt: u32) -> bool {
    backoff::exhausted(attempt)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]
    #![expect(
        clippy::float_cmp,
        reason = "the round trip is a bit-exact value; an epsilon would stop noticing a re-rounding"
    )]

    use super::{
        SlopDeskPaneSession, slopdesk_pane_backoff_default, slopdesk_pane_backoff_delay,
        slopdesk_pane_backoff_direct_attempts, slopdesk_pane_backoff_exhausted,
        slopdesk_pane_backoff_max_attempts, slopdesk_pane_backoff_next_after, slopdesk_pane_session_ack,
        slopdesk_pane_session_ack_failed, slopdesk_pane_session_adopt, slopdesk_pane_session_adopts,
        slopdesk_pane_session_announces_drop, slopdesk_pane_session_campaign_runs,
        slopdesk_pane_session_connect_refusal, slopdesk_pane_session_deliver,
        slopdesk_pane_session_refusal_reason, slopdesk_pane_session_rtt, slopdesk_pane_session_seeded,
        slopdesk_pane_session_stream_ended,
    };
    use crate::testing::delivered;

    /// The whole reconnect story, through the doors alone, in the order the WIRE produces it: a
    /// restored pane presents its mark, the host honours the resume and replays only past that
    /// mark, so the first seq is the live one — a late duplicate behind it drops without
    /// revising anything.
    #[test]
    fn a_warm_reattach_crosses_end_to_end() {
        let mut session = slopdesk_pane_session_seeded(7);
        assert_eq!(session.highest_contiguous, 7);

        // SAFETY: the machine is a live local for every call below.
        unsafe {
            assert_eq!(
                slopdesk_pane_session_adopt(&raw mut session, 7, 8),
                0,
                "the marks are kept"
            );
            assert_eq!(slopdesk_pane_session_deliver(&raw mut session, 8), 1);
            assert_eq!(session.outcome, 2, "the same shell resumed");
            assert_eq!(
                slopdesk_pane_session_deliver(&raw mut session, 5),
                0,
                "already rendered"
            );
            assert_eq!(session.outcome, 2, "and a late duplicate revises nothing");

            let mut acked = 0_i64;
            assert!(slopdesk_pane_session_ack(&raw mut session, &raw mut acked));
            assert_eq!(acked, 8);
            assert!(
                !slopdesk_pane_session_ack(&raw mut session, &raw mut acked),
                "once each"
            );
        }
    }

    /// A fresh shell clears the marks, so its seq 1 is not mistaken for a duplicate of a session
    /// that is gone — the failure this door exists to prevent.
    #[test]
    fn a_fresh_shell_clears_the_marks_and_says_so() {
        let mut session = slopdesk_pane_session_seeded(42);
        // SAFETY: the machine is a live local for every call below.
        unsafe {
            assert_eq!(slopdesk_pane_session_adopt(&raw mut session, 42, 0), 1, "cleared");
            assert_eq!(session.highest_fed, 0);
            assert_eq!(slopdesk_pane_session_deliver(&raw mut session, 1), 1);
            assert_eq!(session.outcome, 1, "a fresh shell");
        }
    }

    /// A failed ack is re-armed, and a stream end drops only the verdict.
    #[test]
    fn the_re_arm_and_the_stream_end_cross() {
        let mut session = SlopDeskPaneSession::default();
        // SAFETY: the machine and the out-slot are live locals for every call below.
        unsafe {
            slopdesk_pane_session_deliver(&raw mut session, 4);
            let mut acked = 0_i64;
            assert!(slopdesk_pane_session_ack(&raw mut session, &raw mut acked));
            slopdesk_pane_session_ack_failed(&raw mut session);
            assert!(slopdesk_pane_session_ack(&raw mut session, &raw mut acked));
            assert_eq!(acked, 4);

            slopdesk_pane_session_deliver(&raw mut session, 5);
            slopdesk_pane_session_stream_ended(&raw mut session);
            assert_eq!(session.outcome, 0);
            assert_eq!(
                session.highest_contiguous, 5,
                "what was delivered survives the drop"
            );
            assert!(session.ack_pending);
        }
    }

    /// A null machine is answered rather than dereferenced, and the answer is the one that does
    /// nothing: drop the chunk, keep the marks, say no ack is owed.
    #[test]
    fn a_null_machine_is_answered_not_dereferenced() {
        // SAFETY: a null machine is the documented way to ask a door to do nothing.
        unsafe {
            assert_eq!(slopdesk_pane_session_deliver(core::ptr::null_mut(), 9), 0);
            assert_eq!(slopdesk_pane_session_adopt(core::ptr::null_mut(), 1, 0), 0);
            assert!(!slopdesk_pane_session_ack(
                core::ptr::null_mut(),
                core::ptr::null_mut()
            ));
            slopdesk_pane_session_ack_failed(core::ptr::null_mut());
            slopdesk_pane_session_stream_ended(core::ptr::null_mut());
        }
    }

    /// A null seq slot still answers WHETHER there is an ack owed.
    #[test]
    fn a_null_seq_slot_still_answers() {
        let mut session = SlopDeskPaneSession::default();
        // SAFETY: the machine is a live local; a null out-slot is the documented way to skip it.
        unsafe {
            slopdesk_pane_session_deliver(&raw mut session, 3);
            assert!(slopdesk_pane_session_ack(&raw mut session, core::ptr::null_mut()));
        }
    }

    /// The round trip crosses as a value plus a flag, and an impossible echo says nothing.
    #[test]
    fn the_round_trip_crosses_with_its_flag() {
        let mut smoothed = -1.0_f64;
        // SAFETY: the out-slot is a live local for every call below.
        unsafe {
            assert!(slopdesk_pane_session_rtt(
                1_100,
                1_000,
                false,
                0.0,
                &raw mut smoothed
            ));
            assert_eq!(smoothed, 100.0);
            assert!(slopdesk_pane_session_rtt(
                1_300,
                1_000,
                true,
                100.0,
                &raw mut smoothed
            ));
            assert_eq!(smoothed, 100.0 * 0.75 + 300.0 * 0.25);

            smoothed = 42.0;
            assert!(!slopdesk_pane_session_rtt(
                1_000,
                1_001,
                true,
                42.0,
                &raw mut smoothed
            ));
            assert_eq!(smoothed, 42.0, "the previous reading stands");
            assert!(slopdesk_pane_session_rtt(
                1_000,
                1_000,
                false,
                0.0,
                core::ptr::null_mut()
            ));
        }
    }

    /// Every refusal crosses with its sentence, and a code that is not one says nothing.
    #[test]
    fn every_refusal_crosses_with_its_sentence() {
        assert_eq!(slopdesk_pane_session_connect_refusal(false, false, false), 0);
        assert_eq!(slopdesk_pane_session_connect_refusal(true, true, true), 1);
        assert_eq!(slopdesk_pane_session_connect_refusal(false, true, true), 2);
        assert_eq!(slopdesk_pane_session_connect_refusal(false, false, true), 3);

        let say = |code: u8| {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_pane_session_refusal_reason(code, out, cap) }
            });
            String::from_utf8_lossy(&blob).into_owned()
        };
        assert_eq!(say(1), "connect after close");
        assert_eq!(say(2), "connect after child exit");
        assert_eq!(say(3), "connect after host closed the channel");
        assert_eq!(say(0), "");
        assert_eq!(say(200), "");
    }

    /// The three yes-or-no gates cross unchanged.
    #[test]
    fn the_gates_cross_unchanged() {
        assert!(slopdesk_pane_session_adopts(false, false, false, false));
        assert!(!slopdesk_pane_session_adopts(false, false, false, true));
        assert!(slopdesk_pane_session_announces_drop(false, false, false));
        assert!(!slopdesk_pane_session_announces_drop(false, true, false));
        assert!(slopdesk_pane_session_campaign_runs(false, false, false, false));
        assert!(!slopdesk_pane_session_campaign_runs(false, false, false, true));
    }

    /// The shipped ladder crosses in nanoseconds, and the two ceilings cross as themselves.
    #[test]
    fn the_ladder_crosses_in_nanoseconds() {
        let shipped = slopdesk_pane_backoff_default();
        assert_eq!(shipped.initial_ns, 250_000_000);
        assert_eq!(slopdesk_pane_backoff_delay(shipped, 1), 250_000_000);
        assert_eq!(slopdesk_pane_backoff_delay(shipped, 3), 1_000_000_000);
        assert_eq!(slopdesk_pane_backoff_delay(shipped, 99), 2_000_000_000);
        assert_eq!(
            slopdesk_pane_backoff_next_after(shipped, 250_000_000),
            500_000_000
        );

        let ceiling = slopdesk_pane_backoff_max_attempts();
        assert_eq!(ceiling, 20);
        assert_eq!(slopdesk_pane_backoff_direct_attempts(), 64);
        assert!(!slopdesk_pane_backoff_exhausted(ceiling));
        assert!(slopdesk_pane_backoff_exhausted(ceiling + 1));
    }
}
