//! How a typed query ranks against one candidate, and which of its characters matched.
//!
//! `rust/slopdesk-fuzzy` owns the answer — fzf's `FuzzyMatchV2`. Every search field in the app asks
//! it: the command palette, Open-Quickly, the command navigator, Jump-To.
//!
//! ## Why the answer is one blob rather than a struct
//! A match is a score and a variable number of positions, and the positions are what the caller
//! underlines. A `#[repr(C)]` struct cannot hold them without either a cap (a query longer than the
//! cap would silently under-underline) or an allocation crossing the boundary (which this door does
//! not do). So the answer takes §4's shape: `[i32 BE score][u32 BE position]*`, one call to learn
//! the size and one to read it — and the size is exactly `4 + 4 * matched`.
//!
//! A refusal is 0 bytes, which cannot be confused with a match: the score alone is already four.

use std::ffi::c_uchar;

use crate::{borrow, deliver};

/// The score and the matched positions of `query` against `candidate`.
///
/// Both strings are read as UTF-8, lossily — a candidate is a pane title, a path or a command line
/// that a foreign program wrote, and a search field is never the place to refuse one.
///
/// Returns 0 when the candidate does not carry the query's characters in order. An empty or
/// whitespace-only query matches everything with score 0 and no positions (4 bytes), which is what
/// keeps a search field's zero state in its source order.
///
/// # Safety
/// Both `(ptr, len)` pairs and `(out, cap)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_fuzzy_score(
    query: *const c_uchar,
    query_len: usize,
    candidate: *const c_uchar,
    candidate_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let (q, c) = unsafe { (borrow(query, query_len), borrow(candidate, candidate_len)) };
    let Some(found) = slopdesk_fuzzy::score(&String::from_utf8_lossy(q), &String::from_utf8_lossy(c)) else {
        return 0;
    };
    let mut answer = Vec::with_capacity(4 + 4 * found.positions.len());
    answer.extend_from_slice(&found.score.to_be_bytes());
    for position in found.positions {
        answer.extend_from_slice(&position.to_be_bytes());
    }
    // SAFETY: the caller's obligation above.
    unsafe { deliver(&answer, out, cap) }
}

/// The score alone, for a caller that will not underline anything.
///
/// `-1` is the refusal. No fzf score is ever negative — every cell is `max(…, 0)` and the answer is
/// the best cell — so the refusal cannot collide with an answer, and a score-only caller needs no
/// out-buffer, no second call and no allocation on either side of the boundary. This is most
/// callers: a filtered list ranks every row and highlights only the handful it draws.
///
/// # Safety
/// Both `(ptr, len)` pairs must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_fuzzy_rank(
    query: *const c_uchar,
    query_len: usize,
    candidate: *const c_uchar,
    candidate_len: usize,
) -> i64 {
    // SAFETY: the caller's obligation above.
    let (q, c) = unsafe { (borrow(query, query_len), borrow(candidate, candidate_len)) };
    slopdesk_fuzzy::rank(&String::from_utf8_lossy(q), &String::from_utf8_lossy(c)).map_or(-1, i64::from)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{slopdesk_fuzzy_rank, slopdesk_fuzzy_score};

    fn ask(query: &str, candidate: &str) -> Option<(i32, Vec<u32>)> {
        let mut buffer = [0_u8; 256];
        // SAFETY: every pointer names a live local for the duration of the call.
        let needed = unsafe {
            slopdesk_fuzzy_score(
                query.as_ptr(),
                query.len(),
                candidate.as_ptr(),
                candidate.len(),
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        if needed == 0 {
            return None;
        }
        let mut words = buffer
            .get(..needed)
            .unwrap_or_default()
            .chunks_exact(4)
            .filter_map(|word| <[u8; 4]>::try_from(word).ok());
        let score = words.next().map(i32::from_be_bytes).unwrap_or_default();
        Some((score, words.map(u32::from_be_bytes).collect()))
    }

    #[test]
    fn a_match_answers_its_score_and_every_position_it_underlines() {
        assert_eq!(
            ask("fm", "FuzzyMatcher"),
            Some((score_of("fm", "FuzzyMatcher"), vec![0, 5]))
        );
    }

    #[test]
    fn a_candidate_that_does_not_carry_the_query_answers_nothing() {
        assert_eq!(ask("xyz", "getConfig"), None);
    }

    #[test]
    fn an_empty_query_is_a_match_with_no_positions_rather_than_a_refusal() {
        assert_eq!(ask("", "anything"), Some((0, Vec::new())));
        assert_eq!(ask("   ", "anything"), Some((0, Vec::new())));
    }

    #[test]
    fn a_buffer_too_small_writes_nothing_and_asks_for_the_size_it_needs() {
        let query = "fm";
        let candidate = "FuzzyMatcher";
        let mut buffer = [0xAA_u8; 4];
        // SAFETY: every pointer names a live local for the duration of the call.
        let needed = unsafe {
            slopdesk_fuzzy_score(
                query.as_ptr(),
                query.len(),
                candidate.as_ptr(),
                candidate.len(),
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        assert_eq!(needed, 12, "a score and two positions");
        assert_eq!(buffer, [0xAA; 4], "an undersized buffer is left untouched");
    }

    fn score_of(query: &str, candidate: &str) -> i32 {
        slopdesk_fuzzy::score(query, candidate).map_or(0, |m| m.score)
    }

    fn ranked(query: &str, candidate: &str) -> i64 {
        // SAFETY: both pointers name a live local for the duration of the call.
        unsafe { slopdesk_fuzzy_rank(query.as_ptr(), query.len(), candidate.as_ptr(), candidate.len()) }
    }

    #[test]
    fn the_score_only_door_agrees_with_the_one_that_underlines() {
        assert_eq!(
            ranked("fm", "FuzzyMatcher"),
            i64::from(score_of("fm", "FuzzyMatcher"))
        );
        assert_eq!(ranked("", "anything"), 0, "an empty query still ranks everything");
    }

    #[test]
    fn a_refusal_is_negative_and_no_score_ever_is() {
        assert_eq!(ranked("xyz", "getConfig"), -1);
        for candidate in ["a", "-", "café", "Sources/SlopDeskClientUI"] {
            assert!(
                ranked("a", candidate) >= -1,
                "a rank is a score or the one refusal"
            );
        }
    }
}
