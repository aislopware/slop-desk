// FULL-RANGE COLOR — the vocabulary for the YCbCr→RGB coefficients the client's Metal shader uses,
// as the Swift face of `rust/slopdesk-video`'s `ycbcr`, reached through `rust/slopdesk-ffi`'s
// `video_policy` door.
//
// The encoded stream's luma range is negotiated over `helloAck` (the `fullRange` byte), so BOTH
// ends derive the range from the stream — the client never needs its own env flag, and the host's
// capture pixel-format + encoder VUI + the client's decoder pixel-format + this shader all follow
// ONE negotiated value. DEFAULT is `.video`.
//
// ⚠️ THE WHOLE MATH DIFFERENCE between the two ranges is the LUMA expansion ONLY:
//   • video: Y in [16,235] → [0,1] via bias 16/255 + scale 255/219.
//   • full:  Y in [0,255]  → [0,1] via bias 0    + scale 1.0.
// CHROMA is IDENTICAL in both (centre 128/255, no extra 255/224 scale — the shader already
// normalises chroma /255, the full-range convention, even for video-range, so DO NOT "correct" it
// or the default path stops being byte-identical). The four matrix coefficients (BT.709,
// Kr=0.2126 / Kb=0.0722 / Kg=0.7152) are RANGE-INDEPENDENT.
//
// The literals themselves are NOT here. They are `f32` end to end on the Rust side — an `f64`
// intermediate narrowed to `Float` diverges in the low bits and breaks the bit patterns the `ycbcr`
// golden vector pins — and a second copy of a pinned constant is exactly the drift this door
// removes. What stays is the vocabulary the renderer and the wire speak in.

import CSlopDeskFFI

/// The luma code-range of an encoded NV12 stream.
public enum ColorRange: Sendable, Equatable {
    /// "Studio swing" — Y in [16,235], Cb/Cr in [16,240] (the default; the NV12 `…VideoRange`
    /// pixel-format variant + `video_full_range_flag = 0`).
    case video
    /// "Full swing" — Y in [0,255] (the NV12 `…FullRange` pixel-format variant +
    /// `video_full_range_flag = 1`). ~16% more luma code space.
    case full

    /// Maps the negotiated `helloAck.fullRange` wire bit to a range. A stray/unknown value
    /// can never reach here (it is a `Bool` on the wire); `false` → `.video` (the safe default).
    public init(fullRange: Bool) { self = fullRange ? .full : .video }

    /// The wire bit for `helloAck.fullRange`.
    public var isFullRange: Bool { self == .full }
}

/// The seven YCbCr→RGB coefficients the Metal fragment shader applies (and the unit test
/// pins to the shader's literals). All `Float` to match the GPU's single-precision math.
///
/// The shader computes (UV already cropped for zoom/pan):
/// ```
/// yy = (y  - lumaBias) * lumaScale
/// cb =  cbcr.x - chromaBias
/// cr =  cbcr.y - chromaBias
/// r  = yy + crToR * cr
/// g  = yy - cbToG * cb - crToG * cr
/// b  = yy + cbToB * cb
/// ```
public struct YCbCrCoefficients: Sendable, Equatable {
    /// Luma scale: maps the (bias-subtracted) luma onto [0,1]. video `255/219`, full `1.0`.
    public let lumaScale: Float
    /// Luma bias subtracted before scaling. video `16/255`, full `0`.
    public let lumaBias: Float
    /// Chroma centre subtracted from Cb/Cr. `128/255` in BOTH ranges.
    public let chromaBias: Float
    /// Cr→R coefficient `2(1-Kr) = 1.5748`. Range-independent.
    public let crToR: Float
    /// Cb→G coefficient `2·Kb(1-Kb)/Kg = 0.1873`. Range-independent.
    public let cbToG: Float
    /// Cr→G coefficient `2·Kr(1-Kr)/Kg = 0.4681`. Range-independent.
    public let crToG: Float
    /// Cb→B coefficient `2(1-Kb) = 1.8556`. Range-independent.
    public let cbToB: Float

    public init(
        lumaScale: Float,
        lumaBias: Float,
        chromaBias: Float,
        crToR: Float,
        cbToG: Float,
        crToG: Float,
        cbToB: Float,
    ) {
        self.lumaScale = lumaScale
        self.lumaBias = lumaBias
        self.chromaBias = chromaBias
        self.crToR = crToR
        self.cbToG = cbToG
        self.crToG = crToG
        self.cbToB = cbToB
    }
}

/// The BT.709 YCbCr→RGB coefficient table, selected by range.
public enum YCbCrConversion {
    /// The coefficients for `range`. `.video` reproduces the shader's hardcoded literals EXACTLY,
    /// so the default path feeds the GPU identical numbers; `.full` changes ONLY the luma pair.
    ///
    /// One flag is the whole input because that is the whole difference — chroma and the four
    /// matrix coefficients are bit-identical between the two ranges.
    public static func coefficients(_ range: ColorRange) -> YCbCrCoefficients {
        let c = slopdesk_ycbcr_coefficients(range.isFullRange)
        return YCbCrCoefficients(
            lumaScale: c.luma_scale,
            lumaBias: c.luma_bias,
            chromaBias: c.chroma_bias,
            crToR: c.cr_to_r,
            cbToG: c.cb_to_g,
            crToG: c.cr_to_g,
            cbToB: c.cb_to_b,
        )
    }
}
