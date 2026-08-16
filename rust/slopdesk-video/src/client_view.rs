//! The pane's geometry decisions: what scale the cursor rides, when a resize is adopted, and when
//! the pane snaps to the stream.
//!
//! Every one of them is arithmetic the renderer and the input path must AGREE on, which is why they
//! live together and away from any layer: the gate, the clamp and the layout each key off the same
//! displayed size, and the inverse of the render transform is written beside the forward one.

use crate::geometry::{VideoPoint, VideoSize};

/// Whether the displayed content extends past the pane on some axis, with a point of slack.
///
/// It keys off the window times the zoom — the DISPLAYED size, which is the frame the compositor
/// actually lays out. Keying off the un-zoomed size instead makes a zoomed-in window's overflow
/// unreachable, because edge-pan is the only in-pane way to reach it.
#[must_use]
pub fn is_navigable(window: VideoSize, pane: VideoSize, zoom: f64) -> bool {
    window.width * zoom > pane.width + 1.0 || window.height * zoom > pane.height + 1.0
}

/// The maximum pan offset per axis, in display points from the top-left.
///
/// The displayed size less the pane, floored at zero. Identical basis to the navigability gate and
/// to the layer's own frame clamp, so the gate, the pan step and the layer position can never
/// disagree about where the content ends.
#[must_use]
pub fn max_pan_offset(window: VideoSize, pane: VideoSize, zoom: f64) -> VideoPoint {
    VideoPoint {
        x: 0.0_f64.max(window.width * zoom - pane.width),
        y: 0.0_f64.max(window.height * zoom - pane.height),
    }
}

/// The single uniform scale relating the host window to the on-screen layer: client view points per
/// host window point.
///
/// The cursor is reported in host WINDOW points and the capture size is in the SAME points, because
/// the host clamps the viewport to the window's point size — so one ratio maps between them. It
/// keys on the WIDTH, since capture preserves aspect and width is the stable axis. A degenerate
/// frame answers one, so the cursor is still placed somewhere sensible.
#[must_use]
pub fn video_scale(layer_size: VideoSize, decoded_size: VideoSize) -> f64 {
    if decoded_size.width > 0.0 {
        layer_size.width / decoded_size.width
    } else {
        1.0
    }
}

/// Pre-decode triage for a reassembled frame.
///
/// A zero-byte frame must never reach the decoder as an empty sample buffer: the decode fails, and
/// the hard-failure recovery tears the live decompression session down and forces a full keyframe
/// round-trip — a visible stall, paid for what is really a corrupt fragment or a host bug.
/// Classifying up front costs nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameDecodability {
    /// Non-empty: submit it.
    Decodable,
    /// An empty DELTA — drop it without touching the decoder. One empty delta does not warrant a
    /// re-anchor, and the reassembler's loss recovery covers a genuine gap.
    DropSilently,
    /// An empty KEYFRAME — ask the host for a fresh one, but do NOT invalidate an otherwise healthy
    /// session.
    RequestKeyframe,
}

impl FrameDecodability {
    /// Triages a frame by its keyframe flag and its reassembled byte count.
    #[must_use]
    pub const fn classify(keyframe: bool, byte_count: usize) -> Self {
        if byte_count > 0 {
            Self::Decodable
        } else if keyframe {
            Self::RequestKeyframe
        } else {
            Self::DropSilently
        }
    }
}

/// How close two aspect ratios must be to count as the same one.
pub const ASPECT_EPSILON: f64 = 0.02;

/// Whether a just-decoded buffer is the genuinely NEW size, rather than an in-flight old-size frame
/// queued behind the resize acknowledgement.
///
/// Adopting early would briefly mis-scale the cursor and the video scale, so there are two gates
/// and both are required. The ASPECT gate catches the common freeform drag, where the resize
/// changed the shape. The MAGNITUDE gate catches a proportional resize, where the aspect gate alone
/// would adopt on the first identical-aspect old frame: the client cannot exact-match pixels to
/// points, having no capture scale of its own, but the first genuinely new frame is the first whose
/// dimensions differ from the steady old ones.
///
/// One residual, known and accepted: a rapid double-resize WITHIN the in-flight window can adopt on
/// an intermediate size, since both gates pass for it. It is rare and heals on the next keyframe.
#[must_use]
pub fn should_adopt_resize(
    pending: VideoSize,
    decoded: VideoSize,
    previous_decoded: Option<VideoSize>,
) -> bool {
    if pending.width <= 0.0 || pending.height <= 0.0 || decoded.width <= 0.0 || decoded.height <= 0.0 {
        return false;
    }
    let aspect_matches =
        (pending.width / pending.height - decoded.width / decoded.height).abs() < ASPECT_EPSILON;
    let size_changed = previous_decoded.is_none_or(|previous| {
        (decoded.width - previous.width).abs() >= 1.0 || (decoded.height - previous.height).abs() >= 1.0
    });
    aspect_matches && size_changed
}

/// What the debounce decided for one layer-size sample.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ResizeDecision {
    /// The size settled and differs enough: emit a resize request for it.
    Request(VideoSize),
    /// Still mid-burst, or the settled size is inside the jitter band.
    Hold,
}

/// The client-side debounce for an in-session resize.
///
/// The view fires a layout callback on EVERY frame of a live window drag, but capture should
/// re-size once per SETTLED size: a flood of requests mid-drag would thrash the host's window
/// resize and its capture reconfigure, and pump epochs for nothing. This coalesces a burst to the
/// size the surface settles on. No timer and no clock — the caller passes the layer size and how
/// long it has been unchanged, the same discipline every other timing policy here uses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResizeDebounce {
    last_requested: Option<VideoSize>,
    last_epoch: u32,
    min_delta: f64,
    settle_interval: f64,
}

impl Default for ResizeDebounce {
    fn default() -> Self {
        Self::new(8.0, 0.2)
    }
}

impl ResizeDebounce {
    /// A debounce with the given jitter band and settle interval.
    #[must_use]
    pub const fn new(min_delta: f64, settle_interval: f64) -> Self {
        Self {
            last_requested: None,
            last_epoch: 0,
            min_delta,
            settle_interval,
        }
    }

    /// A debounce rebuilt from state that was carried elsewhere and handed back.
    ///
    /// Four fields, all of them answered by the getters below, so a caller that holds the debounce
    /// by value — the Swift view struct across the FFI boundary — hands the whole thing in on every
    /// call rather than owning an allocation here. Replaying the epoch through
    /// [`Self::note_requested`] would be a loop over a counter that only ever grows.
    #[must_use]
    pub const fn restored(
        last_requested: Option<VideoSize>,
        last_epoch: u32,
        min_delta: f64,
        settle_interval: f64,
    ) -> Self {
        Self {
            last_requested,
            last_epoch,
            min_delta,
            settle_interval,
        }
    }

    /// The size of the last request actually emitted, or nothing while still at the negotiated one.
    #[must_use]
    pub const fn last_requested(&self) -> Option<VideoSize> {
        self.last_requested
    }

    /// The per-axis jitter band, in points.
    #[must_use]
    pub const fn min_delta(&self) -> f64 {
        self.min_delta
    }

    /// How long the layer must be unchanged before a burst counts as settled, in seconds.
    #[must_use]
    pub const fn settle_interval(&self) -> f64 {
        self.settle_interval
    }

    /// The epoch of the last emitted request. Zero means none has been emitted.
    #[must_use]
    pub const fn last_epoch(&self) -> u32 {
        self.last_epoch
    }

    /// The decision for one layer-size sample. A pure query: acting on a request means calling
    /// [`Self::note_requested`] afterward.
    #[must_use]
    pub fn decide(&self, layer_size: VideoSize, elapsed_since_last_change: f64) -> ResizeDecision {
        if elapsed_since_last_change < self.settle_interval {
            // Changed too recently to be the final size — coalesce.
            return ResizeDecision::Hold;
        }
        if self.changed_enough(layer_size) {
            ResizeDecision::Request(layer_size)
        } else {
            ResizeDecision::Hold
        }
    }

    /// Records that a request went out: it becomes the new baseline, and the epoch advances.
    /// Returns the epoch the emitted request must carry.
    pub const fn note_requested(&mut self, size: VideoSize) -> u32 {
        self.last_requested = Some(size);
        self.last_epoch = self.last_epoch.wrapping_add(1);
        self.last_epoch
    }

    /// Rebases the jitter baseline on a size the CLIENT adopted by itself — the pane snapping to
    /// the stream, with nothing sent to the host — WITHOUT minting an epoch.
    ///
    /// The snap's own layout pass then decides to hold, because the delta against this baseline is
    /// zero. Without it the snap would echo a resize request back, which would resize the host
    /// window and re-trigger the snap: a feedback loop. A later user drag still differs by more
    /// than the jitter band and requests normally.
    pub const fn note_adopted(&mut self, size: VideoSize) {
        self.last_requested = Some(size);
    }

    /// Whether a size differs from the baseline by at least the jitter band on some axis. No
    /// baseline always counts as changed, so the first settle always fires.
    fn changed_enough(&self, to: VideoSize) -> bool {
        self.last_requested.is_none_or(|from| {
            (to.width - from.width).abs() >= self.min_delta
                || (to.height - from.height).abs() >= self.min_delta
        })
    }
}

/// The default slack below which a snap is layout noise rather than a real difference.
pub const SNAP_EPSILON: f64 = 0.5;

/// The layer point size at which the decoded stream renders one-to-one.
///
/// The scale here must be the HOST's capture scale, NOT the client's contents scale. The latter is
/// only correct when the host happens to capture at the client's scale. With no virtual display the
/// host captures at one while a Retina client is at two, so dividing by the client's scale would
/// HALVE the pane on every resize cycle and the panes would keep shrinking. A non-positive scale
/// falls back to one.
#[must_use]
pub fn snap_target_points(pixel_size: VideoSize, capture_scale: f64) -> VideoSize {
    let scale = if capture_scale > 0.0 { capture_scale } else { 1.0 };
    VideoSize::new(pixel_size.width / scale, pixel_size.height / scale)
}

/// The host capture scale inferred from the first decoded frame: decoded pixels per negotiated
/// window point.
///
/// It is not on the wire but is CONSTANT for a session — the host captures at a fixed scale and
/// only the window's points change on a resize — so the client infers it once and reuses it for
/// every later in-session resize. A degenerate input falls back to one, which the acknowledgement's
/// real size makes unreachable in practice.
#[must_use]
pub fn inferred_capture_scale(decoded_pixels: VideoSize, window_points: VideoSize) -> f64 {
    if window_points.width > 0.0 && decoded_pixels.width > 0.0 {
        decoded_pixels.width / window_points.width
    } else {
        1.0
    }
}

/// Whether the pane should snap.
///
/// The one-to-one target must differ from the current layer size by at least the epsilon on some
/// axis. Sub-epsilon deltas are layout noise, and snapping on them would churn the canvas frame and
/// its persistence for an invisible change.
#[must_use]
pub fn should_snap(target: VideoSize, current: VideoSize, epsilon: f64) -> bool {
    (target.width - current.width).abs() >= epsilon || (target.height - current.height).abs() >= epsilon
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the sizes and scales are exact small values compared against their own constants"
    )]

    use super::{
        FrameDecodability, ResizeDebounce, ResizeDecision, SNAP_EPSILON, inferred_capture_scale,
        is_navigable, max_pan_offset, should_adopt_resize, should_snap, snap_target_points, video_scale,
    };
    use crate::geometry::VideoSize;

    #[test]
    fn the_navigability_gate_reads_the_zoomed_size_rather_than_the_native_one() {
        let window = VideoSize::new(800.0, 600.0);
        let pane = VideoSize::new(1000.0, 800.0);
        assert!(!is_navigable(window, pane, 1.0), "it fits at native size");
        assert!(
            is_navigable(window, pane, 2.0),
            "zoomed in, the overflow must be reachable"
        );
    }

    #[test]
    fn the_pan_clamp_stops_where_the_displayed_content_ends() {
        let window = VideoSize::new(800.0, 600.0);
        let pane = VideoSize::new(1000.0, 400.0);
        let offset = max_pan_offset(window, pane, 2.0);
        assert_eq!(offset.x, 600.0);
        assert_eq!(offset.y, 800.0);
        let none = max_pan_offset(window, pane, 0.5);
        assert_eq!(none.x, 0.0, "content inside the pane never pans");
        assert_eq!(none.y, 0.0);
    }

    #[test]
    fn the_video_scale_keys_on_the_stable_axis_and_survives_a_degenerate_frame() {
        assert_eq!(
            video_scale(VideoSize::new(600.0, 400.0), VideoSize::new(1200.0, 800.0)),
            0.5,
        );
        assert_eq!(
            video_scale(VideoSize::new(600.0, 400.0), VideoSize::new(0.0, 0.0)),
            1.0,
            "the cursor still has to land somewhere sensible",
        );
    }

    #[test]
    fn an_empty_keyframe_asks_for_another_where_an_empty_delta_is_just_dropped() {
        assert_eq!(
            FrameDecodability::classify(true, 900),
            FrameDecodability::Decodable
        );
        assert_eq!(
            FrameDecodability::classify(false, 900),
            FrameDecodability::Decodable
        );
        assert_eq!(
            FrameDecodability::classify(true, 0),
            FrameDecodability::RequestKeyframe,
            "but the session itself is still healthy",
        );
        assert_eq!(
            FrameDecodability::classify(false, 0),
            FrameDecodability::DropSilently,
            "one empty delta does not warrant a re-anchor",
        );
    }

    #[test]
    fn a_freeform_drag_is_adopted_on_the_first_frame_of_the_new_shape() {
        let pending = VideoSize::new(1000.0, 500.0);
        let old = VideoSize::new(1600.0, 1200.0);
        assert!(
            !should_adopt_resize(pending, old, Some(old)),
            "an in-flight old-size frame must not trip adoption",
        );
        assert!(should_adopt_resize(
            pending,
            VideoSize::new(2000.0, 1000.0),
            Some(old)
        ));
    }

    #[test]
    fn a_proportional_resize_needs_the_magnitude_gate_to_reject_the_old_frame() {
        let pending = VideoSize::new(800.0, 600.0);
        let old = VideoSize::new(1600.0, 1200.0);
        assert!(
            !should_adopt_resize(pending, old, Some(old)),
            "the aspect alone would have adopted here",
        );
        assert!(should_adopt_resize(
            pending,
            VideoSize::new(1200.0, 900.0),
            Some(old)
        ));
    }

    #[test]
    fn the_first_frame_of_a_session_has_nothing_to_compare_against() {
        let pending = VideoSize::new(800.0, 600.0);
        assert!(should_adopt_resize(pending, VideoSize::new(1600.0, 1200.0), None));
        assert!(!should_adopt_resize(pending, VideoSize::new(0.0, 0.0), None));
        assert!(!should_adopt_resize(VideoSize::new(0.0, 0.0), pending, None));
    }

    #[test]
    fn a_live_drag_coalesces_to_the_size_it_settles_on() {
        let debounce = ResizeDebounce::default();
        let mid_drag = VideoSize::new(900.0, 700.0);
        assert_eq!(debounce.decide(mid_drag, 0.05), ResizeDecision::Hold);
        assert_eq!(debounce.decide(mid_drag, 0.2), ResizeDecision::Request(mid_drag));
    }

    #[test]
    fn a_settled_size_inside_the_jitter_band_never_re_requests() {
        let mut debounce = ResizeDebounce::default();
        let settled = VideoSize::new(900.0, 700.0);
        assert_eq!(debounce.note_requested(settled), 1);
        assert_eq!(
            debounce.decide(VideoSize::new(903.0, 702.0), 1.0),
            ResizeDecision::Hold
        );
        let real = VideoSize::new(950.0, 700.0);
        assert_eq!(debounce.decide(real, 1.0), ResizeDecision::Request(real));
        assert_eq!(
            debounce.note_requested(real),
            2,
            "each request carries a fresh epoch"
        );
        assert_eq!(debounce.last_requested(), Some(real));
    }

    #[test]
    fn a_client_side_snap_rebases_the_baseline_without_minting_an_epoch() {
        let mut debounce = ResizeDebounce::default();
        let snapped = VideoSize::new(1200.0, 800.0);
        debounce.note_adopted(snapped);
        assert_eq!(
            debounce.last_epoch(),
            0,
            "nothing was sent, so nothing is owed an epoch"
        );
        assert_eq!(
            debounce.decide(snapped, 1.0),
            ResizeDecision::Hold,
            "echoing the snap back would resize the host window and re-trigger the snap",
        );
        let dragged = VideoSize::new(1400.0, 800.0);
        assert_eq!(debounce.decide(dragged, 1.0), ResizeDecision::Request(dragged));
    }

    #[test]
    fn the_snap_target_divides_by_the_hosts_scale_so_the_loop_has_gain_one() {
        let pixels = VideoSize::new(2400.0, 1600.0);
        assert_eq!(snap_target_points(pixels, 2.0), VideoSize::new(1200.0, 800.0));
        assert_eq!(
            snap_target_points(pixels, 1.0),
            VideoSize::new(2400.0, 1600.0),
            "a one-times host capture is the case that halving would have shrunk forever",
        );
        assert_eq!(snap_target_points(pixels, 0.0), VideoSize::new(2400.0, 1600.0));
    }

    #[test]
    fn the_capture_scale_is_inferred_once_from_the_first_frame() {
        assert_eq!(
            inferred_capture_scale(VideoSize::new(2400.0, 1600.0), VideoSize::new(1200.0, 800.0)),
            2.0,
        );
        assert_eq!(
            inferred_capture_scale(VideoSize::new(1200.0, 800.0), VideoSize::new(1200.0, 800.0)),
            1.0,
        );
        assert_eq!(
            inferred_capture_scale(VideoSize::new(0.0, 0.0), VideoSize::new(1200.0, 800.0)),
            1.0,
        );
        assert_eq!(
            inferred_capture_scale(VideoSize::new(2400.0, 1600.0), VideoSize::new(0.0, 0.0)),
            1.0,
        );
    }

    #[test]
    fn sub_epsilon_layout_noise_never_churns_the_canvas() {
        let target = VideoSize::new(1200.0, 800.0);
        assert!(!should_snap(target, VideoSize::new(1200.2, 800.1), SNAP_EPSILON));
        assert!(should_snap(target, VideoSize::new(1200.0, 799.0), SNAP_EPSILON));
        assert!(should_snap(target, VideoSize::new(1000.0, 800.0), SNAP_EPSILON));
    }
}
