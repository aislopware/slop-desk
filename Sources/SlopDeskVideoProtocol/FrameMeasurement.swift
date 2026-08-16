// The three measurements the capture path takes on a frame it has just locked, as the Swift face
// of `rust/slopdesk-video`'s `frame_hash`, `scroll_shift` and `adaptive_qp` — reached through
// `rust/slopdesk-ffi`'s `video_frame` door.
//
// ## Why they share one file
//
// They are one pass over one pair of locked planes. The frame hash says whether this frame is a
// byte-identical re-delivery (skip the encoder entirely); the scroll estimate says how far the
// picture translated (the client can warp the last frame on a spare tick instead of waiting); the
// QP ceiling says how much changed (a one-row caret move must not be coarsened like a scroll
// burst). All three walk the same rows with the same row hash, and splitting them across three
// files only ever meant three copies of the same plane-borrow preamble.
//
// ## What is not here
//
// Every byte of the fold, the mode-hash background exclusion, the informative-row scoring, the QP
// ramp and the plane validation. They are Rust's, in a crate that forbids `unsafe`, and this file
// holds no arithmetic at all: a stride, a width and a base address go over, a scalar comes back.
// The one number that used to be spelled on both sides — the "no measurement" sentinel — is now
// vended by the door, because comparing a hash against it IS the frame-suppression decision.
//
// The planes cross as ADDRESSES, which no other door here does: the pixels only exist inside a
// Core Video mapping, so there is no `Data` to lend. `CVPixelBufferLockBaseAddress` around the call
// is what `withUnsafeBytes` is everywhere else, and the length arithmetic (`stride * rows`) is done
// with a checked multiply on the Rust side, so an absurd stride is a defined "no measurement".

import CSlopDeskFFI

/// The constants the frame hash is read against.
public enum FrameHash {
    /// The value a degenerate or guarded-out call answers instead of a hash — distinct from any
    /// real hash, including the one a genuine all-zero plane produces. Vended by the door.
    public static let SENTINEL: UInt64 = slopdesk_video_frame_hash_sentinel()
}

/// The whole-frame hash: one strong 64-bit value per captured frame.
public enum FrameHasher {
    /// Hashes an NV12 frame's already-locked luma and interleaved-chroma planes into one value,
    /// reading only the first `width` bytes of each `*Stride`-spaced row so the answer depends on
    /// the picture and not on the capture's padding.
    ///
    /// Answers ``FrameHash/SENTINEL`` for a null `y`, a zero dimension, a `yStride < width` or a
    /// `stride * height` that overflows — never a fault. A nil `cbcr` hashes luma only.
    ///
    /// The pointers are BORROWED for the call: the caller must hold the pixel-buffer lock across it.
    public static func hashNV12(
        y: UnsafeRawPointer?,
        yStride: Int,
        width: Int,
        height: Int,
        cbcr: UnsafeRawPointer?,
        cbcrStride: Int,
    ) -> UInt64 {
        slopdesk_video_frame_hash_nv12(
            y?.assumingMemoryBound(to: UInt8.self), yStride, width, height,
            cbcr?.assumingMemoryBound(to: UInt8.self), cbcrStride,
        )
    }
}

/// The dominant vertical shift between two frames — how far the picture scrolled.
public enum ScrollShiftEstimator {
    /// Estimates the vertical content shift between two locked NV12 luma planes.
    ///
    /// `shift` positive means the content moved DOWN; `confidenceMilli` is in `0...1000` and is
    /// what the caller gates on; `bandTop`/`bandBottom` are the inclusive current-frame row span of
    /// the moving content, or `-1`/`-1` when there is no band to reproject. `quantizeShift`
    /// (`0...7`) drops that many low bits of each luma byte before the row hash, so capture noise
    /// stops breaking the exact row match; `0` is the byte-for-byte path.
    ///
    /// An unmeasurable pair answers `(0, 0, -1, -1)` — a defined "no measurement", not a fault.
    /// The pointers are BORROWED: the caller must hold both pixel-buffer locks across the call.
    public static func estimateNV12(
        prevY: UnsafeRawPointer?,
        prevStride: Int,
        curY: UnsafeRawPointer?,
        curStride: Int,
        width: Int,
        height: Int,
        maxShift: Int,
        quantizeShift: UInt8 = 0,
    ) -> (shift: Int32, confidenceMilli: UInt32, bandTop: Int32, bandBottom: Int32) {
        let estimate = slopdesk_video_scroll_nv12(
            lumaPair(prevY, prevStride, curY, curStride, width, height), maxShift, quantizeShift,
        )
        return (estimate.shift, estimate.confidence_milli, estimate.band_top, estimate.band_bottom)
    }
}

/// The per-frame QP ceiling implied by how much of the picture changed.
public enum AdaptiveFrameQP {
    // swiftlint:disable function_parameter_count

    /// The adaptive `MaxAllowedFrameQP` ceiling for the frame in `curY`, from its change against
    /// `prevY`.
    ///
    /// `bLoMilli` and `bHiMilli` are the change-fraction thresholds ×1000: below the first the
    /// ceiling is `qpSharp` (the picture stays sharp), above the second it is `qpMax` (blur is
    /// graded), and between them it ramps. `changeMilli` is the measured fraction ×1000, for the
    /// log rather than for the encoder.
    ///
    /// An unmeasurable pair answers `(qpMax, 0)`: the configured static ceiling, applied
    /// unnarrowed, which is the safe fallback rather than a guess at a ceiling. The pointers are
    /// BORROWED: the caller must hold both pixel-buffer locks across the call.
    public static func computeNV12(
        prevY: UnsafeRawPointer?,
        prevStride: Int,
        curY: UnsafeRawPointer?,
        curStride: Int,
        width: Int,
        height: Int,
        qpSharp: UInt8,
        qpMax: UInt8,
        bLoMilli: UInt32,
        bHiMilli: UInt32,
    ) -> (qp: UInt8, changeMilli: UInt32) {
        let decision = slopdesk_video_adaptive_qp_nv12(
            lumaPair(prevY, prevStride, curY, curStride, width, height),
            qpSharp, qpMax, bLoMilli, bHiMilli,
        )
        return (decision.qp, decision.change_milli)
    }

    // swiftlint:enable function_parameter_count
}

/// The two planes a frame-difference measurement compares, in the shape the door takes them.
///
/// One helper for both entries, because the pair is the argument that must not be assembled
/// differently at two call sites — a plane paired with the other plane's stride is the bug the
/// whole port removes.
private func lumaPair(
    _ prevY: UnsafeRawPointer?, _ prevStride: Int,
    _ curY: UnsafeRawPointer?, _ curStride: Int,
    _ width: Int, _ height: Int,
) -> SlopDeskLumaPair {
    SlopDeskLumaPair(
        prev: SlopDeskLumaPlane(base: prevY?.assumingMemoryBound(to: UInt8.self), stride: prevStride),
        cur: SlopDeskLumaPlane(base: curY?.assumingMemoryBound(to: UInt8.self), stride: curStride),
        width: width,
        height: height,
    )
}
