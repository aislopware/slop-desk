import Foundation

// WF-6 (#8) FULL-RANGE COLOR — the SINGLE pure source of truth for the YCbCr→RGB
// coefficients the client's Metal shader uses. NO platform deps (this is the shared
// host+client protocol module), so the coefficient math is headlessly unit-testable
// while the actual rendered pixels (HW-only-verifiable) read these exact values.
//
// The encoded stream's luma range is negotiated over `helloAck` (the `fullRange` byte),
// so BOTH ends derive the range from the stream — the client never needs its own env
// flag, and the host's capture pixel-format + encoder VUI + the client's decoder
// pixel-format + this shader all follow ONE negotiated value. DEFAULT is `.video`
// (today's behaviour, byte-identical).
//
// ⚠️ THE WHOLE MATH DIFFERENCE between the two ranges is the LUMA expansion ONLY:
//   • video: Y in [16,235] → [0,1] via bias 16/255 + scale 255/219.
//   • full:  Y in [0,255]  → [0,1] via bias 0    + scale 1.0.
// CHROMA is IDENTICAL in both (centre 128/255, no extra 255/224 scale — today's shader
// already normalises chroma /255, the full-range convention, even for video-range, so
// DO NOT "correct" it or the OFF path stops being byte-identical). The four matrix
// coefficients (BT.709, Kr=0.2126 / Kb=0.0722 / Kg=0.7152) are RANGE-INDEPENDENT.

/// The luma code-range of an encoded NV12 stream.
public enum ColorRange: Sendable, Equatable {
    /// "Studio swing" — Y in [16,235], Cb/Cr in [16,240] (today's default; the NV12
    /// `…VideoRange` pixel-format variant + `video_full_range_flag = 0`).
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

/// PURE selector: the BT.709 YCbCr→RGB coefficients for `range`. The `.video` result
/// reproduces today's hardcoded shader literals EXACTLY (the unit test enforces this), so
/// the default-OFF path feeds the GPU identical numbers. `.full` changes ONLY the luma
/// (scale 1.0, bias 0); chroma + the four matrix coefficients are byte-identical to `.video`.
///
/// The coefficient table is computed natively here in `Float` end-to-end (the SINGLE source of
/// truth for the shader literals); pinned bit-exact by `YCbCrConversionTests` + the `ycbcr` golden
/// vector. ⚠️ Every value MUST stay `Float` — an `f64`/`Double` intermediate narrowed to `Float`
/// diverges the low bits and breaks the pinned bit-patterns. The four matrix coefficients + the
/// chroma centre are range-independent; only the luma scale/bias differ between the two ranges.
public enum YCbCrConversion {
    public static func coefficients(_ range: ColorRange) -> YCbCrCoefficients {
        // Shared (range-independent): chroma centre + the four BT.709 matrix coefficients.
        let chromaBias: Float = 128.0 / 255.0
        let crToR: Float = 1.5748
        let cbToG: Float = 0.1873
        let crToG: Float = 0.4681
        let cbToB: Float = 1.8556
        switch range {
        case .video:
            // Studio swing: Y in [16,235] → [0,1] via bias 16/255, scale 255/219.
            return YCbCrCoefficients(
                lumaScale: 255.0 / 219.0,
                lumaBias: 16.0 / 255.0,
                chromaBias: chromaBias,
                crToR: crToR,
                cbToG: cbToG,
                crToG: crToG,
                cbToB: cbToB,
            )
        case .full:
            // Full swing: Y in [0,255] → [0,1] (scale 1.0, bias 0); chroma + matrix unchanged.
            return YCbCrCoefficients(
                lumaScale: 1.0,
                lumaBias: 0.0,
                chromaBias: chromaBias,
                crToR: crToR,
                cbToG: cbToG,
                crToG: crToG,
                cbToB: cbToB,
            )
        }
    }
}
