//! The closed-loop validation harness's PURE half: content, loss, and the measurements over both.
//!
//! `slopdesk-loopback-validate` drives the real encode → packetize → lose → reassemble → decode
//! path on real hardware, and its stdout IS the evidence. Everything in that pipeline that is not a
//! framework call is here, for the reason every other split in this crate exists: a decision made
//! in a binary is a decision nothing can test, and this crate `forbid`s `unsafe` so the decisions
//! stay reviewable on their own.
//!
//! Three families live here:
//!
//! | family | what it decides |
//! | --- | --- |
//! | [`LossModel`] / [`should_drop`] | which fragment the wire eats, from an INDEX — never an RNG |
//! | the `fill_*` / `expected_*` pair | what a synthetic frame contains, and what it should decode to |
//! | [`Mad`] / [`ScenarioStats`] | what a run measured |
//!
//! ## Why the content formula is written twice
//! [`fill_luma`] writes a picture and [`expected_luma`] says what byte a given pixel of that
//! picture holds. They are the same formula on purpose: the decode side compares the frame it got
//! against the analytic source rather than against a stored reference, so a reference-chain
//! corruption — a delta predicted from data the decoder never received — shows up as a
//! mean-absolute-difference spike with no reference frames retained anywhere. A pair of functions
//! that must agree is exactly the shape a test can pin, and
//! [`tests::the_fill_and_the_expectation_are_the_same_formula`] does.
//!
//! ## Determinism, and why it is a requirement rather than a preference
//! No clock, no RNG, no thread. Loss is a function of a fragment's index, jitter is a function of a
//! frame's index, and every timestamp in the harness is a virtual millisecond counter. A validation
//! run that could not be repeated byte-for-byte would report a regression it could not reproduce.

use crate::adaptive_fec;
use crate::fragment::{Flags, FrameFragment};

/// Which fragments the wire eats, as a function of position.
///
/// Every arm is INDEX-driven. `EveryN` and `FirstPerGroup` model steady per-fragment attrition;
/// `WireBurst` models the one shape that actually costs a real link a frame — adjacent datagrams
/// lost together, which lands entirely inside one FEC group unless the transmit order interleaves.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LossModel {
    /// Nothing is dropped.
    None,
    /// Drop a fragment when its scenario-global index is a non-zero multiple of `n`, so roughly one
    /// in `n` dies and the very first fragment of the run never does.
    EveryN(usize),
    /// Drop the first `k` DATA fragments of EVERY per-frame FEC group; parity is never dropped.
    ///
    /// At `k == 1` every group has exactly one recoverable hole, which exercises FEC recovery on
    /// every group. On an OFF tier there is no group and no parity, so only data fragment zero dies
    /// and the frame is unrecoverable — which is the `Dropped` → forced-keyframe re-anchor path.
    FirstPerGroup(usize),
    /// Drop `len` CONSECUTIVE positions of each frame's WIRE transmission list, starting at
    /// `start`.
    ///
    /// The per-frame wire index, POST-interleave, is what this reads: without the reorder those
    /// positions are one FEC group and a single-parity code cannot repair two holes in it; with the
    /// column-major reorder they land one per group and every one of them repairs.
    WireBurst {
        /// First wire position dropped.
        start: usize,
        /// How many consecutive positions die.
        len: usize,
    },
}

/// Whether the wire eats this fragment.
///
/// `tier_group_size` is the frame's RESOLVED FEC group size — zero when the tier is OFF, which
/// [`LossModel::FirstPerGroup`] reads as "there are no groups, so only fragment zero is first".
#[must_use]
pub fn should_drop(
    fragment: &FrameFragment,
    global_index: usize,
    frame_local_index: usize,
    model: LossModel,
    tier_group_size: usize,
) -> bool {
    match model {
        LossModel::None => false,
        LossModel::EveryN(n) => n > 0 && global_index != 0 && global_index.is_multiple_of(n),
        LossModel::FirstPerGroup(k) => {
            if fragment.header.flags.contains(Flags::PARITY) {
                return false;
            }
            let group = if tier_group_size == 0 {
                usize::MAX
            } else {
                tier_group_size
            };
            usize::from(fragment.header.frag_index) % group < k
        },
        LossModel::WireBurst { start, len } => {
            frame_local_index >= start && frame_local_index < start.saturating_add(len)
        },
    }
}

/// One plane of a synthetic frame, as the harness hands it over: the bytes, and the row pitch.
///
/// A pair rather than two arguments because a plane read at another plane's stride is the entire
/// class of bug this split could introduce, and a pair that cannot be split cannot be mismatched.
#[derive(Debug)]
pub struct PlaneMut<'a> {
    /// The mapping, `stride * height` bytes.
    pub bytes: &'a mut [u8],
    /// Bytes from the start of one row to the start of the next.
    pub stride: usize,
    /// Visible bytes per row.
    pub width: usize,
    /// Rows.
    pub height: usize,
}

impl PlaneMut<'_> {
    /// The mutable slice of one row's VISIBLE bytes, or `None` when the geometry does not admit it.
    fn row(&mut self, y: usize) -> Option<&mut [u8]> {
        let start = y.checked_mul(self.stride)?;
        let end = start.checked_add(self.width)?;
        self.bytes.get_mut(start..end)
    }
}

/// The moving block's top-left corner for a frame index, as both the fill and the expectation read
/// it.
const fn block_origin(index: usize, width: usize, height: usize) -> (usize, usize) {
    let across = if width == 0 { 1 } else { width };
    let down = if height == 0 { 1 } else { height };
    (index.wrapping_mul(9) % across, index.wrapping_mul(5) % down)
}

/// Whether a pixel is inside the moving high-contrast block.
const fn inside_block(x: usize, y: usize, origin: (usize, usize)) -> bool {
    x.abs_diff(origin.0) < 40 && y.abs_diff(origin.1) < 40
}

/// The luma byte at `(x, y)` of frame `index` under the FULL-MOTION formula.
///
/// A 16-pixel checkerboard, a diagonal gradient that advances four levels per frame, and a moving
/// high-contrast block. Structured so a keyframe is a healthy multi-fragment size — which is what
/// exercises fragmentation and FEC group splitting at all — and frame-varying so deltas are not
/// trivial; a flat buffer collapses to about one fragment and proves nothing.
#[must_use]
pub const fn expected_luma(x: usize, y: usize, index: usize, width: usize, height: usize) -> u8 {
    luma(
        x,
        y,
        x.wrapping_add(y).wrapping_add(index.wrapping_mul(4)) & 0x3F,
        block_origin(index, width, height),
    )
}

/// The luma byte at `(x, y)` of frame `index` under the LOW-MOTION formula.
///
/// The same picture with the gradient FROZEN: only the block moves. This is the shape of a real
/// desktop, and it is the discriminator the ack-referenced-encoding probe turns on — genuine P
/// deltas collapse to a few kilobytes on static content, while a stream that is secretly all-intra
/// stays large no matter how little moved.
#[must_use]
pub const fn expected_luma_low_motion(x: usize, y: usize, index: usize, width: usize, height: usize) -> u8 {
    luma(x, y, x.wrapping_add(y) & 0x3F, block_origin(index, width, height))
}

/// The shared body of the two luma formulas: checkerboard, gradient, block.
#[expect(
    clippy::cast_possible_truncation,
    reason = "every branch is built to land in 0..=255 and is masked to a byte before it lands"
)]
const fn luma(x: usize, y: usize, gradient: usize, origin: (usize, usize)) -> u8 {
    if inside_block(x, y, origin) {
        return 235;
    }
    let cell = ((x >> 4) & 1) ^ ((y >> 4) & 1);
    let value = if cell == 0 {
        50 + gradient
    } else {
        190usize.saturating_sub(gradient)
    };
    (value & 0xFF) as u8
}

/// Paints the FULL-MOTION picture into a luma plane.
pub fn fill_luma(plane: &mut PlaneMut<'_>, index: usize) {
    paint(plane, index, expected_luma);
}

/// Paints the LOW-MOTION picture into a luma plane.
pub fn fill_luma_low_motion(plane: &mut PlaneMut<'_>, index: usize) {
    paint(plane, index, expected_luma_low_motion);
}

/// The shared row walk behind the two luma fills.
fn paint(plane: &mut PlaneMut<'_>, index: usize, formula: fn(usize, usize, usize, usize, usize) -> u8) {
    let (width, height) = (plane.width, plane.height);
    for y in 0..height {
        let Some(row) = plane.row(y) else { continue };
        for (x, byte) in row.iter_mut().enumerate() {
            *byte = formula(x, y, index, width, height);
        }
    }
}

/// Paints the FULL-MOTION chroma: near-neutral with a faint frame-varying pattern.
///
/// Faint rather than flat because a chroma plane that never changes lets the encoder predict it for
/// free, which would quietly halve the delta sizes the harness is measuring.
#[expect(
    clippy::cast_possible_truncation,
    reason = "both writes are 128 plus a value masked to three bits"
)]
pub fn fill_chroma(plane: &mut PlaneMut<'_>, index: usize) {
    for y in 0..plane.height {
        let Some(row) = plane.row(y) else { continue };
        for (x, byte) in row.iter_mut().enumerate() {
            *byte = if x % 2 == 0 {
                (128 + (((x >> 5) ^ (y >> 5) ^ index) & 7)) as u8
            } else {
                (128 + ((x >> 4) & 7)) as u8
            };
        }
    }
}

/// Paints a flat neutral chroma — the LOW-MOTION arm's, where only the luma block moves.
pub fn fill_chroma_neutral(plane: &mut PlaneMut<'_>) {
    for y in 0..plane.height {
        let Some(row) = plane.row(y) else { continue };
        row.fill(128);
    }
}

/// The LCG multiplier and increment Knuth's MMIX uses — a full-period 64-bit step.
const LCG_MUL: u64 = 6_364_136_223_846_793_005;
/// The LCG's additive constant, from the same source.
const LCG_ADD: u64 = 1_442_695_040_888_963_407;

/// Fills a plane with deterministic per-pixel noise, advancing `state` as it goes.
///
/// UNCOMPRESSIBLE content, and that is the whole point: the structured checkerboard compresses so
/// well that the fps governor's budget test can never fire — `VideoToolbox` fits it under any
/// actuated rate. Proving that fps itself must give needs content the encoder genuinely cannot
/// squeeze, which is what a real high-entropy scroll is.
///
/// Eight bytes per LCG step, so a 1280×720 frame costs about 138 000 steps rather than 1.1 million.
pub fn fill_noise(plane: &mut PlaneMut<'_>, state: &mut u64) {
    for y in 0..plane.height {
        let Some(row) = plane.row(y) else { continue };
        for chunk in row.chunks_mut(8) {
            *state = state.wrapping_mul(LCG_MUL).wrapping_add(LCG_ADD);
            let word = state.to_le_bytes();
            for (byte, source) in chunk.iter_mut().zip(word) {
                *byte = source;
            }
        }
    }
}

/// The LCG seed for one frame index, so a noise frame is a function of its number alone.
#[must_use]
pub const fn noise_seed(index: usize) -> u64 {
    (index as u64).wrapping_mul(LCG_MUL).wrapping_add(LCG_ADD)
}

/// The decode-side picture check: mean absolute difference against the analytic source.
///
/// A healthy lossy decode sits at a small constant. A frame predicted from data the decoder never
/// received does not — it is a different picture, and the difference is large and obvious. Sampling
/// every fifth row and every seventh column keeps the measurement a rounding error against the
/// encode it follows while still touching every region of the frame.
#[derive(Clone, Copy, Debug, Default)]
pub struct Mad {
    /// Sum of the per-frame means.
    sum: f64,
    /// How many frames were measured.
    count: u64,
    /// The largest per-frame mean seen.
    max: f64,
    /// The largest per-frame mean seen within three frames of a whole-frame wire loss.
    post_drop_max: f64,
}

impl Mad {
    /// A fresh accumulator.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            sum: 0.0,
            count: 0,
            max: 0.0,
            post_drop_max: 0.0,
        }
    }

    /// Folds one decoded luma plane against the source formula for `index`.
    ///
    /// `drop_recent` says a whole frame died on the wire within the last three frames, which routes
    /// the measurement into [`Self::post_drop_max`] as well — the number every survival verdict in
    /// the harness compares against the clean arm's own noise floor.
    pub fn measure(&mut self, plane: &LumaView<'_>, index: usize, low_motion: bool, drop_recent: bool) {
        let mut sum = 0_u64;
        let mut n = 0_u64;
        let mut y = 2;
        while y < plane.height {
            let start = y.saturating_mul(plane.stride);
            let Some(row) = plane.bytes.get(start..start.saturating_add(plane.width)) else {
                break;
            };
            let mut x = 3;
            while x < plane.width {
                let Some(&got) = row.get(x) else { break };
                let want = if low_motion {
                    expected_luma_low_motion(x, y, index, plane.width, plane.height)
                } else {
                    expected_luma(x, y, index, plane.width, plane.height)
                };
                sum += u64::from(got.abs_diff(want));
                n += 1;
                x += 7;
            }
            y += 5;
        }
        if n == 0 {
            return;
        }
        // Divided, then compared — never fused, per the repo's float rule.
        #[expect(
            clippy::cast_precision_loss,
            reason = "`sum` is a sampled absolute-difference total (255 per sample) and `n` the sample \
                      count — both bounded by the plane's pixel count, exact in an f64 many orders below \
                      its mantissa"
        )]
        let mean = sum as f64 / n as f64;
        self.sum += mean;
        self.count += 1;
        self.max = f64::max(self.max, mean);
        if drop_recent {
            self.post_drop_max = f64::max(self.post_drop_max, mean);
        }
    }

    /// The mean of the per-frame means, or zero when nothing was measured.
    #[must_use]
    #[expect(
        clippy::cast_precision_loss,
        reason = "`count` is a frame count in a headless run — thousands, not quadrillions"
    )]
    pub fn average(&self) -> f64 {
        if self.count == 0 {
            return 0.0;
        }
        self.sum / self.count as f64
    }

    /// The worst per-frame mean.
    #[must_use]
    pub const fn max(&self) -> f64 {
        self.max
    }

    /// The worst per-frame mean measured just after a whole-frame wire loss.
    #[must_use]
    pub const fn post_drop_max(&self) -> f64 {
        self.post_drop_max
    }
}

/// A decoded luma plane, borrowed for one measurement.
#[derive(Debug)]
pub struct LumaView<'a> {
    /// The mapping.
    pub bytes: &'a [u8],
    /// Row pitch.
    pub stride: usize,
    /// Visible bytes per row.
    pub width: usize,
    /// Rows.
    pub height: usize,
}

/// What one closed-loop scenario counted.
#[derive(Clone, Debug, Default)]
pub struct ScenarioStats {
    /// The scenario's name, as the summary table prints it.
    pub name: String,
    /// Frames the encoder emitted.
    pub encoded: u64,
    /// Fragments handed to the wire.
    pub fragments_sent: u64,
    /// Fragments the loss model ate.
    pub fragments_dropped: u64,
    /// Frames the reassembler completed.
    pub reassembled: u64,
    /// Of those, how many needed parity to complete.
    pub fec_recovered: u64,
    /// Frames the reassembler declared unrecoverable.
    pub frames_dropped: u64,
    /// Frames the decoder delivered.
    pub decoded: u64,
    /// Decodes that failed — a delta whose reference never arrived, or a mis-recovery.
    pub decode_failures: u64,
}

impl ScenarioStats {
    /// An empty run under a name.
    #[must_use]
    pub fn named(name: &str) -> Self {
        Self {
            name: name.to_owned(),
            ..Self::default()
        }
    }
}

/// How a tier prints: its group size, or `OFF`.
#[must_use]
pub fn tier_description(tier: u8) -> String {
    adaptive_fec::group_size(tier, 5).map_or_else(|| "OFF".to_owned(), |group| format!("g{group}"))
}

/// The heavier of two tiers by REDUNDANCY, which the wire's tier numbering does not order.
///
/// `g2` protects more than `g5`, which protects more than OFF, and none of that is visible in the
/// tier byte — so a peak-tier reading that used `max` on the raw value would report the wrong one.
#[must_use]
pub fn heavier_tier(a: u8, b: u8) -> u8 {
    let redundancy = |tier: u8| adaptive_fec::group_size(tier, 5).map_or(0, |group| 100 - group);
    if redundancy(b) > redundancy(a) { b } else { a }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::indexing_slicing,
        reason = "the fills write exact small integers and the MADs compare exact zeroes, and a test that \
                  indexes past its own scratch plane should fail loudly rather than shrug"
    )]

    use super::{
        LossModel, LumaView, Mad, PlaneMut, ScenarioStats, expected_luma, expected_luma_low_motion,
        fill_chroma, fill_chroma_neutral, fill_luma, fill_luma_low_motion, fill_noise, heavier_tier,
        noise_seed, should_drop, tier_description,
    };
    use crate::fragment::{Flags, FrameFragment, FrameFragmentHeader};

    /// A plane over a freshly-zeroed mapping at a stride wider than the picture, so padding is
    /// always distinguishable from content.
    fn scratch(width: usize, height: usize) -> (Vec<u8>, usize) {
        let stride = width + 7;
        (vec![0_u8; stride * height], stride)
    }

    fn plane(bytes: &mut [u8], stride: usize, width: usize, height: usize) -> PlaneMut<'_> {
        PlaneMut {
            bytes,
            stride,
            width,
            height,
        }
    }

    fn fragment(frag_index: u16, flags: Flags) -> FrameFragment {
        FrameFragment::new(FrameFragmentHeader::new(1, 1, frag_index, 8, flags, 4, 0), vec![
            0;
            4
        ])
    }

    /// The pair the module header promises: whatever the fill wrote, the expectation predicts,
    /// on both formulas and at a padded stride.
    #[test]
    fn the_fill_and_the_expectation_are_the_same_formula() {
        let (width, height) = (48, 40);
        let (mut bytes, stride) = scratch(width, height);
        for index in [0_usize, 1, 7, 250] {
            fill_luma(&mut plane(&mut bytes, stride, width, height), index);
            for y in 0..height {
                for x in 0..width {
                    assert_eq!(
                        bytes[y * stride + x],
                        expected_luma(x, y, index, width, height),
                        "full motion at ({x},{y}) of frame {index}"
                    );
                }
                // Padding past the visible width is never written.
                assert_eq!(&bytes[y * stride + width..(y + 1) * stride], &[0; 7]);
            }
            fill_luma_low_motion(&mut plane(&mut bytes, stride, width, height), index);
            for y in 0..height {
                for x in 0..width {
                    assert_eq!(
                        bytes[y * stride + x],
                        expected_luma_low_motion(x, y, index, width, height),
                        "low motion at ({x},{y}) of frame {index}"
                    );
                }
            }
        }
    }

    /// The low-motion picture is frozen except for the block; the full-motion one is not.
    #[test]
    fn only_the_block_moves_in_the_low_motion_picture() {
        let (width, height) = (256, 256);
        // A pixel far from either block position: (200, 200) is >40 from both origins below.
        let still = expected_luma_low_motion(200, 200, 0, width, height);
        assert_eq!(still, expected_luma_low_motion(200, 200, 1, width, height));
        assert_ne!(
            expected_luma(200, 200, 0, width, height),
            expected_luma(200, 200, 1, width, height),
            "the full-motion gradient advances every frame"
        );
        // The block itself is the brightest value and it does move.
        assert_eq!(expected_luma_low_motion(0, 0, 0, width, height), 235);
        assert_ne!(expected_luma_low_motion(0, 0, 20, width, height), 235);
    }

    /// Chroma stays near neutral in both arms, and the neutral fill is exactly neutral.
    #[test]
    fn chroma_stays_near_neutral() {
        let (width, height) = (32, 16);
        let (mut bytes, stride) = scratch(width, height);
        fill_chroma(&mut plane(&mut bytes, stride, width, height), 3);
        for y in 0..height {
            for x in 0..width {
                let value = bytes[y * stride + x];
                assert!((128..=135).contains(&value), "chroma {value} at ({x},{y})");
            }
        }
        fill_chroma_neutral(&mut plane(&mut bytes, stride, width, height));
        for y in 0..height {
            assert!(bytes[y * stride..y * stride + width].iter().all(|&b| b == 128));
        }
    }

    /// Noise is a function of the frame index and nothing else, and it is not flat.
    #[test]
    fn noise_is_deterministic_per_frame_and_not_flat() {
        let (width, height) = (64, 8);
        let (mut first, stride) = scratch(width, height);
        let (mut second, _) = scratch(width, height);
        let mut state = noise_seed(11);
        fill_noise(&mut plane(&mut first, stride, width, height), &mut state);
        let mut again = noise_seed(11);
        fill_noise(&mut plane(&mut second, stride, width, height), &mut again);
        assert_eq!(first, second, "the same seed paints the same frame");

        let (mut other, _) = scratch(width, height);
        let mut third = noise_seed(12);
        fill_noise(&mut plane(&mut other, stride, width, height), &mut third);
        assert_ne!(first, other, "a different frame index paints a different frame");

        let distinct: std::collections::BTreeSet<u8> = first
            .chunks(stride)
            .flat_map(|row| row[..width].iter().copied())
            .collect();
        assert!(distinct.len() > 200, "noise touches most of the byte range");
    }

    /// Every loss arm drops exactly what its doc says, and parity is never eaten by the per-group
    /// arm.
    #[test]
    fn each_loss_arm_eats_what_it_promises() {
        let data = fragment(0, Flags::empty());
        let parity = fragment(0, Flags::PARITY);

        assert!(!should_drop(&data, 100, 0, LossModel::None, 5));

        assert!(
            !should_drop(&data, 0, 0, LossModel::EveryN(50), 5),
            "index zero survives"
        );
        assert!(should_drop(&data, 50, 0, LossModel::EveryN(50), 5));
        assert!(!should_drop(&data, 51, 0, LossModel::EveryN(50), 5));
        assert!(
            !should_drop(&data, 50, 0, LossModel::EveryN(0), 5),
            "n = 0 eats nothing"
        );

        assert!(should_drop(&data, 0, 0, LossModel::FirstPerGroup(1), 5));
        assert!(!should_drop(
            &fragment(1, Flags::empty()),
            0,
            0,
            LossModel::FirstPerGroup(1),
            5
        ));
        assert!(should_drop(
            &fragment(5, Flags::empty()),
            0,
            0,
            LossModel::FirstPerGroup(1),
            5
        ));
        assert!(
            !should_drop(&parity, 0, 0, LossModel::FirstPerGroup(1), 5),
            "parity is never dropped"
        );
        // An OFF tier has no groups: only data fragment zero is "first".
        assert!(should_drop(&data, 0, 0, LossModel::FirstPerGroup(1), 0));
        assert!(!should_drop(
            &fragment(1, Flags::empty()),
            0,
            0,
            LossModel::FirstPerGroup(1),
            0
        ));

        let burst = LossModel::WireBurst { start: 1, len: 2 };
        assert!(!should_drop(&data, 0, 0, burst, 5));
        assert!(should_drop(&data, 0, 1, burst, 5));
        assert!(should_drop(&data, 0, 2, burst, 5));
        assert!(!should_drop(&data, 0, 3, burst, 5));
    }

    /// A frame measured against its own source is near zero; one measured against another frame's
    /// is not, and a post-drop measurement lands in the second accumulator too.
    #[test]
    fn the_mad_separates_the_right_picture_from_the_wrong_one() {
        let (width, height) = (64, 48);
        let (mut bytes, stride) = scratch(width, height);
        fill_luma(&mut plane(&mut bytes, stride, width, height), 5);
        let view = LumaView {
            bytes: &bytes,
            stride,
            width,
            height,
        };

        let mut clean = Mad::new();
        clean.measure(&view, 5, false, false);
        assert_eq!(clean.average(), 0.0, "the source compared with itself");
        assert_eq!(clean.post_drop_max(), 0.0, "no loss was recent");

        let mut wrong = Mad::new();
        wrong.measure(&view, 40, false, true);
        assert!(wrong.average() > 1.0, "a different frame is a different picture");
        assert_eq!(wrong.max(), wrong.post_drop_max(), "a recent loss routes to both");
    }

    /// Tier printing and the redundancy ordering the wire numbering hides.
    #[test]
    fn tiers_print_and_order_by_redundancy_rather_than_by_number() {
        assert_eq!(tier_description(1), "OFF");
        assert_eq!(tier_description(0), "g5");
        // g2 protects more than g5, and g5 more than OFF, whatever the tier bytes are.
        assert_eq!(tier_description(heavier_tier(0, 4)), tier_description(4));
        assert_eq!(heavier_tier(1, 0), 0, "any parity beats OFF");
        assert_eq!(heavier_tier(0, 1), 0);
        assert_eq!(heavier_tier(0, 0), 0);
    }

    /// A named run starts empty.
    #[test]
    fn a_named_run_starts_at_zero() {
        let stats = ScenarioStats::named("1. clean link");
        assert_eq!(stats.name, "1. clean link");
        assert_eq!(stats.encoded, 0);
        assert_eq!(stats.decode_failures, 0);
    }
}
