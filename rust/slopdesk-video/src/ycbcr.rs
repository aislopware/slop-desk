//! The BT.709 YCbCr→RGB coefficients the client's Metal shader applies —
//! `Sources/SlopDeskVideoProtocol/YCbCrConversion.swift`.
//!
//! This is the SINGLE source of truth for the shader's literals, kept platform-free so the
//! coefficient math is headlessly testable while the actual rendered pixels — verifiable only on
//! hardware — read these exact values.
//!
//! The stream's luma range is negotiated over `helloAck` (the `full_range` byte), so BOTH ends
//! derive it from the stream: the client never needs its own flag, and the host's capture pixel
//! format, the encoder VUI, the client's decoder pixel format and this shader all follow one
//! negotiated value.
//!
//! ## The whole difference between the two ranges is the LUMA expansion
//!
//! * video: Y in `[16, 235]` → `[0, 1]` via bias `16/255` and scale `255/219`.
//! * full: Y in `[0, 255]` → `[0, 1]` via bias `0` and scale `1.0`.
//!
//! CHROMA is IDENTICAL in both — centre `128/255`, with no extra `255/224` scale, because the
//! shader already normalises chroma by `/255` (the full-range convention) even for video range. Do
//! NOT "correct" that, or the default path stops being byte-identical. The four matrix coefficients
//! (Kr = 0.2126, Kb = 0.0722, Kg = 0.7152) are range-independent.
//!
//! ⚠️ Every value is `f32` end to end. An `f64` intermediate narrowed to `f32` diverges in the low
//! bits and breaks the bit patterns the `ycbcr` golden vector pins.

/// The luma code range of an encoded NV12 stream.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ColorRange {
    /// "Studio swing" — Y in `[16, 235]`, Cb/Cr in `[16, 240]`: the NV12 `…VideoRange` pixel-format
    /// variant with `video_full_range_flag = 0`. The default.
    #[default]
    Video,
    /// "Full swing" — Y in `[0, 255]`: the NV12 `…FullRange` variant with
    /// `video_full_range_flag = 1`. About 16% more luma code space.
    Full,
}

impl ColorRange {
    /// Maps the negotiated `helloAck.fullRange` wire bit to a range. It is a bool on the wire, so
    /// there is no unknown value to handle; `false` is `Video`, the safe default.
    #[must_use]
    pub const fn from_full_range(full_range: bool) -> Self {
        if full_range { Self::Full } else { Self::Video }
    }
}

/// The seven YCbCr→RGB coefficients the Metal fragment shader applies.
///
/// With the UV already cropped for zoom and pan, the shader computes:
///
/// ```text
/// yy = (y - luma_bias) * luma_scale
/// cb =  cbcr.x - chroma_bias
/// cr =  cbcr.y - chroma_bias
/// r  = yy + cr_to_r * cr
/// g  = yy - cb_to_g * cb - cr_to_g * cr
/// b  = yy + cb_to_b * cb
/// ```
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct YCbCrCoefficients {
    /// Luma scale: maps the bias-subtracted luma onto `[0, 1]`. Video `255/219`, full `1.0`.
    pub luma_scale: f32,
    /// Luma bias subtracted before scaling. Video `16/255`, full `0`.
    pub luma_bias: f32,
    /// Chroma centre subtracted from Cb/Cr. `128/255` in BOTH ranges.
    pub chroma_bias: f32,
    /// Cr→R coefficient `2(1 - Kr) = 1.5748`. Range-independent.
    pub cr_to_r: f32,
    /// Cb→G coefficient `2·Kb(1 - Kb)/Kg = 0.1873`. Range-independent.
    pub cb_to_g: f32,
    /// Cr→G coefficient `2·Kr(1 - Kr)/Kg = 0.4681`. Range-independent.
    pub cr_to_g: f32,
    /// Cb→B coefficient `2(1 - Kb) = 1.8556`. Range-independent.
    pub cb_to_b: f32,
}

/// The BT.709 coefficients for `range`.
///
/// `Video` reproduces the shader's hardcoded literals exactly, so the default path feeds the GPU
/// identical numbers. `Full` changes ONLY the luma pair; chroma and the four matrix coefficients
/// are bit-identical between the two.
#[must_use]
pub const fn coefficients(range: ColorRange) -> YCbCrCoefficients {
    let (luma_scale, luma_bias) = match range {
        // Studio swing: Y in [16, 235] → [0, 1] via bias 16/255, scale 255/219.
        ColorRange::Video => (255.0 / 219.0, 16.0 / 255.0),
        // Full swing: Y in [0, 255] → [0, 1]; chroma and matrix unchanged.
        ColorRange::Full => (1.0, 0.0),
    };
    YCbCrCoefficients {
        luma_scale,
        luma_bias,
        // Range-independent: the chroma centre and the four BT.709 matrix coefficients, written as
        // literals so no intermediate binding can widen them to `f64` on the way in.
        chroma_bias: 128.0 / 255.0,
        cr_to_r: 1.5748,
        cb_to_g: 0.1873,
        cr_to_g: 0.4681,
        cb_to_b: 1.8556,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "these constants are pinned bit patterns, so exact equality is the assertion"
    )]

    use super::{ColorRange, coefficients};

    #[test]
    fn only_the_luma_pair_differs_between_the_ranges() {
        let video = coefficients(ColorRange::Video);
        let full = coefficients(ColorRange::Full);
        assert_eq!(video.chroma_bias, full.chroma_bias);
        assert_eq!(video.cr_to_r, full.cr_to_r);
        assert_eq!(video.cb_to_g, full.cb_to_g);
        assert_eq!(video.cr_to_g, full.cr_to_g);
        assert_eq!(video.cb_to_b, full.cb_to_b);
        assert_eq!(full.luma_scale, 1.0);
        assert_eq!(full.luma_bias, 0.0);
        assert_ne!(video.luma_scale, full.luma_scale);
    }

    #[test]
    fn the_wire_bit_maps_both_ways() {
        assert_eq!(ColorRange::from_full_range(false), ColorRange::Video);
        assert_eq!(ColorRange::from_full_range(true), ColorRange::Full);
        assert_eq!(
            ColorRange::default(),
            ColorRange::Video,
            "video is the safe default"
        );
    }

    #[test]
    fn the_video_range_expands_studio_swing_onto_zero_to_one() {
        // The property the constants exist for: 16/255 maps to 0 and 235/255 maps to 1.
        let c = coefficients(ColorRange::Video);
        let expand = |code: f32| (code / 255.0 - c.luma_bias) * c.luma_scale;
        assert!(expand(16.0).abs() < 1e-6, "black lands at 0");
        assert!((expand(235.0) - 1.0).abs() < 1e-6, "white lands at 1");
    }
}
