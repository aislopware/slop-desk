//! The ctl socket's supervision vocabulary, in C —
//! `Sources/SlopDeskHost/AgentControlListener.swift` and `HostServer.swift`.
//!
//! The rule is [`slopdesk_agent::supervision`]; what is here is the marshalling.
//!
//! ## Why a four-word table needed a door
//! The four words are a CLOSED set with two independent readers — the `report` verb, which
//! validates a client's string against it, and the `events --state` filter, which parses a
//! comma-set of them. Both used to hold the set as a Swift array while the host status they map
//! FROM had already been Rust for a year, so the mapping was the last place a fifth state could be
//! added on one side only. Now the enum that maps and the table that validates are the same value.

use core::ffi::c_uchar;

use slopdesk_agent::supervision::{self, ALL, SupervisionState};

use crate::agent::status_from;
use crate::{borrow, deliver, push_text};

/// The supervision word for a host status byte, under §4's delivery convention.
///
/// An unknown byte reads as the default status, which maps to `"idle"` — a supervisor told nothing
/// is a supervisor with nothing to do, which is the safe reading of a byte this build cannot name.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_agent_supervision_state(
    status_byte: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let word = SupervisionState::from_status(status_from(status_byte)).name();
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(word.as_bytes(), out, cap) }
}

/// Whether a host status byte means an agent is PRESENT in the pane at all — the bit the four-word
/// vocabulary collapses away, and the reason an orchestrator watching `events` can see one leave.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_agent_supervision_presence(status_byte: u8) -> bool {
    supervision::presence(status_from(status_byte))
}

/// Whether `name` is one of the four supervision words. The `report` verb's validate-then-drop
/// guard, asked BEFORE it touches any session.
///
/// # Safety
/// `name` must be null or point to `len` live bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_agent_supervision_valid(name: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let bytes = unsafe { borrow(name, len) };
    core::str::from_utf8(bytes).is_ok_and(supervision::is_valid)
}

/// Every supervision word, in increasing-urgency order, as `[u32 big-endian length][UTF-8]` runs —
/// what the two error messages print when a client names something outside the set.
///
/// `count` receives how many runs were written. It is always four today; the door reports it so a
/// fifth word could not silently desynchronise a reader that had assumed the number.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes; `count` must be null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_agent_supervision_states(
    out: *mut c_uchar,
    cap: usize,
    count: *mut usize,
) -> usize {
    let mut blob: Vec<u8> = Vec::new();
    for state in ALL {
        push_text(&mut blob, state.name());
    }
    if !count.is_null() {
        // SAFETY: non-null and writable by the caller's obligation above.
        unsafe { *count = ALL.len() };
    }
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the door is the point"
)]
mod tests {
    use slopdesk_agent::status::ClaudeStatus;

    use super::{
        slopdesk_agent_supervision_presence, slopdesk_agent_supervision_state,
        slopdesk_agent_supervision_states, slopdesk_agent_supervision_valid,
    };
    use crate::agent::status_byte;
    use crate::testing::delivered;

    fn word(status: ClaudeStatus) -> String {
        // SAFETY: `delivered` asks by length first and hands back a buffer it owns.
        String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_agent_supervision_state(status_byte(status), out, cap)
        }))
        .expect("a `&'static str` crosses as its own bytes")
    }

    fn valid(name: &str) -> bool {
        // SAFETY: `name` is a live slice for the call.
        unsafe { slopdesk_agent_supervision_valid(name.as_ptr(), name.len()) }
    }

    #[test]
    fn every_status_crosses_as_its_supervision_word() {
        assert_eq!(word(ClaudeStatus::None), "idle");
        assert_eq!(word(ClaudeStatus::Idle), "idle");
        assert_eq!(word(ClaudeStatus::Working), "working");
        assert_eq!(word(ClaudeStatus::Done), "done");
        assert_eq!(word(ClaudeStatus::NeedsPermission), "blocked");
    }

    #[test]
    fn presence_is_the_bit_the_word_loses() {
        assert!(!slopdesk_agent_supervision_presence(status_byte(
            ClaudeStatus::None
        )));
        for status in ClaudeStatus::ALL.into_iter().filter(|s| *s != ClaudeStatus::None) {
            assert!(
                slopdesk_agent_supervision_presence(status_byte(status)),
                "{status:?} implies a detected agent"
            );
        }
    }

    #[test]
    fn an_unknown_byte_is_a_quiet_idle_rather_than_a_trap() {
        assert_eq!(word(ClaudeStatus::default()), "idle");
        // SAFETY: `delivered` asks by length first.
        let unknown = String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_agent_supervision_state(200, out, cap)
        }))
        .expect("still a `&'static str`");
        assert_eq!(unknown, "idle");
    }

    #[test]
    fn validation_admits_the_four_and_nothing_else() {
        for name in ["idle", "working", "done", "blocked"] {
            assert!(valid(name), "{name} is in the set");
        }
        assert!(!valid("needsPermission"));
        assert!(!valid("unknown"));
        assert!(!valid(""));
        // SAFETY: a null pointer with length 0 is what the door's contract admits.
        assert!(!unsafe { slopdesk_agent_supervision_valid(std::ptr::null(), 0) });
        // SAFETY: a live slice of bytes that are not UTF-8 — the door must refuse, not decode.
        assert!(!unsafe { slopdesk_agent_supervision_valid([0xFF_u8, 0xFE].as_ptr(), 2) });
    }

    #[test]
    fn the_table_crosses_as_four_runs_in_urgency_order() {
        let mut count = 0_usize;
        // SAFETY: `delivered` asks by length first; `count` is a live cell for both calls.
        let blob =
            delivered(|out, cap| unsafe { slopdesk_agent_supervision_states(out, cap, &raw mut count) });
        assert_eq!(count, 4);
        let mut cursor = 0_usize;
        let mut words: Vec<String> = Vec::new();
        for _ in 0..count {
            let length = u32::from_be_bytes(
                blob.get(cursor..cursor + 4)
                    .and_then(|slice| slice.try_into().ok())
                    .expect("a length prefix"),
            ) as usize;
            cursor += 4;
            words.push(
                String::from_utf8(blob.get(cursor..cursor + length).expect("a run").to_vec())
                    .expect("a `&'static str`"),
            );
            cursor += length;
        }
        assert_eq!(words, ["idle", "working", "done", "blocked"]);
        assert_eq!(cursor, blob.len(), "the delivery is exactly its runs");
    }
}
