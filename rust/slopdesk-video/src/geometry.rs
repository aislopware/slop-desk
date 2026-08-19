//! Pure 2-D geometry and the aspect-fit math — `Sources/SlopDeskVideoProtocol/Geometry.swift`.
//!
//! These types mirror `CGPoint` / `CGSize` / `CGRect` without any platform dependency, so the
//! renderer's FORWARD transform and the input encoder's INVERSE transform derive from one shared
//! source and cannot drift — including across a fit↔fill toggle.
//!
//! ## Bit-exactness is the contract, not an aspiration
//!
//! `golden/golden_vectors.json` pins these as raw `f64` BIT PATTERNS, so two rules bind every line
//! below and are repeated at each site rather than assumed:
//!
//! * `a * b + c` stays two operations. A fused multiply-add rounds once instead of twice and
//!   changes the low bit, which the pinned patterns catch and nothing else would.
//! * Clamps use `f64::max` / `f64::min`, which IGNORE NaN and answer the other operand. Swift
//!   spells the same thing `Double.maximum` / `Double.minimum` — deliberately NOT
//!   `Swift.max`/`min`, which propagate NaN. A NaN pan must clamp to a finite `±panLimit`, not
//!   poison the coordinate.
//!
//! The crate has ONE other float policy and [`ordered_clamp`] is it, kept here so the two are read
//! together rather than discovered apart: it lets a NaN fall THROUGH, because its callers screen
//! for finiteness before the clamp and would rather see the NaN than a silently plausible bound.
//! It is not `f64::clamp`, which panics on `lo > hi`. Two policies, both deliberate; the names are
//! what keep a future reader from merging them.
//!
//! What did NOT come over is the `#if canImport(CoreGraphics)` bridge at the bottom of the Swift
//! file. `CGPoint` conversion is platform glue for an `AppKit` caller, which is the one category
//! `CLAUDE.md` keeps in Swift.

/// An ordered clamp that lets a NaN fall THROUGH to itself: below `lo` is `lo`, above `hi` is `hi`.
///
/// The crate's OTHER clamp policy — see the module header. Not [`f64::clamp`], which panics when
/// `lo > hi` and answers NaN for a NaN; every caller here has already screened the value for
/// finiteness, so a NaN arriving means a bug worth seeing rather than a bound worth inventing.
///
/// The comparisons are ternaries and stay ternaries: `golden/golden_vectors.json` pins the playout
/// and scroll-reprojection outputs these feed, and `f64::max`/`min` answer differently on a NaN.
#[must_use]
pub fn ordered_clamp(value: f64, lo: f64, hi: f64) -> f64 {
    if value < lo {
        return lo;
    }
    if value > hi {
        return hi;
    }
    value
}

/// A pure 2-D point (host space, points).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoPoint {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}

impl VideoPoint {
    /// Builds a point.
    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// A pure 2-D size (points).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoSize {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl VideoSize {
    /// Builds a size.
    #[must_use]
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

/// A pure rectangle (origin + size), in whatever coordinate space the caller states.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoRect {
    /// The origin corner — which corner depends on the coordinate space the caller declared.
    pub origin: VideoPoint,
    /// The extent.
    pub size: VideoSize,
}

impl VideoRect {
    /// Builds a rect from an origin and a size.
    #[must_use]
    pub const fn new(origin: VideoPoint, size: VideoSize) -> Self {
        Self { origin, size }
    }

    /// Builds a rect from scalar components.
    #[must_use]
    pub const fn xywh(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            origin: VideoPoint::new(x, y),
            size: VideoSize::new(width, height),
        }
    }

    /// Minimum x (`origin.x`). Does NOT standardize — the only caller deals in positive rects.
    #[must_use]
    pub const fn min_x(&self) -> f64 {
        self.origin.x
    }

    /// Minimum y (`origin.y`). Does NOT standardize.
    #[must_use]
    pub const fn min_y(&self) -> f64 {
        self.origin.y
    }

    /// Maximum x (`origin.x + width`). Does NOT standardize.
    #[must_use]
    pub fn max_x(&self) -> f64 {
        self.origin.x + self.size.width
    }

    /// Maximum y (`origin.y + height`). Does NOT standardize.
    #[must_use]
    pub fn max_y(&self) -> f64 {
        self.origin.y + self.size.height
    }

    /// The area of intersection with `other`, or `0` when they are disjoint. Used by the
    /// multi-monitor screen pick in [`crate::coordinate_mapping`].
    #[must_use]
    pub fn intersection_area(&self, other: &Self) -> f64 {
        // NaN-ignoring IEEE min/max, matching Swift's `Double.maximum`/`.minimum`.
        let ix = 0.0_f64.max(self.max_x().min(other.max_x()) - self.min_x().max(other.min_x()));
        let iy = 0.0_f64.max(self.max_y().min(other.max_y()) - self.min_y().max(other.min_y()));
        ix * iy
    }

    /// Whether this rect OVERLAPS `other` — `CGRect.intersects` for standardised rects.
    ///
    /// Touching edges do not overlap, and an empty rect overlaps nothing, which is what makes this
    /// "can a person reach this window on that display" rather than "is it adjacent to it". The
    /// ordered compares are spelled out instead of routed through
    /// [`intersection_area`](Self::intersection_area): that one uses NaN-ignoring min/max for the
    /// screen pick, where a NaN here must answer "no overlap" the way `CGRect` does.
    #[must_use]
    pub fn intersects(&self, other: &Self) -> bool {
        self.size.width > 0.0
            && self.size.height > 0.0
            && other.size.width > 0.0
            && other.size.height > 0.0
            && self.min_x() < other.max_x()
            && other.min_x() < self.max_x()
            && self.min_y() < other.max_y()
            && other.min_y() < self.max_y()
    }
}

/// How the decoded video is scaled into the on-screen layer (doc 17 §3.7).
///
/// BOTH modes PRESERVE the native aspect ratio — neither stretches. `Fit` letterboxes or
/// pillarboxes so the whole remote window is visible; `Fill` covers the pane with no bars and the
/// overflowing axis cropped by the viewport. Zoom and pan then navigate within either.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum VideoContentMode {
    /// Contain: the whole video sits inside the view, with bars on the longer axis.
    #[default]
    Fit,
    /// Cover: the video fills the view and the longer axis is cropped.
    Fill,
}

/// The rect the displayed video occupies inside a `view_size` layer, preserving the video's native
/// aspect ratio.
///
/// In [`VideoContentMode::Fit`] the rect is CONTAINED in the view (centred, letterbox or
/// pillarbox bars). In [`VideoContentMode::Fill`] it COVERS the view (centred, and it may exceed
/// the view — a negative origin or a size past the view IS the crop). Either way it is the exact
/// region the renderer maps the full texture onto and the region the input encoder's `normalize`
/// inverts, so the two always agree.
///
/// Any non-positive dimension falls back to the full `view_size` rect, so degenerate input is
/// placed sensibly instead of producing a NaN scale.
#[must_use]
pub fn displayed_video_rect(
    view_size: VideoSize,
    video_native_size: VideoSize,
    mode: VideoContentMode,
) -> VideoRect {
    let (vw, vh) = (video_native_size.width, video_native_size.height);
    let (cap_w, cap_h) = (view_size.width, view_size.height);
    if !(vw > 0.0 && vh > 0.0 && cap_w > 0.0 && cap_h > 0.0) {
        return VideoRect::xywh(0.0, 0.0, 0.0_f64.max(cap_w), 0.0_f64.max(cap_h));
    }
    // `Fit` scales to the SMALLER axis ratio (contain), `Fill` to the LARGER (cover). One uniform
    // scale either way, so neither distorts. NaN-ignoring min/max, moot under the guard above but
    // kept faithful.
    let (scale_x, scale_y) = (cap_w / vw, cap_h / vh);
    let scale = match mode {
        VideoContentMode::Fit => scale_x.min(scale_y),
        VideoContentMode::Fill => scale_x.max(scale_y),
    };
    let (w, h) = (vw * scale, vh * scale);
    VideoRect::xywh((cap_w - w) / 2.0, (cap_h - h) / 2.0, w, h)
}

/// FORWARD render transform: where a host-window-space point is drawn in the layer's view space.
///
/// The exact inverse of the input encoder's `normalize`, and of the renderer's aspect-fit plus
/// zoom/pan crop — which is what places the local cursor overlay where clicks actually land
/// (doc 17 §3.3 / §3.7). Three steps:
///
/// 1. host point → source 0..1 (`host_point / video_native_size`).
/// 2. invert the renderer's crop (`uv = (in.uv - 0.5) * inv_zoom + 0.5 + pan`), giving `display_uv
///    = (source_uv - 0.5 - pan) * zoom + 0.5`.
/// 3. `display_uv` → a view point inside the aspect-fit displayed rect.
///
/// Pan is clamped exactly as the renderer clamps it: `pan_limit = 0.5 * (1 - inv_zoom)`.
#[must_use]
pub fn view_point(
    host_point: VideoPoint,
    view_size: VideoSize,
    video_native_size: VideoSize,
    zoom: f64,
    pan: VideoPoint,
    mode: VideoContentMode,
) -> VideoPoint {
    let su = if video_native_size.width > 0.0 {
        host_point.x / video_native_size.width
    } else {
        0.0
    };
    let sv = if video_native_size.height > 0.0 {
        host_point.y / video_native_size.height
    } else {
        0.0
    };
    let z = 1.0_f64.max(zoom);
    let inv_zoom = 1.0 / z;
    // keep mul+add separate — FMA breaks bit-exact golden parity
    let pan_limit = 0.5 * (1.0 - inv_zoom);
    // NaN-ignoring clamp: a NaN pan lands on ±pan_limit, a finite coordinate, rather than poisoning
    // the result the way `Swift.max`/`min` would.
    let px = pan.x.max(-pan_limit).min(pan_limit);
    let py = pan.y.max(-pan_limit).min(pan_limit);
    // keep mul+add separate — FMA breaks bit-exact golden parity
    let du = (su - 0.5 - px) * z + 0.5;
    let dv = (sv - 0.5 - py) * z + 0.5;
    let r = displayed_video_rect(view_size, video_native_size, mode);
    // keep mul+add separate — FMA breaks bit-exact golden parity
    VideoPoint::new(r.origin.x + du * r.size.width, r.origin.y + dv * r.size.height)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "these are pinned bit patterns, so exact equality is the assertion"
    )]

    use super::{VideoContentMode, VideoPoint, VideoRect, VideoSize, displayed_video_rect, view_point};

    #[test]
    fn fit_letterboxes_and_fill_crops_the_same_frame() {
        let view = VideoSize::new(1000.0, 1000.0);
        let video = VideoSize::new(1920.0, 1080.0);

        // `vw * (cap_w / vw)` is not exactly `cap_w` in binary floating point, and deliberately is
        // not "corrected" — the pinned bit patterns are of the multiply, so the tolerance goes here
        // rather than into the function.
        let fit = displayed_video_rect(view, video, VideoContentMode::Fit);
        assert!(
            (fit.size.width - 1000.0).abs() < 1e-9,
            "fit takes the smaller ratio, so width binds"
        );
        assert!(fit.origin.x.abs() < 1e-9);
        assert!(
            fit.size.height < 1000.0 && fit.origin.y > 0.0,
            "bars top and bottom"
        );

        let fill = displayed_video_rect(view, video, VideoContentMode::Fill);
        assert!(
            (fill.size.height - 1000.0).abs() < 1e-9,
            "fill takes the larger ratio, so height binds"
        );
        assert!(
            fill.size.width > 1000.0 && fill.origin.x < 0.0,
            "the crop is the overflow"
        );
    }

    #[test]
    fn both_modes_preserve_the_aspect_ratio() {
        let view = VideoSize::new(640.0, 999.0);
        let video = VideoSize::new(1920.0, 1080.0);
        for mode in [VideoContentMode::Fit, VideoContentMode::Fill] {
            let r = displayed_video_rect(view, video, mode);
            let ratio = r.size.width / r.size.height;
            assert!(
                (ratio - 1920.0 / 1080.0).abs() < 1e-12,
                "{mode:?} distorted the frame"
            );
        }
    }

    #[test]
    fn a_degenerate_size_falls_back_to_the_view_rather_than_dividing_by_zero() {
        let view = VideoSize::new(800.0, 600.0);
        for video in [
            VideoSize::new(0.0, 1080.0),
            VideoSize::new(1920.0, 0.0),
            VideoSize::new(-1.0, -1.0),
        ] {
            assert_eq!(
                displayed_video_rect(view, video, VideoContentMode::Fit),
                VideoRect::xywh(0.0, 0.0, 800.0, 600.0)
            );
        }
        assert_eq!(
            displayed_video_rect(
                VideoSize::new(-5.0, -5.0),
                VideoSize::new(16.0, 9.0),
                VideoContentMode::Fit
            ),
            VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
            "a negative view floors at zero rather than going negative"
        );
    }

    #[test]
    fn at_zoom_one_the_view_point_is_just_the_aspect_fit_placement() {
        let view = VideoSize::new(1000.0, 1000.0);
        let video = VideoSize::new(1920.0, 1080.0);
        let rect = displayed_video_rect(view, video, VideoContentMode::Fit);
        let centre = view_point(
            VideoPoint::new(960.0, 540.0),
            view,
            video,
            1.0,
            VideoPoint::new(0.0, 0.0),
            VideoContentMode::Fit,
        );
        assert_eq!(centre.x, rect.origin.x + rect.size.width / 2.0);
        assert_eq!(centre.y, rect.origin.y + rect.size.height / 2.0);
    }

    #[test]
    fn zoom_below_one_is_floored_rather_than_inverting_the_transform() {
        let view = VideoSize::new(800.0, 600.0);
        let video = VideoSize::new(800.0, 600.0);
        let at_one = view_point(
            VideoPoint::new(200.0, 100.0),
            view,
            video,
            1.0,
            VideoPoint::new(0.0, 0.0),
            VideoContentMode::Fit,
        );
        let at_half = view_point(
            VideoPoint::new(200.0, 100.0),
            view,
            video,
            0.5,
            VideoPoint::new(0.0, 0.0),
            VideoContentMode::Fit,
        );
        assert_eq!(at_one, at_half);
    }

    #[test]
    fn a_nan_pan_clamps_to_a_finite_limit_instead_of_poisoning_the_point() {
        // This is the whole reason the clamp is `f64::max`/`min` and not a comparison: a NaN pan off
        // the wire must land the cursor somewhere, not paint NaN into a CALayer frame.
        let out = view_point(
            VideoPoint::new(100.0, 100.0),
            VideoSize::new(800.0, 600.0),
            VideoSize::new(800.0, 600.0),
            2.0,
            VideoPoint::new(f64::NAN, f64::NAN),
            VideoContentMode::Fit,
        );
        assert!(out.x.is_finite() && out.y.is_finite(), "got {out:?}");
    }

    #[test]
    fn the_pan_clamp_stops_at_the_renderer_limit() {
        let view = VideoSize::new(800.0, 800.0);
        let video = VideoSize::new(800.0, 800.0);
        let point = VideoPoint::new(400.0, 400.0);
        // At zoom 2 the limit is 0.5 * (1 - 0.5) = 0.25, so a pan of 10 clamps to the same place.
        let at_limit = view_point(
            point,
            view,
            video,
            2.0,
            VideoPoint::new(0.25, 0.25),
            VideoContentMode::Fit,
        );
        let past_limit = view_point(
            point,
            view,
            video,
            2.0,
            VideoPoint::new(10.0, 10.0),
            VideoContentMode::Fit,
        );
        assert_eq!(at_limit, past_limit);
    }

    #[test]
    fn intersection_area_is_zero_when_disjoint_and_the_overlap_otherwise() {
        let a = VideoRect::xywh(0.0, 0.0, 100.0, 100.0);
        assert_eq!(
            a.intersection_area(&VideoRect::xywh(200.0, 200.0, 10.0, 10.0)),
            0.0
        );
        assert_eq!(
            a.intersection_area(&VideoRect::xywh(100.0, 0.0, 10.0, 10.0)),
            0.0,
            "edge-touching"
        );
        assert_eq!(
            a.intersection_area(&VideoRect::xywh(50.0, 50.0, 100.0, 100.0)),
            2500.0
        );
        assert_eq!(a.intersection_area(&a), 10_000.0);
    }

    #[test]
    fn touching_is_not_overlapping_and_empty_overlaps_nothing() {
        let a = VideoRect::xywh(0.0, 0.0, 100.0, 100.0);
        assert!(a.intersects(&VideoRect::xywh(50.0, 50.0, 100.0, 100.0)));
        assert!(
            !a.intersects(&VideoRect::xywh(100.0, 0.0, 10.0, 10.0)),
            "edge-touching"
        );
        assert!(!a.intersects(&VideoRect::xywh(200.0, 200.0, 10.0, 10.0)));
        assert!(
            !a.intersects(&VideoRect::xywh(50.0, 50.0, 0.0, 10.0)),
            "a zero-width rect is nowhere"
        );
    }
}
