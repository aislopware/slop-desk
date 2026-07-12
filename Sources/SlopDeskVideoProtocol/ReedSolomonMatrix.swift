// The pure GF(2^8) linear algebra behind the systematic Reed-Solomon code in `FECScheme`:
// the parity coefficient matrix (a Cauchy block) and a Gauss-Jordan inverse.
//
// Matrix build order, pivot selection, and row operations are pinned exactly as written: any of
// them determines the recovered parity coefficients and the matrix inverse, so changing the order
// changes the wire output. All field arithmetic routes through the existing `GF256` tables
// (`GF256.mul`/`GF256.inv`); no second table.
//
// ## The encoder matrix
//
// For `k` data shards and `m` parity shards the encoder is the `(k + m) × k` matrix
//
//   ┌      ┐
//   │  I_k │   ← top k rows: identity (shard i is copied verbatim → "systematic")
//   │  P   │   ← bottom m rows: a Cauchy block (the parity coefficients)
//   └      ┘
//
// The code is MDS (any `k` of the `k + m` encoded shards reconstruct all `k` data shards) because
// the parity block is a Cauchy matrix: `P[i][j] = inv(x_i ⊕ y_j)` over two DISJOINT index sets
// `{x_i}` (the `m` parity indices `k + i`) and `{y_j}` (the `k` data indices `j`). Every square
// submatrix of a Cauchy matrix is non-singular, so every `k`-subset inverts. `k + m ≤ 256` keeps
// the two index sets inside the field.

enum ReedSolomonMatrix {
    /// The `m × k` parity coefficient block of the systematic encoder (row-major, `m` rows of
    /// `k` coefficients each); the implicit top `I_k` is NOT materialised.
    ///
    /// `parityRows(k, m)[i * k + j]` is the GF(2^8) weight of data shard `j` in parity shard `i`,
    /// namely the Cauchy entry `inv(x_i ⊕ y_j)`. We pick `y_j = j` for the `k` data indices and
    /// `x_i = k + i` for the `m` parity indices, so the two sets are disjoint and `x_i ⊕ y_j` is
    /// never `0` (it would require `x_i == y_j`, impossible across disjoint sets) — `inv` is always
    /// defined here.
    ///
    /// Precondition: `k + m <= 256` (the two index sets must fit GF(2^8)'s 256 elements). The codec
    /// enforces `k + m <= 255` upstream, so this is a defensive guard.
    static func parityRows(k: Int, m: Int) -> [UInt8] {
        precondition(k + m <= 256, "k + m must fit GF(2^8)'s 256 elements for the Cauchy index sets")
        var rows = [UInt8](repeating: 0, count: m * k)
        for i in 0..<m {
            let xi = UInt8(k + i) // parity index x_i, disjoint from the data indices 0..<k
            for j in 0..<k {
                let yj = UInt8(j) // data index y_j
                // x_i ⊕ y_j != 0 by disjointness, so inv() is always defined here.
                rows[i * k + j] = GF256.inv(xi ^ yj)
            }
        }
        return rows
    }

    /// Gauss-Jordan inverse of the `k × k` matrix `rows` (each inner array is one row of `k`
    /// coefficients), returning the inverse row-major as a flat `[UInt8]` of `k * k` entries.
    ///
    /// Returns `nil` ONLY if the matrix is singular — which, for a genuine `k`-subset of an MDS
    /// encoder matrix, never happens; the `nil` arm is purely defensive against a caller that passes
    /// a malformed (e.g. duplicated-row) selection, so the decoder degrades to "leave the hole"
    /// rather than crash. Never traps on a bad shape: a non-`k` row count or row length falls through
    /// to `nil`.
    static func invertSubset(_ rows: [[UInt8]], k: Int) -> [UInt8]? {
        guard rows.count == k else { return nil }
        // Augment [A | I] in a single k×2k working buffer (row-major).
        let stride = 2 * k
        var work = [UInt8](repeating: 0, count: k * stride)
        for (r, row) in rows.enumerated() {
            guard row.count == k else { return nil }
            for (c, v) in row.enumerated() {
                work[r * stride + c] = v
            }
            work[r * stride + k + r] = 1 // identity on the right
        }

        for col in 0..<k {
            // Find a nonzero pivot at/below the diagonal in this column.
            var pivot = col
            while pivot < k, work[pivot * stride + col] == 0 {
                pivot += 1
            }
            if pivot == k {
                return nil // singular column → no inverse
            }
            if pivot != col {
                swapRows(&work, stride: stride, pivot, col)
            }

            // Normalise the pivot row so the pivot becomes 1.
            let invPivot = GF256.inv(work[col * stride + col])
            scaleRow(&work, stride: stride, col, invPivot)

            // Eliminate this column from every other row.
            for r in 0..<k {
                if r == col { continue }
                let factor = work[r * stride + col]
                if factor != 0 {
                    eliminateRow(&work, stride: stride, src: col, dst: r, factor: factor)
                }
            }
        }

        // The right half is now A^-1.
        var inverse = [UInt8](repeating: 0, count: k * k)
        for r in 0..<k {
            for c in 0..<k {
                inverse[r * k + c] = work[r * stride + k + c]
            }
        }
        return inverse
    }

    // MARK: Row operations over the augmented working matrix (stride = 2k)

    /// Swaps rows `a` and `b` of the augmented working matrix.
    private static func swapRows(_ work: inout [UInt8], stride: Int, _ a: Int, _ b: Int) {
        if a == b { return }
        for c in 0..<stride {
            work.swapAt(a * stride + c, b * stride + c)
        }
    }

    /// Multiplies every entry of row `r` by the field scalar `s` in place.
    private static func scaleRow(_ work: inout [UInt8], stride: Int, _ r: Int, _ s: UInt8) {
        if s == 1 { return }
        let base = r * stride
        for c in 0..<stride {
            work[base + c] = GF256.mul(work[base + c], s)
        }
    }

    /// `row[dst] ^= factor * row[src]` over the whole augmented row (Gauss-Jordan elimination).
    private static func eliminateRow(_ work: inout [UInt8], stride: Int, src: Int, dst: Int, factor: UInt8) {
        let srcBase = src * stride
        let dstBase = dst * stride
        for c in 0..<stride {
            work[dstBase + c] ^= GF256.mul(factor, work[srcBase + c])
        }
    }
}
