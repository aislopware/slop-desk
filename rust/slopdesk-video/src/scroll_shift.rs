//! The dominant-vertical-shift estimator: how far the picture scrolled between two frames.
//!
//! The host hashes each row of a captured luma plane ([`crate::frame_hash`]) and asks, frame to
//! frame: *did the content translate vertically, and by how many rows?* For an editor that answer
//! is the true scroll amount, and the client can warp the last frame by it on a spare 120 Hz tick
//! instead of waiting for the encoder.
//!
//! ## The uniform-row trap this is built around
//!
//! A code editor is mostly uniform background rows that all hash IDENTICALLY. Counted as matches,
//! EVERY candidate shift would "match" hundreds of background rows and the confidence would be a
//! false ~1.0. So the MODE hash — the background — is excluded, and a shift is scored only over the
//! INFORMATIVE rows: the text and the edges, the only rows whose motion means anything.

use std::collections::HashMap;

use crate::frame_hash::LumaPlane;

/// The result of a vertical-shift estimate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShiftEstimate {
    /// The dominant vertical shift in ROWS. Positive means the content moved DOWN by `shift` rows —
    /// row `i` of the current frame is row `i - shift` of the previous one. `0` is no shift.
    pub shift: i32,
    /// The fraction of INFORMATIVE rows that match at `shift`, in `0.0..=1.0`. The caller gates on
    /// this; the estimator itself never decides that a shift is good enough to act on.
    pub confidence: f64,
    /// The inclusive `[top, bottom]` CURRENT-frame row span of the informative rows that translated
    /// by `shift` — the vertical extent of the MOVING content, with the chrome excluded. `None`
    /// when there is no confident non-zero shift, because a zero shift has nothing to reproject.
    pub band: Option<(usize, usize)>,
}

impl ShiftEstimate {
    /// The "nothing to measure" result: no shift, no confidence, no band.
    pub const NONE: Self = Self {
        shift: 0,
        confidence: 0.0,
        band: None,
    };

    /// The confidence as thousandths, in `0..=1000` — the form the gate on the other side reads.
    ///
    /// The clamp precedes the scale and the scale precedes the round, and each stays its own
    /// operation: the caller's gate is an integer comparison against this value, so a fused or
    /// reordered arithmetic here would move the threshold rather than round differently. A
    /// confidence outside `0.0..=1.0` cannot arise from [`estimate_vertical_shift`] — it is a count
    /// over its own denominator — so the clamp is the guard on a value that was computed elsewhere,
    /// not a correction of this one.
    #[must_use]
    pub fn confidence_milli(&self) -> u32 {
        let bounded = self.confidence.clamp(0.0, 1.0) * 1000.0;
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "clamped to `[0, 1]` and scaled by 1000 before the round, so the value is in `0..=1000`"
        )]
        let milli = bounded.round() as u32;
        milli
    }
}

impl Default for ShiftEstimate {
    fn default() -> Self {
        Self::NONE
    }
}

/// The most frequent value among the first `n` row hashes — the background.
///
/// A linear scan with a running best, so the winner is the value that first reached its count in
/// row order: the tie-break is the picture's own top-to-bottom order and not the map's.
fn mode_hash(rows: &[u64], n: usize) -> u64 {
    let mut counts: HashMap<u64, usize> = HashMap::with_capacity(n);
    let mut best = rows.first().copied().unwrap_or(0);
    let mut best_count = 0;
    for &hash in rows.iter().take(n) {
        let count = counts.entry(hash).or_insert(0);
        *count += 1;
        if *count > best_count {
            best_count = *count;
            best = hash;
        }
    }
    best
}

/// How many informative rows still match after translating the current frame by `shift`.
fn matches_at(prev: &[u64], cur: &[u64], n: usize, informative: &[usize], shift: i32) -> usize {
    informative
        .iter()
        .filter(|&&row| matched_row(prev, cur, n, row, shift))
        .count()
}

/// Whether current-frame row `row` is previous-frame row `row - shift`: both inside the compared
/// span `0..n`, and equal.
fn matched_row(prev: &[u64], cur: &[u64], n: usize, row: usize, shift: i32) -> bool {
    let Some(source) = i32::try_from(row).ok().and_then(|index| index.checked_sub(shift)) else {
        return false;
    };
    let Ok(source) = usize::try_from(source) else {
        return false; // the row translated in from off-frame: nothing to compare it against
    };
    if source >= n {
        return false;
    }
    match (prev.get(source), cur.get(row)) {
        (Some(before), Some(after)) => before == after,
        _ => false,
    }
}

/// Estimates the dominant vertical content shift between two frames' per-row luma hashes.
///
/// `prev` and `cur` are row-hash arrays indexed top to bottom; `max_shift` bounds the search in
/// rows. Returns [`ShiftEstimate::NONE`] when there is nothing to measure: empty input, a
/// fully-uniform frame, or no informative match at any shift.
#[must_use]
pub fn estimate_vertical_shift(prev: &[u64], cur: &[u64], max_shift: usize) -> ShiftEstimate {
    let n = prev.len().min(cur.len());
    if n == 0 {
        return ShiftEstimate::NONE;
    }
    let background = mode_hash(cur, n);
    let informative: Vec<usize> = (0..n)
        .filter(|&row| cur.get(row).copied() != Some(background))
        .collect();
    if informative.is_empty() {
        return ShiftEstimate::NONE; // a blank or fully-uniform frame carries no scroll signal
    }

    let max_d = i32::try_from(max_shift.min(n)).unwrap_or(i32::MAX);
    let mut best_shift = 0_i32;
    let mut best_matches = 0;
    for shift in -max_d..=max_d {
        let matches = matches_at(prev, cur, n, &informative, shift);
        // Strictly-greater keeps the earlier (more negative) shift on a tie; the explicit magnitude
        // re-bias then prefers the smaller movement, so a tie resolves to the calmer answer.
        if matches > best_matches
            || (matches == best_matches && shift.unsigned_abs() < best_shift.unsigned_abs())
        {
            best_matches = matches;
            best_shift = shift;
        }
    }

    // The moving-content band: the inclusive row span of the informative rows that actually
    // translated by the winning shift. Only meaningful for a real, matched, non-zero scroll.
    let band = if best_shift != 0 && best_matches > 0 {
        let mut top = None;
        let mut bottom = 0;
        for &row in &informative {
            if matched_row(prev, cur, n, row, best_shift) {
                top.get_or_insert(row);
                bottom = row;
            }
        }
        top.map(|first| (first, bottom))
    } else {
        None
    };

    #[expect(
        clippy::cast_precision_loss,
        reason = "both counts are row counts, bounded by `MAX_PLANE_DIMENSION`, and so are exact in an f64 \
                  by four orders of magnitude"
    )]
    // A plain division, never a reciprocal multiply: the confidence is compared against a
    // configured gate on both sides of the port.
    let confidence = best_matches as f64 / informative.len() as f64;
    ShiftEstimate {
        shift: best_shift,
        confidence,
        band,
    }
}

/// Estimates the dominant vertical content shift between two locked NV12 luma planes.
///
/// `quantize_shift` (`0..=7`) right-shifts each luma byte before row-hashing, so real capture noise
/// no longer breaks the exact row match; `0` is the exact, byte-for-byte path. A degenerate
/// dimension or an overflowing stride is a defined "no measurement", never a fault.
#[must_use]
pub fn estimate_nv12(
    prev: LumaPlane<'_>,
    cur: LumaPlane<'_>,
    width: usize,
    height: usize,
    max_shift: usize,
    quantize_shift: u8,
) -> ShiftEstimate {
    let (Some(prev_rows), Some(cur_rows)) = (
        prev.row_hashes(width, height, quantize_shift),
        cur.row_hashes(width, height, quantize_shift),
    ) else {
        return ShiftEstimate::NONE;
    };
    estimate_vertical_shift(&prev_rows, &cur_rows, max_shift)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::cast_possible_truncation,
        reason = "the synthetic planes are built from small row/column arithmetic, and a wrapped byte would \
                  still be a deterministic byte"
    )]
    #![expect(
        clippy::float_cmp,
        reason = "a confidence of exactly zero is the property under test — no informative row matched at \
                  any shift — and not a computed value that happens to be near it"
    )]

    use super::{ShiftEstimate, estimate_nv12, estimate_vertical_shift};
    use crate::frame_hash::LumaPlane;

    /// Rows that are all the same value are the background; the rest carry the signal.
    fn frame(rows: &[u64]) -> Vec<u64> {
        rows.to_vec()
    }

    #[test]
    fn nothing_to_measure_is_the_none_estimate() {
        assert_eq!(estimate_vertical_shift(&[], &[], 8), ShiftEstimate::NONE);
        assert_eq!(estimate_vertical_shift(&[1, 2, 3], &[], 8), ShiftEstimate::NONE);
        // Every row identical: the whole frame is background, so there is no informative row.
        assert_eq!(
            estimate_vertical_shift(&[7; 16], &[7; 16], 8),
            ShiftEstimate::NONE
        );
    }

    #[test]
    fn a_clean_scroll_down_reads_as_a_positive_shift() {
        let prev = frame(&[0, 0, 11, 12, 13, 0, 0, 0]);
        let cur = frame(&[0, 0, 0, 0, 11, 12, 13, 0]);
        let estimate = estimate_vertical_shift(&prev, &cur, 4);
        assert_eq!(estimate.shift, 2);
        assert!((estimate.confidence - 1.0).abs() < f64::EPSILON);
        assert_eq!(estimate.band, Some((4, 6)));
    }

    #[test]
    fn a_clean_scroll_up_reads_as_a_negative_shift() {
        let prev = frame(&[0, 0, 0, 21, 22, 23, 0, 0]);
        let cur = frame(&[0, 21, 22, 23, 0, 0, 0, 0]);
        let estimate = estimate_vertical_shift(&prev, &cur, 4);
        assert_eq!(estimate.shift, -2);
        assert_eq!(estimate.band, Some((1, 3)));
    }

    /// The uniform-row trap: a still frame must read as a zero shift at full confidence, and the
    /// background rows must not be what earned that confidence.
    #[test]
    fn a_still_frame_is_a_zero_shift_and_carries_no_band() {
        let rows = frame(&[0, 0, 5, 6, 0, 0, 7, 0]);
        let estimate = estimate_vertical_shift(&rows, &rows, 4);
        assert_eq!(estimate.shift, 0);
        assert!((estimate.confidence - 1.0).abs() < f64::EPSILON);
        assert_eq!(estimate.band, None, "a zero shift has nothing to reproject");
    }

    /// Partial agreement is the case the caller's gate exists for.
    #[test]
    fn a_partial_match_reports_the_fraction_that_moved() {
        let prev = frame(&[0, 31, 32, 0, 0, 0]);
        let cur = frame(&[0, 0, 31, 99, 0, 0]);
        let estimate = estimate_vertical_shift(&prev, &cur, 3);
        assert_eq!(estimate.shift, 1);
        // Two informative rows in `cur` (31 and 99); only the 31 translated by one row.
        assert!((estimate.confidence - 0.5).abs() < f64::EPSILON);
        assert_eq!(estimate.band, Some((2, 2)));
    }

    /// The search cannot report a shift it was never allowed to consider.
    #[test]
    fn the_search_stays_inside_the_max_shift() {
        let prev = frame(&[41, 42, 0, 0, 0, 0, 0, 0]);
        let cur = frame(&[0, 0, 0, 0, 0, 0, 41, 42]);
        assert_eq!(estimate_vertical_shift(&prev, &cur, 2).shift, 0);
        assert_eq!(estimate_vertical_shift(&prev, &cur, 6).shift, 6);
        // A zero bound admits only the zero shift.
        assert_eq!(estimate_vertical_shift(&prev, &cur, 0).shift, 0);
    }

    /// Two shifts that match equally often resolve to the smaller movement, every run.
    #[test]
    fn a_tie_resolves_to_the_smaller_movement() {
        // Row 3 is the only informative row, and it matches at both -1 and +1.
        let prev = frame(&[0, 51, 0, 51, 0]);
        let cur = frame(&[0, 0, 0, 51, 0]);
        let estimate = estimate_vertical_shift(&prev, &cur, 2);
        assert_eq!(estimate.shift, 0, "the still reading wins the tie against +2");
    }

    #[test]
    fn the_plane_entry_measures_the_same_scroll_the_row_hashes_do() {
        let width = 8;
        let height = 8;
        let stride = 12;
        let mut prev = vec![0_u8; stride * height];
        let mut cur = vec![0_u8; stride * height];
        // Three distinct content rows, moved down by two rows between the frames.
        for row in 0..3_usize {
            for column in 0..width {
                let value = (row * 40 + column * 3 + 1) as u8;
                if let Some(slot) = prev.get_mut(row * stride + column) {
                    *slot = value;
                }
                if let Some(slot) = cur.get_mut((row + 2) * stride + column) {
                    *slot = value;
                }
            }
        }
        let estimate = estimate_nv12(
            LumaPlane::new(&prev, stride),
            LumaPlane::new(&cur, stride),
            width,
            height,
            4,
            0,
        );
        assert_eq!(estimate.shift, 2);
        assert_eq!(estimate.band, Some((2, 4)));
    }

    #[test]
    fn an_unmeasurable_plane_is_no_measurement_rather_than_a_fault() {
        let plane = vec![0_u8; 64];
        let degenerate = estimate_nv12(LumaPlane::new(&plane, 8), LumaPlane::new(&plane, 8), 0, 8, 4, 0);
        assert_eq!(degenerate, ShiftEstimate::NONE);
        let overflowing = estimate_nv12(
            LumaPlane::new(&plane, usize::MAX),
            LumaPlane::new(&plane, usize::MAX),
            8,
            8,
            4,
            0,
        );
        assert_eq!(overflowing, ShiftEstimate::NONE);
    }

    /// Quantizing is what makes a real captured scroll measurable at all: one noisy low bit per row
    /// is enough to collapse the exact-match confidence to nothing.
    #[test]
    fn quantizing_rescues_a_scroll_that_capture_noise_would_hide() {
        let width = 16;
        let height = 8;
        let mut prev = vec![0_u8; width * height];
        let mut cur = vec![0_u8; width * height];
        for row in 0..4_usize {
            for column in 0..width {
                let value = (row * 20 + column * 5 + 3) as u8;
                if let Some(slot) = prev.get_mut(row * width + column) {
                    *slot = value;
                }
                // The same content one row down, with a ±1 LSB of capture noise on every pixel.
                if let Some(slot) = cur.get_mut((row + 1) * width + column) {
                    *slot = value ^ 1;
                }
            }
        }
        let exact = estimate_nv12(
            LumaPlane::new(&prev, width),
            LumaPlane::new(&cur, width),
            width,
            height,
            4,
            0,
        );
        assert_eq!(exact.confidence, 0.0, "exact hashing sees noise as new content");
        let quantized = estimate_nv12(
            LumaPlane::new(&prev, width),
            LumaPlane::new(&cur, width),
            width,
            height,
            4,
            2,
        );
        assert_eq!(quantized.shift, 1);
        assert!((quantized.confidence - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn the_confidence_reports_as_thousandths() {
        let milli = |confidence| {
            ShiftEstimate {
                shift: 1,
                confidence,
                band: None,
            }
            .confidence_milli()
        };
        assert_eq!(ShiftEstimate::NONE.confidence_milli(), 0);
        assert_eq!(milli(1.0), 1000);
        assert_eq!(milli(0.5), 500);
        // Half-away-from-zero, at the boundary the caller's `>= 500` gate reads.
        assert_eq!(milli(0.4995), 500);
        assert_eq!(milli(0.4994), 499);
        // A confidence from outside this module cannot widen the range it reports in.
        assert_eq!(milli(-1.0), 0);
        assert_eq!(milli(2.0), 1000);
    }
}
