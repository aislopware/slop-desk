//! The pure GF(2^8) linear algebra behind the systematic Reed-Solomon code in
//! [`crate::fec`]: the parity coefficient matrix and a Gauss-Jordan inverse. No IO, no
//! allocation beyond the returned `Vec`s.
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
//! The code is **MDS** (maximum distance separable: *any* `k` of the `k + m` encoded
//! shards reconstruct all `k` data shards) iff every `k × k` submatrix formed by choosing
//! `k` of the `k + m` rows is invertible. We get that for free from a **Cauchy** parity
//! block: `P[i][j] = inv(x_i ⊕ y_j)` over two **disjoint** sets `{x_i}` (the `m` parity
//! indices) and `{y_j}` (the `k` data indices). Every square submatrix of a Cauchy matrix
//! is non-singular, and any submatrix that mixes identity rows with Cauchy rows reduces (by
//! deleting the unit columns the identity rows pin) to a smaller Cauchy submatrix — still
//! non-singular. Hence every `k`-subset inverts. `k + m ≤ 256` keeps the two index sets
//! inside the field.

use crate::gf256;

/// The `m × k` parity coefficient block of the systematic encoder (row-major, `m` rows of
/// `k` coefficients each); the implicit top `I_k` is *not* materialised.
///
/// `parity_rows(k, m)[i * k + j]` is the GF(2^8) weight of data shard `j` in parity shard
/// `i`, namely the Cauchy entry `inv(x_i ⊕ y_j)`. We pick `y_j = j` for the `k` data indices
/// and `x_i = k + i` for the `m` parity indices, so the two sets are disjoint and `x_i ⊕ y_j`
/// is never `0` (it would require `x_i == y_j`, impossible across disjoint sets).
///
/// # Panics
/// Panics if `k + m > 256` (the two index sets would collide / exceed the field). The codec
/// (`ReedSolomonFec::new`) enforces `k + m ≤ 255` upstream, so this is a defensive assert.
#[must_use]
pub fn parity_rows(k: usize, m: usize) -> Vec<u8> {
    assert!(
        k + m <= 256,
        "k + m must fit GF(2^8)'s 256 elements for the Cauchy index sets"
    );
    let mut rows = vec![0u8; m * k];
    for i in 0..m {
        let x_i = (k + i) as u8; // parity index, disjoint from the data indices 0..k
        for j in 0..k {
            let y_j = j as u8; // data index
            // x_i ⊕ y_j != 0 by disjointness, so inv() is always defined here.
            rows[i * k + j] = gf256::inv(x_i ^ y_j);
        }
    }
    rows
}

/// Gauss-Jordan inverse of the `k × k` matrix `rows` (each inner `Vec` is one row of `k`
/// coefficients), returning the inverse row-major as a flat `Vec<u8>` of `k * k` entries.
///
/// Returns `None` only if the matrix is singular — which, for a genuine `k`-subset of an MDS
/// encoder matrix, never happens; the `None` arm is purely defensive against a caller that
/// passes a malformed (e.g. duplicated-row) selection so the decoder degrades to "leave the
/// hole" rather than panic.
///
/// # Panics
/// Panics in debug builds if a row's length is not `k` (a caller contract violation). Never
/// panics in release: a bad shape just falls through to the singular `None` path or is masked
/// by the upstream `debug_assert`.
#[must_use]
pub fn invert_subset(rows: &[Vec<u8>], k: usize) -> Option<Vec<u8>> {
    debug_assert_eq!(rows.len(), k, "invert_subset expects k rows");
    if rows.len() != k {
        return None;
    }
    // Augment [A | I] in a single k×2k working buffer (row-major).
    let stride = 2 * k;
    let mut work = vec![0u8; k * stride];
    for (r, row) in rows.iter().enumerate() {
        debug_assert_eq!(row.len(), k, "invert_subset expects square rows");
        if row.len() != k {
            return None;
        }
        for (c, &v) in row.iter().enumerate() {
            work[r * stride + c] = v;
        }
        work[r * stride + k + r] = 1; // identity on the right
    }

    for col in 0..k {
        // Find a nonzero pivot at/below the diagonal in this column.
        let mut pivot = col;
        while pivot < k && work[pivot * stride + col] == 0 {
            pivot += 1;
        }
        if pivot == k {
            return None; // singular column → no inverse
        }
        if pivot != col {
            swap_rows(&mut work, stride, pivot, col);
        }

        // Normalise the pivot row so the pivot becomes 1.
        let inv_pivot = gf256::inv(work[col * stride + col]);
        scale_row(&mut work, stride, col, inv_pivot);

        // Eliminate this column from every other row.
        for r in 0..k {
            if r == col {
                continue;
            }
            let factor = work[r * stride + col];
            if factor != 0 {
                eliminate_row(&mut work, stride, col, r, factor);
            }
        }
    }

    // The right half is now A^-1.
    let mut inverse = vec![0u8; k * k];
    for r in 0..k {
        for c in 0..k {
            inverse[r * k + c] = work[r * stride + k + c];
        }
    }
    Some(inverse)
}

/// Swaps rows `a` and `b` of the augmented working matrix (stride = `2k`).
fn swap_rows(work: &mut [u8], stride: usize, a: usize, b: usize) {
    if a == b {
        return;
    }
    let (lo, hi) = (a.min(b), a.max(b));
    // Split so the two row windows borrow disjointly (no `unsafe`, no clone).
    let (head, tail) = work.split_at_mut(hi * stride);
    let lo_row = &mut head[lo * stride..lo * stride + stride];
    let hi_row = &mut tail[..stride];
    lo_row.swap_with_slice(hi_row);
}

/// Multiplies every entry of row `r` by the field scalar `s` in place.
fn scale_row(work: &mut [u8], stride: usize, r: usize, s: u8) {
    if s == 1 {
        return;
    }
    let row = &mut work[r * stride..r * stride + stride];
    for v in row.iter_mut() {
        *v = gf256::mul(*v, s);
    }
}

/// `row[dst] ^= factor * row[src]` over the whole augmented row (Gauss-Jordan elimination).
fn eliminate_row(work: &mut [u8], stride: usize, src: usize, dst: usize, factor: u8) {
    let (lo, hi) = (src.min(dst), src.max(dst));
    let (head, tail) = work.split_at_mut(hi * stride);
    let lo_row = &mut head[lo * stride..lo * stride + stride];
    let hi_row = &mut tail[..stride];
    let (src_row, dst_row) = if src < dst {
        (&*lo_row, hi_row)
    } else {
        (&*hi_row, lo_row)
    };
    for (d, &sv) in dst_row.iter_mut().zip(src_row.iter()) {
        *d ^= gf256::mul(factor, sv);
    }
}

#[cfg(test)]
mod tests {
    use crate::gf256;
    use crate::rs_matrix::{invert_subset, parity_rows};

    /// Builds the full `(k + m) × k` encoder matrix as rows-of-`Vec`: identity then parity.
    fn encoder_rows(k: usize, m: usize) -> Vec<Vec<u8>> {
        let parity = parity_rows(k, m);
        let mut rows = Vec::with_capacity(k + m);
        for i in 0..k {
            let mut row = vec![0u8; k];
            row[i] = 1;
            rows.push(row);
        }
        for i in 0..m {
            rows.push(parity[i * k..i * k + k].to_vec());
        }
        rows
    }

    /// GF(2^8) product of a `k×k` (`a`) and `k×k` (`b`), both row-major flat.
    fn mat_mul(a: &[u8], b: &[u8], k: usize) -> Vec<u8> {
        let mut out = vec![0u8; k * k];
        for i in 0..k {
            for j in 0..k {
                let mut acc = 0u8;
                for t in 0..k {
                    acc ^= gf256::mul(a[i * k + t], b[t * k + j]);
                }
                out[i * k + j] = acc;
            }
        }
        out
    }

    fn identity(k: usize) -> Vec<u8> {
        let mut id = vec![0u8; k * k];
        for i in 0..k {
            id[i * k + i] = 1;
        }
        id
    }

    /// Recursive worker for [`for_each_subset`]: chooses indices in increasing order.
    fn subset_recurse(
        start: usize,
        depth: usize,
        n: usize,
        k: usize,
        chosen: &mut [usize],
        f: &mut impl FnMut(&[usize]),
    ) {
        if depth == k {
            f(chosen);
            return;
        }
        for v in start..n {
            chosen[depth] = v;
            subset_recurse(v + 1, depth + 1, n, k, chosen, f);
        }
    }

    /// Enumerate every k-subset of `0..n` and invoke `f` with the chosen indices.
    fn for_each_subset(n: usize, k: usize, mut f: impl FnMut(&[usize])) {
        let mut chosen = vec![0usize; k];
        subset_recurse(0, 0, n, k, &mut chosen, &mut f);
    }

    #[test]
    fn parity_rows_shape_and_nonzero() {
        let p = parity_rows(4, 2);
        assert_eq!(p.len(), 4 * 2);
        // Cauchy entries inv(x⊕y) over disjoint index sets are always nonzero.
        assert!(p.iter().all(|&c| c != 0));
    }

    #[test]
    fn every_k_subset_is_mds_and_inverts_to_identity() {
        // Exhaustive MDS proof for the small parameter grid the codec ships against.
        for k in 1..=8usize {
            for m in 1..=4usize {
                if k + m > 12 {
                    continue;
                }
                let rows = encoder_rows(k, m);
                let n = k + m;
                for_each_subset(n, k, |idx| {
                    let sub: Vec<Vec<u8>> = idx.iter().map(|&r| rows[r].clone()).collect();
                    let inv = invert_subset(&sub, k).unwrap_or_else(|| {
                        panic!("k-subset {idx:?} of ({k},{m}) encoder was singular — not MDS")
                    });
                    // A · A^-1 == I.
                    let flat: Vec<u8> = sub.iter().flatten().copied().collect();
                    let product = mat_mul(&flat, &inv, k);
                    assert_eq!(product, identity(k), "A·A^-1 != I for subset {idx:?}");
                    // A^-1 · A == I too (two-sided).
                    let product2 = mat_mul(&inv, &flat, k);
                    assert_eq!(product2, identity(k), "A^-1·A != I for subset {idx:?}");
                });
            }
        }
    }

    #[test]
    fn singular_matrix_returns_none() {
        // Two identical rows → rank-deficient → no inverse (defensive path).
        let rows = vec![vec![1u8, 2u8], vec![1u8, 2u8]];
        assert!(invert_subset(&rows, 2).is_none());
    }

    #[test]
    fn one_by_one_inverse() {
        let rows = vec![vec![0x53u8]];
        let inv = invert_subset(&rows, 1).expect("nonzero 1x1 inverts");
        assert_eq!(gf256::mul(0x53, inv[0]), 1);
    }
}
