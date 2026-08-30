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

    /// The rect `CGRectNull` is: an INFINITE origin and a zero extent.
    ///
    /// It is not "empty" and not "zero" — those are ordinary rects that happen to enclose nothing.
    /// `CGRectIntersection` answers this and only this when two rects are disjoint, so a caller can
    /// tell "they miss each other" from "they meet along an edge", which is a real distinction for
    /// the capture region: an edge touch is a zero-area overlap, a miss is no overlap at all.
    pub const NULL: Self = Self::xywh(f64::INFINITY, f64::INFINITY, 0.0, 0.0);

    /// Whether this is [`NULL`](Self::NULL) — `CGRectIsNull`.
    ///
    /// Probe-verified against CoreGraphics: a POSITIVE infinity in EITHER origin field is null; a
    /// negative infinity is not, and neither is a NaN anywhere. That is narrower than "not finite"
    /// and the difference is load-bearing, since a NaN rect must flow through the same arithmetic
    /// a NaN flows through everywhere else rather than short-circuiting to a sentinel.
    #[must_use]
    pub fn is_null(&self) -> bool {
        self.origin.x == f64::INFINITY || self.origin.y == f64::INFINITY
    }

    /// The rect with a non-negative extent — `CGRectStandardize`. A negative width moves the origin
    /// left by that much and flips the sign; likewise for height. NaN and infinity pass through,
    /// because `< 0.0` is false for both and the framework does not test them either.
    #[must_use]
    pub fn standardized(&self) -> Self {
        let (x, width) = if self.size.width < 0.0 {
            (self.origin.x + self.size.width, -self.size.width)
        } else {
            (self.origin.x, self.size.width)
        };
        let (y, height) = if self.size.height < 0.0 {
            (self.origin.y + self.size.height, -self.size.height)
        } else {
            (self.origin.y, self.size.height)
        };
        Self::xywh(x, y, width, height)
    }

    /// The STANDARDISED width — what `CGRect.width` answers, never the raw `size.width` field.
    ///
    /// Swift spells the raw field `size.width` and the standardised extent `.width`, and the host
    /// geometry deciders read the second everywhere. Naming them apart here is what keeps a port
    /// from silently squaring a negative extent into a positive area.
    #[must_use]
    pub fn width(&self) -> f64 {
        self.standardized().size.width
    }

    /// The STANDARDISED height — `CGRect.height`. See [`width`](Self::width).
    #[must_use]
    pub fn height(&self) -> f64 {
        self.standardized().size.height
    }

    /// The horizontal centre — `CGRect.midX`, over the standardised rect.
    #[must_use]
    pub fn mid_x(&self) -> f64 {
        let rect = self.standardized();
        rect.origin.x + rect.size.width / 2.0
    }

    /// The vertical centre — `CGRect.midY`.
    #[must_use]
    pub fn mid_y(&self) -> f64 {
        let rect = self.standardized();
        rect.origin.y + rect.size.height / 2.0
    }

    /// The overlap with `other`, or [`NULL`](Self::NULL) when they are disjoint —
    /// `CGRectIntersection`.
    ///
    /// Probe-verified against CoreGraphics, and every clause below is one of the answers it gave:
    /// the disjoint test is STRICT, so two rects meeting along an edge answer a real zero-EXTENT
    /// rect at the seam rather than null; the corner picks are NaN-IGNORING (`fmax`/`fmin`, which
    /// is Rust's `f64::max`/`min` and Swift's `Double.maximum`/`.minimum`), so a rect with a NaN
    /// coordinate resolves to the other one instead of poisoning the result.
    #[must_use]
    pub fn intersection(&self, other: &Self) -> Self {
        if self.is_null() || other.is_null() {
            return Self::NULL;
        }
        let (first, second) = (self.standardized(), other.standardized());
        if first.max_x() < second.min_x()
            || second.max_x() < first.min_x()
            || first.max_y() < second.min_y()
            || second.max_y() < first.min_y()
        {
            return Self::NULL;
        }
        let x = first.min_x().max(second.min_x());
        let y = first.min_y().max(second.min_y());
        Self::xywh(
            x,
            y,
            first.max_x().min(second.max_x()) - x,
            first.max_y().min(second.max_y()) - y,
        )
    }

    /// The smallest rect enclosing both — `CGRectUnion`.
    ///
    /// A null rect is the identity and the ONLY special case: an empty-but-real rect still
    /// contributes its corner, so `(100,100,0,0) ∪ (0,0,10,10)` is `(0,0,100,100)` and not
    /// `(0,0,10,10)`. Probe-verified; a port that "helpfully" skipped empty rects would shrink
    /// every capture region that ever saw a zero-size window.
    #[must_use]
    pub fn union(&self, other: &Self) -> Self {
        if self.is_null() {
            return other.standardized();
        }
        if other.is_null() {
            return self.standardized();
        }
        let (first, second) = (self.standardized(), other.standardized());
        let x = first.min_x().min(second.min_x());
        let y = first.min_y().min(second.min_y());
        Self::xywh(
            x,
            y,
            first.max_x().max(second.max_x()) - x,
            first.max_y().max(second.max_y()) - y,
        )
    }

    /// Whether `point` is inside — `CGRectContainsPoint`. The minimum edges are INCLUSIVE and the
    /// maximum edges are not, so adjacent displays cannot both claim the pixel on their seam.
    ///
    /// Needs no null or empty special case: `NULL`'s infinite origin fails the first compare, an
    /// empty rect's `x < max_x` fails on its own, and a NaN coordinate fails every one of them.
    #[must_use]
    pub fn contains_point(&self, point: VideoPoint) -> bool {
        let rect = self.standardized();
        point.x >= rect.min_x() && point.x < rect.max_x() && point.y >= rect.min_y() && point.y < rect.max_y()
    }

    /// Whether `other` lies wholly inside — `CGRectContainsRect`.
    ///
    /// Both max edges are INCLUSIVE here, unlike [`contains_point`](Self::contains_point): a rect
    /// flush with this one's right edge is contained, while the point ON that edge is not. That
    /// asymmetry is CoreGraphics's, probe-verified, and so is the one special case — a null rect is
    /// contained by everything, including by another null rect.
    #[must_use]
    pub fn contains_rect(&self, other: &Self) -> bool {
        if other.is_null() {
            return true;
        }
        let (outer, inner) = (self.standardized(), other.standardized());
        inner.min_x() >= outer.min_x()
            && inner.max_x() <= outer.max_x()
            && inner.min_y() >= outer.min_y()
            && inner.max_y() <= outer.max_y()
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
        // This is the whole reason the clamp is `f64::max`/`min` and not a comparison: a NaN pan
        // off the wire must land the cursor somewhere, not paint NaN into a CALayer frame.
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

    // ---- The `CGRect` algebra ------------------------------------------------------------------
    //
    // Every expectation below was READ OFF CoreGraphics by a probe rather than reasoned about: a
    // Swift program built each case, printed the answer as raw `f64` bit patterns, and those are
    // the numbers asserted here. The cases are exactly the ones where a plausible reimplementation
    // and the framework part company — an edge touch, a NaN coordinate, a negative extent, an
    // empty-but-real rect in a union, a null on either side — so this is the differential suite
    // that `capture_region` and `window_list` stand on.

    #[test]
    fn only_a_positive_infinity_in_the_origin_reads_as_null() {
        assert!(VideoRect::NULL.is_null());
        assert!(VideoRect::xywh(f64::INFINITY, 2.0, 3.0, 4.0).is_null());
        assert!(VideoRect::xywh(1.0, f64::INFINITY, 3.0, 4.0).is_null());
        assert!(
            !VideoRect::xywh(f64::NEG_INFINITY, 2.0, 3.0, 4.0).is_null(),
            "a negative infinity is a real, very distant rect"
        );
        assert!(!VideoRect::xywh(f64::NAN, 2.0, 3.0, 4.0).is_null());
        assert!(!VideoRect::xywh(1.0, 2.0, f64::INFINITY, 4.0).is_null());
        assert!(
            !VideoRect::xywh(1.0, 2.0, 0.0, 0.0).is_null(),
            "a zero rect encloses nothing but is not the null rect"
        );
    }

    #[test]
    fn a_negative_extent_moves_the_origin_rather_than_being_read_as_zero() {
        let flipped = VideoRect::xywh(10.0, 10.0, -10.0, -6.0);
        assert_eq!(flipped.standardized(), VideoRect::xywh(0.0, 4.0, 10.0, 6.0));
        assert_eq!(flipped.width(), 10.0);
        assert_eq!(flipped.height(), 6.0);
        assert_eq!(flipped.mid_x(), 5.0);
        assert_eq!(flipped.mid_y(), 7.0);
    }

    #[test]
    fn an_edge_touch_intersects_at_the_seam_while_a_miss_answers_null() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        assert_eq!(
            a.intersection(&VideoRect::xywh(5.0, 5.0, 10.0, 10.0)),
            VideoRect::xywh(5.0, 5.0, 5.0, 5.0)
        );
        assert_eq!(
            a.intersection(&VideoRect::xywh(20.0, 20.0, 10.0, 10.0)),
            VideoRect::NULL
        );
        assert_eq!(
            a.intersection(&VideoRect::xywh(10.0, 0.0, 10.0, 10.0)),
            VideoRect::xywh(10.0, 0.0, 0.0, 10.0),
            "an edge touch is a zero-WIDTH overlap, not a miss"
        );
        assert_eq!(
            a.intersection(&VideoRect::xywh(10.0, 10.0, 10.0, 10.0)),
            VideoRect::xywh(10.0, 10.0, 0.0, 0.0),
            "and a corner touch is a zero-AREA one"
        );
        assert_eq!(
            VideoRect::xywh(0.0, 0.0, 0.0, 0.0).intersection(&a),
            VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
            "a zero rect ON the other still meets it"
        );
        assert_eq!(
            VideoRect::xywh(120.0, 120.0, 700.0, 500.0).intersection(&VideoRect::xywh(0.0, 0.0, 0.0, 0.0)),
            VideoRect::NULL,
            "a zero rect ELSEWHERE does not — this is the zero-area-display vector"
        );
        assert_eq!(
            VideoRect::xywh(10.0, 10.0, -10.0, -10.0).intersection(&VideoRect::xywh(5.0, 5.0, 10.0, 10.0)),
            VideoRect::xywh(5.0, 5.0, 5.0, 5.0),
            "both sides standardise first"
        );
        assert_eq!(
            VideoRect::NULL.intersection(&a),
            VideoRect::NULL,
            "null is absorbing"
        );
    }

    #[test]
    fn a_nan_coordinate_resolves_to_the_other_rect_instead_of_poisoning_it() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        assert_eq!(
            VideoRect::xywh(f64::NAN, 0.0, 10.0, 10.0).intersection(&a),
            a,
            "the corner picks ignore NaN, the way fmax/fmin do"
        );
        assert_eq!(VideoRect::xywh(0.0, 0.0, f64::NAN, 10.0).intersection(&a), a);
        assert_eq!(VideoRect::xywh(f64::NAN, 0.0, 10.0, 10.0).union(&a), a);
    }

    #[test]
    fn an_empty_rect_still_contributes_its_corner_to_a_union() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        assert_eq!(
            a.union(&VideoRect::xywh(5.0, 5.0, 10.0, 10.0)),
            VideoRect::xywh(0.0, 0.0, 15.0, 15.0)
        );
        assert_eq!(
            VideoRect::xywh(100.0, 100.0, 0.0, 0.0).union(&a),
            VideoRect::xywh(0.0, 0.0, 100.0, 100.0),
            "the empty rect is a POINT in the bounding box, never skipped"
        );
        assert_eq!(
            VideoRect::xywh(100.0, 100.0, 0.0, 0.0).union(&VideoRect::xywh(3.0, 3.0, 0.0, 0.0)),
            VideoRect::xywh(3.0, 3.0, 97.0, 97.0),
            "even when both are empty"
        );
        assert_eq!(VideoRect::NULL.union(&a), a, "null is the identity");
        assert_eq!(a.union(&VideoRect::NULL), a);
        assert_eq!(
            VideoRect::xywh(10.0, 10.0, -10.0, -10.0).union(&VideoRect::xywh(5.0, 5.0, 10.0, 10.0)),
            VideoRect::xywh(0.0, 0.0, 15.0, 15.0)
        );
    }

    #[test]
    fn a_point_belongs_to_the_display_whose_minimum_edge_it_is_on() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        assert!(a.contains_point(VideoPoint::new(5.0, 5.0)));
        assert!(a.contains_point(VideoPoint::new(0.0, 0.0)), "min edge inclusive");
        assert!(
            !a.contains_point(VideoPoint::new(10.0, 5.0)),
            "max edge exclusive, so two abutting displays never both claim the seam"
        );
        assert!(!a.contains_point(VideoPoint::new(-1.0, 5.0)));
        assert!(!a.contains_point(VideoPoint::new(f64::NAN, 5.0)));
        assert!(!VideoRect::xywh(0.0, 0.0, 0.0, 0.0).contains_point(VideoPoint::new(0.0, 0.0)));
        assert!(!VideoRect::NULL.contains_point(VideoPoint::new(0.0, 0.0)));
        assert!(
            VideoRect::xywh(10.0, 10.0, -10.0, -10.0).contains_point(VideoPoint::new(5.0, 5.0)),
            "standardised first"
        );
    }

    #[test]
    fn a_rect_flush_with_the_outer_edge_is_contained_though_the_point_on_it_is_not() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        assert!(a.contains_rect(&VideoRect::xywh(2.0, 2.0, 3.0, 3.0)));
        assert!(a.contains_rect(&a));
        assert!(
            a.contains_rect(&VideoRect::xywh(5.0, 5.0, 5.0, 5.0)),
            "flush with the max edge — inclusive here, unlike contains_point"
        );
        assert!(!a.contains_rect(&VideoRect::xywh(2.0, 2.0, 30.0, 3.0)));
        assert!(a.contains_rect(&VideoRect::xywh(2.0, 2.0, 0.0, 0.0)));
        assert!(!a.contains_rect(&VideoRect::xywh(20.0, 2.0, 0.0, 0.0)));
        assert!(a.contains_rect(&VideoRect::NULL), "null is contained by all");
        assert!(!VideoRect::NULL.contains_rect(&a));
        assert!(!a.contains_rect(&VideoRect::xywh(f64::NAN, 2.0, 3.0, 3.0)));
    }
}
