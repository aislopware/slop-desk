//! The per-frame QP-ceiling law: sharp on a small change, blur graded by burst size.
//!
//! ## Why this exists
//!
//! Pure VBR grades quality with complexity, but under congestion control it meets the AVERAGE by
//! raising QP across EVERY frame — so a one-row caret move is coarsened alongside a scroll burst.
//! This law derives a PER-FRAME ceiling from the frame's measured change magnitude instead: a small
//! change gets a tight, low ceiling the rate controller cannot coarsen past, and the picture stays
//! sharp; a big burst lets the ceiling ride up to the configured maximum, and the blur is graded.
//!
//! ## Bit-exact trap — the ramp is float
//!
//! `t = (b - b_lo) / (b_hi - b_lo); ramp = t * range; q = qp_sharp + ramp` keeps the multiply and
//! the add SEPARATE — never fused — and only then rounds half-away-from-zero and clamps. Every
//! comparison is ORDERED, so a non-finite change fraction reads as `b_lo`, which is the sharp end.

use crate::frame_hash::LumaPlane;

/// The shape of the QP ramp: its two ends, and the change-fraction band between them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QpCurve {
    /// The sharp (low) ceiling applied when little of the frame changed.
    pub qp_sharp: u8,
    /// The configured live ceiling, applied once the change is a full burst.
    pub qp_max: u8,
    /// Where the ramp starts, as a change fraction ×1000.
    pub b_lo_milli: u32,
    /// Where the ramp reaches `qp_max`, as a change fraction ×1000.
    pub b_hi_milli: u32,
}

/// What one frame's measurement produced: the ceiling to set, and the change it was derived from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QpDecision {
    /// The `MaxAllowedFrameQP` ceiling for this frame.
    pub qp: u8,
    /// The measured change fraction ×1000, in `0..=1000` — for the log, not for the encoder.
    pub change_milli: u32,
}

/// The fraction of rows that changed between two frames' per-row luma hashes, in `0.0..=1.0`.
///
/// The count of indices whose hashes differ, over the compared (shorter) length. Empty input is
/// `0.0`: nothing measured is not the same as nothing changed, but the caller's ramp treats both as
/// the sharp end, which is the safe direction.
#[must_use]
pub fn changed_fraction(prev: &[u64], cur: &[u64]) -> f64 {
    let n = prev.len().min(cur.len());
    if n == 0 {
        return 0.0;
    }
    // `zip` already stops at the shorter side, which is what `n` measures.
    let changed = prev
        .iter()
        .zip(cur.iter())
        .filter(|(before, after)| before != after)
        .count();
    #[expect(
        clippy::cast_precision_loss,
        reason = "both counts are row counts, bounded by `MAX_PLANE_DIMENSION`, and so are exact in an f64 \
                  by four orders of magnitude"
    )]
    {
        changed as f64 / n as f64
    }
}

/// Maps a change fraction `b` to a per-frame QP ceiling.
///
/// `b <= b_lo` is `qp_sharp` — a tight, low ceiling that stays sharp. `b >= b_hi` is `qp_max` — the
/// configured live ceiling, where graded blur is allowed. Between them the ceiling ramps linearly.
/// `qp_sharp` is the sharp end and should be at or below `qp_max`; if it is not, there is no ramp
/// and the answer is `qp_max`. A non-finite `b` reads as `b_lo`, and a degenerate band
/// (`b_hi <= b_lo`) collapses the ramp to a step at `b_lo`.
#[must_use]
pub fn adaptive_max_qp(b: f64, qp_sharp: u8, qp_max: u8, b_lo: f64, b_hi: f64) -> u8 {
    if qp_sharp >= qp_max {
        return qp_max;
    }
    // ORDERED comparisons: the finite test catches NaN and both infinities before the band test.
    if !b.is_finite() || b <= b_lo {
        return qp_sharp;
    }
    if b >= b_hi || b_hi <= b_lo {
        return qp_max;
    }

    let sharp = f64::from(qp_sharp);
    let max = f64::from(qp_max);
    let t = (b - b_lo) / (b_hi - b_lo);
    let range = max - sharp;
    let ramp = t * range; // a SEPARATE multiply...
    let q = sharp + ramp; // ...and a SEPARATE add, never fused with it
    let rounded = q.round(); // half away from zero, as on the other side of the port
    // `rounded` is already inside `[qp_sharp, qp_max]`; the clamp is what makes the cast total.
    if rounded <= sharp {
        return qp_sharp;
    }
    if rounded >= max {
        return qp_max;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the two branches above have already pinned `rounded` strictly inside `(qp_sharp, \
                  qp_max)`, and both ends are `u8`"
    )]
    {
        rounded as u8
    }
}

/// The adaptive per-frame QP ceiling from the change between two locked NV12 luma planes.
///
/// A degenerate or overflowing plane is `(qp_max, 0)`: no adaptive narrowing, which is the safe
/// "just use the configured static ceiling" fallback rather than a guess at a ceiling.
#[must_use]
pub fn compute_nv12(
    prev: LumaPlane<'_>,
    cur: LumaPlane<'_>,
    width: usize,
    height: usize,
    curve: QpCurve,
) -> QpDecision {
    let (Some(prev_rows), Some(cur_rows)) = (
        prev.row_hashes(width, height, 0),
        cur.row_hashes(width, height, 0),
    ) else {
        return QpDecision {
            qp: curve.qp_max,
            change_milli: 0,
        };
    };
    let b = changed_fraction(&prev_rows, &cur_rows);
    let b_lo = f64::from(curve.b_lo_milli) / 1000.0;
    let b_hi = f64::from(curve.b_hi_milli) / 1000.0;
    let qp = adaptive_max_qp(b, curve.qp_sharp, curve.qp_max, b_lo, b_hi);
    // `b` is in `[0, 1]`, so the milli value is in `[0, 1000]`: clamp, then scale, then round.
    let bounded = b.clamp(0.0, 1.0) * 1000.0;
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "clamped to `[0, 1]` and scaled by 1000 before the round, so the value is in `0..=1000`"
    )]
    let change_milli = bounded.round() as u32;
    QpDecision { qp, change_milli }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "these fractions are exact small rationals — an eighth, a half, zero — and the point of \
                  the assertion is that they came out exact"
    )]
    #![expect(
        clippy::cast_possible_truncation,
        reason = "the synthetic planes are built from small row/column arithmetic, and a wrapped byte would \
                  still be a deterministic byte"
    )]

    use super::{QpCurve, QpDecision, adaptive_max_qp, changed_fraction, compute_nv12};
    use crate::frame_hash::LumaPlane;

    #[test]
    fn the_changed_fraction_is_over_the_compared_length() {
        assert_eq!(changed_fraction(&[], &[]), 0.0);
        assert_eq!(changed_fraction(&[1, 2, 3], &[]), 0.0);
        assert_eq!(changed_fraction(&[1, 2, 3, 4], &[1, 2, 3, 4]), 0.0);
        assert_eq!(changed_fraction(&[1, 2, 3, 4], &[9, 9, 9, 9]), 1.0);
        assert_eq!(changed_fraction(&[1, 2, 3, 4], &[1, 9, 3, 9]), 0.5);
        // The longer array's extra rows were never compared, so they cannot change the fraction.
        assert_eq!(changed_fraction(&[1, 2, 3, 4, 5, 6], &[1, 9]), 0.5);
    }

    #[test]
    fn the_two_ends_of_the_ramp_are_flat() {
        assert_eq!(adaptive_max_qp(0.0, 20, 40, 0.02, 0.20), 20);
        assert_eq!(
            adaptive_max_qp(0.02, 20, 40, 0.02, 0.20),
            20,
            "the low end is inclusive"
        );
        assert_eq!(
            adaptive_max_qp(0.20, 20, 40, 0.02, 0.20),
            40,
            "the high end is inclusive"
        );
        assert_eq!(adaptive_max_qp(0.99, 20, 40, 0.02, 0.20), 40);
    }

    #[test]
    fn the_middle_of_the_band_is_the_middle_of_the_ramp() {
        // b halfway between 0.0 and 0.4 ⇒ halfway between 20 and 40.
        assert_eq!(adaptive_max_qp(0.2, 20, 40, 0.0, 0.4), 30);
        assert_eq!(adaptive_max_qp(0.1, 20, 40, 0.0, 0.4), 25);
        assert_eq!(adaptive_max_qp(0.3, 20, 40, 0.0, 0.4), 35);
    }

    /// Every degenerate configuration has to answer with a ceiling, because the encoder is going to
    /// be handed one either way.
    #[test]
    fn a_degenerate_curve_still_answers_with_a_ceiling() {
        assert_eq!(adaptive_max_qp(0.5, 40, 40, 0.0, 1.0), 40, "no room to ramp");
        assert_eq!(
            adaptive_max_qp(0.5, 51, 40, 0.0, 1.0),
            40,
            "an inverted pair is the max"
        );
        assert_eq!(
            adaptive_max_qp(0.7, 20, 40, 0.6, 0.3),
            40,
            "an inverted band steps at b_lo"
        );
        assert_eq!(
            adaptive_max_qp(0.5, 20, 40, 0.6, 0.3),
            20,
            "…and stays sharp at or below it"
        );
        assert_eq!(
            adaptive_max_qp(f64::NAN, 20, 40, 0.02, 0.2),
            20,
            "NaN reads as the sharp end"
        );
        assert_eq!(adaptive_max_qp(f64::INFINITY, 20, 40, 0.02, 0.2), 20);
        assert_eq!(adaptive_max_qp(f64::NEG_INFINITY, 20, 40, 0.02, 0.2), 20);
    }

    #[test]
    fn an_unmeasurable_plane_falls_back_to_the_static_ceiling() {
        let plane = vec![0_u8; 64];
        let curve = QpCurve {
            qp_sharp: 20,
            qp_max: 44,
            b_lo_milli: 20,
            b_hi_milli: 200,
        };
        let decision = compute_nv12(LumaPlane::new(&plane, 8), LumaPlane::new(&plane, 8), 0, 8, curve);
        assert_eq!(decision, QpDecision {
            qp: 44,
            change_milli: 0
        });
    }

    #[test]
    fn an_unchanged_frame_stays_sharp_and_a_full_repaint_does_not() {
        let width = 16;
        let height = 8;
        let still: Vec<u8> = (0..(width * height) as u32)
            .map(|value| (value % 251) as u8)
            .collect();
        let curve = QpCurve {
            qp_sharp: 20,
            qp_max: 44,
            b_lo_milli: 20,
            b_hi_milli: 200,
        };
        let unchanged = compute_nv12(
            LumaPlane::new(&still, width),
            LumaPlane::new(&still, width),
            width,
            height,
            curve,
        );
        assert_eq!(unchanged, QpDecision {
            qp: 20,
            change_milli: 0
        });

        let repainted: Vec<u8> = still.iter().map(|byte| byte.wrapping_add(37)).collect();
        let burst = compute_nv12(
            LumaPlane::new(&still, width),
            LumaPlane::new(&repainted, width),
            width,
            height,
            curve,
        );
        assert_eq!(burst, QpDecision {
            qp: 44,
            change_milli: 1000
        });
    }

    /// The case the law was written for: a caret-sized change must not be coarsened.
    #[test]
    fn a_single_changed_row_lands_on_the_sharp_end() {
        let width = 16;
        let height = 16;
        let before = vec![7_u8; width * height];
        let mut after = before.clone();
        if let Some(row) = after.get_mut(width * 5..width * 6) {
            row.fill(9);
        }
        let curve = QpCurve {
            qp_sharp: 20,
            qp_max: 44,
            b_lo_milli: 100,
            b_hi_milli: 600,
        };
        let decision = compute_nv12(
            LumaPlane::new(&before, width),
            LumaPlane::new(&after, width),
            width,
            height,
            curve,
        );
        // One row of sixteen: 62.5 per mille, below the 100 per mille ramp start.
        assert_eq!(decision, QpDecision {
            qp: 20,
            change_milli: 63
        });
    }
}
