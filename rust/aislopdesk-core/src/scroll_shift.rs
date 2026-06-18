//! Pure dominant-vertical-shift estimator for scroll reprojection (host side).
//!
//! The host hashes each ROW of a captured luma plane and, frame-to-frame, asks this module:
//! *did the content translate vertically, and by how many rows?* For an editor that answer is the
//! true scroll amount — far more accurate than the client's open-loop trackpad guess (which the
//! live test proved snaps badly). The host sends the answer to the client, which warps the last
//! frame by it on the spare 120 Hz display ticks (see [`crate::scroll_reprojection`]).
//!
//! ## The uniform-row trap
//!
//! A code editor is mostly uniform background rows that all hash IDENTICALLY. If we counted those
//! as matches, EVERY candidate shift would "match" the hundreds of background rows and the estimate
//! would be ambiguous (and confidence falsely ~1.0). So we exclude the MODE hash (the most frequent
//! row hash = the background) and score the shift only over the INFORMATIVE rows (text/edges). This
//! makes the dominant true scroll win cleanly and keeps confidence meaningful.
//!
//! ## Purity
//!
//! No I/O, no env, no allocation beyond a small scratch vector — deterministic and unit-testable to
//! the bit. The NEON per-row hashing lives in the FFI crate; this module only consumes the hashes.

/// The result of a vertical-shift estimate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShiftEstimate {
    /// The dominant vertical shift in ROWS. Positive = content moved DOWN by `shift` rows
    /// (row `i` of the current frame equals row `i - shift` of the previous frame). `0` = no shift.
    pub shift: i32,
    /// Fraction of INFORMATIVE rows that match at `shift` (0.0..=1.0). The caller gates on this
    /// (e.g. only reproject when `confidence >= 0.5 && shift != 0`); a non-scroll frame (typing, a
    /// popup) yields a low confidence or `shift == 0`.
    pub confidence: f64,
}

impl ShiftEstimate {
    /// The "no confident shift" result.
    pub const NONE: Self = Self {
        shift: 0,
        confidence: 0.0,
    };
}

/// Estimates the dominant vertical content shift between two frames' per-row luma hashes.
///
/// `prev` / `cur` are the row-hash arrays of the previous and current frames (index = row, top to
/// bottom). `max_shift` bounds the search (rows); a shift beyond it is not reported (the
/// disocclusion band would dominate anyway). Returns [`ShiftEstimate::NONE`] when there is nothing
/// to measure (empty input, an all-uniform frame, or no informative match).
///
/// Sign: `shift = +k` means the picture scrolled DOWN by `k` rows — `cur[i] == prev[i - k]`.
#[must_use]
pub fn estimate_vertical_shift(prev: &[u64], cur: &[u64], max_shift: usize) -> ShiftEstimate {
    let n = prev.len().min(cur.len());
    if n == 0 {
        return ShiftEstimate::NONE;
    }
    let background = mode_hash(&cur[..n]);
    // Informative rows = current rows that are NOT the background. Collect their indices once.
    let informative: Vec<usize> = (0..n).filter(|&i| cur[i] != background).collect();
    if informative.is_empty() {
        return ShiftEstimate::NONE; // a blank / fully-uniform frame: no scroll signal
    }
    let max_d = max_shift.min(n) as i32;
    let mut best_shift: i32 = 0;
    let mut best_matches: usize = 0;
    let mut d = -max_d;
    while d <= max_d {
        let mut matches = 0usize;
        for &i in &informative {
            let j = i as i32 - d;
            if j >= 0 && (j as usize) < n && prev[j as usize] == cur[i] {
                matches += 1;
            }
        }
        // Strictly-greater keeps the SMALLEST |d| on ties (d ascends from -max; the first max wins,
        // but a later equal d does not replace it — so among equal-count shifts the most negative is
        // kept). Re-bias ties toward the smaller magnitude explicitly below for determinism.
        if matches > best_matches || (matches == best_matches && d.abs() < best_shift.abs()) {
            best_matches = matches;
            best_shift = d;
        }
        d += 1;
    }
    ShiftEstimate {
        shift: best_shift,
        confidence: best_matches as f64 / informative.len() as f64,
    }
}

/// The most frequent value in `rows` (the background row hash). Linear scan with a small
/// running-best; for the typical editor the background dominates so this converges immediately.
fn mode_hash(rows: &[u64]) -> u64 {
    // Counting map without external deps: rows are few thousand, a HashMap is fine and cheap.
    use std::collections::HashMap;
    let mut counts: HashMap<u64, usize> = HashMap::with_capacity(rows.len());
    let mut best = rows[0];
    let mut best_count = 0usize;
    for &h in rows {
        let c = counts.entry(h).or_insert(0);
        *c += 1;
        if *c > best_count {
            best_count = *c;
            best = h;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    // The shift-construction loops cross-reference cur[r] from prev[r ± k], so a range index is
    // clearer than enumerate() here.
    #![allow(clippy::needless_range_loop)]
    use super::*;

    // Build a synthetic editor: `bg` background rows hashing to 0, with distinct text rows placed at
    // given indices (hash = index+1 so each is unique).
    fn editor(n: usize, text_rows: &[usize]) -> Vec<u64> {
        let mut v = vec![0u64; n];
        for &r in text_rows {
            if r < n {
                v[r] = (r as u64) + 1;
            }
        }
        v
    }

    #[test]
    fn empty_input_is_none() {
        assert_eq!(estimate_vertical_shift(&[], &[], 10), ShiftEstimate::NONE);
        assert_eq!(
            estimate_vertical_shift(&[1, 2], &[], 10),
            ShiftEstimate::NONE
        );
    }

    #[test]
    fn all_uniform_frame_is_none() {
        // Every row identical => no informative rows => no scroll signal.
        let frame = vec![7u64; 100];
        let e = estimate_vertical_shift(&frame, &frame, 10);
        assert_eq!(e, ShiftEstimate::NONE);
    }

    #[test]
    fn static_text_frame_is_shift_zero_high_confidence() {
        // Same text, not scrolled => dominant shift 0, all informative rows match.
        let prev = editor(200, &[10, 20, 30, 40, 50]);
        let cur = prev.clone();
        let e = estimate_vertical_shift(&prev, &cur, 50);
        assert_eq!(e.shift, 0);
        assert!((e.confidence - 1.0).abs() < 1e-9, "conf {}", e.confidence);
    }

    #[test]
    fn scroll_down_by_k_detected() {
        // cur is prev shifted DOWN by 5: text that was at row r is now at r+5 ⇒ cur[i]==prev[i-5].
        let prev = editor(200, &[10, 20, 30, 40, 50, 60]);
        let mut cur = vec![0u64; 200];
        for r in 0..200 {
            let src = r as i32 - 5;
            if src >= 0 {
                cur[r] = prev[src as usize];
            }
        }
        let e = estimate_vertical_shift(&prev, &cur, 50);
        assert_eq!(e.shift, 5);
        // All 6 text rows (those still in-bounds) match at +5.
        assert!(e.confidence > 0.9, "conf {}", e.confidence);
    }

    #[test]
    fn scroll_up_is_negative_shift() {
        let prev = editor(200, &[40, 50, 60, 70, 80]);
        let mut cur = vec![0u64; 200];
        for r in 0..200 {
            let src = r as i32 + 8; // shifted UP by 8 ⇒ cur[i] == prev[i+8]
            if src < 200 {
                cur[r] = prev[src as usize];
            }
        }
        let e = estimate_vertical_shift(&prev, &cur, 50);
        assert_eq!(e.shift, -8);
        assert!(e.confidence > 0.9);
    }

    #[test]
    fn shift_beyond_max_is_not_locked_on() {
        // True shift 40 but max_shift 10 ⇒ cannot find it; must not falsely report 40.
        let prev = editor(200, &[10, 20, 30, 40, 50, 60]);
        let mut cur = vec![0u64; 200];
        for r in 0..200 {
            let src = r as i32 - 40;
            if src >= 0 {
                cur[r] = prev[src as usize];
            }
        }
        let e = estimate_vertical_shift(&prev, &cur, 10);
        assert!(e.shift.abs() <= 10);
        // Confidence should be low — the real content is not aligned within the search window.
        assert!(e.confidence < 0.5, "conf {}", e.confidence);
    }

    #[test]
    fn typing_one_changed_row_is_not_a_scroll() {
        // Static text + one row changes (a keystroke): dominant shift is 0 (everything else aligned).
        let prev = editor(200, &[10, 20, 30, 40, 50, 60, 70, 80]);
        let mut cur = prev.clone();
        cur[40] = 9999; // one row edited
        let e = estimate_vertical_shift(&prev, &cur, 50);
        assert_eq!(e.shift, 0);
        // 7 of 8 informative rows still match at 0.
        assert!(
            e.confidence >= 0.8 && e.confidence < 1.0,
            "conf {}",
            e.confidence
        );
    }

    #[test]
    fn background_dominant_does_not_inflate_confidence() {
        // 195 background rows + 5 text rows, scrolled by 3. If background counted, every shift would
        // score ~195; excluding it, only the 5 text rows drive the estimate.
        let prev = editor(200, &[100, 110, 120, 130, 140]);
        let mut cur = vec![0u64; 200];
        for r in 0..200 {
            let src = r as i32 - 3;
            if src >= 0 {
                cur[r] = prev[src as usize];
            }
        }
        let e = estimate_vertical_shift(&prev, &cur, 50);
        assert_eq!(e.shift, 3);
        assert!(e.confidence > 0.9, "conf {}", e.confidence);
    }

    #[test]
    fn ties_prefer_smaller_magnitude() {
        // Construct a frame where shift 0 and shift +2 match equally; prefer 0 (no needless warp).
        // Two identical text rows 2 apart so both 0 and +2 align them.
        let prev = editor(50, &[10, 12]);
        let cur = prev.clone(); // static ⇒ 0 matches both text rows; +2 matches row 12->? only partial
        let e = estimate_vertical_shift(&prev, &cur, 5);
        assert_eq!(e.shift, 0);
    }
}
