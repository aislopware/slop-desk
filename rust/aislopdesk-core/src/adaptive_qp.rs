//! Pure adaptive per-frame QP-ceiling law: "sharp on a small change, blur graded by burst size".
//!
//! ## Why this exists
//!
//! Pure-VBR already grades quality with complexity (a small caret-move delta costs few bits → the
//! rate-control leaves QP low → sharp; a scroll burst costs many bits → QP rises → blur). But when
//! congestion control lowers the bitrate target on a tight WAN, VBR meets the *average* by raising
//! QP across EVERY frame — so a 1-row caret move is coarsened alongside a scroll burst, purely
//! because the budget is tight. A static `MaxAllowedFrameQP` ceiling cannot say "hold THIS small
//! frame low". This law derives a PER-FRAME ceiling from the frame's measured change magnitude:
//! small change → a tight (low) ceiling the RC cannot coarsen past (stays sharp, regardless of
//! budget); big burst → the ceiling rides up to the configured max (graded blur, never "fully soft"
//! unless the burst is huge). It also generalizes the crisp-on-FULL-static refresh to the common
//! "almost-static editing" case (a blinking caret no longer defeats it).
//!
//! Pure: no I/O, no env, deterministic, unit-testable. Float math uses ORDERED comparisons and
//! SEPARATE `mul`+`add` (never `mul_add` — FMA would diverge low bits), per the workspace rule.

/// Fraction of rows that changed between two frames' per-row luma hashes (`0.0..=1.0`).
///
/// `prev` / `cur` are the row-hash arrays (one `u64` per luma row). The result is the count of
/// indices where the hashes differ, over the compared length — a resolution-independent measure of
/// "how much of the frame changed this tick" (the burst magnitude). Empty input ⇒ `0.0`.
#[must_use]
pub fn changed_fraction(prev: &[u64], cur: &[u64]) -> f64 {
    let n = prev.len().min(cur.len());
    if n == 0 {
        return 0.0;
    }
    let mut changed = 0usize;
    for i in 0..n {
        if prev[i] != cur[i] {
            changed += 1;
        }
    }
    changed as f64 / n as f64
}

/// Maps a change fraction `b` to a per-frame `MaxAllowedFrameQP` ceiling.
///
/// * `b <= b_lo` (small change) ⇒ `qp_sharp` (a tight, low ceiling — protected, stays sharp).
/// * `b >= b_hi` (big burst) ⇒ `qp_max` (the configured live ceiling — graded blur allowed).
/// * between ⇒ a linear ramp from `qp_sharp` up to `qp_max` (graded, never a binary jump).
///
/// `qp_sharp` is the sharp (low) end and should be `<= qp_max`; if a caller passes `qp_sharp >=
/// qp_max` the function returns `qp_max` (no ramp). A non-finite `b` is treated as `b_lo` (sharp).
/// A degenerate band (`b_hi <= b_lo`) collapses to a step at `b_lo`.
#[must_use]
pub fn adaptive_max_qp(b: f64, qp_sharp: u8, qp_max: u8, b_lo: f64, b_hi: f64) -> u8 {
    if qp_sharp >= qp_max {
        return qp_max;
    }
    if !b.is_finite() || b <= b_lo {
        return qp_sharp;
    }
    if b >= b_hi || b_hi <= b_lo {
        return qp_max;
    }
    // Linear ramp. t ∈ (0, 1); SEPARATE mul + add (no mul_add) to keep the result bit-stable.
    let t = (b - b_lo) / (b_hi - b_lo);
    let range = f64::from(qp_max) - f64::from(qp_sharp);
    let ramp = t * range;
    let q = f64::from(qp_sharp) + ramp;
    let rounded = q.round();
    // rounded ∈ [qp_sharp, qp_max] ⊂ [0, 255]; clamp defensively before the cast.
    if rounded <= f64::from(qp_sharp) {
        qp_sharp
    } else if rounded >= f64::from(qp_max) {
        qp_max
    } else {
        rounded as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    // ---- changed_fraction ----

    #[test]
    fn changed_fraction_empty_is_zero() {
        assert!(approx(changed_fraction(&[], &[]), 0.0));
        assert!(approx(changed_fraction(&[1, 2], &[]), 0.0));
    }

    #[test]
    fn changed_fraction_identical_is_zero() {
        let f = vec![1u64, 2, 3, 4, 5];
        assert!(approx(changed_fraction(&f, &f), 0.0));
    }

    #[test]
    fn changed_fraction_all_different_is_one() {
        let a = vec![1u64, 2, 3, 4];
        let b = vec![9u64, 8, 7, 6];
        assert!(approx(changed_fraction(&a, &b), 1.0));
    }

    #[test]
    fn changed_fraction_partial() {
        // 2 of 8 rows changed → 0.25.
        let a = vec![0u64; 8];
        let mut b = vec![0u64; 8];
        b[1] = 1;
        b[5] = 1;
        assert!(approx(changed_fraction(&a, &b), 0.25));
    }

    #[test]
    fn changed_fraction_uses_min_length() {
        // Compares only the overlapping prefix.
        let a = vec![0u64, 0, 0, 0];
        let b = vec![0u64, 1]; // n=2, one differs → 0.5
        assert!(approx(changed_fraction(&a, &b), 0.5));
    }

    // ---- adaptive_max_qp ----

    const SHARP: u8 = 22;
    const MAXQP: u8 = 34;
    const LO: f64 = 0.02;
    const HI: f64 = 0.30;

    #[test]
    fn small_change_pins_sharp() {
        assert_eq!(adaptive_max_qp(0.0, SHARP, MAXQP, LO, HI), SHARP);
        assert_eq!(adaptive_max_qp(0.01, SHARP, MAXQP, LO, HI), SHARP);
        assert_eq!(adaptive_max_qp(LO, SHARP, MAXQP, LO, HI), SHARP); // boundary inclusive
    }

    #[test]
    fn big_burst_pins_max() {
        assert_eq!(adaptive_max_qp(0.30, SHARP, MAXQP, LO, HI), MAXQP);
        assert_eq!(adaptive_max_qp(0.9, SHARP, MAXQP, LO, HI), MAXQP);
        assert_eq!(adaptive_max_qp(1.0, SHARP, MAXQP, LO, HI), MAXQP);
    }

    #[test]
    fn midpoint_ramps_between() {
        // b at the band midpoint (0.16) → QP halfway between 22 and 34 = 28.
        let mid = f64::midpoint(LO, HI);
        let q = adaptive_max_qp(mid, SHARP, MAXQP, LO, HI);
        assert_eq!(q, 28);
    }

    #[test]
    fn ramp_is_monotonic_nondecreasing() {
        let mut prev = adaptive_max_qp(0.0, SHARP, MAXQP, LO, HI);
        let mut x = 0.0;
        while x <= 1.0 {
            let q = adaptive_max_qp(x, SHARP, MAXQP, LO, HI);
            assert!(
                q >= prev,
                "QP must not decrease as b grows (b={x} q={q} prev={prev})"
            );
            assert!((SHARP..=MAXQP).contains(&q), "QP stays within the band");
            prev = q;
            x += 0.01;
        }
    }

    #[test]
    fn non_finite_b_is_sharp() {
        // A garbage b (NaN or ±inf) is caught by !is_finite() and treated as a safe-default sharp.
        assert_eq!(adaptive_max_qp(f64::NAN, SHARP, MAXQP, LO, HI), SHARP);
        assert_eq!(adaptive_max_qp(f64::INFINITY, SHARP, MAXQP, LO, HI), SHARP);
        assert_eq!(
            adaptive_max_qp(f64::NEG_INFINITY, SHARP, MAXQP, LO, HI),
            SHARP
        );
    }

    #[test]
    fn degenerate_band_steps_at_lo() {
        // b_hi <= b_lo: below/at lo → sharp, above → max (a step, no ramp / no div-by-zero).
        assert_eq!(adaptive_max_qp(0.0, SHARP, MAXQP, 0.2, 0.2), SHARP);
        assert_eq!(adaptive_max_qp(0.3, SHARP, MAXQP, 0.2, 0.2), MAXQP);
    }

    #[test]
    fn sharp_ge_max_returns_max_no_ramp() {
        // Defensive: a caller passing qp_sharp >= qp_max gets qp_max (no inverted ramp).
        assert_eq!(adaptive_max_qp(0.1, 40, 34, LO, HI), 34);
        assert_eq!(adaptive_max_qp(0.0, 34, 34, LO, HI), 34);
    }
}
