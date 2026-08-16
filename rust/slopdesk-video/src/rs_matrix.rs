//! The pure GF(2^8) linear algebra behind the systematic Reed-Solomon code in [`crate::fec`]: the
//! parity coefficient matrix and a Gauss-Jordan inverse. No IO, no allocation beyond the returned
//! `Vec`s.
//!
//! ## The encoder matrix
//!
//! For `k` data shards and `m` parity shards the encoder is the `(k + m) × k` matrix
//!
//! ```text
//!   ┌      ┐
//!   │  I_k │   ← top k rows: identity (shard i is copied verbatim → "systematic")
//!   │  P   │   ← bottom m rows: a Cauchy block (the parity coefficients)
//!   └      ┘
//! ```
//!
//! The code is **MDS** (maximum distance separable: *any* `k` of the `k + m` encoded shards
//! reconstruct all `k` data shards) iff every `k × k` submatrix formed by choosing `k` of the
//! `k + m` rows is invertible. We get that for free from a **Cauchy** parity block:
//! `P[i][j] = inv(x_i ⊕ y_j)` over two **disjoint** sets `{x_i}` (the `m` parity indices) and
//! `{y_j}` (the `k` data indices). Every square submatrix of a Cauchy matrix is non-singular, and
//! any submatrix that mixes identity rows with Cauchy rows reduces (by deleting the unit columns
//! the identity rows pin) to a smaller Cauchy submatrix — still non-singular. Hence every
//! `k`-subset inverts. `k + m ≤ 256` keeps the two index sets inside the field.
//!
//! Build order, pivot selection and row operations are pinned exactly as written: they decide the
//! bytes, not just the answer, because a different pivot order inverts to the same matrix by a
//! different sequence of intermediate rows and any drift there is invisible until a real loss
//! pattern hits it.

use crate::gf256;

/// The `m × k` parity coefficient block of the systematic encoder (row-major, `m` rows of `k`
/// coefficients each); the implicit top `I_k` is *not* materialised.
///
/// `parity_rows(k, m)[i * k + j]` is the GF(2^8) weight of data shard `j` in parity shard `i`,
/// namely the Cauchy entry `inv(x_i ⊕ y_j)`. We pick `y_j = j` for the `k` data indices and
/// `x_i = k + i` for the `m` parity indices, so the two sets are disjoint and `x_i ⊕ y_j` is never
/// `0` (it would require `x_i == y_j`, impossible across disjoint sets).
///
/// # Panics
/// Panics if `k + m > 256` (the two index sets would collide / leave the field). The codec
/// (`ReedSolomonFec::new`) enforces `k + m <= 255` at construction, so this is a defensive assert
/// on a configuration error, never on network input.
#[must_use]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the assert above bounds `k + i` and `j` by 255, so both casts are exact"
)]
pub fn parity_rows(k: usize, m: usize) -> Vec<u8> {
    assert!(
        k + m <= 256,
        "k + m must fit GF(2^8)'s 256 elements for the Cauchy index sets"
    );
    let mut rows = Vec::with_capacity(m * k);
    for i in 0..m {
        let x_i = (k + i) as u8; // parity index, disjoint from the data indices 0..k
        for j in 0..k {
            let y_j = j as u8; // data index
            // x_i ⊕ y_j != 0 by disjointness, so inv() is always defined here.
            rows.push(gf256::inv(x_i ^ y_j));
        }
    }
    rows
}

/// Gauss-Jordan inverse of the `k × k` matrix `rows` (each inner slice is one row of `k`
/// coefficients), returning the inverse row-major as a flat `Vec<u8>` of `k * k` entries.
///
/// Returns `None` only if the matrix is singular or malformed — which, for a genuine `k`-subset of
/// an MDS encoder matrix, never happens. The `None` arm is purely defensive against a caller that
/// passes a duplicated-row or wrong-shape selection, so the decoder degrades to "leave the hole"
/// rather than crash.
#[must_use]
pub fn invert_subset(rows: &[Vec<u8>], k: usize) -> Option<Vec<u8>> {
    if k == 0 || rows.len() != k {
        return None;
    }
    // Augment [A | I] in a single k×2k working buffer (row-major).
    let stride = 2 * k;
    let mut work = vec![0_u8; k * stride];
    for (r, (row, dst)) in rows.iter().zip(work.chunks_exact_mut(stride)).enumerate() {
        if row.len() != k {
            return None;
        }
        dst.get_mut(..k)?.copy_from_slice(row);
        *dst.get_mut(k + r)? = 1; // identity on the right
    }

    for col in 0..k {
        // Find a nonzero pivot at/below the diagonal in this column.
        let mut pivot = col;
        while pivot < k && at(&work, stride, pivot, col) == 0 {
            pivot += 1;
        }
        if pivot == k {
            return None; // singular column → no inverse
        }
        if pivot != col {
            swap_rows(&mut work, stride, pivot, col);
        }

        // Normalise the pivot row so the pivot becomes 1.
        let inv_pivot = gf256::inv(at(&work, stride, col, col));
        scale_row(&mut work, stride, col, inv_pivot);

        // Eliminate this column from every other row.
        for r in 0..k {
            if r == col {
                continue;
            }
            let factor = at(&work, stride, r, col);
            if factor != 0 {
                eliminate_row(&mut work, stride, col, r, factor);
            }
        }
    }

    // The right half is now A^-1.
    let mut inverse = Vec::with_capacity(k * k);
    for row in work.chunks_exact(stride) {
        inverse.extend_from_slice(row.get(k..stride)?);
    }
    Some(inverse)
}

/// Cell `(r, c)` of the augmented working matrix. Total by construction: every caller's `r` is
/// below `k` and `c` below `stride`, and an out-of-range read would mean a bug in the loop bounds
/// rather than bad input, so `0` (a singular column, which returns `None`) is the safe answer.
#[inline]
fn at(work: &[u8], stride: usize, r: usize, c: usize) -> u8 {
    work.get(r * stride + c).copied().unwrap_or(0)
}

/// Swaps rows `a` and `b` of the augmented working matrix (stride = `2k`).
fn swap_rows(work: &mut [u8], stride: usize, a: usize, b: usize) {
    if a == b {
        return;
    }
    let (lo, hi) = (a.min(b), a.max(b));
    // Split so the two row windows borrow disjointly (no `unsafe`, no clone).
    let Some((head, tail)) = work.split_at_mut_checked(hi * stride) else {
        return;
    };
    let (Some(lo_row), Some(hi_row)) = (head.get_mut(lo * stride..), tail.get_mut(..stride)) else {
        return;
    };
    let Some(lo_row) = lo_row.get_mut(..stride) else {
        return;
    };
    lo_row.swap_with_slice(hi_row);
}

/// Multiplies every entry of row `r` by the field scalar `s` in place.
fn scale_row(work: &mut [u8], stride: usize, r: usize, s: u8) {
    if s == 1 {
        return;
    }
    let Some(row) = work.get_mut(r * stride..).and_then(|tail| tail.get_mut(..stride)) else {
        return;
    };
    for v in row.iter_mut() {
        *v = gf256::mul(*v, s);
    }
}

/// `row[dst] ^= factor * row[src]` over the whole augmented row (Gauss-Jordan elimination).
fn eliminate_row(work: &mut [u8], stride: usize, src: usize, dst: usize, factor: u8) {
    if src == dst {
        return;
    }
    let (lo, hi) = (src.min(dst), src.max(dst));
    let Some((head, tail)) = work.split_at_mut_checked(hi * stride) else {
        return;
    };
    let (Some(lo_row), Some(hi_row)) = (head.get_mut(lo * stride..), tail.get_mut(..stride)) else {
        return;
    };
    let Some(lo_row) = lo_row.get_mut(..stride) else {
        return;
    };
    let (src_row, dst_row) = if src < dst {
        (&*lo_row, hi_row)
    } else {
        (&*hi_row, lo_row)
    };
    gf256::mul_add(factor, src_row, dst_row);
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::cast_possible_truncation,
        clippy::indexing_slicing,
        clippy::panic,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{invert_subset, parity_rows};
    use crate::gf256;

    /// Builds the full `(k + m) × k` encoder matrix as rows-of-`Vec`: identity then parity.
    fn encoder_rows(k: usize, m: usize) -> Vec<Vec<u8>> {
        let parity = parity_rows(k, m);
        let mut rows = Vec::with_capacity(k + m);
        for i in 0..k {
            let mut row = vec![0_u8; k];
            row[i] = 1;
            rows.push(row);
        }
        for i in 0..m {
            rows.push(parity[i * k..i * k + k].to_vec());
        }
        rows
    }

    /// GF(2^8) product of two `k×k` row-major flat matrices.
    fn mat_mul(a: &[u8], b: &[u8], k: usize) -> Vec<u8> {
        let mut out = vec![0_u8; k * k];
        for i in 0..k {
            for j in 0..k {
                let mut acc = 0_u8;
                for t in 0..k {
                    acc ^= gf256::mul(a[i * k + t], b[t * k + j]);
                }
                out[i * k + j] = acc;
            }
        }
        out
    }

    fn identity(k: usize) -> Vec<u8> {
        let mut out = vec![0_u8; k * k];
        for i in 0..k {
            out[i * k + i] = 1;
        }
        out
    }

    #[test]
    fn parity_rows_are_the_cauchy_block() {
        let (k, m) = (5, 3);
        let rows = parity_rows(k, m);
        assert_eq!(rows.len(), m * k);
        for i in 0..m {
            for j in 0..k {
                let expected = gf256::inv((k + i) as u8 ^ j as u8);
                assert_eq!(rows[i * k + j], expected, "Cauchy entry ({i},{j})");
                assert_ne!(rows[i * k + j], 0, "a Cauchy entry is never zero");
            }
        }
    }

    #[test]
    fn every_k_subset_of_the_encoder_inverts() {
        // The MDS property, checked rather than asserted: for k=4, m=3 there are C(7,4) = 35
        // subsets, and EVERY one of them must be invertible or a real loss pattern is unrecoverable.
        let (k, m) = (4_usize, 3_usize);
        let rows = encoder_rows(k, m);
        let n = k + m;
        let mut checked = 0_usize;
        for mask in 0_u32..(1 << n) {
            if mask.count_ones() as usize != k {
                continue;
            }
            let subset: Vec<Vec<u8>> = (0..n)
                .filter(|i| mask & (1 << i) != 0)
                .map(|i| rows[i].clone())
                .collect();
            let inverse = invert_subset(&subset, k).unwrap_or_else(|| {
                panic!("subset {mask:#b} of an MDS encoder must invert");
            });
            let flat: Vec<u8> = subset.concat();
            assert_eq!(
                mat_mul(&flat, &inverse, k),
                identity(k),
                "A · A⁻¹ == I for subset {mask:#b}"
            );
            checked += 1;
        }
        assert_eq!(checked, 35, "C(7,4) subsets");
    }

    #[test]
    fn a_duplicated_row_is_singular_rather_than_a_crash() {
        let row = vec![1_u8, 2, 3];
        assert!(invert_subset(&[row.clone(), row.clone(), row], 3).is_none());
    }

    #[test]
    fn a_wrong_shape_is_rejected_before_the_pivot_loop() {
        assert!(
            invert_subset(&[vec![1_u8, 0], vec![0, 1]], 3).is_none(),
            "too few rows"
        );
        assert!(
            invert_subset(&[vec![1_u8, 0, 0], vec![0, 1]], 2).is_none(),
            "a row is not k wide"
        );
        assert!(
            invert_subset(&[], 0).is_none(),
            "a zero-order matrix has no inverse to return"
        );
    }

    #[test]
    fn the_identity_inverts_to_itself() {
        for k in 1..=8_usize {
            let rows: Vec<Vec<u8>> = (0..k)
                .map(|i| {
                    let mut row = vec![0_u8; k];
                    row[i] = 1;
                    row
                })
                .collect();
            assert_eq!(invert_subset(&rows, k).unwrap(), identity(k), "I⁻¹ == I at k={k}");
        }
    }

    #[test]
    fn a_pivot_swap_still_inverts() {
        // Row 0 has a zero in column 0, so the pivot search must walk down and swap.
        let rows = vec![vec![0_u8, 1], vec![1, 0]];
        let inverse = invert_subset(&rows, 2).unwrap();
        assert_eq!(mat_mul(&rows.concat(), &inverse, 2), identity(2));
    }
}
